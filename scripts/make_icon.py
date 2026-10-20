#!/usr/bin/env python3
"""Draw a simple blue app icon and, on macOS, pack it into an .icns file."""

import struct
import subprocess
import sys
import zlib
from pathlib import Path


def chunk(tag: bytes, data: bytes) -> bytes:
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)


def png(width: int, height: int, pixel) -> bytes:
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        for x in range(width):
            raw.extend(pixel(x, y, width, height))
    return b"".join(
        [
            b"\x89PNG\r\n\x1a\n",
            chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)),
            chunk(b"IDAT", zlib.compress(bytes(raw), 9)),
            chunk(b"IEND", b""),
        ]
    )


def icon_pixel(x: int, y: int, width: int, height: int):
    # Blue rounded square with three white audio bars.
    margin = int(width * 0.12)
    radius = int(width * 0.22)
    inside = margin <= x < width - margin and margin <= y < height - margin
    dx = min(x - margin, width - margin - 1 - x)
    dy = min(y - margin, height - margin - 1 - y)
    if dx < radius and dy < radius:
        inside = (radius - dx) ** 2 + (radius - dy) ** 2 <= radius**2
    if not inside:
        return (0, 0, 0, 0)
    bars = [
        (0.28, 0.62, 0.42, 0.70),
        (0.44, 0.38, 0.58, 0.70),
        (0.60, 0.48, 0.74, 0.70),
    ]
    fx, fy = x / width, y / height
    for left, top, right, bottom in bars:
        if left <= fx <= right and top <= fy <= bottom:
            return (255, 255, 255, 255)
    return (47, 111, 228, 255)


def main() -> None:
    destination = Path(sys.argv[1] if len(sys.argv) > 1 else "AppIcon.icns")
    destination.parent.mkdir(parents=True, exist_ok=True)
    iconset = destination.with_suffix(".iconset")
    if iconset.exists():
        subprocess.run(["rm", "-rf", str(iconset)], check=True)
    iconset.mkdir(parents=True)
    sizes = [16, 32, 64, 128, 256, 512, 1024]
    names = {
        16: ["icon_16x16.png"],
        32: ["icon_16x16@2x.png", "icon_32x32.png"],
        64: ["icon_32x32@2x.png"],
        128: ["icon_128x128.png"],
        256: ["icon_128x128@2x.png", "icon_256x256.png"],
        512: ["icon_256x256@2x.png", "icon_512x512.png"],
        1024: ["icon_512x512@2x.png"],
    }
    cache = {}
    for size in sizes:
        cache[size] = png(size, size, icon_pixel)
    for size, filenames in names.items():
        for filename in filenames:
            (iconset / filename).write_bytes(cache[size])
    if destination.suffix == ".icns":
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(destination)], check=True)
        subprocess.run(["rm", "-rf", str(iconset)], check=True)
    else:
        destination.write_bytes(cache[1024])
    print(destination)


if __name__ == "__main__":
    main()
