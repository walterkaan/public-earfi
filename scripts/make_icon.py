#!/usr/bin/env python3
"""Build the Public EarFi app icon.

The source artwork is design/icon-loudhailer.jpg (Walter's yellow loudhailer
on purple). `python3 scripts/make_icon.py --generate` writes a macOS AppIcon
set: every standard size, PNG, with the white page margin removed and the
corners outside the squircle transparent.

`python3 scripts/make_icon.py build/AppIcon.icns` packs that set with iconutil.
The bundle loads the icns via CFBundleIconFile. The asset catalog is the
source of the sizes; actool is not used, because it would mask the squircle
a second time.
"""

import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "design" / "icon-loudhailer.jpg"
APPICON = (
    ROOT
    / "Sources"
    / "PublicEarFi"
    / "Resources"
    / "Assets.xcassets"
    / "AppIcon.appiconset"
)

# Pixel size -> iconutil / asset-catalog filenames.
SIZES = {
    16: ["icon_16x16.png"],
    32: ["icon_16x16@2x.png", "icon_32x32.png"],
    64: ["icon_32x32@2x.png"],
    128: ["icon_128x128.png"],
    256: ["icon_128x128@2x.png", "icon_256x256.png"],
    512: ["icon_256x256@2x.png", "icon_512x512.png"],
    1024: ["icon_512x512@2x.png"],
}


def generate() -> None:
    from collections import deque

    from PIL import Image

    image = Image.open(SOURCE).convert("RGB")
    width, height = image.size
    pixels = image.load()

    def distance(red, green, blue):
        return max(255 - red, 255 - green, 255 - blue)

    outside = bytearray(width * height)
    queue = deque()

    def consider(x, y):
        index = y * width + x
        if outside[index]:
            return
        red, green, blue = pixels[x, y]
        # White page, including faint JPEG crumbs. Interior yellow stays.
        if distance(red, green, blue) >= 28:
            return
        outside[index] = 1
        queue.append((x, y))

    for x in range(width):
        consider(x, 0)
        consider(x, height - 1)
    for y in range(height):
        consider(0, y)
        consider(width - 1, y)
    while queue:
        x, y = queue.popleft()
        for nx, ny in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)):
            if 0 <= nx < width and 0 <= ny < height:
                consider(nx, ny)

    masked = Image.new("RGBA", (width, height))
    output = masked.load()
    minx, miny, maxx, maxy = width, height, -1, -1
    for y in range(height):
        for x in range(width):
            red, green, blue = pixels[x, y]
            if outside[y * width + x]:
                output[x, y] = (0, 0, 0, 0)
                continue
            touches_outside = False
            for nx, ny in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)):
                if 0 <= nx < width and 0 <= ny < height and outside[ny * width + nx]:
                    touches_outside = True
                    break
            if touches_outside and distance(red, green, blue) < 160:
                # Green separates the purple squircle from the white page.
                alpha = max(0, min(255, int(round((255 - green) / (255 - 55) * 255))))
                if alpha < 20:
                    output[x, y] = (0, 0, 0, 0)
                    continue
                coverage = alpha / 255

                def unblend(channel):
                    value = (channel - 255 * (1 - coverage)) / coverage
                    return max(0, min(255, int(round(value))))

                output[x, y] = (unblend(red), unblend(green), unblend(blue), alpha)
            else:
                output[x, y] = (red, green, blue, 255)
            if output[x, y][3] >= 20:
                minx = min(minx, x)
                miny = min(miny, y)
                maxx = max(maxx, x)
                maxy = max(maxy, y)

    if maxx < minx or maxy < miny:
        raise SystemExit("icon mask removed the whole image")
    cropped = masked.crop((minx, miny, maxx + 1, maxy + 1))
    side = max(cropped.size)
    canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    canvas.paste(
        cropped,
        ((side - cropped.size[0]) // 2, (side - cropped.size[1]) // 2),
        cropped,
    )
    master = canvas.resize((1024, 1024), Image.Resampling.LANCZOS)
    for point in ((0, 0), (1023, 0), (0, 1023), (1023, 1023)):
        if master.getpixel(point)[3] != 0:
            raise SystemExit(f"icon corner {point} is not transparent")
    APPICON.mkdir(parents=True, exist_ok=True)
    for size, names in SIZES.items():
        rendered = master if size == 1024 else master.resize((size, size), Image.Resampling.LANCZOS)
        payload = rendered
        for name in names:
            payload.save(APPICON / name, optimize=True)
    print(APPICON)


def pack(destination: Path) -> None:
    missing = [name for names in SIZES.values() for name in names if not (APPICON / name).is_file()]
    if missing:
        raise SystemExit("AppIcon set is missing " + ", ".join(missing))
    iconutil = shutil.which("iconutil")
    if iconutil is None:
        raise SystemExit("iconutil is required to build AppIcon.icns")
    destination.parent.mkdir(parents=True, exist_ok=True)
    iconset = destination.with_suffix(".iconset")
    if iconset.exists():
        shutil.rmtree(iconset)
    iconset.mkdir(parents=True)
    for names in SIZES.values():
        for name in names:
            shutil.copyfile(APPICON / name, iconset / name)
    subprocess.run(
        [iconutil, "-c", "icns", str(iconset), "-o", str(destination)],
        check=True,
    )
    shutil.rmtree(iconset)
    print(destination)


def main() -> None:
    if len(sys.argv) > 1 and sys.argv[1] == "--generate":
        generate()
        return
    destination = Path(sys.argv[1] if len(sys.argv) > 1 else "AppIcon.icns")
    pack(destination)


if __name__ == "__main__":
    main()
