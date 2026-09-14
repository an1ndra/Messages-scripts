#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"

info "=== Fresh start ==="
adb_ shell am force-stop "$PKG"
sleep 2

info "=== Send SMS ==="
adb_ emu sms send +1234567890 "Test" >/dev/null 2>&1
sleep 3

info "=== Show notifications ==="
adb_ shell "dumpsys notification" | grep "pkg=$PKG" | grep -v "AppSettings" | grep -v "NotificationChannel" | head -5

info "=== Start app ==="
adb_ shell "am start -n $PKG/.MainActivity" >/dev/null
sleep 5

info "=== Show notifications after ==="
adb_ shell "dumpsys notification" | grep "pkg=$PKG" | grep -v "AppSettings" | grep -v "NotificationChannel" | head -5

# Also try cancelAll programmatically
info "=== Manual cancel test via adb shell ==="
adb_ shell "am start -a android.intent.action.VIEW -d sms:+1234567890 -p $PKG" >/dev/null
sleep 3

info "=== Show notifications ==="
adb_ shell "dumpsys notification" | grep "pkg=$PKG" | grep -v "AppSettings" | grep -v "NotificationChannel" | head -5
