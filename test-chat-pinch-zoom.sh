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

info "An absurd request is clamped, not honoured"
open_chat 9.0
H3=$(text_height)
if [ -n "$H3" ] && [ "$H3" -le $((H2 * 3 / 2)) ]; then
    ok "9x clamps to the 2x ceiling (height ${H3}px)"
else
    bad "9x was not clamped (height ${H3:-none}px, 1.8x was ${H2:-none}px)"
fi

echo ""
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
