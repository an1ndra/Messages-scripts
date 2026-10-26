#!/usr/bin/env bash
# Regression for #345 (second half, card numbers): a Pasargad card-transfer SMS
# carries masked card numbers - digits around Latin 'x' masks. The 'x' letters
# are strong LTR, so while they stayed outside the number run the digits
# reordered around them and the reporter could only read the card by selecting
# it. The number run now swallows the masks, so each card stays one contiguous
# LTR isolate.
#
# uiautomator reports the text as the app hands it to the renderer, so the
# isolates the app inserts (U+2066 … U+2069) are visible in the dump. That is
# the assertion: the card is isolated whole. Visual order itself is the
# platform's job once the isolates are there.
#
# Run: scripts/test-bidi-card-numbers.sh
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

MARK="card$(date +%s)$$"
NUM="+1555986${MARK: -4}"
LRI=$'\u2066'
PDI=$'\u2069'
CARD1="5022-29xx-xxxx-9227"
CARD2="6104-33xx-xxxx-8284"
STAMP="22:20:51 1405/08/03"

adb_ root >/dev/null 2>&1; adb_ wait-for-device; sleep 1
sql() { adb_ shell "sqlite3 /data/data/$PKG/databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r'; }

# SQLite string literal for a multi-line body: a literal newline on the adb
# command line does not survive the trip. char(10) keeps each line a line.
sqltext() {
    python3 - "$1" <<'PY'
import sys
print("||char(10)||".join("'%s'" % line.replace("'", "''")
      for line in sys.argv[1].split("\n")), end="")
PY
}

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM');" >/dev/null 2>&1
    sql "DELETE FROM conversations WHERE address='$NUM';" >/dev/null 2>&1
}
trap cleanup EXIT

for p in READ_SMS RECEIVE_SMS READ_CONTACTS POST_NOTIFICATIONS; do
    adb_ shell pm grant "$PKG" "android.permission.$p" >/dev/null 2>&1
done

info "Seed the reporter's verbatim Pasargad body"
TS=$(date +%s000)
BODY="کارت مبدا:
$CARD1
کارت مقصد:
$CARD2
نام دریافت کننده: 
مبلغ:00000000 ریال
تاریخ انتقال:$STAMP"
sql "INSERT INTO conversations(address,name,snippet,timestamp,unread_count) VALUES('$NUM','$MARK','$MARK',$TS,0);" >/dev/null 2>&1
CID=$(sql "SELECT id FROM conversations WHERE address='$NUM';")
[ -z "$CID" ] && { bad "could not seed a conversation"; exit 1; }
sql "INSERT INTO messages(conversation_id,body,timestamp,status) VALUES($CID,$(sqltext "$BODY"),$TS,'received');" >/dev/null 2>&1
ok "card transfer seeded"

info "Open the conversation"
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" --es open_conversation_address "$NUM" >/dev/null 2>&1
sleep 6
dump_ui

# The seeded snippet is the marker, so the bubble's own wording proves the chat
# opened rather than the list row being dumped.
if ! grep -q "کارت" "$TMP/ui.xml"; then
    bad "the conversation did not open on the seeded chat"
else
    ok "conversation opened"
fi

# Each card must sit inside its own LTR isolate, whole.
check_isolated() {
    local label="$1" value="$2"
    out=$(python3 - "$TMP/ui.xml" "$LRI" "$PDI" "$value" <<'PY'
import sys
xml = open(sys.argv[1], encoding='utf-8', errors='replace').read()
lri, pdi, value = sys.argv[2], sys.argv[3], sys.argv[4]
print("yes" if lri + value + pdi in xml else "no")
print("raw" if value in xml else "absent")
PY
)
    if [ "$(echo "$out" | sed -n 1p)" = "yes" ]; then
        ok "$label is rendered inside one LTR isolate"
    else
        bad "$label is not isolated whole (the digits reorder around the x masks)"
    fi
    if [ "$(echo "$out" | sed -n 2p)" = "raw" ]; then
        ok "$label itself is still on screen"
    else
        bad "$label is missing from the rendered text"
    fi
}

check_isolated "the source card $CARD1" "$CARD1"
check_isolated "the destination card $CARD2" "$CARD2"
check_isolated "the transfer stamp $STAMP" "$STAMP"

info "The bare amount has no separators and stays a plain digit run"
# 'مبلغ:00000000' has nothing to reorder: no mask letters, no separators. The
# run isolator deliberately leaves a pure digit run alone.
if python3 - "$TMP/ui.xml" <<'PY'
import sys
xml = open(sys.argv[1], encoding='utf-8', errors='replace').read()
raise SystemExit(0 if "مبلغ:00000000 ریال" in xml else 1)
PY
then
    ok "the amount line is on screen unisolated"
else
    bad "the amount line lost its digits or gained a stray isolate"
fi

echo ""
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
