#!/usr/bin/env bash
# Regression: Spam & blocked -> Messages and Trash -> Messages label each row
# with the SAVED CONTACT NAME when the sender is in the device contact list.
# Previously the folder query mapped the *display destination* (the formatted
# number) into the sender name, so a contact's rows showed only the number.
#
# Seeds its own contact, a parked keyword-blocked message and a normal message,
# moving the latter to trash through the UI.
# Run: scripts/test-folder-sender-name.sh
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh

PASS=0
FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }

NAME="Fran"
NUM="+15551230022"
DISPLAY="(555) 123-0022"
KW="FOLDKW$RANDOM"
BODY_N="normal foldername $RANDOM"
SID="foldersname$(date +%s)"
TS=$(date +%s%3N)

db_sql() {
    adb_ shell "run-as $PKG sqlite3 databases/messages.db \"$1\"" 2>/dev/null && return 0
    adb_ shell "su -c \"sqlite3 /data/data/$PKG/databases/messages.db \\\"$1\\\"\"" 2>/dev/null || true
}

scrub_fran() {
    local sql="DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM'); DELETE FROM conversations WHERE address='$NUM'; DELETE FROM participants WHERE normalized_destination='$NUM';" i n
    for i in 1 2 3 4 5; do
        adb_ shell "run-as $PKG sqlite3 databases/messages.db \"$sql\"" >/dev/null 2>&1 || true
        n=$(db_sql "SELECT (SELECT COUNT(*) FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM')) + (SELECT COUNT(*) FROM conversations WHERE address='$NUM');" || true)
        [ "$n" = "0" ] && break
        sleep 1
    done
    adb_ shell "content delete --uri content://com.android.contacts/raw_contacts --where \"sourceid LIKE 'foldersname%'\"" >/dev/null 2>&1 || true
}

bubble_center() {
    local q="$1" b
    dump_ui || return 1
    b=$(grep -oE '<node[^>]*text="[^"]*'"$q"'[^"]*"[^>]*>' "$TMP/ui.xml" | head -1 \
        | grep -oE '\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]' | head -1)
    [ -z "$b" ] && return 1
    sed -E 's/\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]/\1 \2 \3 \4/' <<< "$b" \
        | awk '{print int(($1+$3)/2), int(($2+$4)/2)}'
}

scroll_until() {
    local target="$1" i
    for i in $(seq 1 8); do
        dump_ui >/dev/null 2>&1 || true
        grep -q "text=\"$target\"" "$TMP/ui.xml" && return 0
        adb_ shell input swipe 540 1700 540 900 250 >/dev/null 2>&1; sleep 0.5
    done
    return 1
}

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    sleep 0.5
    scrub_fran
    sleep 1
    scrub_fran
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

seed_msgs() {
    local cid
    db_sql "INSERT INTO conversations (address,name,snippet,timestamp) VALUES ('$NUM','$NAME','',0);"
    cid=$(db_sql "SELECT id FROM conversations WHERE address='$NUM';" | tail -1)
    [ -n "$cid" ] || return 1
    db_sql "INSERT INTO participants (normalized_destination,send_destination,display_destination,comparable_destination,country_code,sub_id) VALUES ('$NUM','$NUM','$DISPLAY','$NUM','US',1);"
    db_sql "INSERT INTO messages (conversation_id,body,timestamp,status,deleted_at,blocked_reason) VALUES ($cid,'$KW probe',$TS,'sent',$TS,'blocked_keyword');"
    db_sql "INSERT INTO messages (conversation_id,body,timestamp,status) VALUES ($cid,'$BODY_N',$TS,'sent');"
}

scrub_fran
info "seeding saved contact $NAME / $NUM"
seed_contact || fail 'could not seed the saved contact'

info "seeding a parked keyword-blocked message toward $NUM"
seed_msgs || fail 'could not seed the test messages'
PARKED=$(db_sql "SELECT DISTINCT blocked_reason FROM messages WHERE body LIKE '%$KW%' AND deleted_at>0;" || true)
[ "$PARKED" = "blocked_keyword" ] && pass 'parked a keyword-blocked message' || fail "parked message missing ($PARKED)"

info "moving a normal message to trash via the UI"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
adb_ shell am start -n "$ACT" --es open_conversation_address "$NUM" >/dev/null; sleep 4
C=$(bubble_center "$BODY_N") || { fail 'message bubble not found'; exit 1; }
adb_ shell input swipe $C $C 900 >/dev/null 2>&1; sleep 1.2
if tap_text "Move to trash"; then
    sleep 1.5
    pass 'normal SMS moved to trash'
else
    fail 'Move to trash not available'
fi

info "Spam & blocked -> Messages shows the saved name"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null 2>&1; sleep 3
scroll_until "Spam &amp; Blocked" >/dev/null 2>&1
tap_text "Spam &amp; Blocked" >/dev/null 2>&1; sleep 2
tap_text "Messages" >/dev/null 2>&1; sleep 1.5
dump_ui >/dev/null 2>&1
if grep -q "text=\"$NAME\"" "$TMP/ui.xml"; then
    pass 'blocked-message row shows the saved contact name'
else
    fail 'blocked-message row does not show the saved contact name'
fi

info "Trash -> Messages shows the saved name"
adb_ shell input keyevent 4 >/dev/null 2>&1; sleep 1
tap_text "Trash" >/dev/null 2>&1; sleep 2
tap_text "Messages" >/dev/null 2>&1; sleep 1.5
dump_ui >/dev/null 2>&1
if grep -q "text=\"$NAME\"" "$TMP/ui.xml"; then
    pass 'trashed-message row shows the saved contact name'
else
    fail 'trashed-message row does not show the saved contact name'
fi

printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
exit $((FAIL > 0))