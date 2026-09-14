#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"

info "=== Fresh start ==="
adb_ shell am force-stop "$PKG"
sleep 2
adb_ shell am start -n "$ACT" >/dev/null
sleep 2

info "=== Check notifications after force-stop ==="
adb_ shell "dumpsys notification | grep 'pkg=com.anindra.messages' | grep -v 'AppSettings' | grep -v 'NotificationChannel'" | head -5
echo "(above should be empty)"

info "=== Send SMS ==="
adb_ emu sms send +1234567890 "Test message" >/dev/null 2>&1
sleep 3

info "=== Count notifications after SMS ==="
N1=$(adb_ shell "dumpsys notification | grep 'pkg=com.anindra.messages' | grep -v 'AppSettings' | grep -v 'NotificationChannel' | grep -c 'id=' 2>/dev/null || echo 0")
echo "Active notifications: $N1"

info "=== Open first conversation ==="
adb_ shell "input tap 540 400"
sleep 4

info "=== Count after tap ==="
N2=$(adb_ shell "dumpsys notification | grep 'pkg=com.anindra.messages' | grep -v 'AppSettings' | grep -v 'NotificationChannel' | grep -c 'id=' 2>/dev/null || echo 0")
echo "Active notifications: $N2"

if [ "$N2" -eq 0 ]; then
  echo "== PASSED: notifications dismissed =="
else
  echo "== FAILED: $N2 notifications still active =="
fi
