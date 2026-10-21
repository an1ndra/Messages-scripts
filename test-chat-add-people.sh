#!/usr/bin/env bash
# Regression for #327: "Add people" in a chat's overflow menu did nothing.
#
# It must open the same picker the contact-profile row opens, and the picker's
# back must return to the chat it was opened from.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

PRIMARY="+1555771030"

cleanup() { adb_ shell am force-stop "$PKG" >/dev/null 2>&1; }
trap cleanup EXIT

for p in READ_SMS SEND_SMS POST_NOTIFICATIONS; do
    adb_ shell pm grant "$PKG" android.permission.$p 2>/dev/null
done

info "Open a 1:1 conversation"
adb_ shell am force-stop "$PKG"; sleep 1
OPENED=0
for i in 1 2 3; do
    adb_ shell am start -n "$ACT" --es open_conversation_address "$PRIMARY" >/dev/null
    if layout_has "More options"; then OPENED=1; break; fi
    adb_ shell am force-stop "$PKG"; sleep 2
done
if [ "$OPENED" = "1" ]; then
    ok "chat opened"
else
    bad "chat did not open"
    echo; echo "Results: $PASS passed, $FAIL failed"; exit 1
fi

info "Open the overflow menu and tap Add people"
if tap_layout "More options"; then
    ok "opened the overflow menu"
else
    bad "no overflow control"
fi
sleep 1.5
if tap_layout "Add people"; then
    ok "tapped Add people"
else
    bad "Add people item not found in the menu"
fi

info "The picker must open (not stay on the chat)"
if wait_layout_has "Create group" 8; then
    ok "the add-people picker opened"
else
    bad "Add people did nothing — the picker never opened"
fi
if layout_has "Create group"; then
    ok "the picker shows its Create group action"
else
    bad "the picker action is missing"
fi

info "Back returns to the chat"
adb_ shell input keyevent 4 >/dev/null; sleep 1.5
if wait_layout_has "More options" 8; then
    ok "back returned to the chat"
else
    bad "back did not return to the chat"
fi
if layout_has "Create group"; then
    bad "still on the picker after back"
else
    ok "the picker was left behind"
fi

echo
info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
