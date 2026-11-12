#!/usr/bin/env bash
# Issue #449: a conversation deleted from the home list came back after a
# force-close or reboot.
#
# The sync treats every provider row missing from `message_provider_ids` as
# never imported. Received SMS, sent SMS and imported MMS recorded only
# `messages.sys_id`, so while that linkage row was absent (the normal state
# after the app has been killed for longer than the 120 s body-match window) a
# restart read those rows as pending, failed to re-insert them, and still asked
# getOrCreateConversationBlocking for the address -- which un-trashes the
# deleted thread.
#
# The script recreates that durable state deliberately (it is what any send or
# receive leaves behind when the app is not alive to link it) instead of
# waiting out the 120 s window, then deletes the row through the real swipe
# path, force-stops, and relaunches.
source "$(dirname "$0")/env.sh"

NUM="+15558809449"
DELETE_LABEL=$(res_string sheet_delete)
BODY="restart probe $(date +%s)"
PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

sql() { echo "$1" | adb_ shell "run-as $PKG sqlite3 databases/messages.db" 2>/dev/null | tr -d '\r'; }
psql() { adb_su "sqlite3 /data/data/com.android.providers.telephony/databases/mmssms.db \"$1\"" 2>/dev/null | tr -d '\r'; }

# The linkage table is keyed on the provider's `_id`, and SQLite reuses that id
# once a row is deleted. A linkage row left behind by an earlier run therefore
# makes the NEXT run's provider row look already imported: the sync reports
# 0 pending, never calls getOrCreateConversationBlocking, and this script goes
# green on a build that still resurrects the conversation. That is exactly how
# it passed once against the unfixed build. Every path that deletes a message
# or a provider row here drops the matching linkage row first.
unlink_by_sys_id() {
    local ids
    ids=$(psql "SELECT group_concat(_id) FROM sms WHERE address='$NUM';" | tr -d '\r')
    [ -n "$ids" ] && [ "$ids" != "null" ] && sql "DELETE FROM message_provider_ids WHERE sys_id IN ($ids);" >/dev/null 2>&1
    ids=$(sql "SELECT group_concat(sys_id) FROM messages WHERE sys_id>0 AND conversation_id IN (SELECT id FROM conversations WHERE address='$NUM');" | tr -d '\r')
    [ -n "$ids" ] && [ "$ids" != "null" ] && sql "DELETE FROM message_provider_ids WHERE sys_id IN ($ids);" >/dev/null 2>&1
}

cleanup() {
    unlink_by_sys_id
    sql "DELETE FROM message_provider_ids WHERE message_id IN (SELECT id FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM'));" >/dev/null 2>&1
    sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM');" >/dev/null 2>&1
    sql "DELETE FROM conversations WHERE address='$NUM';" >/dev/null 2>&1
    psql "DELETE FROM sms WHERE address='$NUM';" >/dev/null 2>&1
}
trap cleanup EXIT
cleanup

fresh_launch() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
    adb_ shell am start -n "$ACT" >/dev/null 2>&1
}

row_bounds() {
    grep -oE "(text|content-desc)=\"[^\"]*$BODY[^\"]*\"[^>]*bounds=\"[^\"]*\"" "$TMP/ui.xml" \
        | head -1 | grep -oE '\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]'
}

info "Hold the default SMS role"
adb_su "cmd role add-role-holder android.app.role.SMS $PKG" >/dev/null 2>&1

info "Seed a conversation through the real inbound path"
fresh_launch
sleep 6
adb_ emu sms send "$NUM" "$BODY" >/dev/null 2>&1
CID=""
for _ in $(seq 1 20); do
    CID=$(sql "SELECT id FROM conversations WHERE address='$NUM' LIMIT 1;")
    [ -n "$CID" ] && break
    sleep 1
done
if [ -z "$CID" ]; then
    bad "inbound SMS never created a conversation; nothing to delete"
    echo ""
    echo "=== Results: $PASS passed, $FAIL failed ==="
    exit 1
fi
ok "inbound SMS opened a conversation (id $CID)"

# The home list is populated from the database at launch; re-launching is how
# every other script gets a deterministic list. It also runs the startup sync,
# which links the provider row this test then removes.
fresh_launch
if wait_for_text "$BODY" 30; then
    ok "the conversation is on the home list before the delete"
else
    bad "the conversation never showed on the home list"
fi

info "Leave the durable unlinked state and delete the row"
# Exactly the state a send/receive leaves when the app is not around to link it.
# Deleting by `message_id` alone is not enough: an orphaned linkage row from an
# earlier run can carry the same `sys_id` this run's provider row was given when
# SQLite reused the id, and the sync would then read the row as imported.
SID=$(sql "SELECT sys_id FROM messages WHERE conversation_id=$CID AND sys_id>0 ORDER BY id DESC LIMIT 1;")
sql "DELETE FROM message_provider_ids WHERE message_id IN (SELECT id FROM messages WHERE conversation_id=$CID);" >/dev/null
[ -n "$SID" ] && sql "DELETE FROM message_provider_ids WHERE sys_id=$SID;" >/dev/null
REMAINING=$(sql "SELECT count(*) FROM message_provider_ids WHERE sys_id=${SID:-0} AND transport='sms';")
if [ -n "$SID" ] && [ "$REMAINING" = "0" ]; then
    ok "provider linkage removed (the state sync cannot repair)"
else
    bad "could not remove the provider linkage (sys_id=$SID still linked=$REMAINING)"
fi

# Long-press -> Delete, not a swipe: the swipe action is a user setting and
# defaults to Archive on this build, which hides the row without trashing it.
DELETED=""
for attempt in 1 2 3; do
    dump_ui >/dev/null 2>&1
    B=$(row_bounds)
    [ -z "$B" ] && { sleep 3; continue; }
    YMID=$(( ($(sed -E 's/\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]/\2/' <<< "$B") \
        + $(sed -E 's/\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]/\4/' <<< "$B")) / 2 ))
    adb_ shell input swipe 540 "$YMID" 540 "$YMID" 1000 >/dev/null 2>&1
    sleep 2
    tap_text "$DELETE_LABEL" >/dev/null 2>&1
    sleep 2
    DELETED=$(sql "SELECT deleted_at FROM conversations WHERE id=$CID;")
    [ -n "$DELETED" ] && [ "$DELETED" != "0" ] && break
done
if [ -n "$DELETED" ] && [ "$DELETED" != "0" ]; then
    ok "the long-press Delete moved the conversation to the trash"
else
    bad "the conversation was not deleted (deleted_at='$DELETED')"
fi
BEFORE=$(sql "SELECT count(*) FROM messages WHERE conversation_id=$CID;")

info "Force-close, relaunch, and check it stayed deleted"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 2
adb_ shell logcat -c >/dev/null 2>&1
adb_ shell am start -n "$ACT" >/dev/null 2>&1
# The startup sync is what brings it back on a broken build.
for _ in $(seq 1 20); do
    AFTER=$(sql "SELECT deleted_at FROM conversations WHERE id=$CID;")
    [ "$AFTER" = "0" ] && break
    sleep 2
done

if [ -z "$AFTER" ]; then
    bad "the conversation disappeared from the database entirely"
elif [ "$AFTER" = "0" ]; then
    bad "the restart un-trashed the deleted conversation (deleted_at=0)"
else
    ok "the conversation is still in the trash after the restart"
fi

BACK=""
for _ in $(seq 1 5); do
    dump_ui >/dev/null 2>&1
    if grep -qF "$BODY" "$TMP/ui.xml"; then BACK=1; break; fi
    sleep 3
done
[ -z "$BACK" ] && ok "the home list does not show the deleted conversation" \
    || bad "the deleted conversation is back on the home list"

COUNT=$(sql "SELECT count(*) FROM messages WHERE conversation_id=$CID;")
[ "$COUNT" = "$BEFORE" ] && ok "the sync did not duplicate its messages" \
    || bad "message count changed across the restart ($BEFORE -> $COUNT)"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
exit $((FAIL > 0))
