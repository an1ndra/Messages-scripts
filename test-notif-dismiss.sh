#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

info "Fresh start"
adb_ shell am force-stop "$PKG"; sleep 2

info "Send SMS"
adb_ emu sms send +1234567890 "Your code is 123456" >/dev/null 2>&1
sleep 3

info "Check notification appeared"
N1=$(adb_ shell "dumpsys notification" | grep -E "^\s+NotificationRecord" | grep -c "pkg=$PKG" || true)
if [ "$N1" -gt 0 ]; then
  pass "notification visible"
else
  fail "notification not found"
fi

info "Open first conversation"
adb_ shell "input tap 540 400"; sleep 4

info "Check notification dismissed"
N2=$(adb_ shell "dumpsys notification" | grep -E "^\s+NotificationRecord" | grep -c "pkg=$PKG" || true)
if [ "$N2" -eq 0 ]; then
  pass "notification dismissed"
else
  fail "notification still visible"
fi

adb_ shell "input keyevent 4"; sleep 1
if [ $FAIL -eq 0 ]; then echo "== ALL PASSED =="; else echo "== SOME FAILED =="; fi
exit $FAIL
