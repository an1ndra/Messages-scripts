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

echo ""
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
