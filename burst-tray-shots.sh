#!/usr/bin/env bash
# Capture the keyboard→tray swap as a burst of frames, so the composer's
# position can be compared across the transition instead of guessed at.
set -u
source "$(dirname "$0")/env.sh"

OUT="$SHOTS_DIR/tray-burst"
mkdir -p "$OUT"
rm -f "$OUT"/*.png

# Land in a chat that has a message in it.
adb_ shell am force-stop "$PKG" >/dev/null 2>&1
adb_ shell am start -n "$ACT" >/dev/null 2>&1
sleep 3
adb_ shell input tap 540 300 >/dev/null 2>&1
sleep 3

# Type, so the keyboard is genuinely up.
adb_ shell input tap 300 2186 >/dev/null 2>&1
sleep 2
adb_ shell input text "hello%stray" >/dev/null 2>&1
sleep 1
adb_ exec-out screencap -p > "$OUT/01-typing.png"

# Tap attach, then grab frames while the swap happens.
ATTACH=$(adb_ shell "uiautomator dump /sdcard/u.xml >/dev/null 2>&1; cat /sdcard/u.xml" \
    | grep -oE 'content-desc="Attach"[^>]*bounds="\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]"' \
    | head -1 | grep -oE '\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]')
x1=$(sed -E 's/^\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]$/\1/' <<< "$ATTACH")
y1=$(sed -E 's/^\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]$/\2/' <<< "$ATTACH")
x2=$(sed -E 's/^\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]$/\3/' <<< "$ATTACH")
y2=$(sed -E 's/^\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]$/\4/' <<< "$ATTACH")
adb_ shell input tap $(( (x1 + x2) / 2 )) $(( (y1 + y2) / 2 )) >/dev/null 2>&1

for i in $(seq -w 2 12); do
    adb_ exec-out screencap -p > "$OUT/${i}-swap.png"
done

# Settled, and then the keyboard coming back.
sleep 2
adb_ exec-out screencap -p > "$OUT/20-settled.png"
adb_ shell input tap 300 1400 >/dev/null 2>&1
sleep 2
adb_ exec-out screencap -p > "$OUT/30-back-to-keyboard.png"

echo "wrote $(ls "$OUT" | wc -l) frames to $OUT"
