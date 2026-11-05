#!/usr/bin/env bash
# Regression for #354: with App lock on, locking the phone threw away the
# conversation a window was showing.
#
# The reporter: "open a conversation, lock your phone, unlock it, you will see
# a blank conversion" — in the app and in a conversation bubble. The chat id
# lived in the gate's composable content, so re-arming the lock on resume
# discarded it while the route stayed "chat": the chat came back with no name
# and no messages. The id now belongs to the activity and survives.
#
# Run: scripts/test-354-applock-chat-survives.sh
source "$(dirname "$0")/env.sh"

PIN=1234
MARK="applockroute$(date +%s)"
TEXT="app lock route $MARK"
NUM="+1555$(( (RANDOM % 9000) + 1000 ))"

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

# `locksettings verify --old` succeeds vacuously when no credential exists, so
# it cannot detect one. `get-disabled` prints "true" only when there is none;
# with a credential it throws instead, which also means one is set.
had_credential=1
case "$(adb_ shell locksettings get-disabled 2>&1)" in
    *true*) had_credential=0 ;;
esac

sql() { adb_su "sqlite3 /data/data/$PKG/databases/messages.db \"$1\""; }

convo_id() { sql "SELECT conversation_id FROM messages WHERE body LIKE '%$MARK%' LIMIT 1;" | tr -d '\r'; }

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    sql "DELETE FROM messages WHERE body LIKE '%$MARK%';" >/dev/null 2>&1
    sql "DELETE FROM conversations WHERE address='$NUM';" >/dev/null 2>&1
    adb_ shell am start -n "$ACT" --es app_lock_probe disable >/dev/null 2>&1
    sleep 1
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    if [ "$had_credential" = 0 ]; then
        adb_ shell locksettings clear --old "$PIN" >/dev/null 2>&1
    fi
    adb_ shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1
    adb_ shell wm dismiss-keyguard >/dev/null 2>&1
}
trap cleanup EXIT

wake() {
    adb_ shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1
    sleep 1
    adb_ shell wm dismiss-keyguard >/dev/null 2>&1
    sleep 1
}

prompt_up() { adb_ shell dumpsys window 2>/dev/null | grep -q "BiometricPrompt"; }

enter_pin() {
    local i
    for i in 1 2 3; do
        prompt_up || return 0
        adb_ shell input text "$PIN" >/dev/null 2>&1; sleep 1
        adb_ shell input keyevent 66 >/dev/null 2>&1; sleep 3
        prompt_up || return 0
        sleep 1
    done
}

# Screen off, back on, then past the device keyguard and the app's own gate.
lock_and_unlock() {
    adb_ shell input keyevent KEYCODE_SLEEP >/dev/null 2>&1; sleep 2
    adb_ shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1; sleep 1
    adb_ shell wm dismiss-keyguard >/dev/null 2>&1; sleep 1
    # Only a secure keyguard needs the PIN; typing into an absent bouncer opens
    # the system's "set a screen lock" wizard and the app never comes back.
    if adb_ shell dumpsys window 2>/dev/null | grep -q "mDreamingLockscreen=true"; then
        adb_ shell input swipe 540 1900 540 600 200 >/dev/null 2>&1; sleep 1
        adb_ shell input text "$PIN" >/dev/null 2>&1; sleep 1
        adb_ shell input keyevent 66 >/dev/null 2>&1; sleep 3
    fi
    local i
    for i in $(seq 1 8); do
        prompt_up && break
        sleep 1
    done
    enter_pin
    sleep 2
}

# `layout_has` greps whatever dump is on disk even when the dump itself failed,
# so a stale copy from before the lock would read as a pass; require the dump.
shows_mark() { dump_ui >/dev/null 2>&1 && grep -qF "$MARK" "$TMP/ui.decoded.xml"; }

# Wait for the chat to render the seeded message, up to ~12s.
wait_mark() {
    local i
    for i in $(seq 1 12); do
        shows_mark && return 0
        sleep 1
    done
    return 1
}

info "Preconditions"
if [ "$had_credential" = 0 ]; then
    adb_ shell locksettings clear --old "$PIN" >/dev/null 2>&1
    adb_ shell locksettings set-pin "$PIN" >/dev/null 2>&1
    sleep 2
    # A credential now exists, so `get-disabled` stops answering "true".
    case "$(adb_ shell locksettings get-disabled 2>&1)" in
        *true*)
            bad "could not set the temporary screen lock"
            echo ""
            echo "=== RESULTS: $PASS passed, $FAIL failed ==="
            exit 1
            ;;
        *) ok "set a temporary screen lock" ;;
    esac
else
    if adb_ shell locksettings verify --old "$PIN" >/dev/null 2>&1; then
        ok "device already had a screen lock; leaving it alone"
    else
        bad "the device has a screen lock that is not PIN $PIN"
        echo ""
        echo "=== RESULTS: $PASS passed, $FAIL failed ==="
        exit 1
    fi
fi
adb_ shell svc power stayon true >/dev/null 2>&1
# A reinstall drops the default-SMS role, and an app that is not the default SMS
# app never sees the inbound message.
adb_su "cmd role add-role-holder android.app.role.SMS $PKG" >/dev/null 2>&1 || true
# A fresh install also raises its runtime-permission dialog on first launch,
# which covers the window these assertions read.
for perm in READ_SMS RECEIVE_SMS SEND_SMS READ_CONTACTS READ_PHONE_STATE READ_MEDIA_IMAGES; do
    adb_ shell pm grant "$PKG" "android.permission.$perm" >/dev/null 2>&1 || true
done
wake
# The database is created by the app's first launch; a freshly installed build
# has none yet, and the inbound SMS would be dropped before anything can read it.
adb_ shell am force-stop "$PKG" >/dev/null 2>&1
adb_ shell am start -n "$ACT" >/dev/null 2>&1
sleep 4
adb_ emu sms send "$NUM" "$TEXT" >/dev/null 2>&1
for _ in $(seq 1 15); do
    [ -n "$(convo_id)" ] && break
    sleep 1
done
CONVO=$(convo_id)
if [ -n "$CONVO" ]; then
    ok "seeded conversation $CONVO"
else
    bad "the seeded message never reached the database"
    echo ""
    echo "=== RESULTS: $PASS passed, $FAIL failed ==="
    exit 1
fi

info "A full-screen chat survives the lock"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
adb_ shell am start -n "$ACT" --es app_lock_probe enable --es lock_session_probe unlock \
    --es open_conversation_address "$NUM" >/dev/null 2>&1
if wait_mark; then
    ok "the chat opened before locking"
else
    bad "the chat never opened, so the lock case cannot be judged"
fi
lock_and_unlock
if wait_mark; then
    ok "the chat is still on screen after unlock"
else
    bad "the chat came back blank after unlock (#354)"
fi

info "A conversation bubble survives the lock"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
adb_ shell am start -a android.intent.action.VIEW -d "messages://conversation/$CONVO" \
    -n "$PKG/.BubbleChatActivity" -f 0x18080000 \
    --es app_lock_probe enable --es lock_session_probe unlock \
    --es open_conversation_address "$NUM" --ez open_in_bubble true >/dev/null 2>&1
if wait_mark; then
    ok "the bubble opened before locking"
else
    bad "the bubble never opened, so the lock case cannot be judged"
fi
lock_and_unlock
if wait_mark; then
    ok "the bubble still shows its chat after unlock"
else
    bad "the bubble came back blank after unlock (#354)"
fi

echo ""
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
