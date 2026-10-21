#!/usr/bin/env bash
# Regression: #317 -- a contact added or renamed in the phone book must reach
# the conversation list while the app stays in front.
#
# The app watched the SMS/MMS provider but never Contacts, and names were only
# re-resolved from `MainActivity.onResume` behind a 5-minute gate. So a contact
# edited while Messages was open kept its old name (the reporter measured 20
# minutes to 2 hours) until some later resume happened to clear the gate.
#
# This seeds a conversation with no matching contact, leaves the app on the list
# and inserts/renames the contact underneath it without ever leaving the screen.
# Pre-fix the row keeps the number/old name; post-fix it refreshes in place.
#
# The list row hides its children behind a single a11y node, so assertions match
# the row's content-desc, not a TextView's text.
#
# Run: scripts/test-contact-name-refresh.sh
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh

PASS=0
FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }

# A fresh number each run keeps stale contacts/conversations out of the way.
NUM="+1555$(printf '%06d' $((RANDOM % 1000000)))"
ADD_NAME="AddProbe$RANDOM"
REN_NAME="RenameProbe$RANDOM"
SID="probe$(date +%s)$RANDOM"
BODY="contact refresh probe $RANDOM"
TS=$(date +%s%3N)

db_sql() {
    adb_ shell "run-as $PKG sqlite3 databases/messages.db \"$1\"" 2>/dev/null && return 0
    adb_ shell "su -c \"sqlite3 /data/data/$PKG/databases/messages.db \\\"$1\\\"\"" 2>/dev/null || true
}

scrub() {
    adb_ shell "content delete --uri content://com.android.contacts/raw_contacts --where \"sourceid LIKE 'probe%'\"" >/dev/null 2>&1 || true
    db_sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM'); DELETE FROM conversations WHERE address='$NUM'; DELETE FROM participants WHERE normalized_destination='$NUM';" >/dev/null 2>&1 || true
}
trap scrub EXIT

seed_contact() { # number, name -> prints raw contact id
    adb_ shell "content insert --uri content://com.android.contacts/raw_contacts --bind account_name:s:probe --bind account_type:s:com.local --bind sourceid:s:$SID" >/dev/null 2>&1
    local rid
    rid=$(adb_ shell "content query --uri content://com.android.contacts/raw_contacts --projection _id --where \"sourceid='$SID'\"" 2>/dev/null \
        | grep -oE '_id=[0-9]+' | head -1 | cut -d= -f2 | tr -d '\r')
    [ -n "$rid" ] || return 1
    adb_ shell "content insert --uri content://com.android.contacts/data --bind raw_contact_id:l:$rid --bind mimetype:s:vnd.android.cursor.item/name --bind data1:s:$2" >/dev/null 2>&1
    adb_ shell "content insert --uri content://com.android.contacts/data --bind raw_contact_id:l:$rid --bind mimetype:s:vnd.android.cursor.item/phone_v2 --bind data1:s:$1 --bind data2:l:0" >/dev/null 2>&1
    echo "$rid"
}

rename_contact() { # raw id, new name
    adb_ shell "content update --uri content://com.android.contacts/data --where \"raw_contact_id=$1 AND mimetype='vnd.android.cursor.item/name'\" --bind data1:s:$2" >/dev/null 2>&1
    local ver
    ver=$(adb_ shell "content query --uri content://com.android.contacts/raw_contacts --projection version --where \"_id=$1\"" 2>/dev/null | grep -oE 'version=[0-9]+' | head -1 | cut -d= -f2 | tr -d '\r')
    [ -n "$ver" ] && adb_ shell "content update --uri content://com.android.contacts/raw_contacts/$1 --bind version:i:$ver" >/dev/null 2>&1 || true
}

seed_conversation() {
    db_sql "INSERT INTO conversations (address,name,snippet,timestamp) VALUES ('$1','$1','$BODY',$TS);"
    local cid
    cid=$(db_sql "SELECT id FROM conversations WHERE address='$1';" | tail -1)
    [ -n "$cid" ] || return 1
    db_sql "INSERT INTO messages (conversation_id,body,timestamp,status) VALUES ($cid,'$BODY',$TS,'sent');"
}

# Poll until the dump contains $1, and (optionally) no longer contains $2.
wait_row() { # want, gone, tries
    local i
    for i in $(seq 1 "${3:-30}"); do
        dump_ui >/dev/null 2>&1 || true
        if grep -qF "$1" "$TMP/ui.xml" 2>/dev/null; then
            if [ -z "$2" ] || ! grep -qF "$2" "$TMP/ui.xml" 2>/dev/null; then
                return 0
            fi
        fi
        sleep 1
    done
    return 1
}

info "seeding a conversation whose number has no contact"
scrub
seed_conversation "$NUM" || fail 'could not seed the conversation'
adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
adb_ shell am start -n "$ACT" >/dev/null 2>&1
wait_row "$BODY" "" 20 || fail 'seeded conversation never reached the list'
if grep -qF "$ADD_NAME" "$TMP/ui.xml" 2>/dev/null; then
    fail 'probe name appeared before the contact was created'
else
    pass 'the unsaved number lists without a name, as expected'
fi

info "adding the contact while the app stays on the list"
RID=$(seed_contact "$NUM" "$ADD_NAME") || fail 'could not seed the contact'
if wait_row "$ADD_NAME" "" 30; then
    pass 'a contact added in the phone book refreshes the list without a resume'
else
    fail 'a contact added in the phone book never reached the list (no resume)'
fi

info "renaming the contact while the app stays on the list"
[ -n "${RID:-}" ] && rename_contact "$RID" "$REN_NAME" || fail 'could not rename the contact'
if wait_row "$REN_NAME" "$ADD_NAME" 30; then
    pass 'a renamed contact refreshes the list without a resume'
else
    fail 'a renamed contact kept the old name until a resume'
fi

printf '\nPASS=%s FAIL=%s\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
