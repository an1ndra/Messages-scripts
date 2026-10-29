#!/usr/bin/env bash
# #386: "Can't Schedule Texts After Installation" — the app had a Scheduled
# messages section and a settings toggle, but the only way to create one was a
# long-press on Send, and the toggle was written by the legacy screen and read
# nowhere.
#
# This asserts the reporter's expectation: with something to send, a Schedule
# control is visible in the composer, tapping it opens the picker, and turning
# the setting off removes it again.
#
# Fails on the pre-change build: there is no "Schedule" node in the composer at
# all — only a long-press nobody can see.
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
adb_ root >/dev/null 2>&1

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { printf '\n=== %s ===\n' "$1"; }

MARK="schedprobe$(date +%s)"
PREFS="shared_prefs/messages_settings.xml"

set_setting() {   # value
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    adb_ shell "run-as $PKG sh -c 'if grep -q name=\"scheduled_messages_enabled\" $PREFS; then sed -i \"s#name=\\\"scheduled_messages_enabled\\\" value=\\\"[^\\\"]*\\\"#name=\\\"scheduled_messages_enabled\\\" value=\\\"$1\\\"#\" $PREFS; else sed -i \"s#</map>#    <boolean name=\\\"scheduled_messages_enabled\\\" value=\\\"$1\\\" /></map>#\" $PREFS; fi'" >/dev/null 2>&1
}

open_first_chat() {
    adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 4
    adb_ shell input tap 500 300 >/dev/null 2>&1; sleep 3
}

clear_draft() {
    # Drafts are persisted (drafts_enabled defaults true), so a run that typed
    # text leaves the composer non-empty for the next one.
    adb_ shell input tap 500 2140 >/dev/null 2>&1; sleep 1
    adb_ shell input keyevent 123 >/dev/null 2>&1
    for _ in $(seq 1 40); do adb_ shell input keyevent 67 >/dev/null 2>&1; done
    adb_ shell input keyevent 4 >/dev/null 2>&1; sleep 1
}

type_draft() {
    adb_ shell input tap 500 2140 >/dev/null 2>&1; sleep 1
    adb_ shell input text "$1" >/dev/null 2>&1; sleep 2
}

cleanup() {
    adb_ shell input keyevent 4 >/dev/null 2>&1
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    adb_ shell "sqlite3 /data/data/$PKG/databases/messages.db \"DELETE FROM messages WHERE body LIKE '%$MARK%';\"" >/dev/null 2>&1
    set_setting true
    adb_ shell am start -n "$ACT" >/dev/null 2>&1
}
trap cleanup EXIT

info "Preconditions"
adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1
adb_ shell pm grant "$PKG" android.permission.READ_SMS >/dev/null 2>&1
adb_ shell pm grant "$PKG" android.permission.SEND_SMS >/dev/null 2>&1
set_setting true
open_first_chat
ok "opened a conversation with scheduling enabled"

info "The composer shows the control only when there is something to send"
clear_draft
if layout_has "Schedule"; then
    bad "an empty composer already shows Schedule"
else
    ok "an empty composer stays clean, like Google Messages"
fi
type_draft "$MARK"
if wait_layout_has "Schedule" 6; then
    ok "typing shows a Schedule control (no hidden long-press needed)"
else
    bad "no Schedule control appeared with a draft — #386 is not fixed"
fi

info "Tapping it opens the schedule picker"
tap_layout "Schedule" >/dev/null 2>&1; sleep 3
if wait_layout_has "Select time" 6 || wait_layout_has "Next" 4; then
    ok "the picker opened"
else
    bad "tapping Schedule did not open the picker"
fi
adb_ shell input keyevent 4 >/dev/null 2>&1; sleep 2

info "Turning scheduling off removes the control (the setting is real)"
set_setting false
open_first_chat
type_draft "$MARK"
if layout_has "Schedule"; then
    bad "the control is still there with scheduling disabled"
else
    ok "with scheduling off the composer offers no Schedule control"
fi

echo ""
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
exit $((FAIL > 0))
