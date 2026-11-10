#!/usr/bin/env bash
# Regression: #444 -- a contact stored with a country code ("+46701234567")
# must be matched for a conversation whose address arrives without one
# ("0701234567"), even when the receiving SIM is in a different country.
#
# Pre-fix: the row kept the raw number as its name. Post-fix: the contact name.
#
# Run: scripts/test-444-contact-country-code.sh
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh

PASS=0
FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }

NUM_NAT="0701234567"
NUM_E164="+46701234567"
CNAME="Probe444$RANDOM"
SID="probe444$(date +%s)$RANDOM"

db_sql() {
    adb_ shell "run-as $PKG sqlite3 databases/messages.db \"$1\"" 2>/dev/null && return 0
    adb_ shell "su -c \"sqlite3 /data/data/$PKG/databases/messages.db \\\"$1\\\"\"" 2>/dev/null || true
}

scrub() {
    adb_ shell "content delete --uri content://com.android.contacts/raw_contacts --where \"sourceid LIKE 'probe444%'\"" >/dev/null 2>&1 || true
    db_sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM_NAT' OR address='$NUM_E164' OR address='+10701234567'); DELETE FROM conversations WHERE address='$NUM_NAT' OR address='$NUM_E164' OR address='+10701234567'; DELETE FROM participants WHERE normalized_destination='$NUM_E164' OR normalized_destination='+10701234567';" >/dev/null 2>&1 || true
}
trap scrub EXIT

# Seed the contact with a country code.
adb_ shell "content insert --uri content://com.android.contacts/raw_contacts --bind account_name:s:probe --bind account_type:s:com.local --bind sourceid:s:$SID" >/dev/null 2>&1
RID=$(adb_ shell "content query --uri content://com.android.contacts/raw_contacts --projection _id --where \"sourceid='$SID'\"" 2>/dev/null \
    | grep -oE '_id=[0-9]+' | head -1 | cut -d= -f2 | tr -d '\r')
[ -n "$RID" ] || { echo "could not create raw contact"; exit 1; }
adb_ shell "content insert --uri content://com.android.contacts/data --bind raw_contact_id:l:$RID --bind mimetype:s:vnd.android.cursor.item/name --bind data1:s:$CNAME" >/dev/null 2>&1
adb_ shell "content insert --uri content://com.android.contacts/data --bind raw_contact_id:l:$RID --bind mimetype:s:vnd.android.cursor.item/phone_v2 --bind data1:s:$NUM_E164 --bind data2:l:0" >/dev/null 2>&1

# Take the SMS role for our app BEFORE injecting, so the SMS is delivered to us.
adb_ shell "su -c 'cmd role add-role-holder android.app.role.SMS $PKG'" >/dev/null 2>&1
sleep 1

# Give the contacts provider a moment, then inject the SMS.
sleep 2
adb_ emu sms send "$NUM_NAT" "probe 444" >/dev/null 2>&1
sleep 4

adb_ shell "am force-stop $PKG" >/dev/null 2>&1
adb_ shell "monkey -p $PKG -c android.intent.category.LAUNCHER 1" >/dev/null 2>&1
sleep 12

# Dump and check.
adb_ shell "uiautomator dump /sdcard/ui444.xml" >/dev/null 2>&1
adb_ pull /sdcard/ui444.xml "$TMP/ui444.xml" >/dev/null 2>&1 || true
if grep -q "$CNAME" "$TMP/ui444.xml"; then
    pass "contact name resolved for country-code-mismatched number"
else
    fail "contact name NOT resolved (still shows the raw number)"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]