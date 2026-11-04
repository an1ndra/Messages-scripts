#!/usr/bin/env python3
"""Composite the Play Store listing screenshots from the raw app captures.

The raw 1080x2400 captures live in screenshots/store-raw/ and come from
take-fdroid-screenshots.sh. This script puts each one inside a phone frame
under a two-line headline on a seeded gradient, and writes 1080x1920 PNGs to
fastlane/metadata/android/en-US/images/phoneScreenshots/ — the 9:16 aspect Play
requires (a raw 1080x2400 shot is 20:9 and gets rejected).

Compositing runs through photocraft-cli so the frames are built from real
layers instead of a pixel library:

  python3 scripts/make-store-screenshots.py            # all shots
  python3 scripts/make-store-screenshots.py --only 01-home.png

Every colour is mixed from the app's theme seed, read out of Theme.kt, so the
listing cannot drift from the palette the app actually paints.
"""

import argparse
import json
import re
import struct
import subprocess
import sys
from pathlib import Path

PROJECT_DIR = Path(__file__).resolve().parent.parent
RAW_DIR = PROJECT_DIR / "screenshots" / "store-raw"
OUT_DIR = PROJECT_DIR / "fastlane" / "metadata" / "android" / "en-US" / "images" / "phoneScreenshots"
THEME = PROJECT_DIR / "app" / "src" / "main" / "java" / "com" / "anindra" / "messages" / "ui" / "theme" / "Theme.kt"

CANVAS_W, CANVAS_H = 1080, 1920

# Phone frame: the screenshot overruns the canvas at the bottom, the way a
# listing shot normally does, so the device runs off the edge instead of
# floating. The screen height follows the captures' own aspect ratio — they are
# 1080x2340 on emulator-5558 and 1080x2400 on emulator-5557.
SCREEN_W = 752
BEZEL = 24
PHONE_TOP = 470
FRAME_W = SCREEN_W + 2 * BEZEL
FRAME_X = (CANVAS_W - FRAME_W) // 2
SCREEN_X = FRAME_X + BEZEL
SCREEN_Y = PHONE_TOP + BEZEL

HEADLINE_BOX = [90, 118, 900, 120]
HEADLINE_SIZE = 96
HEADLINE_LEADING = 110
HEADLINE_TRACKING = -30
SUBHEAD_BOX = [90, 248, 900, 160]
SUBHEAD_SIZE = 40
SUBHEAD_LEADING = 54
FONT = "Inter"

# Raw capture -> (published name, headline, subhead). The subheads stay short
# because they wrap to two lines inside SUBHEAD_BOX.
SHOTS = [
    ("01-home.png", "01-chats.png", "All your texts",
     "Every conversation, in one calm place."),
    ("06-typing.png", "02-replying.png", "Fast replies",
     "Type, send and get on with your day."),
    ("05-reaction.png", "03-reactions.png", "React instantly",
     "A single tap says everything."),
    ("08-new-chat.png", "04-new-chat.png", "Start in a tap",
     "Pick a contact and start chatting."),
    ("04-contact.png", "05-contact.png", "Per-chat control",
     "Notifications, bubbles and blocking, person by person."),
    ("02-settings.png", "06-themes.png", "Make it yours",
     "Light, dark or a true-black AMOLED theme."),
    ("03-advanced-settings.png", "07-advanced.png", "Fine control",
     "Every setting the app has, in one place."),
    ("07-import-messages.png", "08-import.png", "Bring them along",
     "Restore your history from a backup."),
]


def seed_hex():
    """The scheme seed Theme.kt builds every role from."""
    text = THEME.read_text(encoding="utf-8")
    match = re.search(r"seed #([0-9A-Fa-f]{6})", text)
    if not match:
        sys.exit(f"make-store-screenshots: no seed colour in {THEME}")
    return match.group(1)


def mix(hex_color, other, weight):
    """Blend hex_color toward other; weight 0 keeps it, 1 is all other."""
    a = [int(hex_color[i:i + 2], 16) for i in (0, 2, 4)]
    b = [int(other[i:i + 2], 16) for i in (0, 2, 4)]
    return "#%02X%02X%02X" % tuple(round(x + (y - x) * weight) for x, y in zip(a, b))


def palette():
    seed = seed_hex()
    return {
        "bg_top": mix(seed, "FFFFFF", 0.30),
        "bg_mid": seed,
        "bg_bottom": mix(seed, "000000", 0.26),
        "ink": "#FFFFFF",
        "frame": mix(seed, "000000", 0.88),
        "button": mix(seed, "000000", 0.70),
        "shadow": mix(seed, "000000", 0.72),
    }


def png_size(path):
    """Width and height out of the PNG IHDR, without an image library."""
    with open(path, "rb") as handle:
        head = handle.read(24)
    if head[:8] != b"\x89PNG\r\n\x1a\n" or head[12:16] != b"IHDR":
        sys.exit(f"make-store-screenshots: {path} is not a PNG")
    return struct.unpack(">II", head[16:24])


BUTTON_W = 14


def steps(raw, headline, subhead, colors):
    raw_w, raw_h = png_size(raw)
    screen_h = round(raw_h * SCREEN_W / raw_w)
    frame_h = screen_h + 2 * BEZEL
    mid = PHONE_TOP + 520
    return [
        ("gradient.fill.create",
         {"from": [CANVAS_W // 2, 0], "to": [CANVAS_W // 2, CANVAS_H],
          "stops": [[0, colors["bg_top"]], [0.55, colors["bg_mid"]],
                    [1, colors["bg_bottom"]]]}),
        ("type.create",
         {"box": HEADLINE_BOX, "align": "center", "text": headline, "font": FONT,
          "weight": 800, "size": HEADLINE_SIZE, "leading": HEADLINE_LEADING,
          "tracking": HEADLINE_TRACKING, "color": colors["ink"]}),
        ("type.create",
         {"box": SUBHEAD_BOX, "align": "center", "text": subhead, "font": FONT,
          "weight": 500, "size": SUBHEAD_SIZE, "leading": SUBHEAD_LEADING,
          "tracking": -10, "color": colors["ink"]}),
        ("layer.setProps", {"opacity": 0.86}),
        ("shape.create",
         {"kind": "roundedRect", "rect": [FRAME_X - 6, mid - 170, 12, 110],
          "radii": 5, "fill": colors["frame"], "name": "Volume up"}),
        ("shape.create",
         {"kind": "roundedRect", "rect": [FRAME_X - 6, mid - 44, 12, 110],
          "radii": 5, "fill": colors["frame"], "name": "Volume down"}),
        ("shape.create",
         {"kind": "roundedRect", "rect": [FRAME_X + FRAME_W - 6, mid - 120, 12, 150],
          "radii": 5, "fill": colors["frame"], "name": "Power"}),
        ("shape.create",
         {"kind": "roundedRect", "rect": [FRAME_X, PHONE_TOP, FRAME_W, frame_h],
          "radii": 72, "fill": colors["frame"], "name": "Bezel"}),
        ("layer.select", {"layer": "Bezel"}),
        ("layer.layerStyle.dropShadow",
         {"color": colors["shadow"], "opacity": 34, "blend": "multiply",
          "angle": 90, "distance": 30, "size": 90}),
        ("shape.create",
         {"kind": "roundedRect", "rect": [SCREEN_X, SCREEN_Y, SCREEN_W, screen_h],
          "radii": 48, "fill": "#FFFFFF", "name": "ScreenClip"}),
        ("file.placeEmbedded",
         {"path": str(raw), "scale": SCREEN_W / raw_w * 100,
          "center": [CANVAS_W // 2, SCREEN_Y + screen_h // 2], "smartObject": False}),
        ("layer.createClippingMask", {}),
    ]


def compose(raw_name, out_name, headline, subhead, colors):
    raw = RAW_DIR / raw_name
    if not raw.exists():
        sys.exit(f"make-store-screenshots: {raw} is missing — run take-fdroid-screenshots.sh first")
    out = OUT_DIR / out_name
    cmd = ["photocraft-cli", "run", "--new",
           '{"width": %d, "height": %d, "background": "#FFFFFF"}' % (CANVAS_W, CANVAS_H)]
    for name, params in steps(raw, headline, subhead, colors):
        cmd += ["--cmd", name, "--params", json.dumps(params)]
    cmd += ["--out", str(out)]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f"make-store-screenshots: {out_name} failed\n{result.stdout}\n{result.stderr}")
    print(f"  {out_name}  <- {raw_name}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--only", help="compose one raw capture, e.g. 01-home.png")
    args = parser.parse_args()

    colors = palette()
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    if args.only is None:
        for stale in OUT_DIR.glob("*.png"):
            stale.unlink()
    selected = [s for s in SHOTS if args.only is None or s[0] == args.only]
    if not selected:
        sys.exit(f"make-store-screenshots: no shot named {args.only}")
    print(f"seed {seed_hex()} -> {OUT_DIR.relative_to(PROJECT_DIR)}")
    for raw_name, out_name, headline, subhead in selected:
        compose(raw_name, out_name, headline, subhead, colors)
    return 0


if __name__ == "__main__":
    sys.exit(main())
