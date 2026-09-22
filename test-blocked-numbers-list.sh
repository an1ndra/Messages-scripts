#!/usr/bin/env bash
# Regression for Settings -> Blocked numbers: blocking a number makes it appear
# in the list (with a count subtitle), and Unblock removes it. Blocks via the
# conversation long-press sheet, then drives the Settings screen.
source "$(dirname "$0")/env.sh"

TAIL=$(printf '%04d' $((RANDOM % 10000)))
SENDER="+1555123$TAIL"
SEED="blocked-list-probe-$TAIL"

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

cleanup() {
    adb_ shell "run-as $PKG sh -c 'sqlite3 databases/messages.db \"DELETE FROM blocked_numbers WHERE number LIKE \\\"%$TAIL%\\\";\"'" >/dev/null 2>&1
    adb_ shell "run-as $PKG sh -c 'sqlite3 databases/messages.db \"DELETE FROM conversations WHERE id IN (SELECT conversation_id FROM messages WHERE body LIKE \\\"%$SEED%\\\");\"'" >/dev/null 2>&1
    adb_ shell "run-as $PKG sh -c 'sqlite3 databases/messages.db \"DELETE FROM messages WHERE body LIKE \\\"%$SEED%\\\";\"'" >/dev/null 2>&1
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
}
trap cleanup EXIT

open_blocked_numbers() {
    adb_ shell am force-stop "$PKG"; sleep 1
    adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null 2>&1; sleep 3
    local i
    for i in $(seq 1 8); do
        dump_ui
        grep -q 'text="Blocked numbers"' "$TMP/ui.xml" && break
        adb_ shell input swipe 540 1700 540 900 300 >/dev/null 2>&1; sleep 0.7
    done
    tap_text "Blocked numbers" >/dev/null 2>&1; sleep 1.5
}

adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1
adb_ shell pm grant "$PKG" android.permission.RECEIVE_SMS 2>/dev/null
adb_ shell pm grant "$PKG" android.permission.POST_NOTIFICATIONS 2>/dev/null

info "Seed a conversation and block the number"
adb_ emu sms send "$SENDER" "$SEED" >/dev/null 2>&1; sleep 4
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 6
c=$(center_of_contains "$TAIL") || { bad "seeded row not on list"; echo "Results: $PASS passed, $FAIL failed"; exit 1; }
xy=($c)
adb_ shell input swipe "${xy[0]}" "${xy[1]}" "${xy[0]}" "${xy[1]}" 900; sleep 1.2
tap_text "Block" >/dev/null 2>&1; sleep 1.5

info "Settings -> Blocked numbers lists the number"
open_blocked_numbers
dump_ui
grep -q "$TAIL" "$TMP/ui.xml" \
    && ok "blocked number listed" \
    || bad "blocked number not listed"

info "Unblock removes it from the list"
tap_text "Unblock" >/dev/null 2>&1; sleep 1.5
dump_ui
grep -q "$TAIL" "$TMP/ui.xml" \
    && bad "number still listed after Unblock" \
    || ok "number removed after Unblock"

echo ""
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
