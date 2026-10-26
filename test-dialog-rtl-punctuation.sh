#!/usr/bin/env bash
# Regression for #345 (third part): the "Mark all as read" confirmation on a
# Persian-locale device. The device runs every window RTL while this app's
# strings are English (no values-fa yet), and an English sentence in an RTL
# paragraph parked its trailing "?" at the visual start of the dialog title.
# Dialog copy must paint in its own strong direction.
#
# A text direction is invisible in a `uiautomator` dump (it carries the string
# and its bounds, not the paint direction), so — like BubbleDirection and
# ComposerDirection before it — the app reports the direction dialog copy
# actually painted with:
#
#   DialogBidi:  dir=Ltr|Rtl len=<n>     (per dialog Text: title and body)
#
# Both settings UIs carry the dialog, so both must report it. Fails on the
# pre-fix build: no marker is ever logged.
#
# Run: scripts/test-dialog-rtl-punctuation.sh
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

PASS=0; FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }

ROW_TITLE="Mark all as read"

pin_new_ui() {
    adb_ shell "run-as $PKG sh -c 'touch shared_prefs/messages_settings.xml'" >/dev/null 2>&1
    adb_ shell "run-as $PKG sh -c 'grep -q use_new_ui shared_prefs/messages_settings.xml || echo \"<?xml version=\\\"1.0\\\" encoding=\\\"utf-8\\\" standalone=\\\"yes\\\" ?><map><boolean name=\\\"use_new_ui\\\" value=\\\"true\\\" /></map>\" > shared_prefs/messages_settings.xml'"
    local from=false to=true
    [ "$1" = "off" ] && { from=true; to=false; }
    adb_ shell "run-as $PKG sh -c 'sed -i \"s#name=\\\"use_new_ui\\\" value=\\\"$from\\\"#name=\\\"use_new_ui\\\" value=\\\"$to\\\"#\" shared_prefs/messages_settings.xml'" >/dev/null 2>&1
}

open_settings() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
    adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null 2>&1; sleep 4
    wait_layout_has "General settings" 8 || return 1
    scroll_to_layout "$ROW_TITLE" || return 1
    return 0
}

await_dialog_marker() {
    local want="$1" i
    for i in $(seq 1 10); do
        adb_ logcat -d -s DialogBidi:D 2>/dev/null | grep -q "dir=$want" && { sleep 1; return 0; }
        sleep 1.5
    done
    return 1
}

# One full pass over a settings UI: open the confirmation, read the directions
# its copy painted with, cancel.
check_ui() {
    local label="$1" seen

    if ! open_settings; then
        fail "$label: Settings never opened"
        return
    fi
    adb_ shell logcat -c >/dev/null 2>&1
    tap_layout "$ROW_TITLE" >/dev/null 2>&1 || { fail "$label: could not tap the row"; return; }
    await_dialog_marker Ltr || { fail "$label: dialog copy painted without reporting a direction"; return; }

    seen=$(adb_ logcat -d -s DialogBidi:D 2>/dev/null | grep -o 'dir=.*' | tr -d '\r')
    local ltr=0 rtl=0
    ltr=$(printf '%s\n' "$seen" | grep -c 'dir=Ltr'); rtl=$(printf '%s\n' "$seen" | grep -c 'dir=Rtl')
    if [ "$ltr" -ge 2 ] && [ "$rtl" -eq 0 ]; then
        pass "$label: title and body painted in their own direction (Ltr, $ltr markers)"
    else
        fail "$label: expected >=2 dir=Ltr and no dir=Rtl, got: $(echo "$seen" | tr '\n' ' ')"
    fi
    if wait_layout_has "Cancel" 4; then
        tap_layout "Cancel" >/dev/null 2>&1
        pass "$label: the dialog was dismissed without marking anything read"
    else
        fail "$label: the dialog had no Cancel to dismiss it with"
    fi
}

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    pin_new_ui on >/dev/null 2>&1 || true
}
trap cleanup EXIT

for p in READ_SMS READ_CONTACTS POST_NOTIFICATIONS; do
    adb_ shell pm grant "$PKG" "android.permission.$p" >/dev/null 2>&1
done
adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1 || true

pin_new_ui on
check_ui "new settings UI"

pin_new_ui off
check_ui "legacy settings UI"

printf '\n[RESULT] %d passed, %d failed\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
