#!/usr/bin/env bash
# Regression: the conversation-details screen shows the saved contact NAME and
# the phone NUMBER beneath it. Previously a saved contact showed only the name
# (the number was never rendered).
#
# Seeds its own contact + conversation so it does not depend on demo data.
# Run: scripts/test-contact-details.sh
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh

PASS=0
FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }

NAME="Sarah"
NUM="+15551230010"
SID="contactdetails$(date +%s)"

db_sql() {
    adb_ shell "run-as $PKG sqlite3 databases/messages.db \"$1\"" >/dev/null 2>&1 && return 0
    adb_ shell "su -c \"sqlite3 /data/data/$PKG/databases/messages.db \\\"$1\\\"\"" >/dev/null 2>&1 || true
}

delete_thread() {
    db_sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM'); DELETE FROM conversations WHERE address='$NUM'; DELETE FROM participants WHERE normalized_destination='$NUM';"
}

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    delete_thread
}
trap cleanup EXIT

seed_contact() {
    adb_ shell "content insert --uri content://com.android.contacts/raw_contacts --bind account_name:s:demo --bind account_type:s:com.local --bind sourceid:s:$SID" >/dev/null 2>&1
    local rid
    rid=$(adb_ shell "content query --uri content://com.android.contacts/raw_contacts --projection _id --where \"sourceid='$SID'\"" 2>/dev/null | grep -oE '_id=[0-9]+' | head -1 | cut -d= -f2 | tr -d '\r')
    [ -z "$rid" ] && return 1
    adb_ shell "content insert --uri content://com.android.contacts/data --bind raw_contact_id:l:$rid --bind mimetype:s:vnd.android.cursor.item/name --bind data1:s:$NAME" >/dev/null 2>&1
    adb_ shell "content insert --uri content://com.android.contacts/data --bind raw_contact_id:l:$rid --bind mimetype:s:vnd.android.cursor.item/phone_v2 --bind data1:s:$NUM --bind data2:l:0" >/dev/null 2>&1
}

info "seeding saved contact $NAME / $NUM"
seed_contact || fail 'could not seed the saved contact'
adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1 || true
bash ./grant-permissions.sh >/dev/null 2>&1 || true

info "seeding an incoming SMS from $NUM"
delete_thread
adb_ shell am start -n "$ACT" >/dev/null; sleep 3
adb_ emu sms send "$NUM" "details probe $(date +%s)" >/dev/null
sleep 3
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" --es open_conversation_address "$NUM" >/dev/null; sleep 4

dump_ui >/dev/null 2>&1
if grep -qE 'text="[^"]*Sarah[^"]*"' "$TMP/ui.xml"; then
    pass 'chat header shows the saved contact name'
else
    fail 'chat header does not show the saved contact name'
fi

info "opening conversation details"
c=$(center_of_contains "More options") || c=""
[ -n "$c" ] && adb_ shell input tap $c; sleep 1
c=$(center_of "Details") || c=""
[ -n "$c" ] && adb_ shell input tap $c; sleep 2
dump_ui >/dev/null 2>&1

if grep -q 'text="Notifications"' "$TMP/ui.xml"; then
    pass 'reached the conversation-details screen'
else
    fail 'could not open the conversation-details screen'
fi
if grep -qE 'text="[^"]*Sarah[^"]*"' "$TMP/ui.xml"; then
    pass 'details screen shows the saved contact name'
else
    fail 'details screen is missing the saved contact name'
fi
if grep -qE 'text="[^"]*0010[^"]*"' "$TMP/ui.xml"; then
    pass 'details screen shows the phone number beneath the name'
else
    fail 'details screen hides the phone number for a saved contact'
fi

printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
