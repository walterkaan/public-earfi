#!/usr/bin/env python3
"""Plain DMG background reminding the user about the first-open step."""

import struct
import sys
import zlib
from pathlib import Path


def chunk(tag: bytes, data: bytes) -> bytes:
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)


def main() -> None:
    destination = Path(sys.argv[1])
    width, height = 640, 360
    raw = bytearray()
    for _y in range(height):
        raw.append(0)
        raw.extend(bytes([232, 236, 242, 255]) * width)
    png = b"".join(
        [
            b"\x89PNG\r\n\x1a\n",
            chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)),
            chunk(b"IDAT", zlib.compress(bytes(raw), 9)),
            chunk(b"IEND", b""),
        ]
    )
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(png)


if __name__ == "__main__":
    main()
