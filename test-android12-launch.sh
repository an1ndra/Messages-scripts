#!/usr/bin/env bash
# Regression for issue #209 (crash on launch on Android 10–13).
#
# Root cause: `ContactsContract.CommonDataKinds.Phone.ENTERPRISE_CONTENT_URI`
# is only available since API 34, but AppViewModel referenced it unguarded in a
# coroutine. On API < 34 the field access throws NoSuchFieldError — an Error,
# so the surrounding `catch (Exception)` did not catch it — killing the app on
# launch. Fixed by guarding on SDK >= 34 and falling back to Phone.CONTENT_URI.
#
# The bug only reproduces on API < 34, so run this on such an emulator:
#   ANDROID_SERIAL=emulator-5556 bash scripts/test-android12-launch.sh
# On API >= 34 it reports SKIP.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0; SKIP=0
ok()   { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad()  { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
skip() { echo "[SKIP] $1"; SKIP=$((SKIP + 1)); }
info() { echo -e "\n=== $* ==="; }

SDK=$(adb_ shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')
info "Device SDK: ${SDK:-unknown}"
if [ -z "$SDK" ] || [ "$SDK" -ge 34 ]; then
    skip "needs API < 34 to reproduce the ENTERPRISE_CONTENT_URI crash"
    echo ""
    info "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 0
fi

cleanup() { adb_ shell am force-stop "$PKG" >/dev/null 2>&1; }
trap cleanup EXIT

info "Grant permissions + default-SMS role"
for p in READ_CONTACTS READ_SMS SEND_SMS RECEIVE_SMS READ_PHONE_STATE; do
    adb_ shell pm grant "$PKG" android.permission.$p 2>/dev/null
done
adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" 2>/dev/null
adb_ shell run-as "$PKG" rm -rf files/crash_reports 2>/dev/null

info "Launch and watch for a crash"
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell logcat -c
adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 6

FATAL=$(adb_ shell logcat -d 2>/dev/null | grep -c "FATAL EXCEPTION")
[ "$FATAL" = "0" ] && ok "no FATAL EXCEPTION on launch" || bad "app crashed on launch ($FATAL)"

if adb_ shell "ps -A 2>/dev/null" | grep -q "$PKG"; then
    ok "process is running"
else
    bad "process is not running"
fi

if adb_ shell logcat -d 2>/dev/null | grep -q "NoSuchFieldError"; then
    bad "NoSuchFieldError still present in logcat"
else
    ok "no NoSuchFieldError"
fi

dump_ui || true
if grep -q 'text="Messages"' "$TMP/ui.xml"; then
    ok "home screen reached"
else
    bad "home screen not reached"
fi

echo ""
info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
