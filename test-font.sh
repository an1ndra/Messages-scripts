#!/usr/bin/env bash
# Regression for the bundled UI fonts.
#
# The app ships several free (SIL OFL) fonts as close stand-ins for Google Sans
# (proprietary). This checks the installed APK contains them + their OFL
# licenses, and that the app launches.
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

info "Font files are bundled"
LISTING=$(unzip -l "$TMP/base.apk" 2>/dev/null)
for f in dm_sans inter figtree montserrat manrope jost \
         poppins_regular poppins_medium poppins_semibold poppins_bold; do
    if echo "$LISTING" | grep -q "res/font/$f\.ttf"; then
        ok "bundled res/font/$f.ttf"
    else
        bad "missing res/font/$f.ttf"
    fi
done

info "OFL licenses ship with the app"
for l in DMSans Figtree Inter Montserrat Manrope Jost Poppins; do
    if echo "$LISTING" | grep -q "assets/licenses/$l-OFL.txt"; then
        ok "license $l-OFL.txt present"
    else
        bad "license $l-OFL.txt missing"
    fi
done

info "App launches with the bundled fonts"
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
