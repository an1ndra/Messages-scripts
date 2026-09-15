#!/usr/bin/env bash
# Regression for the Google-Messages-style home search bar.
#
# The home screen shows a persistent rounded search pill ("Search
# conversations") with a "Search" affordance; tapping it opens the search
# input; back returns to the list with the pill. The old icon-only search
# button is gone (the pill replaces it).
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

info "Launch home"
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 3

info "Search pill is shown on the home screen"
SHOWN=0
for i in 1 2 3; do
    dump_ui || { sleep 1; continue; }
    if grep -q 'text="Search conversations"' "$TMP/ui.xml" && \
       grep -q 'content-desc="Search"' "$TMP/ui.xml"; then
        SHOWN=1; break
    fi
    sleep 1
done
[ "$SHOWN" = "1" ] && ok "home shows the search pill" || bad "home search pill missing"

if grep -q 'text="Messages"' "$TMP/ui.xml"; then
    ok "home title still present"
else
    bad "home title missing"
fi

info "Tapping the pill opens the search field"
tap_text "Search" >/dev/null 2>&1
sleep 2
dump_ui
if grep -q 'content-desc="Close search"' "$TMP/ui.xml" && \
   grep -q 'class="android.widget.EditText"' "$TMP/ui.xml"; then
    ok "search mode opened with an input field"
else
    bad "search mode did not open"
fi

info "Back closes search and returns to the list with the pill"
adb_ shell input keyevent 4 >/dev/null 2>&1
sleep 2
dump_ui
if grep -q 'text="Search conversations"' "$TMP/ui.xml" && \
   grep -q 'content-desc="Start chat"' "$TMP/ui.xml"; then
    ok "back restores the home list with the search pill"
else
    bad "back did not restore the home list"
fi

echo ""
info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
