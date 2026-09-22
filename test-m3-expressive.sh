#!/usr/bin/env bash
# Regression for the Spam & blocked / Trash tab row: the app boots on the
# stable Material 3 stack and the Conversations/Messages switcher is a
# single-select connected tab row (selected semantics, equal-width buttons).
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

cleanup() { adb_ shell am force-stop "$PKG" >/dev/null 2>&1; }
trap cleanup EXIT

# Prints true|false for the selected node whose label is $1.
selected_state() {
    python3 - "$1" "$TMP/ui.xml" <<'PY'
import re, sys
label, path = sys.argv[1], sys.argv[2]
try:
    x = open(path, errors="replace").read()
except OSError:
    print(""); raise SystemExit
for m in re.finditer(r'<node[^>]*selected="(true|false)"[^>]*>', x):
    seg = x[m.end():m.end() + 500]
    lab = re.search(r'text="([^"]+)"', seg)
    if lab and lab.group(1) == label:
        last = m.group(1)
if 'last' in dir():
    print(last)
PY
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

info "Cold launch"
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 6
dump_ui
grep -q 'text="Messages"' "$TMP/ui.xml" \
    && ok "app boots and renders the main list" \
    || bad "app did not render the main list"

info "Settings > Spam & blocked uses the single-select tab row"
open_spam_folder || { bad "Spam & blocked screen not reachable"; echo ""; echo "=== RESULTS: $PASS passed, $FAIL failed ==="; exit 1; }
dump_ui
grep -q 'text="Conversations"' "$TMP/ui.xml" && grep -q 'text="Messages"' "$TMP/ui.xml" \
    && ok "both tab labels rendered" \
    || bad "tab labels missing"

info "Tabs behave as a single-select group"
[ "$(selected_state Conversations)" = "true" ] \
    && ok "Conversations selected by default" \
    || bad "Conversations not selected by default"
[ "$(selected_state Messages)" = "false" ] \
    && ok "Messages unselected by default" \
    || bad "Messages unexpectedly selected"
tap_text "Messages" >/dev/null 2>&1; sleep 1.5
dump_ui
[ "$(selected_state Messages)" = "true" ] \
    && ok "tapping Messages selects it" \
    || bad "Messages did not become selected"
[ "$(selected_state Conversations)" = "false" ] \
    && ok "Conversations deselected" \
    || bad "Conversations stayed selected"

echo ""
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
