#!/usr/bin/env bash
# Regression for the "News group" flow (add people):
#
#  - Finishing the picker must open the NEW group's chat, not the contact
#    details page (whose Back lands in the old 1:1).
#  - Back from that chat must land on the conversation list.
#  - An empty group must NOT be trashed on the way out: it was created on
#    purpose, and vanishing from the list made it look like the group was never
#    made.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

PRIMARY="+1555771030"
NAME="Carlos Diaz"
DB="/data/data/$PKG/databases/messages.db"

sq() { adb_ shell "run-as $PKG sqlite3 $DB \"$1\"" 2>/dev/null | tr -d '\r'; }
group_row() {
    sq "select id,group_title,deleted_at from conversations
        where address='$PRIMARY' and group_title<>'' order by id desc limit 1;"
}

cleanup() {
    adb_ shell am force-stop com.android.providers.media.module >/dev/null 2>&1
    sq "delete from messages where conversation_id in
            (select id from conversations where address='$PRIMARY');
        delete from scheduled_messages where conversation_id in
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

info "Clean 1:1, then open it"
adb_ shell am force-stop "$PKG"; sleep 1
sq "delete from messages where conversation_id in
        (select id from conversations where address='$PRIMARY');
    delete from conversation_recipients where conversation_id in
        (select id from conversations where address='$PRIMARY');
    delete from conversations where address='$PRIMARY';" >/dev/null
OPENED=0
for i in 1 2 3; do
    adb_ shell am start -n "$ACT" --es open_conversation_address "$PRIMARY" >/dev/null
    if wait_layout_has "More options" 6; then OPENED=1; break; fi
    adb_ shell am force-stop "$PKG"; sleep 2
done
[ "$OPENED" = "1" ] && ok "1:1 chat opened" || { bad "1:1 chat did not open"; echo; echo "Results: $PASS passed, $FAIL failed"; exit 1; }

info "Add people -> pick -> Create group"
tap_layout "More options" >/dev/null || bad "no overflow menu"
sleep 1.5
tap_layout "Add people" >/dev/null || bad "no Add people item"
sleep 3
if ! layout_has "Create group"; then bad "the picker did not open"; fi
scroll_to_layout "$NAME" >/dev/null 2>&1 || true
tap_layout "$NAME" >/dev/null || bad "could not pick $NAME"
sleep 1.5
tap_layout "Create group" >/dev/null || bad "could not tap Create group"
sleep 4

info "Finish lands in the new group's chat (not the details page)"
if layout_has "2 people"; then
    bad "landed on the contact details page, not the group chat"
elif layout_has "More options" && layout_has "$NAME"; then
    ok "opened the new group chat"
else
    bad "did not land in the group chat"
fi
ROW=$(group_row)
if [ -n "$ROW" ]; then
    GID=$(cut -d'|' -f1 <<< "$ROW")
    ok "the group exists (id $GID)"
else
    bad "no group row was created"
fi

info "Back lands on the conversation list"
adb_ shell input keyevent 4 >/dev/null; sleep 2.5
if layout_has "Start chat" || layout_has "Archived"; then
    ok "back reached the conversation list"
else
    bad "back did not reach the conversation list"
fi
# The list keeps its scroll position across navigation; the new group is newest,
# so bring the top back into view before looking for it.
scroll_list_top() {
    local i
    for i in 1 2 3 4 5 6; do
        adb_ shell input swipe 540 700 540 1900 250 < /dev/null
    done
    sleep 1
}
scroll_list_top
if layout_has "$NAME"; then
    ok "the new group is listed at the top"
else
    bad "the new group is not listed"
fi

info "An empty group must survive leaving its chat"
# Open the group from the list, then leave without writing anything.
scroll_list_top
tap_layout "$NAME" >/dev/null || bad "could not reopen the group from the list"
sleep 2.5
if layout_has "More options"; then
    ok "reopened the empty group chat"
else
    bad "could not reopen the empty group chat"
fi
adb_ shell input keyevent 4 >/dev/null; sleep 2.5
ROW=$(group_row)
if [ -n "$ROW" ] && [ "$(cut -d'|' -f3 <<< "$ROW")" = "0" ]; then
    ok "the empty group was not trashed on exit"
else
    bad "the empty group was trashed on exit (state: ${ROW:-gone})"
fi
scroll_list_top
if layout_has "$NAME"; then
    ok "the empty group is still listed"
else
    bad "the empty group disappeared from the list"
fi

echo
info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
