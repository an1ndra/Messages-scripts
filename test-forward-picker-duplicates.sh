#!/usr/bin/env bash
# Regression for #405 follow-up (point 1): "some numbers are duplicated in the
# forward list".
#
# A person reaches the picker twice — once from the address book, once from an
# existing thread — and the two spellings were deduplicated on their raw digits.
# The phone book holds "(555) 016-7788" while the thread is addressed
# "+15550167788", so the digits differ ("5550167788" vs "15550167788") and the
# same person was listed twice, with two different renderings of one number.
# Rows are now keyed on the number's identity (E.164 where the region can parse
# it), so both spellings collapse into the contact's row.
#
# Fails on the pre-fix build: the picker lists the name twice.
#
# Run: scripts/test-forward-picker-duplicates.sh
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

MARK="fdup$(date +%s)$$"
FORWARD_LABEL=$(res_string chat_forward)
FORWARD_TO=$(res_string chat_forward_to)
NAME="Kami${MARK}"
SEARCH="Kami${MARK:0:6}"
STORED="555.016.7788"          # the address book's spelling
ADDRESS="+15550167788"         # the thread's spelling of the same number
SELF="+1555984${MARK: -4}"
SEEDED_RID=""

adb_ root >/dev/null 2>&1; adb_ wait-for-device; sleep 1
sql() { adb_ shell "sqlite3 /data/data/$PKG/databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r'; }

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    if [ -n "$SEEDED_RID" ]; then
        adb_ shell content delete --uri content://com.android.contacts/raw_contacts \
            --where "\"_id=$SEEDED_RID\"" >/dev/null 2>&1 || true
    fi
    sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$ADDRESS' OR address='$SELF');" >/dev/null 2>&1
    sql "DELETE FROM conversations WHERE address='$ADDRESS' OR address='$SELF';" >/dev/null 2>&1
}
trap cleanup EXIT

for p in READ_SMS RECEIVE_SMS READ_CONTACTS POST_NOTIFICATIONS READ_PHONE_STATE; do
    adb_ shell pm grant "$PKG" "android.permission.$p" >/dev/null 2>&1
done
adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1 || true
adb_ shell am force-stop "$PKG" >/dev/null 2>&1
sleep 1

info "One person, two spellings: contact '$STORED', thread '$ADDRESS'"
MAXID=$(adb_ shell content query --uri content://com.android.contacts/raw_contacts \
    --projection _id 2>/dev/null | grep -oE '_id=[0-9]+' | cut -d= -f2 | sort -n | tail -1)
RID=$(( ${MAXID:-0} + 1 ))
adb_ shell content insert --uri content://com.android.contacts/raw_contacts \
    --bind account_type:s:local --bind account_name:s:regression \
    --bind _id:i:"$RID" >/dev/null 2>&1
SEEDED_RID=$RID
adb_ shell content insert --uri content://com.android.contacts/data \
    --bind raw_contact_id:i:"$RID" \
    --bind mimetype:s:vnd.android.cursor.item/name \
    --bind data1:s:"$NAME" --bind data2:s:"$NAME" >/dev/null 2>&1
adb_ shell content insert --uri content://com.android.contacts/data \
    --bind raw_contact_id:i:"$RID" \
    --bind mimetype:s:vnd.android.cursor.item/phone_v2 \
    --bind data1:s:"$STORED" --bind data2:s:2 >/dev/null 2>&1
if adb_ shell content query --uri content://com.android.contacts/data \
    --projection data1 --where "\"data1='$STORED'\"" 2>/dev/null | grep -qF "data1=$STORED"; then
    ok "contact seeded as '$STORED'"
else
    bad "could not seed the contact"
    exit 1
fi

TS=$(date +%s000)
sql "INSERT INTO conversations(address,name,snippet,timestamp,unread_count) VALUES('$ADDRESS','$NAME','$MARK',$TS,0);" >/dev/null 2>&1
CID=$(sql "SELECT id FROM conversations WHERE address='$ADDRESS';")
[ -z "$CID" ] && { bad "could not seed the thread"; exit 1; }
sql "INSERT INTO messages(conversation_id,body,timestamp,status) VALUES($CID,'$MARK',$TS,'received');" >/dev/null 2>&1
ok "thread seeded as '$ADDRESS'"

info "Open the thread and start a forward"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1
adb_ shell am start -n "$ACT" --es open_conversation_address "$ADDRESS" >/dev/null 2>&1
if ! wait_for_text "$MARK" 14; then
    bad "seeded message never rendered in the chat"
    exit 1
fi
BUBBLE=$(center_of "$MARK") || { bad "could not locate the bubble"; exit 1; }
adb_ shell input swipe $BUBBLE $BUBBLE 800; sleep 3
FWD=""
for _ in $(seq 1 6); do
    FWD=$(center_of "$FORWARD_LABEL" 2>/dev/null) && [ -n "$FWD" ] && break
    sleep 1
done
[ -n "$FWD" ] || { bad "no Forward button on the selection toolbar"; exit 1; }
adb_ shell input tap $FWD; sleep 3
if wait_for_text "$FORWARD_TO" 8; then
    ok "Forward opened the target picker"
else
    bad "Forward did not open the target picker"
    exit 1
fi

info "Search the name, then count the rows that carry it"
if tap_edittext >/dev/null 2>&1; then
    type_text "$SEARCH"; sleep 2
else
    bad "could not focus the picker's search box"
    exit 1
fi
if ! wait_for_text "$NAME" 8; then
    bad "the seeded person is not in the picker at all"
    exit 1
fi

# The search box holds the same name, so only nodes whose whole text is the name
# are rows. Two spellings of one person used to give two of them.
rows=$(python3 - "$TMP/ui.xml" "$NAME" <<'PY'
import re, sys, html
xml = open(sys.argv[1], encoding="utf-8", errors="replace").read()
want = html.unescape(sys.argv[2])
texts = [html.unescape(t) for t in re.findall(r'text="([^"]*)"', xml)]
print(sum(1 for t in texts if t == want), end="")
PY
)
if [ "$rows" = "1" ]; then
    ok "the person is listed once"
else
    bad "the person is listed $rows times (one row per spelling of the number)"
fi

# Both spellings must resolve to the same row, and the row keeps the address
# book's wording rather than the thread's.
numbers=$(python3 - "$TMP/ui.xml" <<'PY'
import re, sys, html
xml = open(sys.argv[1], encoding="utf-8", errors="replace").read()
texts = [html.unescape(t) for t in re.findall(r'text="([^"]*)"', xml)]
hit = [t for t in texts if "016" in t and "7788" in t]
print(len(hit), end="")
PY
)
if [ "$numbers" = "1" ]; then
    ok "the number itself is painted once"
else
    bad "the number appears $numbers times in the picker"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
