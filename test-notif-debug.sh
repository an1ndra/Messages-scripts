#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"

info "=== Fresh start ==="
adb_ shell am force-stop "$PKG"
sleep 2
adb_ shell am start -n "$ACT" >/dev/null
sleep 2

info "=== Check no notifications ==="
NOTIF_BEFORE=$(adb_ shell "dumpsys notification | grep 'com.anindra.messages' | wc -l" 2>/dev/null || echo "0")
echo "[Before SMS] notifications: $NOTIF_BEFORE"

info "=== Send SMS ==="
adb_ emu sms send +1234567890 "Test message" >/dev/null 2>&1
sleep 3

info "=== Check notifications after SMS ==="
NOTIF_AFTER=$(adb_ shell "dumpsys notification | grep 'com.anindra.messages' | wc -l" 2>/dev/null || echo "0")
echo "[After SMS] notifications: $NOTIF_AFTER"
if [ "$NOTIF_AFTER" -gt 0 ]; then
  adb_ shell "dumpsys notification | grep 'com.anindra.messages'" | head -5
fi

info "=== Tap first conversation ==="
adb_ shell "input tap 540 400"
sleep 4

info "=== Check notifications after tap ==="
NOTIF_TAP=$(adb_ shell "dumpsys notification | grep 'com.anindra.messages' | wc -l" 2>/dev/null || echo "0")
echo "[After tap] notifications: $NOTIF_TAP"

if [ "$NOTIF_TAP" -eq 0 ]; then
  echo "== PASSED: notifications dismissed =="
else
  echo "== FAILED: notifications still present =="
fi
