#!/usr/bin/env bash
# Regression for issue #227: numbers must keep left-to-right order inside RTL
# (Persian) text. The app isolates number runs with Unicode LRI/PDI
# (U+2066/U+2069) at render time, which is visible in the uiautomator dump,
# while plain LTR messages are left byte-for-byte unchanged.
#
# Seeds an RTL SMS (starts with Persian -> RTL paragraph) and an LTR SMS, both
# carrying the same spaced number, then asserts the RTL occurrences are
# isolated and the LTR one is not. Before the fix no isolates existed anywhere.
source "$(dirname "$0")/env.sh"

RTL_NUM="+989998620453"
LTR_NUM="+15551234577"
LRI=$'\u2066'
PDI=$'\u2069'
PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

info "Seed RTL and LTR messages"
adb_ emu sms send "$RTL_NUM" "شماره 0999 862 0453" >/dev/null 2>&1
adb_ emu sms send "$LTR_NUM" "test 0999 862 0453" >/dev/null 2>&1
sleep 2
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 6

info "Conversation list: RTL title isolated, LTR preview unchanged"
dump_ui || { bad "dump failed"; echo "=== RESULTS: $PASS passed, $FAIL failed ==="; exit 1; }
grep -qF "${LRI}+98 999 862 0453${PDI}" "$TMP/ui.xml" \
    && ok "RTL title carries LTR isolates" \
    || bad "RTL title not isolated"
if grep -qF "${LRI}test 0999 862 0453" "$TMP/ui.xml"; then
    bad "plain LTR preview was isolated"
elif grep -qF "test 0999 862 0453" "$TMP/ui.xml"; then
    ok "plain LTR preview unchanged"
else
    bad "LTR preview not found"
fi

info "RTL message body: number isolated"
c=$(center_of_contains "98 999 862 0453") || c=""
if [ -n "$c" ]; then
    adb_ shell input tap $c; sleep 2
    dump_ui || true
    grep -qF "${LRI}0999 862 0453${PDI}" "$TMP/ui.xml" \
        && ok "RTL body number isolated ($LRI…$PDI)" \
        || bad "RTL body number not isolated"
    adb_ shell input keyevent 4 >/dev/null 2>&1; sleep 1
else
    bad "could not open the RTL conversation"
fi

info "LTR message body: number untouched"
c=$(center_of_contains "123-4577") || c=""
if [ -n "$c" ]; then
    adb_ shell input tap $c; sleep 2
    dump_ui || true
    if grep -qF "${LRI}0999 862 0453" "$TMP/ui.xml"; then
        bad "LTR body number was isolated"
    elif grep -qF "test 0999 862 0453" "$TMP/ui.xml"; then
        ok "LTR body number unchanged"
    else
        bad "LTR body not found"
    fi
    adb_ shell input keyevent 4 >/dev/null 2>&1
else
    bad "could not open the LTR conversation"
fi

echo ""
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
