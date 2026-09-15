#!/usr/bin/env bash
# Regression for the bundled UI font.
#
# The app uses DM Sans (SIL OFL) as a close, freely-licensed stand-in for Google
# Sans (proprietary, cannot be redistributed). This checks the installed APK
# ships the DM Sans variable font + the OFL license, and that the app launches
# with it.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

info "Pull the installed APK"
APK_PATH=$(adb_ shell pm path "$PKG" | sed 's/^package://' | tr -d '\r' | head -1)
if [ -z "$APK_PATH" ]; then
    bad "app is not installed"
    echo ""
    info "Results: $PASS passed, $FAIL failed"
    exit 1
fi
adb_ pull "$APK_PATH" "$TMP/base.apk" >/dev/null 2>&1

info "DM Sans font file is bundled"
if unzip -l "$TMP/base.apk" 2>/dev/null | grep -q 'res/font/dm_sans\.ttf'; then
    ok "bundled res/font/dm_sans.ttf"
else
    bad "missing res/font/dm_sans.ttf"
fi

info "OFL license ships with the app"
if unzip -l "$TMP/base.apk" 2>/dev/null | grep -q 'assets/licenses/DMSans-OFL.txt'; then
    ok "DM Sans OFL license present"
else
    bad "DM Sans OFL license missing"
fi

info "App launches with the bundled font"
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 3
if [ -n "$(adb_ shell pidof "$PKG" | tr -d '\r')" ]; then
    ok "app launched"
else
    bad "app crashed on launch"
fi

echo ""
info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
