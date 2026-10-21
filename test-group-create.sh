#!/usr/bin/env bash
# Turning a 1:1 into a group: pick people, the group is created with a default
# name drawn from its members, and the user lands in the new group chat.
#
# Naming happens on the group's page, not in the picker, so the group is named
# from its members here; a name typed later is kept.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

PRIMARY="+1555771030"   # Alex
PICK_NAME="Carlos Diaz"
DB="/data/data/$PKG/databases/messages.db"

sq() { adb_ shell "run-as $PKG sqlite3 $DB \"$1\"" 2>/dev/null | tr -d '\r'; }
group_id()    { sq "select id from conversations where address='$PRIMARY' and group_title<>'' and deleted_at=0 order by id desc limit 1;"; }
group_members() { sq "select count(*) from conversation_recipients where conversation_id=$(group_id);"; }
group_title() { sq "select group_title from conversations where id=$(group_id);"; }

cleanup() {
    adb_ shell am force-stop com.android.providers.media.module >/dev/null 2>&1
    sq "delete from messages where conversation_id in
            (select id from conversations where address='$PRIMARY');
        delete from conversation_recipients where conversation_id in
            (select id from conversations where address='$PRIMARY');
        delete from conversations where address='$PRIMARY';" >/dev/null
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
}
trap cleanup EXIT

for p in READ_SMS SEND_SMS READ_CONTACTS POST_NOTIFICATIONS; do
    adb_ shell pm grant "$PKG" android.permission.$p 2>/dev/null
done

info "Open a clean 1:1"
adb_ shell am force-stop "$PKG"; sleep 1
sq "delete from messages where conversation_id in
        (select id from conversations where address='$PRIMARY');
    delete from conversation_recipients where conversation_id in
        (select id from conversations where address='$PRIMARY');
    delete from conversations where address='$PRIMARY';" >/dev/null
adb_ shell am start -n "$ACT" --es open_conversation_address "$PRIMARY" >/dev/null
wait_for_text "More options" 15 || { bad "1:1 chat did not open"; echo; echo "Results: $PASS passed, $FAIL failed"; exit 1; }
ok "1:1 chat opened"

info "The picker opens from the chat"
adb_ shell input tap 195 211; sleep 2.5   # header avatar -> contact page
if tap_layout "Add people" >/dev/null; then
    ok "the contact page offered Add people"
else
    bad "could not open the contact page / Add people"
fi
sleep 3
if layout_has "Create group"; then
    ok "the add-people picker opened"
else
    bad "the picker did not open"
fi

info "Pick a person and create the group"
scroll_to_layout "$PICK_NAME" >/dev/null 2>&1 || true
tap_layout "$PICK_NAME" >/dev/null || bad "could not pick $PICK_NAME"
sleep 1.5
tap_layout "Create group" >/dev/null || bad "could not tap Create group"
sleep 4

GID=$(group_id)
if [ -n "$GID" ]; then
    ok "a group was created (id $GID)"
else
    bad "no group was created"
fi
if [ "$(group_members)" = "2" ]; then
    ok "the 1:1 became a group of 2"
else
    bad "expected 2 members, found $(group_members)"
fi
TITLE=$(group_title)
if [ -n "$TITLE" ]; then
    ok "the group got a default name ('$TITLE')"
else
    bad "the group has no name at all"
fi
if [ -n "$TITLE" ] && layout_has "More options" && layout_has "$TITLE"; then
    ok "landed in the new group chat"
else
    bad "did not land in the new group chat"
fi

info "Leaving the empty group keeps it"
adb_ shell input keyevent 4 >/dev/null; sleep 2.5
if [ "$(sq "select deleted_at from conversations where id=$GID;")" = "0" ]; then
    ok "the empty group survived leaving its chat"
else
    bad "the empty group was trashed on exit"
fi

echo
info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
