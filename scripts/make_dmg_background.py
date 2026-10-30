#!/usr/bin/env python3
"""Branded RoomCast DMG background (navy / violet / teal).

Writes design/dmg/background.png (@1x 640×400) and background@2x.png.
Optional argv[1] copies the @1x preview to that path (e.g. Desktop).

Requires Pillow:  python3 -m venv .venv && .venv/bin/pip install Pillow
Or:             /path/to/python with PIL installed.
"""

from __future__ import annotations

import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "design" / "dmg"
ICON = (
    ROOT
    / "Sources"
    / "PublicEarFi"
    / "Resources"
    / "Assets.xcassets"
    / "AppIcon.appiconset"
    / "icon_256x256.png"
)

NAVY = (0x1B, 0x18, 0x40, 255)
VIOLET = (0x8B, 0x5C, 0xF6, 255)
TEAL = (0x5F, 0xE0, 0xC8, 255)
INK = (0xF2, 0xF0, 0xFF, 255)
MUTED = (0xC8, 0xC4, 0xE8, 230)


def _font(size: int, scale: int):
    from PIL import ImageFont

    px = max(10, int(size * scale))
    for name in (
        "/System/Library/Fonts/SFNS.ttf",
        "/System/Library/Fonts/SFNSRounded.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
        "/Library/Fonts/Arial.ttf",
    ):
        try:
            return ImageFont.truetype(name, size=px)
        except OSError:
            continue
    return ImageFont.load_default()


def _arrow(draw, x0: int, y: int, x1: int, scale: int, color) -> None:
    thickness = max(3, int(4 * scale))
    head = max(14, int(18 * scale))
    draw.rounded_rectangle(
        [x0, y - thickness // 2, x1 - head // 2, y + thickness // 2 + (thickness % 2)],
        radius=thickness // 2,
        fill=color,
    )
    tip = x1
    left = x1 - head
    draw.polygon(
        [
            (left, y - head // 2),
            (tip, y),
            (left, y + head // 2),
            (left + head // 3, y),
        ],
        fill=color,
    )


def render(scale: int):
    from PIL import Image, ImageDraw, ImageFilter

    width, height = 640 * scale, 400 * scale
    image = Image.new("RGBA", (width, height), NAVY)
    draw = ImageDraw.Draw(image)

    glow = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    gdraw = ImageDraw.Draw(glow)
    radius = int(220 * scale)
    gdraw.ellipse(
        [width - radius * 1.2, -radius * 0.6, width + radius * 0.4, radius * 0.9],
        fill=(0x8B, 0x5C, 0xF6, 70),
    )
    gdraw.ellipse(
        [-radius * 0.5, height - radius * 0.9, radius * 0.9, height + radius * 0.4],
        fill=(0x5F, 0xE0, 0xC8, 40),
    )
    glow = glow.filter(ImageFilter.GaussianBlur(radius=int(36 * scale)))
    image = Image.alpha_composite(image, glow)
    draw = ImageDraw.Draw(image)

    logo = Image.open(ICON).convert("RGBA")
    logo_size = int(56 * scale)
    logo = logo.resize((logo_size, logo_size), Image.Resampling.LANCZOS)
    logo_x = int(28 * scale)
    logo_y = int(22 * scale)
    image.paste(logo, (logo_x, logo_y), logo)

    title_font = _font(28, scale)
    subtitle_font = _font(13, scale)
    drag_font = _font(12, scale)
    hint_font = _font(11, scale)

    title = "RoomCast"
    title_x = logo_x + logo_size + int(14 * scale)
    title_y = logo_y + int(8 * scale)
    draw.text((title_x, title_y), title, font=title_font, fill=INK)
    bbox = draw.textbbox((title_x, title_y), title, font=title_font)
    draw.rounded_rectangle(
        [bbox[0], bbox[3] + int(4 * scale), bbox[2], bbox[3] + int(7 * scale)],
        radius=int(2 * scale),
        fill=TEAL,
    )
    draw.text(
        (title_x, bbox[3] + int(12 * scale)),
        "Free sound to every phone",
        font=subtitle_font,
        fill=MUTED,
    )

    arrow_y = int(188 * scale)
    _arrow(
        draw,
        int(250 * scale),
        arrow_y,
        int(390 * scale),
        scale,
        (*VIOLET[:3], 200),
    )

    drag = "Drag to Applications"
    drag_box = draw.textbbox((0, 0), drag, font=drag_font)
    drag_w = drag_box[2] - drag_box[0]
    drag_x = (width - drag_w) // 2
    drag_y = arrow_y + int(28 * scale)
    pad_x, pad_y = int(12 * scale), int(6 * scale)
    draw.rounded_rectangle(
        [
            drag_x - pad_x,
            drag_y - pad_y,
            drag_x + drag_w + pad_x,
            drag_y + (drag_box[3] - drag_box[1]) + pad_y,
        ],
        radius=int(10 * scale),
        fill=(0x12, 0x10, 0x30, 160),
    )
    draw.text((drag_x, drag_y), drag, font=drag_font, fill=TEAL)

    hint = "First open: right-click RoomCast → Open"
    hint_box = draw.textbbox((0, 0), hint, font=hint_font)
    hint_x = (width - (hint_box[2] - hint_box[0])) // 2
    draw.text(
        (hint_x, height - int(28 * scale)),
        hint,
        font=hint_font,
        fill=(0xA8, 0xA4, 0xC8, 180),
    )
    draw.rectangle([0, 0, width, max(1, scale)], fill=(*VIOLET[:3], 90))
    return image.convert("RGB")


def main() -> None:
    try:
        from PIL import Image  # noqa: F401
    except ImportError as error:
        raise SystemExit(
            "Pillow is required to regenerate DMG backgrounds.\n"
            "  python3 -m venv .venv && .venv/bin/pip install Pillow\n"
            f"({error})"
        ) from error

    if not ICON.is_file():
        raise SystemExit(f"Missing app icon PNG: {ICON}")

    OUT.mkdir(parents=True, exist_ok=True)
    targets = {
        1: OUT / "background.png",
        2: OUT / "background@2x.png",
    }
    for scale, path in targets.items():
        render(scale).save(path, "PNG", optimize=True)
        print(f"wrote {path} ({path.stat().st_size} bytes)")

    if len(sys.argv) > 1:
        preview = Path(sys.argv[1]).expanduser()
        preview.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(targets[1], preview)
        print(f"preview {preview}")


if __name__ == "__main__":
    main()
