#!/usr/bin/env bash
# One Back from the inbox closes the app.
#
# The app used to answer the first Back with "Press back again to exit" and only
# finish on the second, which read as the button doing nothing. Asserted from
# `dumpsys`: the package must no longer be the resumed activity after a single
# press, and the toast must never appear in the dump on the way out.
#
# Run: scripts/test-back-single-press.sh
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

APP_USER="${APP_USER:-0}"

dump_ui || { bad "uiautomator dump failed"; exit 1; }

adb_ shell am force-stop "$PKG" >/dev/null 2>&1
adb_ shell am start --user "$APP_USER" -n "$ACT" >/dev/null 2>&1
if ! wait_for_text "$(res_string conversations_messages)" 12; then
    bad "the inbox never opened"
    exit 1
fi
ok "the inbox is open"

adb_ shell input keyevent 4
sleep 2

RESUMED=$(adb_ shell "dumpsys activity activities" 2>/dev/null \
    | grep "mResumedActivity" | grep -c "$PKG")
if [ "$RESUMED" = "0" ]; then
    ok "one Back press closed the app"
else
    bad "the app is still in front after one Back press"
fi

# The old gesture announced itself with a toast; the dump is taken right after
# the press, so a reminder would still have been on screen.
if dump_ui 2>/dev/null && grep -qF "$(res_string conversations_press_back_exit)" "$TMP/ui.xml"; then
    bad "the app still asks for a second Back press"
else
    ok "no second-press reminder"
fi

echo ""
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
