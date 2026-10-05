#!/usr/bin/env bash
# Advanced settings regression:
#   - Settings → Advanced is a list of navigation rows (Link behaviour,
#     Auto-delete, Notifications, Accessibility ...); the link and delete
#     toggles now live on their own sub-pages, and there is no Reverse swipe
#     row any more.
#   - Link open warning ON -> tap link shows "Caution: external link" dialog;
#     OFF -> same tap opens the browser directly (no dialog).
#   - Permanent delete ON -> chat 3-dot Delete asks "Delete permanently?";
#     Cancel leaves the conversation untouched. (/docs: cancel, non-destructive)
#   - All toggles are restored to their defaults at the end.
#
# Precondition: emulator booted, app installed with the demo/test row
# the target conversation can be seeded by the script itself.
# Swipe behaviour itself is covered by test-swipe-actions.sh and
# test-swipe-threshold.sh.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0; SKIP=0
check_present() {
    if grep -q "$2" "$TMP/ui.xml"; then
        echo "[PASS] $1"; PASS=$((PASS + 1))
    else
        echo "[FAIL] $1"; FAIL=$((FAIL + 1))
    fi
}
check_absent() {
    if grep -q "$2" "$TMP/ui.xml"; then
        echo "[FAIL] $1"; FAIL=$((FAIL + 1))
    else
        echo "[PASS] $1"; PASS=$((PASS + 1))
    fi
}
info() { echo -e "\n=== $* ==="; }

pref_get() {
    adb_ shell "run-as $PKG cat shared_prefs/messages_settings.xml" 2>/dev/null \
        | grep -oE "name=\"$1\" value=\"[^\"]*\"" | grep -oE 'value="[^"]*"' | cut -d'"' -f2
}
# Returns 0 when the pref is currently "true".
pref_on() { [ "$(pref_get "$1")" = "true" ]; }
# Flip a toggle in the Advanced screen to a wanted state if it differs.
ensure_switch() {
    local label="$1" pref="$2" want="$3" cur=off
    pref_on "$pref" && cur=on
    if [ "$cur" != "$want" ]; then
        dump_ui
        tap_switch_near "$label" || return 1
        sleep 0.6
    fi
}

# "Link open warning" and "Permanent delete" moved off the Advanced screen onto
# their own sub-pages, so toggling them means navigating in first.
open_link_subpage() {
    tap_text "Link behaviour" || tap_contains "Link behaviour" || return 1
    sleep 2; dump_ui
}
open_autodelete_subpage() {
    tap_text "Auto-delete" || tap_contains "Auto-delete" || return 1
    sleep 2; dump_ui
}
close_subpage() { adb_ shell input keyevent 4; sleep 1.5; }

clear_field() { for _ in $(seq 1 42); do adb_ shell input keyevent 67; done; sleep 0.5; }
tap_desc() { local c; c=$(center_of "$1") || return 1; adb_ shell input tap $c; }

launch_settings() {
    adb_ shell am force-stop "$PKG"; sleep 1
    adb_ shell am start -n "$ACT" --ez open_settings true; sleep 3
}
open_advanced() {
    adb_ shell input swipe 500 1900 500 700 400; sleep 0.5
    adb_ shell input swipe 500 1900 500 700 400; sleep 1
    tap_text "Advanced" || tap_contains "Advanced"
    sleep 1.5
}
back_to_home() {
    adb_ shell input keyevent 4; sleep 0.8
    adb_ shell input keyevent 4; sleep 1.8
}


# The row renders the number grouped, so match the subscriber part only.
TARGET_NUM="+15558887777"
TARGET="888-7777"

# This script seeds its own conversation: nothing else creates this number, so
# relying on a pre-seeded row made the whole script unrunnable.
ensure_target() {
    adb_ shell am force-stop "$PKG"; sleep 1
    adb_ shell am start -n "$ACT" >/dev/null; sleep 3.5
    dump_ui
    center_of_contains "$TARGET" >/dev/null && return 0
    adb_ emu sms send "$TARGET_NUM" "advanced settings test" >/dev/null 2>&1
    sleep 2.5
    adb_ shell am force-stop "$PKG"; sleep 1
    adb_ shell am start -n "$ACT" >/dev/null; sleep 3.5
    dump_ui
    center_of_contains "$TARGET" >/dev/null
}
tap_target() {
    local c
    c=$(center_of_contains "$TARGET") || return 1
    adb_ shell input tap $c
}
info "Cold-launch straight into Settings"
launch_settings

info "Verifying 'Highlight links' no longer lives in main Settings"
found_hlinks=0
for _ in $(seq 1 8); do
    dump_ui
    grep -q "Highlight links" "$TMP/ui.xml" && found_hlinks=1
    adb_ shell input swipe 500 1900 500 700 350; sleep 0.4
done
if [ "$found_hlinks" = "1" ]; then
    echo "[FAIL] 'Highlight links' still present in main Settings"; FAIL=$((FAIL + 1))
else
    echo "[PASS] main Settings list has no 'Highlight links' row"; PASS=$((PASS + 1))
fi
for i in 1 2 3 4 5; do adb_ shell input swipe 500 700 500 1900 350; sleep 0.2; done
sleep 0.8

info "Opening Advanced screen"
open_advanced
dump_ui
check_present "Advanced settings title" "Advanced settings"
check_present "Link behaviour row" "Link behaviour"
check_present "Auto-delete row" "Auto-delete"
check_present "Accessibility mode toggle" "Accessibility mode"
# Reverse swipe is gone: left and right are chosen independently in Inbox
# settings, so there is nothing left to reverse.
check_absent "no Reverse swipe row" "Reverse swipe actions"

open_link_subpage
ensure_switch "Link open warning" link_open_warning_enabled on
close_subpage

info "Sending a message with a link into $TARGET_NUM conversation"
ensure_target || { echo "[FAIL] could not prepare target row"; FAIL=$((FAIL + 1)); exit 1; }
tap_target || { echo "[FAIL] target row not found"; FAIL=$((FAIL + 1)); exit 1; }
sleep 2
tap_edittext || tap_desc "Message"
sleep 0.8
type_text "Visit https://example.com/check it now"; sleep 0.8
adb_ shell input keyevent 4; sleep 0.6
tap_desc "Send" || adb_ shell input tap 985 2117
sleep 2.5
dump_ui
if grep -qE 'text="Visit https://example.com/check it now"[^>]*class="android.widget.TextView"' "$TMP/ui.xml"; then
    echo "[PASS] link message rendered as a bubble"; PASS=$((PASS + 1))
else
    echo "[FAIL] link message rendered as a bubble"; FAIL=$((FAIL + 1))
fi

info "Link open warning ON -> tap link shows confirm dialog"
tap_text "Visit https://example.com/check it now"
sleep 1.2; dump_ui
check_present "confirmation dialog shown when warning ON" "Caution: external link"
adb_ shell input keyevent 4; sleep 0.8   # dismiss dialog

info "Toggling Link open warning OFF"
launch_settings
open_advanced
open_link_subpage
ensure_switch "Link open warning" link_open_warning_enabled off
close_subpage
back_to_home
sleep 1.5
ensure_target
tap_target || { echo "[FAIL] target row not found after toggle"; FAIL=$((FAIL + 1)); }
sleep 2
tap_text "Visit https://example.com/check it now"
sleep 1.8; dump_ui
check_absent "no warning dialog when warning OFF" "Caution: external link"
top=$(adb_ shell "dumpsys activity activities | grep topResumedActivity" 2>/dev/null)
if echo "$top" | grep -q "com.anindra.messages"; then
    echo "[FAIL] browser did not come to the foreground"; FAIL=$((FAIL + 1))
else
    echo "[PASS] external browser opened directly"; PASS=$((PASS + 1))
fi
# The browser gets a task rooted at MainActivity; back out of it so the next
# launch_settings cold-starts cleanly instead of "delivering" the intent.
adb_ shell input keyevent 4; sleep 1.5

info "Ensuring Link open warning back ON, Permanent delete ON"
launch_settings
open_advanced
open_link_subpage
ensure_switch "Link open warning" link_open_warning_enabled on
close_subpage
open_advanced
open_autodelete_subpage
ensure_switch "Permanent delete" permanent_delete_enabled on
close_subpage
back_to_home
sleep 1.5
ensure_target
tap_target || { echo "[FAIL] target row not found (permanent-delete step)"; FAIL=$((FAIL + 1)); }
sleep 2
tap_text "More options" || tap_desc "More options"
sleep 1.5
tap_text "Delete"
sleep 1.2; dump_ui
check_present "permanent-delete confirm dialog shown" "Delete permanently?"
check_present "permanent-delete warning body" "removed from your device right away"
tap_text "Cancel" || adb_ shell input keyevent 4
sleep 1.2; dump_ui
check_present "conversation still open after Cancel" "$TARGET"
adb_ shell input keyevent 4; sleep 1.8   # chat -> home

info "Toggling Permanent delete OFF"
launch_settings
open_advanced
open_autodelete_subpage
ensure_switch "Permanent delete" permanent_delete_enabled off
close_subpage
back_to_home
dump_ui

info "Verifying toggles are back to their defaults"
launch_settings
open_advanced
adb_ shell input keyevent 4; sleep 1
if pref_on permanent_delete_enabled; then
    echo "[FAIL] permanent_delete_enabled still 'true'"; FAIL=$((FAIL + 1))
else
    echo "[PASS] permanent_delete_enabled back to default (off)"; PASS=$((PASS + 1))
fi
if pref_on link_open_warning_enabled || [ -z "$(pref_get link_open_warning_enabled)" ]; then
    echo "[PASS] link_open_warning_enabled back to default (on)"; PASS=$((PASS + 1))
else
    echo "[FAIL] link_open_warning_enabled still 'false'"; FAIL=$((FAIL + 1))
fi

echo
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]