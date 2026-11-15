#!/usr/bin/env bash
# Regression for #405 follow-up (point 2): an SMS whose whole body is a phone
# number, or a bare bank stamp, has no letter in it. BidiText calls such a line
# LTR, but the platform lays it out in the *layout* direction — TextDirection
# .Content resolves to FIRSTSTRONG_RTL under an RTL locale — so the bubble
# painted "7899 456 0123 21+" while the composer and Copy were correct. The
# line is now pinned in its own LTR isolate even when it is the only line.
#
# uiautomator dumps the string the app hands to the renderer, so the isolates
# (U+2066 … U+2069) and the non-breaking separators inside them are visible.
# That is the assertion: the whole body is one LTR isolate with its digit
# groups in written order.
#
# Run: scripts/test-bidi-phone-number-only.sh
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

MARK="numonly$(date +%s)$$"
NUM="+1555981${MARK: -4}"
LRI=$'\u2066'
PDI=$'\u2069'
NBSP=$'\u00A0'
NBHYPHEN=$'\u2011'
NUMBER="+21 0123 456 7899"
NUMBER_DISPLAY="${NUMBER// /$NBSP}"
STAMP="1405/07/30 - 16:59"
STAMP_DISPLAY="1405/07/30${NBSP}${NBHYPHEN}${NBSP}16:59"

adb_ root >/dev/null 2>&1; adb_ wait-for-device; sleep 1
sql() { adb_ shell "sqlite3 /data/data/$PKG/databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r'; }

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM');" >/dev/null 2>&1
    sql "DELETE FROM conversations WHERE address='$NUM';" >/dev/null 2>&1
}
trap cleanup EXIT

for p in READ_SMS RECEIVE_SMS READ_CONTACTS POST_NOTIFICATIONS; do
    adb_ shell pm grant "$PKG" "android.permission.$p" >/dev/null 2>&1
done

info "Seed a message that is nothing but a phone number"
TS=$(date +%s000)
sql "INSERT INTO conversations(address,name,snippet,timestamp,unread_count) VALUES('$NUM','$MARK','$MARK',$TS,0);" >/dev/null 2>&1
CID=$(sql "SELECT id FROM conversations WHERE address='$NUM';")
[ -z "$CID" ] && { bad "could not seed a conversation"; exit 1; }
sql "INSERT INTO messages(conversation_id,body,timestamp,status) VALUES($CID,'$NUMBER',$TS,'received');" >/dev/null 2>&1
ok "number-only message seeded"

info "Seed a message that is nothing but a bank stamp"
sql "INSERT INTO messages(conversation_id,body,timestamp,status) VALUES($CID,'$STAMP',$((TS + 1000)),'received');" >/dev/null 2>&1
ok "stamp-only message seeded"

info "Open the conversation"
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" --es open_conversation_address "$NUM" >/dev/null 2>&1
sleep 6
if ! dump_ui; then
    bad "uiautomator dump failed"
    echo ""
    echo "=== RESULTS: $PASS passed, $FAIL failed ==="
    exit 1
fi

if python3 - "$TMP/ui.xml" "$NUMBER" <<'PY'
import sys
xml = open(sys.argv[1], encoding='utf-8', errors='replace').read()
# Normalise what the app may have added: isolates, and the non-breaking
# stand-ins it puts inside them.
for ch in ("\u2066", "\u2069", "\u00a0", "\u2011"):
    xml = xml.replace(ch, " " if ch == "\u00a0" else "-" if ch == "\u2011" else "")
raise SystemExit(0 if sys.argv[2] in xml else 1)
PY
then
    ok "the conversation opened on the seeded chat"
else
    bad "the conversation did not open on the seeded chat"
fi

# The body must be one isolate, with its groups in the order the sender wrote
# them. Before the fix the string reached the renderer bare, so the LRI/PDI
# check is what fails.
check_pinned() {
    local label="$1" shown="$2" raw="$3"
    out=$(python3 - "$TMP/ui.xml" "$LRI" "$PDI" "$shown" "$raw" <<'PY'
import sys
xml = open(sys.argv[1], encoding='utf-8', errors='replace').read()
lri, pdi, value, raw = sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
print("yes" if lri + value + pdi in xml else "no")
shown = xml
for ch in (lri, pdi, "\u00a0", "\u2011"):
    shown = shown.replace(ch, " " if ch == "\u00a0" else "-" if ch == "\u2011" else "")
print("shown" if raw in shown else "missing")
PY
)
    if [ "$(echo "$out" | sed -n 1p)" = "yes" ]; then
        ok "$label is rendered inside one LTR isolate"
    else
        bad "$label is not pinned, so RTL lays its groups out backwards"
    fi
    if [ "$(echo "$out" | sed -n 2p)" = "shown" ]; then
        ok "$label is on screen"
    else
        bad "$label is missing from the rendered text"
    fi
}

check_pinned "the number-only body $NUMBER" "$NUMBER_DISPLAY" "$NUMBER"
check_pinned "the stamp-only body $STAMP" "$STAMP_DISPLAY" "$STAMP"

# Nothing may be handed over in reverse: the failure mode is the whole run
# flipped, which would put the last group first inside the isolate.
out=$(python3 - "$TMP/ui.xml" "$LRI" "$PDI" <<'PY'
import sys
xml = open(sys.argv[1], encoding='utf-8', errors='replace').read()
lri, pdi = sys.argv[2], sys.argv[3]
spans, i = [], 0
while True:
    a = xml.find(lri, i)
    if a < 0:
        break
    b = xml.find(pdi, a)
    if b < 0:
        break
    spans.append(xml[a + 1:b])
    i = b + 1
print("reversed" if any(s.strip().startswith("7899") for s in spans) else "ordered")
print(len([s for s in spans if "0123" in s]))
PY
)
if [ "$(echo "$out" | sed -n 1p)" = "ordered" ]; then
    ok "no isolated run starts with the last digit group"
else
    bad "an isolated run holds the body in reverse order"
fi
if [ "$(echo "$out" | sed -n 2p)" = "1" ]; then
    ok "the number is isolated exactly once"
else
    bad "expected one isolate holding the number, found $(echo "$out" | sed -n 2p)"
fi

echo ""
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
