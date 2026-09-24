#!/usr/bin/env bash
# Regression for the keyword-block follow-up notification bug: once a sender's
# chat has been opened and left, later messages from that same sender must still
# post a notification. Repro path: open the conversation, leave via the in-app
# back arrow (which used to leave ForegroundTracker latched on that address so
# SmsReceiver suppressed every later notification for the sender).
source "$(dirname "$0")/env.sh"

SENDER_A="+1555111$(( RANDOM % 900 + 100 ))"
SENDER_B="+1555222$(( RANDOM % 900 + 100 ))"
MA1="alpha$RANDOM"
MA2="bravo$RANDOM"
MB="charlie$RANDOM"

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

cleanup() {
    adb_ shell "run-as $PKG sh -c 'sqlite3 databases/messages.db \
        \"DELETE FROM messages WHERE body LIKE \\\"%$MA1%\\\" OR body LIKE \\\"%$MA2%\\\" OR body LIKE \\\"%$MB%\\\"; \
         DELETE FROM conversations WHERE address IN (\\\"$SENDER_A\\\",\\\"$SENDER_B\\\");\"'" >/dev/null 2>&1
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
}
trap cleanup EXIT

notif_for() {
    adb_ shell "dumpsys notification --noredact" 2>/dev/null | grep -c "$1" | tr -d '\r'
}

db_count() {
    adb_ shell "run-as $PKG sh -c 'sqlite3 databases/messages.db \"SELECT COUNT(*) FROM messages WHERE body LIKE \\\"%$1%\\\";\"'" 2>/dev/null | tr -d '\r'
}

adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1
adb_ shell pm grant "$PKG" android.permission.RECEIVE_SMS 2>/dev/null
adb_ shell pm grant "$PKG" android.permission.POST_NOTIFICATIONS 2>/dev/null

info "Fresh start"
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 4

info "Baseline: message from sender A notifies before its chat is opened"
adb_ emu sms send "$SENDER_A" "hello $MA1 how are you" >/dev/null 2>&1; sleep 5
[ "$(db_count "$MA1")" = "1" ] && ok "A msg stored" || bad "A msg missing ($(db_count "$MA1"))"
[ "$(notif_for "$MA1")" -ge 1 ] && ok "notification posted for A msg" || bad "no notification for A msg"

info "Open conversation A, then leave via the in-app back arrow"
tap=$(center_of_contains "$MA1") || { bad "could not find conversation row for A"; exit $((FAIL > 0)); }
adb_ shell input tap $tap; sleep 3
dump_ui
if grep -qE 'class="android.widget.EditText"' "$TMP/ui.xml"; then
    ok "chat screen opened"
else
    bad "chat screen did not open"
fi
tap_text "Back" >/dev/null 2>&1 || adb_ shell input keyevent 4
sleep 2
dump_ui
grep -q 'content-desc="Start chat"' "$TMP/ui.xml" && ok "back on the conversation list" || bad "not back on the conversation list"

info "Follow-up message from the same sender A must still notify"
adb_ emu sms send "$SENDER_A" "hi again $MA2 now" >/dev/null 2>&1; sleep 5
[ "$(db_count "$MA2")" = "1" ] && ok "A follow-up stored" || bad "A follow-up missing ($(db_count "$MA2"))"
[ "$(notif_for "$MA2")" -ge 1 ] && ok "notification posted for A follow-up" || bad "NO notification for A follow-up (bug reproduced)"

info "Control: sender B (chat never opened) still notifies"
adb_ emu sms send "$SENDER_B" "hello $MB from b" >/dev/null 2>&1; sleep 5
[ "$(notif_for "$MB")" -ge 1 ] && ok "notification posted for B" || bad "no notification for B"

echo ""
info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))