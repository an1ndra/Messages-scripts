#!/usr/bin/env bash
# Regression for blocked numbers: an incoming SMS from a blocked number is no
# longer dropped — it is kept and its conversation is moved to Trash with the
# "Number" reason tag (recoverable via Restore) and no notification.
# Seeds a conversation, blocks the number via the long-press sheet, sends
# another SMS, checks DB reason + Trash UI, then cleans up.
source "$(dirname "$0")/env.sh"

TAIL=$(printf '%04d' $((RANDOM % 10000)))
SENDER="+1555123$TAIL"
QUERY="123-$TAIL"
FIRST="blocked-number-probe-$TAIL"
SECOND="blocked-number-second-$TAIL"

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

sql() {
    adb_ shell "run-as $PKG sh -c 'sqlite3 databases/messages.db \"$1\"'" 2>/dev/null | tr -d '\r'
}
blocked_count() {
    adb_ shell "run-as $PKG sh -c 'sqlite3 databases/messages.db \"SELECT COUNT(*) FROM blocked_numbers WHERE number LIKE \\\"%$TAIL%\\\";\"'" 2>/dev/null | tr -d '\r'
}
db_count() {
    adb_ shell "run-as $PKG sh -c 'sqlite3 databases/messages.db \"SELECT COUNT(*) FROM messages WHERE body LIKE \\\"%$1%\\\";\"'" 2>/dev/null | tr -d '\r'
}
conv_deleted_at() {
    adb_ shell "run-as $PKG sh -c 'sqlite3 databases/messages.db \"SELECT c.deleted_at FROM conversations c JOIN messages m ON m.conversation_id=c.id WHERE m.body LIKE \\\"%$1%\\\" ORDER BY m.id DESC LIMIT 1;\"'" 2>/dev/null | tr -d '\r'
}
conv_reason() {
    adb_ shell "run-as $PKG sh -c 'sqlite3 databases/messages.db \"SELECT c.deleted_reason FROM conversations c JOIN messages m ON m.conversation_id=c.id WHERE m.body LIKE \\\"%$1%\\\" ORDER BY m.id DESC LIMIT 1;\"'" 2>/dev/null | tr -d '\r'
}

cleanup() {
    adb_ shell "run-as $PKG sh -c 'sqlite3 databases/messages.db \"DELETE FROM blocked_numbers WHERE number LIKE \\\"%$TAIL%\\\";\"'" >/dev/null 2>&1
    adb_ shell "run-as $PKG sh -c 'sqlite3 databases/messages.db \"DELETE FROM conversations WHERE id IN (SELECT conversation_id FROM messages WHERE body LIKE \\\"%$FIRST%\\\" OR body LIKE \\\"%$SECOND%\\\");\"'" >/dev/null 2>&1
    adb_ shell "run-as $PKG sh -c 'sqlite3 databases/messages.db \"DELETE FROM messages WHERE body LIKE \\\"%$FIRST%\\\" OR body LIKE \\\"%$SECOND%\\\";\"'" >/dev/null 2>&1
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
}
trap cleanup EXIT

adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1
adb_ shell pm grant "$PKG" android.permission.RECEIVE_SMS 2>/dev/null
adb_ shell pm grant "$PKG" android.permission.POST_NOTIFICATIONS 2>/dev/null

info "Seed a conversation from $SENDER"
adb_ emu sms send "$SENDER" "$FIRST" >/dev/null 2>&1; sleep 4
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 6

info "Block the number from the conversation long-press sheet"
c=$(center_of_contains "$QUERY") || { bad "seeded row not on list"; echo "Results: $PASS passed, $FAIL failed"; exit 1; }
xy=($c)
adb_ shell input swipe "${xy[0]}" "${xy[1]}" "${xy[0]}" "${xy[1]}" 900; sleep 1.2
if tap_text "Block"; then
    sleep 1.5
    BC=$(blocked_count)
    [ "$BC" = "1" ] && ok "number stored in the blocklist" || bad "number not stored in the blocklist ($BC)"
else
    bad "'Block' action missing from the long-press sheet"
fi

info "Blocked message goes to Trash with reason 'blocked_number'"
adb_ emu sms send "$SENDER" "$SECOND" >/dev/null 2>&1; sleep 4
KEPT=$(db_count "$SECOND")
[ "$KEPT" = "1" ] && ok "blocked message kept in the database" || bad "blocked message missing ($KEPT)"
TRASHED=$(conv_deleted_at "$SECOND")
if [ -n "$TRASHED" ] && [ "$TRASHED" -gt 0 ] 2>/dev/null; then
    ok "conversation moved to Trash (deleted_at=$TRASHED)"
else
    bad "conversation not in Trash (deleted_at='$TRASHED')"
fi
REASON=$(conv_reason "$SECOND")
[ "$REASON" = "blocked_number" ] && ok "trash reason recorded as blocked_number" || bad "wrong trash reason ('$REASON')"
NOTIF=$(adb_ shell dumpsys notification --noredact 2>/dev/null | grep -c "$SECOND")
[ "$NOTIF" = "0" ] && ok "no notification for the blocked message" || bad "notification posted ($NOTIF)"

info "Trash screen shows the 'Number' tag"
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null 2>&1; sleep 3
for i in 1 2 3 4 5; do
    dump_ui
    grep -q 'text="Trash"' "$TMP/ui.xml" && break
    adb_ shell input swipe 540 1800 540 700 300 >/dev/null 2>&1; sleep 0.8
done
tap_text "Trash" >/dev/null 2>&1; sleep 1.5
dump_ui
grep -q "$TAIL" "$TMP/ui.xml" \
    && ok "blocked conversation listed in Trash" \
    || bad "blocked conversation not listed in Trash"
grep -q 'text="Number"' "$TMP/ui.xml" \
    && ok "Trash row shows the 'Number' tag" \
    || bad "Trash row reason tag missing"

echo ""
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
