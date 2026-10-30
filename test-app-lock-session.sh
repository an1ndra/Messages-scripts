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
    adb_ shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1
    adb_ shell wm dismiss-keyguard >/dev/null 2>&1
}
trap cleanup EXIT

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
