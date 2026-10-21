#!/usr/bin/env bash
# Regression for issue #332: the app must request NO network permission.
#
# Between 1.0.27 and 1.0.29 a direct-MMSC HTTP client was compiled in, and its
# module manifest merged INTERNET / ACCESS_NETWORK_STATE / CHANGE_NETWORK_STATE
# into the APK — the F-Droid permission diff the reporter saw. SMS is offline
# and MMS goes through the platform's own MMS service, so the app needs none of
# them. This asserts against the *installed* APK, so a manifest that is clean in
# source but gains a permission from a dependency still fails here.
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

info "Network permissions in the installed APK"
grep -oE "uses-permission: name='android.permission.(INTERNET|ACCESS_NETWORK_STATE|CHANGE_NETWORK_STATE)'" \
    "$BADGING" | sort -u | sed 's/^/    /'

for p in INTERNET ACCESS_NETWORK_STATE CHANGE_NETWORK_STATE; do
    if grep -qF "uses-permission: name='android.permission.$p'" "$BADGING"; then
        bad "the installed APK requests $p"
    else
        ok "no $p in the installed APK"
    fi
done

# Guard against a vacuous pass: the manifest must still request the SMS set, or
# the badging is reading the wrong artifact rather than a clean one.
if grep -qF "uses-permission: name='android.permission.SEND_SMS'" "$BADGING"; then
    ok "SMS permissions are still present, so the check is not vacuous"
else
    bad "no SEND_SMS in the installed APK — wrong APK/badging, not a clean one"
fi

echo ""
echo "=== Result: ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
