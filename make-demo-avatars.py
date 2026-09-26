#!/usr/bin/env python3
"""Generate monogram contact avatars for the F-Droid demo data.

The ContactsProvider stores a contact photo as a thumbnail blob in
data.data15 (see DataRowHandlerForPhoto.preProcessPhoto), so these are written
straight into that column. Sizes follow the provider's own convention: a
square, already-downscaled thumbnail.

Colours are the app's Google Messages avatar palette (ui/Components.kt), so a
monogram and the app's built-in letter tile for the same name read as one set.
"""
import argparse
import os
import sys

from PIL import Image, ImageDraw, ImageFont

# Google Messages avatar palette, in Components.kt order.
PALETTE = [
    (0xFF, 0x63, 0xB8), (0xEE, 0x67, 0x5C), (0xFA, 0x90, 0x3E),
    (0x4E, 0xCD, 0xE6), (0xAF, 0x5C, 0xF7), (0x4C, 0xAF, 0x50),
    (0x21, 0x96, 0xF3), (0xFF, 0x98, 0x00), (0x9C, 0x27, 0xB0),
    (0x00, 0xBC, 0xD4), (0xE9, 0x1E, 0x63), (0x3F, 0x51, 0xB5),
    (0x00, 0x96, 0x88), (0xFF, 0x57, 0x22), (0x79, 0x55, 0x48),
    (0x60, 0x7D, 0x8B),
]

FONT_CANDIDATES = [
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/truetype/noto/NotoSans-Bold.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf",
]

SIZE = 512


def font_path() -> str:
    for path in FONT_CANDIDATES:
        if os.path.exists(path):
            return path
    raise SystemExit("no bold sans font found; install fonts-dejavu-core")


def initials(given: str, family: str, display: str) -> str:
    """First letters of the given and family name, else of the display name."""
    if given and family:
        return (given[0] + family[0]).upper()
    if given:
        return given[0].upper()
    words = [w for w in display.replace(".", " ").split() if w]
    if not words:
        return "?"
    if len(words) == 1:
        return words[0][0].upper()
    return (words[0][0] + words[1][0]).upper()


def shade(rgb, factor):
    return tuple(max(0, min(255, int(c * factor))) for c in rgb)


def render(given: str, family: str, display: str) -> Image.Image:
    text = initials(given, family, display)
    key = f"{given} {family} {display}"
    base = PALETTE[sum(ord(c) for c in key) % len(PALETTE)]

    # Diagonal two-stop gradient, light at the top-left, so the tile has depth
    # without competing with the white glyph.
    top = shade(base, 1.18)
    bottom = shade(base, 0.82)
    img = Image.new("RGB", (SIZE, SIZE), bottom)
    draw = ImageDraw.Draw(img)
    for y in range(SIZE):
        t = y / (SIZE - 1)
        row = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        draw.line([(0, y), (SIZE, y)], fill=row)

    face = font_path()
    glyph = text
    font = ImageFont.truetype(face, int(SIZE * 0.46))
    while draw.textlength(glyph, font=font) > SIZE * 0.66 and font.size > 12:
        font = ImageFont.truetype(face, font.size - 4)
    box = draw.textbbox((0, 0), glyph, font=font)
    draw.text(
        ((SIZE - (box[2] - box[0])) / 2 - box[0],
         (SIZE - (box[3] - box[1])) / 2 - box[1]),
        glyph, font=font, fill=(255, 255, 255),
    )
    return img


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True, help="output directory")
    ap.add_argument("--size", type=int, default=SIZE)
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)

    # name|given|family|number rows on stdin
    for line in sys.stdin:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        display, given, family, number = line.split("|")
        path = os.path.join(args.out, f"{number}.jpg")
        render(given, family, display).save(path, "JPEG", quality=88, optimize=True)
        print(f"  {initials(given, family, display):<3} {display:<18} {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
