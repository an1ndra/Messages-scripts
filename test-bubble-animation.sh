#!/usr/bin/env bash
# Regression for chat bubble entrance animation. A message that arrives after
# the conversation is already on screen (incoming SMS or an outgoing send) must
# play the bubble entrance animation; opening an existing conversation must not
# animate its history.
#
# Asserted via the app's "BubbleAnim" logcat marker, emitted once per animated
# bubble with `id=... mine=<bool>`.
#
# Run: scripts/test-bubble-animation.sh
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh

PASS=0
FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }

[[ "$ANDROID_SERIAL" == emulator-* ]] || { printf 'Requires a disposable emulator.\n'; exit 1; }

NUM="+1555$(date +%s | tail -c 8)"
MARK="bubble $(date +%s)"
entrances() { adb_ logcat -d -s BubbleAnim:D 2>/dev/null | grep -c 'entrance id=' || true; }

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    adb_ shell "run-as $PKG sqlite3 databases/messages.db \"DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM'); DELETE FROM conversations WHERE address='$NUM'; DELETE FROM participants WHERE normalized_destination='$NUM';\"" >/dev/null 2>&1 || true
}
trap cleanup EXIT

adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1 || true
bash ./grant-permissions.sh >/dev/null 2>&1 || true

info "opening a conversation with existing history"
adb_ emu sms send "$NUM" "seed one $MARK" >/dev/null
sleep 3
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell logcat -c
adb_ shell am start -n "$ACT" --es open_conversation_address "$NUM" >/dev/null
sleep 5
HISTORY=$(entrances)
if [[ "$HISTORY" == 0 ]]; then
    pass 'opening an existing conversation does not animate its history'
else
    fail "history replayed the entrance animation ($HISTORY times)"
fi

info "incoming message while the chat is open"
adb_ emu sms send "$NUM" "incoming $MARK" >/dev/null
sleep 4
INCOMING=$(adb_ logcat -d -s BubbleAnim:D 2>/dev/null | grep -c 'entrance id=.* mine=false' || true)
if [[ "$INCOMING" -ge 1 ]]; then
    pass 'incoming message animates its bubble'
else
    fail 'incoming message did not animate its bubble'
fi

info "outgoing message from the chat"
if tap_edittext >/dev/null 2>&1; then
    sleep 1
    adb_ shell input text "outgoing_$MARK" >/dev/null
    sleep 1
    tap_text "Send" >/dev/null 2>&1 || adb_ shell input keyevent 66
    sleep 4
    OUTGOING=$(adb_ logcat -d -s BubbleAnim:D 2>/dev/null | grep -c 'entrance id=.* mine=true' || true)
    if [[ "$OUTGOING" -ge 1 ]]; then
        pass 'outgoing message animates its bubble'
    else
        fail 'outgoing message did not animate its bubble'
    fi
else
    fail 'could not focus the chat input'
fi

info "scrolling does not replay the animation"
BEFORE=$(entrances)
adb_ shell input swipe 540 900 540 1600 250 >/dev/null 2>&1
sleep 1
adb_ shell input swipe 540 1600 540 900 250 >/dev/null 2>&1
sleep 1
AFTER=$(entrances)
if [[ "$AFTER" == "$BEFORE" ]]; then
    pass 'scrolling does not replay the entrance animation'
else
    fail "scrolling replayed the animation ($BEFORE -> $AFTER)"
fi

printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
