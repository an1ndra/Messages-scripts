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
#   * a lock delivered *without* a pause/resume still re-arms the window,
#   * the conversation behind the gate comes back after unlocking, rather than
#     as a blank chat (#354 round 7),
#   * a fresh process starts locked again (the session is never persisted).
#
# Run: scripts/test-app-lock-session.sh
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

MARK="locksession$(date +%s)"
TEXT="lock session probe $MARK"
NUM="+1555$(( (RANDOM % 9000) + 1000 ))"

sql() { adb_ shell "sqlite3 /data/data/$PKG/databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r'; }

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
    sql "DELETE FROM messages WHERE body='$TEXT';" >/dev/null 2>&1
    sql "DELETE FROM conversations WHERE address='$NUM';" >/dev/null 2>&1
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
# Poll: the gate re-arms on the resume that follows the wake, and a single
# uiautomator dump here raced it often enough to report a phantom failure.
if wait_layout_has "App lock is off" 8 || wait_layout_has "Unlock Messages" 2; then
    ok "the open window re-armed the lock after the screen went off"
else
    bad "the open window kept its content after the screen went off (#354)"
fi
if layout_has "Start chat"; then
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

info "A lock delivered without a resume still gates the window (#354)"
# A delayed screen-off broadcast (or a bubble the platform keeps resumed) lands
# after the window is already resumed, so no ON_RESUME follows it. The window
# used to keep its content until the next resume; it now observes the session.
# The debug receiver ends the session with no activity transition at all, which
# is the ordering `am start` cannot produce (it resumes the window).
adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
adb_ shell am start -n "$ACT" --es app_lock_probe enable --es lock_session_probe unlock >/dev/null 2>&1
sleep 4
if ui_has "Not now"; then tap_text "Not now" >/dev/null 2>&1; sleep 1; fi
if wait_layout_has "Start chat" 10; then
    ok "the unlocked app is showing its content"
else
    bad "the app did not open with an unlocked session"
fi
adb_ shell am broadcast -a com.anindra.messages.DEBUG_LOCK_SESSION -p "$PKG" >/dev/null 2>&1
sleep 3
if wait_layout_has "App lock is off" 8 || wait_layout_has "Unlock Messages" 2; then
    ok "a lock delivered while the window was resumed re-armed it"
else
    bad "the window kept its content because no resume event followed (#354)"
fi
if layout_has "Start chat"; then
    bad "the conversation list is still reachable behind the lock"
else
    ok "the conversation list is gone until the lock is answered"
fi
adb_ shell input keyevent KEYCODE_BACK >/dev/null 2>&1
sleep 1

info "A conversation unlocked again comes back, not blank (#354)"
# The reporter: "open a conversation ... lock the phone, unlock it, open the
# app, unlock it, and the conversation is blank". The gate removes the whole
# content composition, which discarded the conversation id while the route
# survived; the chat then rendered for no conversation at all.
adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
adb_ emu sms send "$NUM" "$TEXT" >/dev/null 2>&1
for _ in $(seq 1 20); do
    [ -n "$(sql "SELECT id FROM messages WHERE body='$TEXT' LIMIT 1;")" ] && break
    sleep 1
done
adb_ shell am start -n "$ACT" --es app_lock_probe enable --es lock_session_probe unlock \
    --es open_conversation_address "$NUM" >/dev/null 2>&1
sleep 4
if ui_has "Not now"; then tap_text "Not now" >/dev/null 2>&1; sleep 1; fi
if wait_layout_has "$TEXT" 10; then
    ok "the conversation opened with its message"
else
    bad "the conversation did not open"
fi
adb_ shell input keyevent KEYCODE_SLEEP >/dev/null 2>&1
sleep 2
adb_ shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1
adb_ shell wm dismiss-keyguard >/dev/null 2>&1
sleep 3
if wait_layout_has "App lock is off" 8 || wait_layout_has "Unlock Messages" 2; then
    ok "the open conversation fell back behind the gate"
else
    bad "the open conversation stayed readable after the screen went off"
fi
if wait_layout_has "App lock is off" 1; then
    tap_layout "Got it" >/dev/null 2>&1
    sleep 2
fi
if wait_layout_has "$TEXT" 10; then
    ok "the conversation came back with its messages after unlocking"
else
    bad "the unlocked window showed a blank conversation (#354)"
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
