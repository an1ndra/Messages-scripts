#!/usr/bin/env bash
# Regression for the Material 3 Expressive migration: the app boots on the
# expressive theme and the Spam & blocked switcher is the real M3 ButtonGroup
# (single-select, checkable toggle items) rather than click-only surfaces.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

cleanup() { adb_ shell am force-stop "$PKG" >/dev/null 2>&1; }
trap cleanup EXIT

# Prints true|false for the checkable ButtonGroup item whose label is $1.
checked_state() {
    grep -oE "<node[^>]*checkable=\"true\"[^>]*checked=\"(true|false)\"[^>]*><node[^>]*text=\"$1\"" "$TMP/ui.xml" 2>/dev/null \
        | grep -oE 'checked="(true|false)"' | head -1 | sed -E 's/checked="(.*)"/\1/'
}

open_spam_folder() {
    adb_ shell am force-stop "$PKG"; sleep 1
    adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null 2>&1; sleep 3
    local i c
    for i in $(seq 1 8); do
        dump_ui
        grep -q 'Spam &amp; Blocked' "$TMP/ui.xml" && break
        adb_ shell input swipe 540 1700 540 900 300 >/dev/null 2>&1; sleep 0.7
    done
    c=$(center_of_contains "Spam &amp; Blocked") || return 1
    adb_ shell input tap $c; sleep 2
}

info "Cold launch on the M3 Expressive theme"
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 6
dump_ui
grep -q 'text="Messages"' "$TMP/ui.xml" \
    && ok "app boots and renders the main list" \
    || bad "app did not render the main list"

info "Settings > Spam & blocked uses the M3 Expressive ButtonGroup"
open_spam_folder || { bad "Spam & blocked screen not reachable"; echo ""; echo "=== RESULTS: $PASS passed, $FAIL failed ==="; exit 1; }
dump_ui
grep -q 'text="Conversations"' "$TMP/ui.xml" && grep -q 'text="Messages"' "$TMP/ui.xml" \
    && ok "both tab labels rendered" \
    || bad "tab labels missing"
CHK=$(grep -o 'checkable="true"' "$TMP/ui.xml" | wc -l | tr -d ' ')
[ "$CHK" -ge 2 ] \
    && ok "tabs expose M3 toggle (checkable) semantics" \
    || bad "tabs are not checkable ButtonGroup items (found $CHK)"

info "Tabs behave as a single-select group"
[ "$(checked_state Conversations)" = "true" ] \
    && ok "Conversations selected by default" \
    || bad "Conversations not selected by default"
[ "$(checked_state Messages)" = "false" ] \
    && ok "Messages unselected by default" \
    || bad "Messages unexpectedly selected"
tap_text "Messages" >/dev/null 2>&1; sleep 1.5
dump_ui
[ "$(checked_state Messages)" = "true" ] \
    && ok "tapping Messages selects it" \
    || bad "Messages did not become selected"
[ "$(checked_state Conversations)" = "false" ] \
    && ok "Conversations deselected" \
    || bad "Conversations stayed selected"

echo ""
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
