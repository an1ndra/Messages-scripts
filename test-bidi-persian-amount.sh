#!/usr/bin/env bash
# Regression for #345 (second half): a Persian bank SMS whose balance is written
# in Extended Arabic-Indic digits with U+066C thousands separators must have that
# number pinned left-to-right, or the bidi algorithm drops the following word
# ("مانده") into the middle of the amount.
#
# uiautomator reports the text as the app hands it to the renderer, so the
# isolates the app inserts (U+2066 … U+2069) are visible in the dump. That is the
# assertion: the number is isolated. Visual order itself is the platform's job
# once the isolates are there, and a screenshot would not be more reliable.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

MARK="bank$(date +%s)$$"
NUM="+1555984${MARK: -4}"
LRI=$'\u2066'
PDI=$'\u2069'
AMOUNT="۱۲۳٬۴۵۶٬۷۸۹"
BODY="موجودی: $AMOUNT ریال مانده"

adb_ root >/dev/null 2>&1; adb_ wait-for-device; sleep 1
sql() { adb_ shell "sqlite3 /data/data/$PKG/databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r'; }

cleanup() {
    sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM');" >/dev/null 2>&1
    sql "DELETE FROM conversations WHERE address='$NUM';" >/dev/null 2>&1
}
trap cleanup EXIT

for p in READ_SMS RECEIVE_SMS READ_CONTACTS POST_NOTIFICATIONS; do
    adb_ shell pm grant "$PKG" "android.permission.$p" >/dev/null 2>&1
done

info "Seed the bank message"
TS=$(date +%s000)
sql "INSERT INTO conversations(address,name,snippet,timestamp,unread_count) VALUES('$NUM','$MARK','$MARK',$TS,0);" >/dev/null 2>&1
CID=$(sql "SELECT id FROM conversations WHERE address='$NUM';")
[ -z "$CID" ] && { bad "could not seed a conversation"; exit 1; }
sql "INSERT INTO messages(conversation_id,body,timestamp,status) VALUES($CID,'$BODY',$TS,'received');" >/dev/null 2>&1
ok "bank message seeded"

info "Open the conversation"
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" --es open_conversation_address "$NUM" >/dev/null 2>&1
sleep 6
dump_ui

# The seeded snippet is the marker, so the bubble's own wording proves the chat
# opened rather than the list row being dumped.
if ! grep -q "موجودی" "$TMP/ui.xml"; then
    bad "the conversation did not open on the seeded chat"
else
    ok "conversation opened"
fi

# The inbox row's snippet is rendered through the same isolation path, so check
# the chat bubble first, then fall back to the list row.
out=$(python3 - "$TMP/ui.xml" "$LRI" "$PDI" "$AMOUNT" <<'PY'
import sys
xml = open(sys.argv[1], encoding='utf-8', errors='replace').read()
lri, pdi, amount = sys.argv[2], sys.argv[3], sys.argv[4]
wanted = lri + amount + pdi
print("yes" if wanted in xml else "no")
print("raw" if amount in xml else "absent")
PY
)
isolated=$(echo "$out" | sed -n 1p)
raw=$(echo "$out" | sed -n 2p)

if [ "$isolated" = "yes" ]; then
    ok "the balance is rendered inside an LTR isolate"
else
    bad "the balance is not isolated, so a following word can reorder into it"
fi
if [ "$raw" = "raw" ]; then
    ok "the amount itself is still on screen"
else
    bad "the amount is missing from the rendered text"
fi

info "A Latin-script message is left alone"
# No strong RTL character -> no isolates, otherwise an LTR chat would be split
# into reordered runs.
sql "UPDATE messages SET body='balance: $AMOUNT rials' WHERE conversation_id=$CID;" >/dev/null 2>&1
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" --es open_conversation_address "$NUM" >/dev/null 2>&1
sleep 6
dump_ui
if python3 - "$TMP/ui.xml" "$LRI" "$AMOUNT" <<'PY'
import sys
xml = open(sys.argv[1], encoding='utf-8', errors='replace').read()
raise SystemExit(0 if (sys.argv[2] + sys.argv[3]) in xml else 1)
PY
then
    bad "an LTR message got isolated number runs"
else
    ok "an LTR message is not isolated"
fi

info "The issue's own Saman line, written in ASCII digits"
# #345's screenshot renders "78,556,010" as "78,556 مانده ,010" on 1.0.30: the
# bank wrote the balance in ASCII digits with ASCII commas, and only the
# Persian-digit form was pinned. The same run must be isolated whole.
ASCII="78,556,010"
sql "UPDATE messages SET body='بانک سامان
برداشت مبلغ
خرید کالا
مانده $ASCII
1405/7/28
10:58:22' WHERE conversation_id=$CID;" >/dev/null 2>&1
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" --es open_conversation_address "$NUM" >/dev/null 2>&1
sleep 6
dump_ui
out=$(python3 - "$TMP/ui.xml" "$LRI" "$PDI" "$ASCII" <<'PY'
import sys
xml = open(sys.argv[1], encoding='utf-8', errors='replace').read()
lri, pdi, amount = sys.argv[2], sys.argv[3], sys.argv[4]
print("yes" if lri + amount + pdi in xml else "no")
print("raw" if amount in xml else "absent")
PY
)
if [ "$(echo "$out" | sed -n 1p)" = "yes" ]; then
    ok "the ASCII-digit balance is rendered inside one LTR isolate"
else
    bad "the ASCII-digit balance is not isolated, so مانده can reorder into it"
fi
if [ "$(echo "$out" | sed -n 2p)" = "raw" ]; then
    ok "the ASCII amount itself is still on screen"
else
    bad "the ASCII amount is missing from the rendered text"
fi

echo ""
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
