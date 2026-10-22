#!/usr/bin/env bash
# Regression for #348: pinch-to-zoom on the conversation view.
#
# adb's `input` cannot inject a two-finger gesture, so the pinch itself is driven
# through the app's script hook (`--ef chat_zoom`, the same idea as the other
# probes in MainActivity) and what is asserted here is the *rendering* half: the
# message text must actually re-lay out at the new scale, which a graphics-layer
# zoom or a no-op handler would not. The gesture wiring itself is covered by
# ChatZoomTest plus the source assertions in ZoomWiringTest.
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

cleanup() {
    sql "DELETE FROM messages WHERE body LIKE '%$MARK%';" >/dev/null 2>&1
    sql "DELETE FROM conversations WHERE address='$NUM';" >/dev/null 2>&1
}
trap cleanup EXIT

for p in READ_SMS RECEIVE_SMS READ_CONTACTS POST_NOTIFICATIONS; do
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
