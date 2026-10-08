#!/usr/bin/env bash
# Regression: 3-digit service/short codes (India's 198/199) must be sendable.
# Before the fix they were rejected by isLikelyPhoneNumber's 4-digit floor, so
# the New Chat "Send to" row was disabled and existing short-code threads had
# no composer. This script verifies both gates are now open.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

check_present() {
    if grep -q "$2" "$TMP/ui.xml"; then ok "$1"; else bad "$1"; fi
}
check_absent() {
    if grep -q "$2" "$TMP/ui.xml"; then bad "$1"; else ok "$1"; fi
}
type_safe() {
    local t="${1// /%s}"
    adb_ shell "input text \"$t\""
}
clear_field() {
    for _ in $(seq 1 8); do adb_ shell input keyevent 67; done
    sleep 0.5
}
tap_contains() {
    local c
    c=$(center_of_contains "$1") || return 1
    adb_ shell input tap $c
}

info "Launching app"
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT"; sleep 3

info "Opening New Chat"
tap_text "Start chat" || adb_ shell input tap 940 2260
sleep 2

info "Checking search field is focused on launch"
dump_ui
if grep -q 'class="android.widget.EditText"[^>]*focused="true"' "$TMP/ui.xml"; then
    ok "search field is focused when New Chat opens"
else
    bad "search field is not focused when New Chat opens"
fi

info "Typing short code 198"
type_safe "198"; sleep 1
dump_ui

check_absent "short code accepted (no error text)" "Only phone numbers can be messaged"
if python3 - "$TMP/ui.xml" <<'PY' | grep -q 'clickable=true'; then
import sys, xml.etree.ElementTree as ET

def has_send_to(node):
    text = node.get('text') or ''
    if 'Send to' in text:
        return True
    return any(has_send_to(c) for c in node)

root = ET.parse(sys.argv[1]).getroot()
for n in root.iter('node'):
    if n.get('clickable') == 'true' and has_send_to(n):
        print('clickable=true')
        break
PY
    ok "Send-to row is clickable"
else
    bad "Send-to row is not clickable"
fi

info "Opening conversation for 198"
tap_contains "Send to" || adb_ shell input tap 500 460
sleep 2.5
dump_ui

if grep -q 'class="android.widget.EditText"' "$TMP/ui.xml"; then
    ok "chat composer is present for short code 198"
else
    bad "chat composer missing for short code 198"
fi

info "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
exit $((FAIL > 0))
