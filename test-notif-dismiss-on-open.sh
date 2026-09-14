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
adb_ emu sms send +1234567890 "Your code is 123456" >/dev/null 2>&1
sleep 3

# Check notification is visible
info "Check notification appeared"
NOTIF=$(adb_ shell "dumpsys notification | grep -c 'com.anindra.messages'" 2>/dev/null || echo "0")
if [ "$NOTIF" -gt 0 ]; then
  pass "notification visible"
else
  fail "notification not found"
fi

# Open the conversation
info "Open conversation"
adb_ shell "input tap 540 400"
sleep 3

# Check notification is dismissed
info "Check notification dismissed after opening chat"
NOTIF_AFTER=$(adb_ shell "dumpsys notification | grep -c 'com.anindra.messages'" 2>/dev/null || echo "0")
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
