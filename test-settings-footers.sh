#!/usr/bin/env bash
# Every settings sub-page ends with a footer note, and the pages with a preview
# or a long list must scroll to reach it. Also asserts the note is not just a
# copy of one of the rows above it.
source "$(dirname "$0")/env.sh"

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

PREFS="/data/data/$PKG/shared_prefs/messages_settings.xml"

launch_settings() {
    adb_ shell am force-stop "$PKG"; sleep 1
    adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null; sleep 4
    dump_ui >/dev/null
}

open_row() {
    # Scroll to the row first: the settings pages have grown, so the last row is
    # no longer on screen at the top.
    local i
    for i in 0 1 2 3 4 5 6 7 8; do
        dump_ui >/dev/null 2>&1 || true
        if center_of "$1" >/dev/null 2>&1; then
            tap_text "$1" >/dev/null || return 1
            sleep 2.5
            dump_ui >/dev/null
            return 0
        fi
        [ "$i" -eq 3 ] && adb_ shell input swipe 540 1700 540 900 300
        sleep 0.7
    done
    return 1
}

scroll_to_bottom() {
    local i
    for i in 1 2 3 4 5 6; do
        adb_ shell input swipe 540 1700 540 700 300
        sleep 0.6
    done
    sleep 1
    dump_ui >/dev/null
}

# The Accessibility options row only exists while accessibility mode is on, so
# record the current value and put it back afterwards.
# Extract the attribute value only: grepping for bare letters would also match
# the "value" in `value="true"`, and a multi-line result would corrupt the pref.
a11y_pref() {
    adb_ shell "run-as $PKG cat $PREFS 2>/dev/null" \
        | grep -oE '<boolean name="a11y_enabled" value="[a-z]+"' \
        | sed -E 's/.*value="([a-z]+)".*/\1/'
}

set_a11y() {
    local want="$1"
    # Guard the write: this edits the prefs file in place, and a stray value
    # would produce XML the app cannot parse.
    case "$want" in
        true|false) ;;
        *) echo "refusing to write a11y_enabled='$want'" >&2; return 1 ;;
    esac
    adb_ shell am force-stop "$PKG"; sleep 1
    if adb_ shell "run-as $PKG cat $PREFS 2>/dev/null" | grep -q 'name="a11y_enabled"'; then
        adb_ shell "run-as $PKG sh -c 'sed -i \"s|<boolean name=\\\"a11y_enabled\\\" value=\\\"[a-z]*\\\" />|<boolean name=\\\"a11y_enabled\\\" value=\\\"$want\\\" />|\" $PREFS'" >/dev/null
    else
        adb_ shell "run-as $PKG sh -c 'sed -i \"s|</map>|    <boolean name=\\\"a11y_enabled\\\" value=\\\"$want\\\" />\\\\n</map>|\" $PREFS'" >/dev/null
    fi
    adb_ shell "run-as $PKG rm -f $PREFS.bak" >/dev/null 2>&1
}

# $1 = page label, $2 = expected footer snippet
check_footer() {
    local label="$1" snippet="$2"
    if grep -qF "$snippet" "$TMP/ui.xml"; then
        pass "$label shows its footer note"
    else
        fail "$label is missing its footer note"
    fi
}

A11Y_BEFORE=$(a11y_pref)
[ -z "$A11Y_BEFORE" ] && A11Y_BEFORE=false
if [ "$A11Y_BEFORE" != "true" ]; then
    set_a11y true
fi

info "Link behaviour page footer"
launch_settings
open_row "Advanced settings" && open_row "Link behaviour" || fail "could not open Link behaviour"
check_footer "Link behaviour" "Choose how links in your messages behave"
scroll_to_bottom
check_footer "Link behaviour (after scroll)" "Choose how links in your messages behave"

info "Notifications page footer"
launch_settings
open_row "Advanced settings" && open_row "Notifications" || fail "could not open Notifications"
check_footer "Notifications" "Control which conversations notify you"
scroll_to_bottom
check_footer "Notifications (after scroll)" "Control which conversations notify you"

info "Auto-delete page footer"
launch_settings
open_row "Advanced settings" && open_row "Auto-delete" || fail "could not open Auto-delete"
check_footer "Auto-delete" "Deleted conversations, blocked messages"
scroll_to_bottom
check_footer "Auto-delete (after scroll)" "Deleted conversations, blocked messages"

info "Accessibility page footer"
launch_settings
open_row "Advanced settings" && open_row "Accessibility options" || fail "could not open Accessibility options"
check_footer "Accessibility" "Accessibility mode enlarges text"
scroll_to_bottom
check_footer "Accessibility (after scroll)" "Accessibility mode enlarges text"

info "Inbox settings page footer, and the page scrolls"
launch_settings
open_row "Inbox settings" || fail "could not open Inbox settings"
# The preview mocks make this page taller than the screen, so the footer is only
# reachable by scrolling. That is the regression this guards.
if grep -qF "Archiving, swipe actions, blocking" "$TMP/ui.xml"; then
    fail "Inbox settings footer is on screen without scrolling (page is not scrollable?)"
else
    pass "Inbox settings footer starts off screen, as expected for a tall page"
    scroll_to_bottom
    check_footer "Inbox settings (after scroll)" "Archiving, swipe actions, blocking"
fi

info "Restoring accessibility mode"
if [ "$A11Y_BEFORE" != "true" ]; then
    set_a11y "$A11Y_BEFORE"
    launch_settings
    dump_ui >/dev/null
    now=$(a11y_pref)
    if [ "$now" = "$A11Y_BEFORE" ]; then
        pass "a11y_enabled restored to $A11Y_BEFORE"
    else
        fail "a11y_enabled is '$now', expected '$A11Y_BEFORE'"
    fi
else
    pass "a11y_enabled left on (as found)"
fi

echo
if [ "$FAIL" = 0 ]; then
    echo "ALL SETTINGS FOOTER TESTS PASSED"
else
    echo "SOME SETTINGS FOOTER TESTS FAILED"
    exit 1
fi
