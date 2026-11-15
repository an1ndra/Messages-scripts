#!/usr/bin/env bash
# Issue #476: a message carrying a one-time code is posted as a notification
# whose public (lock-screen / listener) version has its digits redacted.
#
# Delivers a code by modem, then reads the decision the app logged. The log line
# is the assertion surface because the public version lives inside the posted
# Notification, which is not reachable from a dump without root on every image.
#
#   bash scripts/test-otp-notification.sh
set -uo pipefail
cd "$(dirname "$0")"
source ./env.sh

PASS=0
FAIL=0
SENDER="+1555771040"          # Bank, from demo-data.sh

ok()   { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad()  { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

if ! "$ADB" devices | grep -q "^$ANDROID_SERIAL[[:space:]]*device"; then
    echo "ABORT: no device $ANDROID_SERIAL"; exit 2
fi
# An emulator can be fed a text by modem; a real phone cannot, so there the run
# waits for the person holding it to send one.
case "$ANDROID_SERIAL" in
    emulator-*) INJECT=yes ;;
    *) INJECT=no ;;
esac

adb_ shell am force-stop "$PKG" >/dev/null 2>&1
adb_ logcat -c >/dev/null 2>&1 || true

info "A code arrives"
if [ "$INJECT" = "yes" ]; then
    adb_ emu sms send "$SENDER" "Your one-time code is 482913. Do not share it." >/dev/null 2>&1
else
    cat <<MSG
  Send a text to this phone now, or have someone send one, containing a code, e.g.
      Your one-time code is 482913. Do not share it.
  Waiting up to two minutes for the notification decision.
MSG
fi

marker=""
for _ in $(seq 1 40); do
    marker=$(adb_ logcat -d -s OtpNotification 2>/dev/null | grep -m1 "sensitive=true" || true)
    [ -n "$marker" ] && break
    sleep 0.25
done
if [ -n "$marker" ]; then ok "the notification was marked for a code"; else bad "no OtpNotification log line"; fi

info "An ordinary message is left alone"
if [ "$INJECT" != "yes" ]; then
    echo "  skipped: needs a second text, only automatic on an emulator"
else
adb_ logcat -c >/dev/null 2>&1 || true
adb_ emu sms send +1555771010 "Picking up milk on the way home." >/dev/null 2>&1
sleep 2
quiet=$(adb_ logcat -d -s OtpNotification 2>/dev/null | grep -c "sensitive=true" || true)
[ "$quiet" = "0" ] && ok "a plain text did not get marked" || bad "a plain text was marked ($quiet)"
fi

info "Clean up"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1
adb_ logcat -c >/dev/null 2>&1 || true

info "Result"
echo "  PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && echo "=== OK ===" || echo "=== FAILED ==="
exit $((FAIL > 0))
