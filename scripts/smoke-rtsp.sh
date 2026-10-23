#!/bin/bash
# Publish raw f32le PCM through the bundled ffmpeg into MediaMTX and
# require the path to become ready. This is the pipeline that failed when
# the LGPL build had no pcm_f32le decoder.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/dist/RoomCast.app}"
FFMPEG="$APP/Contents/Helpers/ffmpeg"
MEDIAMTX="$APP/Contents/Helpers/mediamtx"

if [[ ! -x "$FFMPEG" || ! -x "$MEDIAMTX" ]]; then
  echo "Bundled ffmpeg or mediamtx is missing in $APP" >&2
  exit 1
fi

required_decoders=(
  pcm_f32le pcm_f32be pcm_f64le pcm_f64be
  pcm_s16le pcm_s16be pcm_s24le pcm_s24be pcm_s32le pcm_s32be
)
decoder_list="$("$FFMPEG" -hide_banner -decoders)"
for name in "${required_decoders[@]}"; do
  if ! printf '%s\n' "$decoder_list" | grep -q " ${name} "; then
    echo "ffmpeg is missing decoder ${name}" >&2
    exit 1
  fi
done

component_list="$(
  "$FFMPEG" -hide_banner -filters
  "$FFMPEG" -hide_banner -encoders
  "$FFMPEG" -hide_banner -protocols
  "$FFMPEG" -hide_banner -muxers
)"
for name in aresample pan aformat libopus rtsp file pipe tcp udp rtp; do
  if ! printf '%s\n' "$component_list" | grep -Eq "(^|[[:space:]])${name}([[:space:]]|$)"; then
    echo "ffmpeg is missing component ${name}" >&2
    printf '%s\n' "$component_list" >&2
    exit 1
  fi
done

RTSP_PORT=18554
API_PORT=19997
WEBRTC_PORT=18889
ICE_PORT=18189
WORK="$(mktemp -d)"
cleanup() {
  if [[ -n "${FFPID:-}" ]]; then
    kill "$FFPID" 2>/dev/null || true
    wait "$FFPID" 2>/dev/null || true
  fi
  if [[ -n "${PYPID:-}" ]]; then
    kill "$PYPID" 2>/dev/null || true
    wait "$PYPID" 2>/dev/null || true
  fi
  if [[ -n "${MTXPID:-}" ]]; then
    kill "$MTXPID" 2>/dev/null || true
    wait "$MTXPID" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

cat > "$WORK/mediamtx.yml" << EOF
logLevel: info
api: yes
apiAddress: 127.0.0.1:${API_PORT}
rtsp: yes
rtspAddress: 127.0.0.1:${RTSP_PORT}
rtspTransports: [tcp]
rtmp: no
hls: no
srt: no
moq: no
webrtc: yes
webrtcAddress: :${WEBRTC_PORT}
webrtcLocalUDPAddress: :${ICE_PORT}
webrtcLocalTCPAddress: :${ICE_PORT}
webrtcIPsFromInterfaces: yes
paths:
  live:
    source: publisher
EOF

"$MEDIAMTX" "$WORK/mediamtx.yml" > "$WORK/mediamtx.log" 2>&1 &
MTXPID=$!

api_up=0
for _ in $(seq 1 50); do
  if curl -sf "http://127.0.0.1:${API_PORT}/v3/paths/list" >/dev/null; then
    api_up=1
    break
  fi
  if ! kill -0 "$MTXPID" 2>/dev/null; then
    echo "mediamtx exited before the API answered" >&2
    cat "$WORK/mediamtx.log" >&2
    exit 1
  fi
  sleep 0.1
done
if [[ "$api_up" != 1 ]]; then
  echo "mediamtx API did not answer" >&2
  cat "$WORK/mediamtx.log" >&2 || true
  exit 1
fi

# Publish realtime 48 kHz f32le, the PCM the app writes from Core Audio,
# as the Speech preset: mono Opus, 32 kbps, 20 ms frames.
# The writer emits one 20 ms chunk per 20 ms, which is the realtime pace.
rm -f "$WORK/pcm.pipe"
mkfifo "$WORK/pcm.pipe"
python3 -u -c '
import math, struct, sys, time
rate = 48000
frames = rate // 50
index = 0
started = time.monotonic()
sent = 0
while True:
    chunk = bytearray()
    for step in range(frames):
        sample = math.sin(2 * math.pi * 440 * (index + step) / rate) * 0.2
        chunk += struct.pack("<f", sample)
    index += frames
    sent += 1
    wait = started + sent * 0.02 - time.monotonic()
    if wait > 0:
        time.sleep(wait)
    try:
        sys.stdout.buffer.write(chunk)
        sys.stdout.buffer.flush()
    except BrokenPipeError:
        break
' > "$WORK/pcm.pipe" &
PYPID=$!

"$FFMPEG" -hide_banner -nostdin -loglevel warning \
  -thread_queue_size 1024 \
  -f f32le -ar 48000 -ac 1 -i pipe:0 \
  -c:a libopus -b:a 32k -application voip -frame_duration 20 \
  -muxdelay 0 -muxpreload 0 \
  -f rtsp -rtsp_transport tcp \
  "rtsp://127.0.0.1:${RTSP_PORT}/live" \
  < "$WORK/pcm.pipe" > "$WORK/ffmpeg.log" 2>&1 &
FFPID=$!

ready=0
for _ in $(seq 1 60); do
  if curl -sf "http://127.0.0.1:${API_PORT}/v3/paths/get/live" -o "$WORK/path.json"; then
    if python3 - "$WORK/path.json" << 'PY'
import json, sys
document = json.load(open(sys.argv[1]))
online = bool(document.get("ready") or document.get("online"))
received = document.get("inboundBytes", document.get("bytesReceived", 0)) or 0
sys.exit(0 if online and int(received) > 0 else 1)
PY
    then
      ready=1
      break
    fi
  fi
  if ! kill -0 "$FFPID" 2>/dev/null; then
    echo "ffmpeg exited before live was ready" >&2
    cat "$WORK/ffmpeg.log" >&2
    exit 1
  fi
  sleep 0.25
done
if [[ "$ready" != 1 ]]; then
  echo "MediaMTX path live did not become ready" >&2
  echo "---- ffmpeg ----" >&2
  cat "$WORK/ffmpeg.log" >&2 || true
  echo "---- mediamtx ----" >&2
  cat "$WORK/mediamtx.log" >&2 || true
  echo "---- path ----" >&2
  cat "$WORK/path.json" >&2 || true
  exit 1
fi
echo "RTSP smoke test passed for live (48000 Hz f32le -> 48000 Hz opus, 20 ms)"
python3 -c 'import json,sys; print(json.load(open(sys.argv[1])))' "$WORK/path.json"

# 32 s covers a 1 s warmup plus 30 s of packets that must stay on a 20 ms grid.
if ! python3 "$ROOT/scripts/check-rtp-timing.py" 127.0.0.1 "$RTSP_PORT" live 32; then
  echo "---- ffmpeg ----" >&2
  cat "$WORK/ffmpeg.log" >&2 || true
  echo "---- mediamtx ----" >&2
  cat "$WORK/mediamtx.log" >&2 || true
  exit 1
fi
if ! kill -0 "$FFPID" 2>/dev/null; then
  echo "ffmpeg exited during the RTP timing check" >&2
  cat "$WORK/ffmpeg.log" >&2
  exit 1
fi
