#!/usr/bin/env bash
# Regression for #348: pinch-to-zoom on the conversation view.
#
# Two halves. The *rendering* half is driven through the app's script hook
# (`--ef chat_zoom`, the same idea as the other probes in MainActivity): the
# message text must actually re-lay out at the new scale, which a graphics-layer
# zoom or a no-op handler would not. The *gesture* half injects a real
# two-finger pinch through the emulator's multi-touch node, because that is the
# part that was broken while every hook-driven case passed: `input` can only
# inject one pointer, so nothing ever tested the pinch itself.
#
# The assertion is geometric: the same message occupies more vertical space at
# 1.8x than at 1.0x, and still renders its text (no cropping of the bubble).
# Two follow-ups from the #348 report are covered here too: the zoom survives
# leaving the chat and killing the process (it is written through to settings per
# conversation), and a double-tap is a one-gesture zoom. The pinch centroid, which
# decides what stays under the user's fingers, cannot be injected through adb at
# all — that half is ChatZoomTest's anchoring maths plus the wiring assertions in
# ZoomWiringTest.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

MARK="zoom$(date +%s)$$"
NUM="+1555983${MARK: -4}"

adb_ root >/dev/null 2>&1; adb_ wait-for-device; sleep 1
sql() { adb_ shell "sqlite3 /data/data/$PKG/databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r'; }

# --- real two-finger pinch ---------------------------------------------------
# `adb shell input` injects one pointer at a time, so a pinch is written
# straight to the emulator's multi-touch node with sendevent. Without this the
# gesture itself was never exercised: only the script hook (`--ef chat_zoom`)
# was, which is why the gesture could be broken while every case passed.
TOUCH_INFO=$(adb_ shell getevent -pl 2>/dev/null | tr -d '\r')
set -- $(printf '%s\n' "$TOUCH_INFO" | python3 -c '
import re, sys
# The emulator exposes one node per virtual finger group (multi_touch_1..N).
# Only _1 is the one Android treats as the primary touchscreen; writing to
# another one is silently ignored, which looks exactly like a broken pinch.
dev, name, xmax, ymax = None, "", None, None
cands = []
for line in sys.stdin:
    m = re.match(r"add device \d+: (\S+)", line)
    if m:
        dev, name, xmax, ymax = m.group(1), "", None, None
        continue
    m = re.match(r"\s+name:\s+\"([^\"]+)\"", line)
    if m:
        name = m.group(1)
        continue
    m = re.search(r"ABS_MT_POSITION_X\s*:.*max (\d+)", line)
    if m:
        xmax = int(m.group(1))
        continue
    m = re.search(r"ABS_MT_POSITION_Y\s*:.*max (\d+)", line)
    if m:
        ymax = int(m.group(1))
        if dev and xmax and ymax:
            cands.append((dev, name, xmax, ymax))
def rank(c):
    m = re.search(r"multi_touch_(\d+)", c[1])
    return (0, int(m.group(1))) if m else (1, 0)
if cands:
    dev, name, xmax, ymax = sorted(cands, key=rank)[0]
    print(dev, xmax, ymax)
')
TOUCH_DEV="$1"; TOUCH_XMAX="$2"; TOUCH_YMAX="$3"

# $1 mode: pinch (both fingers land together) | drag-then-pinch (one finger
# scrolls first, which used to cancel a Modifier.transformable for good)
# $2 half-spread at the start, $3 half-spread at the end, $4 centroid y
gesture() {
    python3 - "$TOUCH_DEV" "$TOUCH_XMAX" "$TOUCH_YMAX" "$1" "$2" "$3" "$4" <<'PY' > "$TMP/gesture.sh"
import sys
dev, xmax, ymax = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
mode, start, end, y = sys.argv[4], float(sys.argv[5]), float(sys.argv[6]), float(sys.argv[7])
W, H, CX = 1080.0, 2400.0, 540.0
rx = lambda px: round(px * xmax / W)
ry = lambda py: round(py * ymax / H)
L = ["D=" + dev]
def e(t, c, v): L.append("sendevent $D %d %d %d" % (t, c, v))
def down(slot, x, yy):
    e(3, 47, slot); e(3, 57, 100 + slot); e(3, 53, rx(x)); e(3, 54, ry(yy))
    e(3, 48, 10); e(3, 58, 80); e(1, 330, 1); e(0, 0, 0)
def move(pts):
    for slot, (x, yy) in enumerate(pts):
        e(3, 47, slot); e(3, 53, rx(x)); e(3, 54, ry(yy))
    e(0, 0, 0)
def up(n):
    for slot in range(n):
        e(3, 47, slot); e(3, 57, -1)
    e(1, 330, 0); e(0, 0, 0)

L.append("sleep 0.3")
down(0, CX - start, y)
L.append("sleep 0.05")
if mode == "drag-then-pinch":
    # One finger lands and moves first: the list starts scrolling, which is what
    # cancelled the old transform gesture for the rest of the touch sequence.
    for i in range(1, 5):
        move([(CX - start, y - 40 * i)]); L.append("sleep 0.05")
    y -= 160
down(1, CX + start, y)
L.append("sleep 0.12")
steps = 12
for i in range(1, steps + 1):
    d = start + (end - start) * i / steps
    move([(CX - d, y), (CX + d, y)]); L.append("sleep 0.03")
L.append("sleep 0.2")
up(2)
L.append("sleep 0.2")
print("\n".join(L))
PY
    adb_ shell sh < "$TMP/gesture.sh"
    sleep 3
}

cleanup() {
    sql "DELETE FROM messages WHERE body LIKE '%$MARK%';" >/dev/null 2>&1
    sql "DELETE FROM conversations WHERE address='$NUM';" >/dev/null 2>&1
}
trap cleanup EXIT

for p in READ_SMS RECEIVE_SMS READ_CONTACTS POST_NOTIFICATIONS; do
    adb_ shell pm grant "$PKG" "android.permission.$p" >/dev/null 2>&1
done
# A chat only opens once the app owns the SMS role; without it the first launch
# stops on a "Set as default SMS app?" dialog and every case below fails with an
# empty screen. The phone-call permissions are the other first-run dialog, and
# the pinched message sits above it.
adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1 || true
for p in READ_PHONE_STATE CALL_PHONE READ_PHONE_NUMBERS; do
    adb_ shell pm grant "$PKG" "android.permission.$p" >/dev/null 2>&1
done

info "Seed a long message so a larger scale has to wrap more"
BODY="$MARK the quick brown fox jumps over the lazy dog and keeps running past the bubble edge"
TS=$(date +%s000)
sql "INSERT INTO conversations(address,name,snippet,timestamp,unread_count) VALUES('$NUM','$MARK','$MARK',$TS,0);" >/dev/null 2>&1
CID=$(sql "SELECT id FROM conversations WHERE address='$NUM';")
if [ -z "$CID" ]; then bad "could not seed a conversation"; exit 1; fi
sql "INSERT INTO messages(conversation_id,body,timestamp,status) VALUES($CID,'$BODY',$TS,'received');" >/dev/null 2>&1
ok "conversation $CID seeded"

# Height of the node carrying the marker text, in px.
text_height() {
    python3 - "$TMP/ui.xml" "$MARK" <<'PY'
import re, sys
xml, needle = open(sys.argv[1], encoding='utf-8', errors='replace').read(), sys.argv[2]
for m in re.finditer(r'text="([^"]*)"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', xml):
    if needle in m.group(1):
        y1, y2 = int(m.group(3)), int(m.group(5))
        print(y2 - y1)
        raise SystemExit
PY
}

open_chat() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
    adb_ shell am start -n "$ACT" --es open_conversation_address "$NUM" --ef chat_zoom "$1" \
        >/dev/null 2>&1
    sleep 6
    dump_ui
}

# Same, without the script hook: what the app opens at on its own, i.e. the zoom
# this conversation was last left at.
open_chat_plain() {
    local addr="${1:-$NUM}"
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
    adb_ shell am start -n "$ACT" --es open_conversation_address "$addr" >/dev/null 2>&1
    sleep 6
    dump_ui
}

# Double-tap on an empty patch of the list: adb cannot inject multi-touch, and the
# two taps have to be further apart than the platform's 40 ms double-tap floor. A
# bubble's own tap handler swallows the gesture, so candidates are tried from just
# below the message down to the input bar until the zoom actually changes.
zoom_percent() {
    python3 - "$TMP/ui.xml" <<'PY'
import re, sys
xml = open(sys.argv[1], encoding='utf-8', errors='replace').read()
m = re.search(r'text="([0-9]+)%"', xml)
print(m.group(1) if m else "100")
PY
}

double_tap_empty() {
    local y before after
    for y in $(python3 - "$TMP/ui.xml" "$MARK" <<'PY'
import re, sys
xml, needle = open(sys.argv[1], encoding='utf-8', errors='replace').read(), sys.argv[2]
bottom = 0
for m in re.finditer(r'text="([^"]*)"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', xml):
    if needle in m.group(1):
        bottom = max(bottom, int(m.group(5)))
for y in (bottom + 300, bottom + 500, 1750, 1950):
    if 320 <= y <= 2050:
        print(y)
PY
    ); do
        before=$(zoom_percent)
        adb_ shell "input tap 540 $y; sleep 0.09; input tap 540 $y" >/dev/null 2>&1
        sleep 2
        dump_ui
        after=$(zoom_percent)
        [ "$before" != "$after" ] && return 0
    done
    return 1
}

info "Open at 1.0x"
open_chat 1.0
H1=$(text_height)
[ -n "$H1" ] && ok "message rendered at 1.0x (height ${H1}px)" || bad "message text not found at 1.0x"

info "Open at 1.8x"
open_chat 1.8
H2=$(text_height)
[ -n "$H2" ] && ok "message rendered at 1.8x (height ${H2}px)" || bad "message text not found at 1.8x"

if [ -n "$H1" ] && [ -n "$H2" ]; then
    if [ "$H2" -gt "$H1" ]; then
        ok "zoomed text re-lays out taller (${H1}px -> ${H2}px)"
    else
        bad "zoom did not change the layout (${H1}px -> ${H2}px)"
    fi
    # A graphics-layer scale would keep the same layout height; a scale that
    # pushed the text off screen would leave nothing to measure. Both fail here.
    if [ "$H2" -lt 2400 ]; then
        ok "zoomed text is still on screen"
    else
        bad "zoomed text occupies the whole viewport ($H2 px)"
    fi
fi

# A dump that fails must never be read as "the zoom did not change": the dump
# file is left behind from the previous case, so a busy or offline device would
# be asserted against stale pixels.
pinch_case() {
    local desc="$1" mode="$2" start="$3" end="$4" lo="$5" hi="$6"
    open_chat 1.0
    if ! grep -q "$MARK" "$TMP/ui.xml"; then
        bad "$desc — the chat did not open, nothing was pinched"
        return
    fi
    gesture "$mode" "$start" "$end" 1000
    if ! dump_ui; then
        bad "$desc — the screen could not be read after the pinch"
        return
    fi
    local p
    p=$(zoom_percent)
    if [ "$p" -ge "$lo" ] && [ "$p" -le "$hi" ]; then
        ok "$desc ($p%)"
    else
        bad "$desc — got $p%, wanted $lo-$hi%"
    fi
}

info "A real two-finger pinch zooms the chat"
if [ -z "$TOUCH_DEV" ]; then
    bad "no multi-touch input device found — the pinch itself cannot be injected"
else
    pinch_case "a two-finger spread of 3.3x zooms in" pinch 120 400 200 250

    # The reporter's actual gesture: one finger lands a few milliseconds before
    # the other, so the list starts scrolling before both fingers are down. That
    # consumed the pointers and cancelled Modifier.transformable for the whole
    # sequence, which is why the chat "would not zoom".
    info "A pinch that begins with one finger on the list still zooms"
    pinch_case "a pinch after a one-finger drag zooms in" drag-then-pinch 120 400 200 250

    info "The zoom follows how far the fingers move"
    pinch_case "a 1.5x finger spread zooms to about 150%" pinch 120 180 145 155

    info "Pinching in shrinks the text"
    pinch_case "a pinch in reaches the 70% floor" pinch 200 120 70 70
fi

info "The zoom is shown, and one tap goes back to 100%"
open_chat 1.5
dump_ui
if grep -qE 'text="150%"' "$TMP/ui.xml"; then
    ok "a 150% pill reports the current zoom"
else
    bad "no 150% pill while the chat is zoomed"
fi
CHIP=$(python3 - "$TMP/ui.xml" <<'PY'
import re, sys
xml = open(sys.argv[1], encoding='utf-8', errors='replace').read()
m = re.search(r'content-desc="Zoom 150%[^"]*"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', xml)
if m:
    x1, y1, x2, y2 = map(int, m.groups())
    print((x1 + x2) // 2, (y1 + y2) // 2)
PY
)
if [ -n "$CHIP" ]; then
    set -- $CHIP
    adb_ shell input tap "$1" "$2" >/dev/null 2>&1
    sleep 1
    dump_ui
    if grep -qE 'text="100%"' "$TMP/ui.xml" || ! grep -qE 'text="[0-9]+%"' "$TMP/ui.xml"; then
        ok "tapping the pill resets the zoom"
    else
        bad "the pill did not reset the zoom"
    fi
    H4=$(text_height)
    if [ -n "$H4" ] && [ "$H4" = "$H1" ]; then
        ok "the text is back to its 100% layout (${H4}px)"
    else
        bad "text did not return to the 100% layout (${H4:-none}px, was ${H1:-none}px)"
    fi
else
    bad "the zoom pill is not tappable"
fi

info "An absurd request is clamped to the 2.5x ceiling"
open_chat 9.0
H3=$(text_height)
open_chat 2.5
H_MAX=$(text_height)
if [ -n "$H3" ] && [ -n "$H_MAX" ] && [ "$H3" = "$H_MAX" ]; then
    ok "9x renders exactly like 2.5x (height ${H3}px)"
else
    bad "9x was not clamped (height ${H3:-none}px, 2.5x was ${H_MAX:-none}px)"
fi

info "The zoom is remembered after leaving the chat and killing the app"
# The reporter's "takes too much work" was partly about having to re-pinch after
# coming back. The zoom is written through to settings per conversation, so a
# plain reopen (no hook, process killed first) still lands at 180%.
open_chat 1.8
open_chat_plain
if grep -qE 'text="180%"' "$TMP/ui.xml"; then
    ok "reopening the chat without the hook comes back at 180%"
else
    bad "the zoom was lost when the chat was reopened"
fi

info "A conversation that was never zoomed stays at 100%"
OTHER="+1555982${MARK: -4}"
OTHER_TS=$(date +%s000)
sql "INSERT INTO conversations(address,name,snippet,timestamp,unread_count) VALUES('$OTHER','$MARK-o','$MARK',$OTHER_TS,0);" >/dev/null 2>&1
OTHER_CID=$(sql "SELECT id FROM conversations WHERE address='$OTHER';")
sql "INSERT INTO messages(conversation_id,body,timestamp,status) VALUES($OTHER_CID,'$MARK other thread',$OTHER_TS,'received');" >/dev/null 2>&1
open_chat_plain "$OTHER"
if grep -qE 'text="[0-9]+%"' "$TMP/ui.xml"; then
    bad "the zoom leaked into a conversation that was never zoomed"
else
    ok "another conversation opens at 100%"
fi
sql "DELETE FROM messages WHERE conversation_id=$OTHER_CID;" >/dev/null 2>&1
sql "DELETE FROM conversations WHERE address='$OTHER';" >/dev/null 2>&1

info "A double-tap zooms out in one gesture, and again zooms back in"
open_chat 1.8
if double_tap_empty; then
    if ! grep -qE 'text="[0-9]+%"' "$TMP/ui.xml"; then
        ok "a double-tap went back to 100%"
    else
        bad "a double-tap did not leave the zoom"
    fi
    H_DT=$(text_height)
    if [ -n "$H_DT" ] && [ "$H_DT" = "$H1" ]; then
        ok "the text re-laid out at the 100% height (${H_DT}px)"
    else
        bad "text height after the double-tap was ${H_DT:-none}px, expected ${H1:-none}px"
    fi
    double_tap_empty
    if grep -qE 'text="150%"' "$TMP/ui.xml"; then
        ok "a second double-tap zooms in to 150%"
    else
        bad "the second double-tap did not zoom in"
    fi
else
    bad "could not find an empty patch of the list to double-tap"
fi

# The zoom is persisted per conversation; drop the seeded conversation's entry so
# a re-run starts from 100%.
adb_ shell am force-stop "$PKG" >/dev/null 2>&1
adb_ shell "sed -i \"/chat_zoom_$CID/d\" /data/data/$PKG/shared_prefs/messages_settings.xml" >/dev/null 2>&1

echo ""
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
