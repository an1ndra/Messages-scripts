#!/usr/bin/env bash
# test-notif-dismiss-on-open.sh
# Verifies: when user opens a conversation, the related notification is dismissed.
# Test: inject SMS, check notification appears, open chat, verify notification gone.
set -euo pipefail
source "$(dirname "$0")/env.sh"
FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

info "Inject SMS with OTP"
BODY="probe$RANDOM"
adb_ shell am start -n "$PKG/.MainActivity" >/dev/null 2>&1
sleep 4
adb_ emu sms send +1234567890 "Your code is $BODY" >/dev/null 2>&1
sleep 3

count_notifs() {
  adb_ shell "dumpsys notification" 2>/dev/null \
    | grep -c "NotificationRecord(.*pkg=$PKG" || true
}

# Check notification is visible
info "Check notification appeared"
NOTIF=$(count_notifs)
if [ "$NOTIF" -gt 0 ]; then
  pass "notification visible"
else
  fail "notification not found"
fi

# Open the conversation
info "Open conversation"
C=$(center_of_contains "$BODY") || { fail "conversation row not found"; }
[ -n "${C:-}" ] && adb_ shell input tap $C
sleep 3
for _ in 1 2 3; do
  if dump_ui && grep -qE 'class="android.widget.EditText"' "$TMP/ui.xml"; then
    pass "chat screen opened"
    break
  fi
  sleep 1
done

# Check notification is dismissed
info "Check notification dismissed after opening chat"
NOTIF_AFTER=$(count_notifs)
if [ "$NOTIF_AFTER" -eq 0 ]; then
  pass "notification dismissed"
else
  fail "notification still visible (count=$NOTIF_AFTER)"
fi

# Navigate back
adb_ shell "input keyevent 4"
sleep 1

if [ $FAIL -eq 0 ]; then
  echo "== ALL PASSED =="
else
  echo "== SOME FAILED =="
fi
exit $FAIL
