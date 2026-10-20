#!/usr/bin/env bash
# Regression for #341: deleting a conversation's only message from the
# notification leaves nothing to show, so the conversation itself must go to
# Trash. Before the fix the message was trashed but the conversation row stayed
# in the inbox with a blank snippet — a sender row with no content under it —
# because the empty-chat prune only ran on the way out of a chat, and a
# notification delete never opens one.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

MARK="empty$(date +%s)"
NUM="+1555$(( (RANDOM % 9000) + 1000 ))"

adb_ root >/dev/null 2>&1
adb_ wait-for-device; sleep 1

sql() { adb_ shell "sqlite3 /data/data/$PKG/databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r'; }

cleanup() {
    sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM');" >/dev/null 2>&1
    sql "DELETE FROM conversations WHERE address='$NUM';" >/dev/null 2>&1
    adb_ shell cmd statusbar collapse >/dev/null 2>&1
}
trap cleanup EXIT

adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1
adb_ shell pm grant "$PKG" android.permission.POST_NOTIFICATIONS 2>/dev/null
adb_ shell pm grant "$PKG" android.permission.RECEIVE_SMS 2>/dev/null

info "Seed a conversation whose only message is the notification's message"
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 4
for _ in $(seq 1 3); do
    adb_ emu sms send "$NUM" "$MARK only message" >/dev/null 2>&1
    for _ in $(seq 1 10); do
        [ "$(sql "SELECT COUNT(*) FROM messages WHERE body LIKE '%$MARK%';")" = "1" ] && break 2
        sleep 1
    done
done
CONVO_ID=$(sql "SELECT id FROM conversations WHERE address='$NUM';")
if [ -n "$CONVO_ID" ]; then ok "conversation seeded (id=$CONVO_ID)"; else bad "conversation never created"; exit 1; fi

info "Delete it from the notification"
adb_ shell am broadcast -n "$PKG/.sms.DeleteMessageReceiver" \
    -a com.anindra.messages.NOTIFICATION_DELETE \
    --es address "$NUM" --ei notif_id "$CONVO_ID" >/dev/null 2>&1
for _ in $(seq 1 10); do
    DEL=$(sql "SELECT deleted_at FROM conversations WHERE id=$CONVO_ID;")
    [ -n "$DEL" ] && [ "$DEL" != "0" ] && break
    sleep 1
done
DEL=$(sql "SELECT deleted_at FROM conversations WHERE id=$CONVO_ID;")
if [ -n "$DEL" ] && [ "$DEL" != "0" ]; then
    ok "emptied conversation moved to Trash (deleted_at=$DEL)"
else
    bad "conversation left in the inbox with no messages (deleted_at=${DEL:-none})"
fi

info "It is gone from the inbox list"
if [ "$(sql "SELECT COUNT(*) FROM conversations WHERE id=$CONVO_ID AND deleted_at=0;")" = "0" ]; then
    ok "conversation no longer listed"
else
    bad "blank conversation row still listed"
fi

info "The message itself is still recoverable from Trash"
if [ "$(sql "SELECT COUNT(*) FROM messages WHERE conversation_id=$CONVO_ID AND deleted_at>0;")" = "1" ]; then
    ok "message row kept in Trash"
else
    bad "message row not kept in Trash"
fi

info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
