#!/usr/bin/env bash
# Regression: adding people to an EXISTING group must add them to that group.
#
# The picker used to always create a new group from the conversation it was
# opened on, so adding Dad to "Alex + Bank" produced a separate "Alex + Dad"
# group and left the original alone. Adding to a group now appends the member
# in place and the automatic name grows with it; adding to a 1:1 still starts a
# new group thread.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

PRIMARY="+1555771030"   # Alex
FIRST="Carlos Diaz"
SECOND="Priya Raman"
DB="/data/data/$PKG/databases/messages.db"

sq() { adb_ shell "run-as $PKG sqlite3 $DB \"$1\"" 2>/dev/null | tr -d '\r'; }
groups()      { sq "select count(*) from conversations where address='$PRIMARY' and group_title<>'' and deleted_at=0;"; }
group_id()    { sq "select id from conversations where address='$PRIMARY' and group_title<>'' and deleted_at=0 order by id desc limit 1;"; }
members()     { sq "select count(*) from conversation_recipients where conversation_id=$(group_id);"; }
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

scroll_list_top() {
    local i
    for i in 1 2 3 4 5 6; do adb_ shell input swipe 540 700 540 1900 250 < /dev/null; done
    sleep 1
}

# overflow -> Add people -> pick -> Create group
add_someone() {
    local name="$1"
    tap_layout "More options" >/dev/null || return 1
    sleep 1.5
    tap_layout "Add people" >/dev/null || return 1
    sleep 3
    layout_has "Create group" || return 1
    scroll_to_layout "$name" >/dev/null 2>&1 || true
    tap_layout "$name" >/dev/null || return 1
    sleep 1.5
    tap_layout "Create group" >/dev/null || return 1
    sleep 4
    return 0
}

info "Start a 1:1 and turn it into a group with $FIRST"
adb_ shell am force-stop "$PKG"; sleep 1
sq "delete from messages where conversation_id in
        (select id from conversations where address='$PRIMARY');
    delete from conversation_recipients where conversation_id in
        (select id from conversations where address='$PRIMARY');
    delete from conversations where address='$PRIMARY';" >/dev/null
OPENED=0
for i in 1 2 3; do
    adb_ shell am start -n "$ACT" --es open_conversation_address "$PRIMARY" >/dev/null
    if layout_has "More options"; then OPENED=1; break; fi
    adb_ shell am force-stop "$PKG"; sleep 2
done
if [ "$OPENED" = "1" ]; then
    ok "1:1 chat opened"
else
    bad "1:1 chat did not open"
    echo; echo "Results: $PASS passed, $FAIL failed"; exit 1
fi
add_someone "$FIRST" || bad "could not add $FIRST"
GID=$(group_id)
if [ -n "$GID" ] && [ "$(members)" = "2" ]; then
    ok "group of 2 created (id $GID, members $(members))"
else
    bad "group of 2 was not created (id ${GID:-none}, members $(members))"
fi
if layout_has "More options" && layout_has "$FIRST"; then
    ok "landed in the new group chat"
else
    bad "did not land in the group chat"
fi

info "Add $SECOND to the existing group"
BEFORE_ID=$(group_id)
add_someone "$SECOND" || bad "could not add $SECOND"

if [ "$(groups)" = "1" ]; then
    ok "still exactly one group (no second group was created)"
else
    bad "expected one group, found $(groups) — a new group was created instead of appending"
fi
if [ "$(group_id)" = "$BEFORE_ID" ]; then
    ok "the same group was kept (id $BEFORE_ID)"
else
    bad "the group id changed from $BEFORE_ID to $(group_id)"
fi
if [ "$(members)" = "3" ]; then
    ok "the group now has 3 members"
else
    bad "expected 3 members, found $(members)"
fi
TITLE=$(group_title)
if [[ "$TITLE" == *"$SECOND"* ]]; then
    ok "the group name grew to include $SECOND ('$TITLE')"
else
    bad "the group name did not include $SECOND ('$TITLE')"
fi
if layout_has "More options" && layout_has "$SECOND"; then
    ok "still in the same group chat after adding"
else
    bad "not in the group chat after adding"
fi

info "A typed group name is not overwritten by a later add"
# Stand in for a rename via the contacts page, then add a fourth person: the
# automatic name would grow, a typed one must not.
sq "update conversations set group_title='My Trip', group_title_custom=1 where id=$BEFORE_ID;" >/dev/null
sleep 1
add_someone "Nina Okafor" || bad "could not add Nina Okafor"
if [ "$(group_title)" = "My Trip" ]; then
    ok "a custom name survives adding a member"
else
    bad "a custom name was overwritten by adding a member ('$(group_title)')"
fi
if [ "$(members)" = "4" ]; then
    ok "the custom-named group grew to 4 members"
else
    bad "expected 4 members, found $(members)"
fi

echo
info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
