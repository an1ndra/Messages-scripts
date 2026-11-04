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
# #405: the app paints spaces and hyphens inside an isolated run as U+00A0 and
# U+2011 so a card cannot wrap across two lines; the dump therefore carries the
# non-breaking form, not the raw body.
NBSP=$' '
NBHYPHEN=$'‑'
CARD1_DISPLAY="${CARD1//-/$NBHYPHEN}"
CARD2_DISPLAY="${CARD2//-/$NBHYPHEN}"
STAMP_DISPLAY="${STAMP/ /$NBSP}"
STARRED_RAW="5022 **29 **** 9227"
STARRED_DISPLAY="5022${NBSP}**29${NBSP}****${NBSP}9227"

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

info "Seed the #405 star-masked card in the same chat"
# #405's screenshot: "5022 **29 **** 9227" wrapped mid-card because the spaces
# inside the isolate were still break opportunities.
sql "INSERT INTO messages(conversation_id,body,timestamp,status) VALUES($CID,'به کارت $STARRED_RAW به نام آقا/خانم',$((TS + 1000)),'received');" >/dev/null 2>&1
ok "#405 card seeded"

info "Open the conversation"
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" --es open_conversation_address "$NUM" >/dev/null 2>&1
sleep 6
if ! dump_ui; then
    # A stale ui.xml from an earlier run would make every check below assert on
    # text the current build never painted.
    bad "uiautomator dump failed"
    echo ""
    echo "=== RESULTS: $PASS passed, $FAIL failed ==="
    exit 1
fi

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

check_isolated "the source card $CARD1" "$CARD1_DISPLAY"
check_isolated "the destination card $CARD2" "$CARD2_DISPLAY"
check_isolated "the transfer stamp $STAMP" "$STAMP_DISPLAY"

info "The #405 star-masked card cannot break inside the isolate"
# The isolate fixes order but not wrapping: LRI/PDI are combining marks, not
# glue, so an ASCII space inside the run is still a line-break opportunity. The
# painted run must hold no ordinary space (and no breakable hyphen).
out=$(python3 - "$TMP/ui.xml" "$LRI" "$PDI" "$STARRED_DISPLAY" <<'PY'
import sys
xml = open(sys.argv[1], encoding='utf-8', errors='replace').read()
lri, pdi, wanted = sys.argv[2], sys.argv[3], sys.argv[4]
spans, i = [], 0
while True:
    a = xml.find(lri, i)
    if a < 0:
        break
    b = xml.find(pdi, a)
    if b < 0:
        break
    spans.append((a, xml[a + 1:b]))
    i = b + 1
card = [s for _, s in spans if "**29" in s]
print("isolated" if any(s == wanted for s in card) else "no")
print("breakable" if any((" " in s or "-" in s) for s in card) else "glued")
PY
)
if [ "$(echo "$out" | sed -n 1p)" = "isolated" ]; then
    ok "the #405 card is one isolate with non-breaking separators"
else
    bad "the #405 card is not the expected non-breaking isolate"
fi
if [ "$(echo "$out" | sed -n 2p)" = "glued" ]; then
    ok "no breakable space or hyphen survives inside the card"
else
    bad "the card still contains an ASCII space or hyphen, so it can wrap"
fi

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
