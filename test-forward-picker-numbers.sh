#!/usr/bin/env bash
# Regression for #405 follow-up: how the forward picker paints a contact's
# number.
#
# The reporter's Samsung phone book showed "091-210-4456", "300-033-03" and
# "671-5014" in the forward list while the same entries were saved without
# separators. The Contacts provider had stored the separators; the picker
# painted `Contact.number` verbatim, so the list disagreed with the phone book
# it had just read. The row now goes through formatPhoneNumber(), the same
# locale-aware NATIONAL formatting every other number row uses, and the raw
# number is still what the row hands back when it is tapped.
#
# Fails on the pre-fix build: the row paints the provider's dotted spelling.
#
# Run: scripts/test-forward-picker-numbers.sh
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

MARK="fwdnum$(date +%s)$$"
CONTACT="NumberFormat$MARK"
STORED="555.010.1234"        # the provider's spelling
PAINTED="(555) 010-1234"     # libphonenumber NATIONAL, region US
SELF="+1555986${MARK: -4}"
SEEDED_RID=""

adb_ root >/dev/null 2>&1; adb_ wait-for-device; sleep 1
sql() { adb_ shell "sqlite3 /data/data/$PKG/databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r'; }

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    if [ -n "$SEEDED_RID" ]; then
        adb_ shell content delete --uri content://com.android.contacts/raw_contacts \
            --where "\"_id=$SEEDED_RID\"" >/dev/null 2>&1 || true
    fi
    sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$SELF');" >/dev/null 2>&1
    sql "DELETE FROM conversations WHERE address='$SELF';" >/dev/null 2>&1
}
trap cleanup EXIT

for p in READ_SMS RECEIVE_SMS READ_CONTACTS POST_NOTIFICATIONS READ_PHONE_STATE; do
    adb_ shell pm grant "$PKG" "android.permission.$p" >/dev/null 2>&1
done
adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1 || true
adb_ shell am force-stop "$PKG" >/dev/null 2>&1
sleep 1

info "Seeding a contact whose number carries the provider's separators ('$STORED')"
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
    --bind data1:s:"$CONTACT" --bind data2:s:"$CONTACT" >/dev/null 2>&1
adb_ shell content insert --uri content://com.android.contacts/data \
    --bind raw_contact_id:i:"$RID" \
    --bind mimetype:s:vnd.android.cursor.item/phone_v2 \
    --bind data1:s:"$STORED" --bind data2:s:2 >/dev/null 2>&1
if adb_ shell content query --uri content://com.android.contacts/data \
    --projection data1 --where "\"data1='$STORED'\"" 2>/dev/null | grep -qF "data1=$STORED"; then
    ok "contact is on the device spelled '$STORED'"
else
    bad "could not seed the contact with the provider spelling"
    exit 1
fi

info "Seeding a message to forward, and opening its chat"
TS=$(date +%s000)
sql "INSERT INTO conversations(address,name,snippet,timestamp,unread_count) VALUES('$SELF','$MARK','$MARK',$TS,0);" >/dev/null 2>&1
CID=$(sql "SELECT id FROM conversations WHERE address='$SELF';")
[ -z "$CID" ] && { bad "could not seed a conversation"; exit 1; }
sql "INSERT INTO messages(conversation_id,body,timestamp,status) VALUES($CID,'$MARK',$TS,'received');" >/dev/null 2>&1
adb_ shell am force-stop "$PKG" >/dev/null 2>&1
adb_ shell am start -n "$ACT" --es open_conversation_address "$SELF" >/dev/null 2>&1
if ! wait_for_text "$MARK" 14; then
    bad "seeded message never rendered in the chat"
    exit 1
fi
ok "message bubble opened"

BUBBLE=$(center_of "$MARK") || { bad "could not locate the bubble"; exit 1; }
adb_ shell input swipe $BUBBLE $BUBBLE 800; sleep 3
FWD=""
for _ in $(seq 1 6); do
    FWD=$(center_of "Forward" 2>/dev/null) && [ -n "$FWD" ] && break
    sleep 1
done
if [ -n "$FWD" ]; then
    ok "long-press opened the selection toolbar with a Forward button"
else
    bad "no Forward button on the selection toolbar"
    exit 1
fi
adb_ shell input tap $FWD; sleep 3

if wait_for_text "Forward to" 8; then
    ok "Forward opened the target picker"
else
    bad "Forward did not open the target picker"
    exit 1
fi

info "The row paints the canonical number, not the provider's spelling"
# The picker lists every contact underneath the recent conversations, and on a
# busy device the seeded row is far below the 300dp list. Search narrows it.
if tap_edittext >/dev/null 2>&1; then
    type_text "$MARK"; sleep 2
else
    bad "could not focus the picker's search box"
    exit 1
fi
if wait_for_text "$CONTACT" 8; then
    ok "the seeded contact is in the picker"
else
    bad "the seeded contact never appeared in the picker"
    exit 1
fi
if python3 - "$TMP/ui.decoded.xml" "$PAINTED" "$STORED" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
canonical, stored = sys.argv[2], sys.argv[3]
sys.exit(0 if canonical in text and stored not in text else 1)
PY
then
    ok "the row paints '$PAINTED' and never '$STORED'"
else
    bad "expected '$PAINTED' with no '$STORED' in the row"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
