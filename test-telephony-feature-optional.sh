#!/usr/bin/env bash
# Regression for lint PermissionImpliesUnsupportedChromeOsHardware.
#
# The SMS/MMS/READ_PHONE_STATE permissions implicitly require
# android.hardware.telephony. Google Play filters apps out of ChromeOS and
# telephony-less tablets unless the manifest opts out with
#   <uses-feature android:name="android.hardware.telephony" android:required="false"/>
# Without it the app is uninstallable on those devices even though it runs
# fine there against the simulated SIM.
#
# This asserts against the *installed* APK on the device, so it catches a
# manifest that is correct in source but lost in the build/merge pipeline.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()   { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad()  { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

AAPT2=$(ls -d "$HOME"/android/build-tools/*/aapt2 2>/dev/null | sort -V | tail -1)
if [ -z "$AAPT2" ] || [ ! -x "$AAPT2" ]; then
    echo "[FAIL] no aapt2 found under ~/android/build-tools"
    exit 1
fi

info "Device: $(adb_ shell getprop ro.build.version.release 2>/dev/null | tr -d '\r') (SDK $(adb_ shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r'))"

if ! adb_ shell pm path "$PKG" >/dev/null 2>&1; then
    echo "[FAIL] $PKG is not installed on $ANDROID_SERIAL"
    exit 1
fi

APK_PATH=$(adb_ shell pm path "$PKG" | tr -d '\r' | sed -n 's/^package://p' | head -1)
PULLED="$TMP/installed-base.apk"
adb_ pull "$APK_PATH" "$PULLED" >/dev/null 2>&1 || { echo "[FAIL] could not pull $APK_PATH"; exit 1; }

BADGING="$TMP/installed-badging.txt"
"$AAPT2" dump badging "$PULLED" > "$BADGING" 2>/dev/null || { echo "[FAIL] aapt2 dump badging failed"; exit 1; }

info "Telephony permissions in the installed APK"
grep -oE "uses-permission: name='android.permission.(SEND_SMS|RECEIVE_SMS|READ_SMS|WRITE_SMS|RECEIVE_MMS|RECEIVE_WAP_PUSH|READ_PHONE_STATE)'" \
    "$BADGING" | sort -u

if ! grep -cF "uses-permission: name='android.permission.SEND_SMS'" "$BADGING" >/dev/null 2>&1; then
    bad "no SEND_SMS permission in the installed APK; test is not exercising anything"
else
    ok "APK requests the SMS permissions that imply telephony"
fi

info "uses-feature declarations in the installed APK"
grep -iE "uses-feature" "$BADGING" | sed 's/^/    /'

if grep -cF "uses-feature-not-required: name='android.hardware.telephony'" "$BADGING" >/dev/null 2>&1; then
    ok "telephony is declared required=\"false\" (installable on ChromeOS/tablets)"
else
    if grep -cE "^  *uses-feature: name='android.hardware.telephony'" "$BADGING" >/dev/null 2>&1; then
        bad "telephony is declared as a REQUIRED feature — Play will hide the app on no-radio devices"
    else
        bad "no <uses-feature android:name=\"android.hardware.telephony\"/> at all — Play implies it from the SMS permissions"
    fi
fi

info "App still launches with the optional feature declared"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1
adb_ shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
sleep 4
FOCUS=$(adb_ shell dumpsys window 2>/dev/null | tr -d '\r' | grep -E "mCurrentFocus|mFocusedApp" | head -2)
if echo "$FOCUS" | grep -cF "$PKG" >/dev/null 2>&1; then
    ok "$PKG is in the foreground after launch"
    echo "$FOCUS" | sed 's/^/    /'
else
    bad "$PKG did not reach the foreground"
    echo "$FOCUS" | sed 's/^/    /'
fi

echo ""
echo "=== Result: ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
