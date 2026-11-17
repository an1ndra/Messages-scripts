#!/usr/bin/env bash
# Regression for #490: a first launch asks for the default-SMS role first, and
# only what the role does not already grant afterwards.
#
# The old flow fired requestSmsPermissions() from onCreate, so a new user met
# the system permission dialogs (SMS, contacts) before the app's own
# "Set as default SMS app" prompt — four yes-screens before a message. Holding
# the SMS role silently grants the whole SMS set, so the SMS dialog asked for
# something the role was about to hand over anyway; contacts moved to the
# moment they are first needed.
#
# What this asserts, in the order a finger meets it:
#   * a fresh install opens onto the app — no system permission dialog ever
#     takes the screen at launch (pre-fix: GrantPermissionsActivity owns it
#     within seconds);
#   * the app's own Set-as-default prompt is the first thing it shows;
#   * declining it leaves a usable inbox;
#   * contacts are asked for only at the moment they are needed: opening the
#     new-chat screen brings up the contacts dialog, and not before.
#
# The system's role dialog itself is outside the app's control and half-broken
# on the comparison AVD (cmd role silently ignores removals there), so the role
# is handed to Google Messages for the run and the walk stops at "Not now".
#
# Run: scripts/test-first-launch-permissions.sh
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

GM=com.google.android.apps.messaging
DEFAULT_SMS_TITLE=$(res_string default_sms_title)
NOT_NOW=$(res_string lock_not_now)
START_CHAT=$(res_string access_start_chat)

adb_ root >/dev/null 2>&1; adb_ wait-for-device; sleep 1
# A stored crash report opens its own dialog over the app on the next launch,
# which no seeded flow can get past. Cleared here so a run starts clean.
adb_su "rm -f $PKG/files/crash_reports/*" >/dev/null 2>&1 || true

cleanup() {
    # Leave the standing test state behind: the role and the grants.
    hand_role_to "$PKG" >/dev/null 2>&1
    for p in SEND_SMS RECEIVE_SMS READ_SMS READ_CONTACTS POST_NOTIFICATIONS READ_PHONE_STATE; do
        adb_ shell pm grant "$PKG" android.permission.$p >/dev/null 2>&1
    done
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
}
trap cleanup EXIT

focus_window() { adb_ shell dumpsys window 2>/dev/null | tr -d '\r' | grep -m1 mCurrentFocus; }
permission_dialog_up() { focus_window | grep -q "GrantPermissionsActivity"; }

# pm clear leaves the package briefly unstartable, so the launch is retried
# until either the app's window or the system's permission dialog owns the
# screen — whichever the build puts in front.
launch_until_up() {
    local i
    for i in $(seq 1 10); do
        adb_ shell am start -n "$ACT" >/dev/null 2>&1
        sleep 1.5
        focus_window | grep -qE "anindra|GrantPermissions" && return 0
    done
    return 1
}

# True when GrantPermissionsActivity owns the screen at any point in the first
# seconds — the window where the pre-fix flow put its launch-time dialogs.
launch_ever_shows_permission_dialog() {
    local i
    for i in $(seq 1 12); do
        permission_dialog_up && return 0
        sleep 0.5
    done
    return 1
}

# Answer every permission dialog in turn; a declined role can queue the SMS
# set, and the walk stops as soon as the app owns the screen again.
walk_permission_dialogs() {
    local i
    for i in $(seq 1 6); do
        permission_dialog_up || return 0
        tap_contains "ALLOW" >/dev/null 2>&1
        sleep 2
    done
}

# Role moves are applied asynchronously and can fail silently, so the move is
# verified from the role manager's own state and retried until it holds.
role_holder() {
    adb_ shell dumpsys role 2>/dev/null | tr -d '\r' \
        | grep -A1 "name=android.app.role.SMS" | grep -oE "holders=.*" | cut -d= -f2
}
hand_role_to() {
    local i
    for i in $(seq 1 5); do
        adb_su "cmd role add-role-holder android.app.role.SMS $1" >/dev/null 2>&1
        sleep 2
        [ "$(role_holder)" = "$1" ] && return 0
    done
    return 1
}

info "Fresh install state: no grants, no history, the role on Google Messages"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1
if hand_role_to "$GM"; then
    ok "the role moved to $GM"
else
    bad "could not move the role to $GM"
    echo ""
    echo "=== RESULTS: $PASS passed, $FAIL failed ==="
    exit 1
fi
adb_ shell pm clear "$PKG" >/dev/null 2>&1
sleep 2
ok "cleared"

info "Launch: the app itself comes up, and no permission dialog takes the screen"
if ! launch_until_up; then
    bad "the app never came up"
    echo ""
    echo "=== RESULTS: $PASS passed, $FAIL failed ==="
    exit 1
fi
ok "the app came up"
if launch_ever_shows_permission_dialog; then
    bad "a system permission dialog is up at launch"
else
    ok "no permission dialog in front of the app"
fi

info "The app's own default-SMS prompt is the first thing it shows"
if wait_for_text "$DEFAULT_SMS_TITLE" 12; then
    ok "the Set-as-default prompt appeared"
else
    bad "the Set-as-default prompt never appeared"
    echo ""
    echo "=== RESULTS: $PASS passed, $FAIL failed ==="
    exit 1
fi

if tap_contains "$NOT_NOW" >/dev/null 2>&1; then
    ok "declining the prompt returns to the app"
else
    bad "could not decline the prompt"
fi
# Declining the role is the designed fallback: without it the app still needs
# the SMS set to do anything, so it is asked for now — after the role had its
# say, which is the whole point. Walk whatever comes up, then land in the app.
sleep 2
if permission_dialog_up; then
    ok "declining the role asks for the SMS set afterwards"
    walk_permission_dialogs
else
    ok "nothing more was asked after declining"
fi
if wait_for_text "$START_CHAT" 12; then
    ok "the inbox is reachable"
else
    bad "the inbox is not reachable"
fi

info "Contacts: asked at the moment they are first needed, not at launch"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
if ! launch_until_up; then
    bad "the app never came back"
    echo ""
    echo "=== RESULTS: $PASS passed, $FAIL failed ==="
    exit 1
fi
if ! wait_for_text "$DEFAULT_SMS_TITLE" 12; then
    bad "the Set-as-default prompt did not reappear on a new session"
    echo ""
    echo "=== RESULTS: $PASS passed, $FAIL failed ==="
    exit 1
fi
tap_contains "$NOT_NOW" >/dev/null 2>&1
if wait_for_text "$START_CHAT" 10; then
    ok "a new session still starts on the prompt and the inbox"
else
    bad "the inbox never came back"
    echo ""
    echo "=== RESULTS: $PASS passed, $FAIL failed ==="
    exit 1
fi
if permission_dialog_up; then
    bad "a permission dialog is up before contacts are needed"
else
    ok "still no permission dialog while only browsing"
fi
if tap_contains "$START_CHAT" >/dev/null 2>&1; then
    ok "the new-chat screen opened"
else
    bad "could not open the new-chat screen"
    echo ""
    echo "=== RESULTS: $PASS passed, $FAIL failed ==="
    exit 1
fi
sleep 2
if permission_dialog_up && ui_has "contacts"; then
    ok "the new-chat screen brings up the contacts dialog"
else
    bad "contacts were never asked for at the moment they were needed"
fi

echo ""
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
