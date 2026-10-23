#!/usr/bin/env python3
"""Record Opus RTP from MediaMTX and require a continuous 20 ms timeline.

WebRTC listeners click when the RTP timestamp jumps or a packet is late.
This reads the RTSP TCP interleaved stream (the same packets MediaMTX
forwards) for about 30 seconds and fails on a sequence gap, a timestamp
step other than 960 (20 ms at the 48 kHz Opus clock), or a hole in arrival
time.
"""

import socket
import struct
import sys
import time

OPUS_CLOCK = 48_000
FRAME_SAMPLES = 960  # 20 ms at 48 kHz
WARMUP_SECONDS = 1.0
MIN_PACKETS = 1_400  # 28 s at 50 packets/s
MIN_SPAN_SECONDS = 28.0
# A missing frame shows up as a sequence or timestamp jump. Arrival time is
# only a backstop: the macOS CI runner has delayed a single packet by about
# half a second while the RTP timestamp stayed exact, and that is not a click.
MAX_ARRIVAL_GAP_SECONDS = 0.8


def assess(packets):
    """Return an error string, or None when the timeline is continuous.

    packets are (arrival_seconds, sequence, timestamp), already past warmup.
    """
    if len(packets) < MIN_PACKETS:
        return f"only {len(packets)} RTP packets after warmup; expected at least {MIN_PACKETS}"
    span = packets[-1][0] - packets[0][0]
    if span < MIN_SPAN_SECONDS:
        return f"packets span {span:.2f}s; a realtime 20 ms stream should cover {MIN_SPAN_SECONDS:.0f}s"
    problems = []
    for index in range(1, len(packets)):
        previous = packets[index - 1]
        current = packets[index]
        sequence_step = (current[1] - previous[1]) & 0xFFFF
        timestamp_step = (current[2] - previous[2]) & 0xFFFFFFFF
        arrival_gap = current[0] - previous[0]
        if (
            sequence_step != 1
            or timestamp_step != FRAME_SAMPLES
            or arrival_gap > MAX_ARRIVAL_GAP_SECONDS
        ):
            problems.append(
                f"packet {index}: sequence +{sequence_step}, timestamp +{timestamp_step}, "
                f"arrived {arrival_gap * 1000:.0f} ms later"
            )
            if len(problems) >= 8:
                break
    if problems:
        return "RTP timeline is not continuous 20 ms frames:\n" + "\n".join(problems)
    return None


def _request(sock, method, target, cseq, extra=""):
    message = (
        f"{method} {target} RTSP/1.0\r\n"
        f"CSeq: {cseq}\r\n"
        "User-Agent: PublicEarFiSmoke\r\n"
        f"{extra}"
        "\r\n"
    )
    sock.sendall(message.encode("ascii"))
    return _read_response(sock)


def _read_response(sock):
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = sock.recv(65535)
        if not chunk:
            raise RuntimeError("RTSP connection closed before the response finished")
        data += chunk
    head, rest = data.split(b"\r\n\r\n", 1)
    text = head.decode("latin1", "replace")
    status_line = text.split("\r\n", 1)[0]
    parts = status_line.split()
    if len(parts) < 2 or not parts[1].isdigit():
        raise RuntimeError(f"bad RTSP status line: {status_line}")
    status = int(parts[1])
    length = 0
    for line in text.split("\r\n"):
        if line.lower().startswith("content-length:"):
            length = int(line.split(":", 1)[1].strip())
    while len(rest) < length:
        chunk = sock.recv(65535)
        if not chunk:
            raise RuntimeError("RTSP connection closed while reading the body")
        rest += chunk
    body, pending = rest[:length], rest[length:]
    if status >= 400:
        raise RuntimeError(f"RTSP {status}\n{text}\n{body[:300]!r}")
    return text, body, pending


def _header(headers, name):
    prefix = name.lower() + ":"
    for line in headers.split("\r\n"):
        if line.lower().startswith(prefix):
            return line.split(":", 1)[1].strip()
    return ""


def _track_url(base, sdp):
    control = None
    for line in sdp.splitlines():
        if line.lower().startswith("a=control:"):
            value = line.split(":", 1)[1].strip()
            if value and value != "*":
                control = value
    if not control:
        raise RuntimeError(f"SDP has no media control URL:\n{sdp}")
    if control.startswith("rtsp://"):
        return control
    return base.rstrip("/") + "/" + control.lstrip("/")


def read_packets(host, port, path, seconds):
    url = f"rtsp://{host}:{port}/{path}"
    sock = socket.create_connection((host, port), timeout=5)
    sock.settimeout(5)
    try:
        headers, body, pending = _request(
            sock, "DESCRIBE", url, 1, "Accept: application/sdp\r\n"
        )
        track = _track_url(url, body.decode("latin1", "replace"))
        setup_headers, _, pending = _request(
            sock,
            "SETUP",
            track,
            2,
            "Transport: RTP/AVP/TCP;unicast;interleaved=0-1\r\n",
        )
        session = _header(setup_headers, "Session").split(";")[0].strip()
        if not session:
            raise RuntimeError("SETUP returned no session")
        _, _, pending = _request(
            sock, "PLAY", url, 3, f"Session: {session}\r\nRange: npt=0.000-\r\n"
        )
        return _collect_rtp(sock, pending, seconds)
    finally:
        sock.close()


def _collect_rtp(sock, pending, seconds):
    buffer = pending
    deadline = time.monotonic() + seconds
    packets = []
    sock.settimeout(1)
    while time.monotonic() < deadline:
        while len(buffer) < 4 and time.monotonic() < deadline:
            try:
                chunk = sock.recv(65535)
            except socket.timeout:
                chunk = b""
            if not chunk:
                break
            buffer += chunk
        if len(buffer) < 4:
            continue
        if buffer[0] != 0x24:
            marker = buffer.find(b"$")
            buffer = b"" if marker < 0 else buffer[marker:]
            continue
        channel = buffer[1]
        length = struct.unpack("!H", buffer[2:4])[0]
        while len(buffer) < 4 + length and time.monotonic() < deadline:
            try:
                chunk = sock.recv(65535)
            except socket.timeout:
                chunk = b""
            if not chunk:
                break
            buffer += chunk
        if len(buffer) < 4 + length:
            break
        packet = buffer[4 : 4 + length]
        buffer = buffer[4 + length :]
        parsed = _rtp(channel, packet)
        if parsed is not None:
            packets.append((time.monotonic(), parsed[0], parsed[1]))
    return packets


def _rtp(channel, packet):
    if channel != 0 or len(packet) < 12:
        return None
    if packet[0] >> 6 != 2:
        return None
    sequence = struct.unpack("!H", packet[2:4])[0]
    timestamp = struct.unpack("!I", packet[4:8])[0]
    return sequence, timestamp


def drop_warmup(packets):
    if not packets:
        return []
    start = packets[0][0]
    return [packet for packet in packets if packet[0] - start >= WARMUP_SECONDS]


def self_test():
    start = 1_000.0
    good = [
        (start + index * 0.02, index & 0xFFFF, (index * FRAME_SAMPLES) & 0xFFFFFFFF)
        for index in range(1_500)
    ]
    error = assess(good)
    if error:
        raise SystemExit(f"self-test rejected a clean timeline: {error}")
    gapped = list(good)
    # Jump one timestamp by an extra frame: the click Walter hears.
    arrival, sequence, timestamp = gapped[100]
    gapped[100] = (arrival, sequence, timestamp + FRAME_SAMPLES)
    if assess(gapped) is None:
        raise SystemExit("self-test missed a timestamp gap")
    late = list(good)
    arrival, sequence, timestamp = late[200]
    late[200] = (arrival + 1.0, sequence, timestamp)
    if assess(late) is None:
        raise SystemExit("self-test missed a late packet")
    print("RTP timing self-test passed")


def main(argv):
    if len(argv) == 2 and argv[1] == "--self-test":
        self_test()
        return 0
    if len(argv) != 5:
        print(
            "usage: check-rtp-timing.py HOST PORT PATH SECONDS",
            file=sys.stderr,
        )
        return 2
    host, port, path, seconds = argv[1], int(argv[2]), argv[3], float(argv[4])
    packets = read_packets(host, port, path, seconds)
    checked = drop_warmup(packets)
    error = assess(checked)
    if error:
        print(error, file=sys.stderr)
        print(f"captured {len(packets)} RTP packets, {len(checked)} after warmup", file=sys.stderr)
        return 1
    span = checked[-1][0] - checked[0][0]
    print(
        f"RTP timing OK: {len(checked)} packets over {span:.1f}s, "
        f"each {FRAME_SAMPLES} ticks ({FRAME_SAMPLES / OPUS_CLOCK * 1000:.0f} ms) at {OPUS_CLOCK} Hz"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
