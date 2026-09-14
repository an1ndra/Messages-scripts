#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"

info "=== Fresh start ==="
adb_ shell am force-stop "$PKG"
sleep 2

info "=== Send SMS to +1234567890 ==="
adb_ emu sms send +1234567890 "Test" >/dev/null 2>&1
sleep 3

info "=== Check notification ==="
N1=$(adb_ shell "dumpsys notification" | grep "pkg=$PKG" | grep -v "AppSettings" | grep -v "NotificationChannel" | grep -c "id=" 2>/dev/null || echo "0")
echo "Notifications before: $N1"

info "=== Start app directly (not via tap) ==="
adb_ shell "am start -n $PKG/.MainActivity" >/dev/null
sleep 5

info "=== Check notification after starting app ==="
N2=$(adb_ shell "dumpsys notification" | grep "pkg=$PKG" | grep -v "AppSettings" | grep -v "NotificationChannel" | grep -c "id=" 2>/dev/null || echo "0")
echo "Notifications after: $N2"

info "=== Open notification drawer to verify visible ==="
adb_ shell "input swipe 500 100 500 800" >/dev/null
sleep 2

info "=== Navigate back ==="
adb_ shell "input keyevent 4" >/dev/null
sleep 1
