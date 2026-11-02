#!/usr/bin/env bash
# Regression for the app-lock session (#354 follow-up).
#
# The reporter: "too many fingerprint interrupts ... may be unlock once until
# screen lock can be good". The prompt used to run in `setContent`, i.e. once
# per activity — cold start, share intent, rotation, and every bubble open.
#
# An emulator has no enrolled fingerprint, so the prompt itself cannot be
# driven. The session behind it can be, through a debug-gated intent extra, and
# that is what these cases pin:
#   * an unlocked session survives a new activity in the same process,
#   * turning the screen off ends it,
#   * a window that is already open notices, and re-arms on the way back
#     (#354: "the bubble of a conversation, when it opens once, won't get
#     locked on screen lock"),
#   * a fresh process starts locked again (the session is never persisted).
#
# Run: scripts/test-app-lock-session.sh
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

query_session() {
    adb_ logcat -c >/dev/null 2>&1
    adb_ shell am start -n "$ACT" --es lock_session_probe query >/dev/null 2>&1
    for _ in $(seq 1 10); do
        sleep 1
        line=$(adb_ logcat -d -s LockSessionProbe:D 2>/dev/null | tr -d '\r' | grep -o "unlocked=[a-z]*" | tail -1)
        [ -n "$line" ] && { echo "$line"; return 0; }
    done
    echo ""
}

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    # The screen-off case below arms App lock through the debug probe; leave the
    # setting as it was found.
    adb_ shell am start -n "$ACT" --es app_lock_probe disable >/dev/null 2>&1
    sleep 1
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    adb_ shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1
    adb_ shell wm dismiss-keyguard >/dev/null 2>&1
}
trap cleanup EXIT

adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1 || true
adb_ shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1
adb_ shell wm dismiss-keyguard >/dev/null 2>&1

info "A fresh process starts locked"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
SEEN=$(query_session)
[ "$SEEN" = "unlocked=false" ] \
    && ok "the session starts locked" \
    || bad "a new process reported '${SEEN:-nothing}' instead of unlocked=false"

info "An unlocked session survives a new activity"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
adb_ shell am start -n "$ACT" --es lock_session_probe unlock >/dev/null 2>&1
sleep 3
SEEN=$(query_session)
[ "$SEEN" = "unlocked=true" ] \
    && ok "opening another activity (a bubble, a share) does not re-lock" \
    || bad "the second activity reported '${SEEN:-nothing}' instead of unlocked=true"

info "The screen going off ends it"
adb_ shell input keyevent KEYCODE_SLEEP >/dev/null 2>&1
sleep 2
adb_ shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1
adb_ shell wm dismiss-keyguard >/dev/null 2>&1
sleep 1
SEEN=$(query_session)
[ "$SEEN" = "unlocked=false" ] \
    && ok "screen off ended the unlocked session" \
    || bad "the session survived the screen going off ('${SEEN:-nothing}')"

info "An open window re-arms when the screen goes off"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
adb_ shell am start -n "$ACT" --es app_lock_probe enable --es lock_session_probe unlock >/dev/null 2>&1
sleep 4
if ui_has "Not now"; then tap_text "Not now" >/dev/null 2>&1; sleep 1; fi
if wait_for_text "Start chat" 10; then
    ok "an unlocked session opens the app with no prompt"
else
    bad "the app did not open with an unlocked session"
fi
adb_ shell input keyevent KEYCODE_SLEEP >/dev/null 2>&1
sleep 2
adb_ shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1
adb_ shell wm dismiss-keyguard >/dev/null 2>&1
sleep 3
# No credential is enrolled on this AVD, so the re-armed gate lands on the
# "App lock is off" screen. With one it would be the Unlock Messages prompt.
# Either proves the window read the session again after the screen came back.
if ui_has "App lock is off" || ui_has "Unlock Messages"; then
    ok "the open window re-armed the lock after the screen went off"
else
    bad "the open window kept its content after the screen went off (#354)"
fi
if grep -qF "Start chat" "$TMP/ui.decoded.xml" 2>/dev/null; then
    bad "the conversation list is still reachable behind the lock"
else
    ok "the conversation list is gone until the lock is answered"
fi
adb_ shell input keyevent KEYCODE_BACK >/dev/null 2>&1
sleep 1

info "The bubble's own window re-arms as well"
# BubbleChatActivity is a MainActivity subclass, so it inherits the resume
# re-check. Asserted from the log rather than the hierarchy: it is the same
# decision, and uiautomator is unreliable on this AVD mid-run.
adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
adb_ shell logcat -c >/dev/null 2>&1
adb_ shell am start -n "$PKG/.BubbleChatActivity" --es app_lock_probe enable --es lock_session_probe unlock >/dev/null 2>&1
sleep 4
adb_ shell input keyevent KEYCODE_SLEEP >/dev/null 2>&1
sleep 2
adb_ shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1
adb_ shell wm dismiss-keyguard >/dev/null 2>&1
sleep 3
if adb_ logcat -d -s LockSession:D 2>/dev/null | grep -q "regate=true"; then
    ok "the bubble window fell back into the gate after the screen went off"
else
    bad "the bubble window kept its content after the screen went off (#354)"
fi
adb_ shell input keyevent KEYCODE_BACK >/dev/null 2>&1
sleep 1

info "A restart does not resume an unlocked session"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
adb_ shell am start -n "$ACT" --es lock_session_probe unlock >/dev/null 2>&1
sleep 3
adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
SEEN=$(query_session)
[ "$SEEN" = "unlocked=false" ] \
    && ok "the session is process-lived, never persisted" \
    || bad "a restarted process reported '${SEEN:-nothing}' instead of unlocked=false"

echo ""
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
