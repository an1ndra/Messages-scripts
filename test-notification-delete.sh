#!/usr/bin/env bash
# Regression for #285: an incoming-message notification offers a Delete action
# that moves the newest message of that conversation to Trash (so it stays
# recoverable) and dismisses the notification.
#
# The action is a broadcast to DeleteMessageReceiver, which is
# android:exported="false" because it mutates the telephony database. The shell
# can therefore only reach it as root on this AOSP image; the notification's
# own record is inspected with `dumpsys notification` to prove the action is
# actually attached to what the user sees.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

MARK="notifdel$(date +%s)"
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

info "Post a notification for an incoming message"
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 4
for _ in $(seq 1 3); do
    adb_ emu sms send "$NUM" "$MARK hello" >/dev/null 2>&1
    for _ in $(seq 1 10); do
        [ "$(sql "SELECT COUNT(*) FROM messages WHERE body LIKE '%$MARK%';")" = "1" ] && break 2
        sleep 1
    done
done
MSG_ID=$(sql "SELECT id FROM messages WHERE body LIKE '%$MARK%';")
CONVO_ID=$(sql "SELECT id FROM conversations WHERE address='$NUM';")
if [ -n "$MSG_ID" ]; then ok "incoming message stored (id=$MSG_ID)"; else bad "message never arrived"; exit 1; fi

info "The notification carries a Delete action"
if adb_ shell "dumpsys notification --noredact" 2>/dev/null | tr -d '\r' \
        | awk -v pkg="$PKG" '/NotificationRecord/ {blk = ($0 ~ pkg)} blk' \
        | grep -q '"Delete"'; then
    ok "notification exposes a Delete action"
else
    bad "no Delete action on the notification"
fi

info "Invoke the action: move the message to Trash"
adb_ shell am broadcast -n "$PKG/.sms.DeleteMessageReceiver" \
    -a com.anindra.messages.NOTIFICATION_DELETE \
    --es address "$NUM" --ei notif_id "$CONVO_ID" >/dev/null 2>&1
for _ in $(seq 1 10); do
    DELETED_AT=$(sql "SELECT deleted_at FROM messages WHERE id=$MSG_ID;")
    [ -n "$DELETED_AT" ] && [ "$DELETED_AT" != "0" ] && break
    sleep 1
done
if [ -n "$DELETED_AT" ] && [ "$DELETED_AT" != "0" ]; then
    ok "message moved to Trash (deleted_at=$DELETED_AT)"
else
    bad "message not trashed (deleted_at=${DELETED_AT:-none})"
fi
if [ "$(sql "SELECT COUNT(*) FROM messages WHERE id=$MSG_ID;")" = "1" ]; then
    ok "message row kept, so it is recoverable from Trash"
else
    bad "message row purged instead of trashed"
fi

info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
