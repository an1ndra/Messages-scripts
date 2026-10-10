#!/usr/bin/env bash
# Turning a conversation into a group: pick people, name it, and land in the chat.
#
# The add step is where a group is created, so this is also where its name is
# chosen -- the user should not have to go back to the profile to rename what they
# just made, and they should end up in the new group ready to write.
source "$(dirname "$0")/env.sh"

FAIL=0
PASS_N=0
pass() { echo "PASS: $1"; PASS_N=$((PASS_N + 1)); }
fail() { echo "FAIL: $1"; FAIL=1; }

DB="/data/data/$PKG/databases/messages.db"
PRIMARY="+1555771030"     # Alex
PICK="+1555775020"        # Carlos Diaz
PICK_NAME="Carlos Diaz"
GROUP="Weekend Trip"

sq() { adb_ shell "run-as $PKG sqlite3 $DB \"$1\"" 2>/dev/null | tr -d '\r'; }

# A clean 1:1 with Alex, whatever earlier tests left behind.
reset_thread() {
    adb_ shell am force-stop "$PKG"; sleep 1
    sq "delete from messages where conversation_id in
        (select id from conversations where address='$PRIMARY');
        delete from conversation_recipients where conversation_id in
        (select id from conversations where address='$PRIMARY');
        delete from conversations where address='$PRIMARY';" >/dev/null
    adb_ shell am start -n "$ACT" --es open_conversation_address "$PRIMARY" >/dev/null
    wait_for_text "Alex" 12 || { echo "could not open the 1:1 with Alex"; exit 1; }
}

# Walk conversation -> profile -> picker, leaving the picker open with nobody
# selected. The conversation is recreated only when asked, so a later case can
# keep going from the group an earlier one built.
open_picker() {
    local fresh="${1:-fresh}"
    if [ "$fresh" = "fresh" ]; then
        reset_thread
    else
        adb_ shell am force-stop "$PKG"; sleep 1
        adb_ shell am start -n "$ACT" --es open_conversation_address "$PRIMARY" >/dev/null
        # The thread already exists here, so wait on its own name rather than on
        # anything the add step is about to create.
        local t
        t=$(sq "select group_title from conversations where address='$PRIMARY' and deleted_at=0 limit 1;")
        wait_for_text "$t" 12 || return 1
    fi
    adb_ shell input tap 195 211      # header avatar opens the contact profile
    wait_for_text "Add people" 12 || return 1
    tap_text "Add people" >/dev/null || return 1
    wait_for_text "Create group" 12 || wait_for_text "Add" 12 || return 1
    return 0
}

# The picker is the whole address book, so the contact wanted may be well below
# the fold. Scroll until it turns up, then tap it.
pick_contact() {
    local i
    for i in 0 1 2 3 4 5 6 7 8 9 10; do
        dump_ui >/dev/null 2>&1 || true
        if center_of "$1" >/dev/null 2>&1; then
            tap_text "$1" >/dev/null || return 1
            sleep 1
            return 0
        fi
        adb_ shell input swipe 540 1700 540 700 300
        sleep 0.6
    done
    return 1
}

info "1. The picker offers a name once someone is picked"
open_picker || { fail "could not open the Add people picker"; exit 1; }
if grep -q "Group name" "$TMP/ui.xml"; then
    fail "the name field is shown before anyone is picked"
else
    pass "no name field before a selection"
fi
pick_contact "$PICK_NAME" || { fail "could not pick $PICK_NAME"; exit 1; }
sleep 1
dump_ui >/dev/null 2>&1 || true
if grep -q "Group name" "$TMP/ui.xml"; then
    pass "the name field appears once someone is picked"
else
    fail "no name field after picking $PICK_NAME"
fi
if grep -q "Create group" "$TMP/ui.xml"; then
    pass "the action becomes Create group"
else
    fail "the action is not Create group"
fi

info "2. Leaving the name blank still creates a group, named for its members"
dump_ui >/dev/null 2>&1 || true
tap_text "Create group" >/dev/null || { fail "could not tap Create group"; exit 1; }
sleep 4
dump_ui >/dev/null 2>&1 || true
CID=$(sq "select id from conversations where address='$PRIMARY' and deleted_at=0 limit 1;")
MEMBERS=$(sq "select count(*) from conversation_recipients where conversation_id=$CID;")
if [ "$MEMBERS" -ge 2 ]; then
    pass "the 1:1 became a group of $MEMBERS"
else
    fail "expected 2+ members, found ${MEMBERS:-0}"
fi
if [ -n "$(sq "select group_title from conversations where id=$CID;")" ]; then
    pass "an unnamed group still gets a default name"
else
    fail "the group has no name at all"
fi
# And the user is in the chat, not back on the profile.
if grep -q "Add people" "$TMP/ui.xml"; then
    fail "landed back on the profile instead of the new group chat"
else
    pass "landed in the new group chat"
fi

info "3. A name typed at the add step is the group's name"
open_picker keep || { fail "could not reopen the picker"; exit 1; }
pick_contact "Priya Raman" || { fail "could not pick Priya Raman"; exit 1; }
sleep 1
dump_ui >/dev/null 2>&1 || true
tap_edittext >/dev/null || { fail "could not focus the name field"; exit 1; }
sleep 1
type_text "${GROUP// /%s}"
sleep 1
adb_ shell input keyevent KEYCODE_BACK; sleep 1
dump_ui >/dev/null 2>&1 || true
tap_text "Create group" >/dev/null || { fail "could not tap Create group"; exit 1; }
sleep 4
dump_ui >/dev/null 2>&1 || true
TITLE=$(sq "select group_title from conversations where id=$CID;")
if [ "$TITLE" = "$GROUP" ]; then
    pass "the chosen name is stored as the group title"
else
    fail "group title is '${TITLE:-blank}', expected '$GROUP'"
fi
if grep -q "$GROUP" "$TMP/ui.xml"; then
    pass "the chat header shows the chosen name"
else
    fail "the chat header does not show '$GROUP'"
fi
# The added person belongs to the group, so the profile must list them.
adb_ shell input tap 195 221; sleep 3
dump_ui >/dev/null 2>&1 || true
if grep -q "3 people" "$TMP/ui.xml"; then
    pass "the profile counts all three members"
else
    fail "the profile does not count three members"
fi
if grep -q "Priya Raman" "$TMP/ui.xml"; then
    pass "the new member is listed on the profile"
else
    fail "the new member is not listed on the profile"
fi
MEMBERS=$(sq "select count(*) from conversation_recipients where conversation_id=$CID;")
if [ "$MEMBERS" -ge 3 ]; then
    pass "the group now has $MEMBERS members"
else
    fail "expected 3+ members, found ${MEMBERS:-0}"
fi

info "4. Everyone in the group can be messaged"
# A send fans out over conversation_recipients, so every member must be listed.
LIST=$(sq "select address from conversation_recipients where conversation_id=$CID;")
N=$(grep -c '+' <<< "$LIST")
if [ "$N" -ge 3 ]; then
    pass "$N recipients are on file to send to"
else
    fail "only $N recipients on file"
fi

info "Cleanup"
sq "delete from messages where conversation_id in
    (select id from conversations where address='$PRIMARY');
    delete from conversation_recipients where conversation_id in
    (select id from conversations where address='$PRIMARY');
    delete from conversations where address='$PRIMARY';" >/dev/null
pass "test group removed"

echo
if [ "$FAIL" = 0 ]; then
    echo "ALL GROUP CREATE TESTS PASSED ($PASS_N checks)"
else
    echo "SOME GROUP CREATE TESTS FAILED"
    exit 1
fi
