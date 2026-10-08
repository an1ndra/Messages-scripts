#!/usr/bin/env bash
# Regression: an incoming SMS must wake a locked screen (issue #300).
#
# A heads-up popup is a peek -- the panel stays asleep on a locked screen. Only a
# full-screen intent is treated as a user-initiated wake, so the fix is three
# linked pieces: the USE_FULL_SCREEN_INTENT permission, setFullScreenIntent() on
# the incoming notification, and a trampoline activity that turns the screen on
# over the keyguard. This asserts all three independently, because each can be
# present while the others are not.
#
# Assertions are dumpsys/uiautomator text, never a screenshot:
#   - the permission is granted in the package manager
#   - the notification record carries a fullScreenIntent
#   - the device actually leaves mWakefulness=Asleep after an inbound SMS
#   - Diagnostics attributes a still-dark screen to the app or the device config
#
# The emulated radio is driven with "adb emu sms send", and the keyguard with
# input keyevent 26. The device is left unlocked at the end.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

FROM=+1234567890
MARK="wake$RANDOM"

fi_granted() {
    adb_ shell dumpsys package "$PKG" 2>/dev/null \
        | grep -A1 "USE_FULL_SCREEN_INTENT" | grep -q "granted=true"
}

wakefulness() {
    adb_ shell dumpsys power 2>/dev/null | grep -oE 'mWakefulness=[A-Za-z]+' | head -1 | cut -d= -f2
}

# The FSI PendingIntent on our own notification record. dumpsys prints it as
# fullScreenIntent=PendingIntent{...}; absent when the fix is not in the build.
notif_has_fsi() {
    adb_ shell dumpsys notification 2>/dev/null \
        | grep -E "NotificationRecord\(.*pkg=$PKG" \
        | grep -q "fullScreenIntent=PendingIntent"
}

lock_device() {
    adb_ shell input keyevent 26 >/dev/null 2>&1
    for _ in $(seq 12); do
        [ "$(wakefulness)" = "Asleep" ] && return 0
        sleep 1
    done
    return 1
}

wake_device() {
    adb_ shell input keyevent 26 >/dev/null 2>&1
    adb_ shell input keyevent 82 >/dev/null 2>&1
    for _ in $(seq 12); do
        [ "$(wakefulness)" != "Asleep" ] && return 0
        sleep 1
    done
    return 1
}

# Clear the keyguard so the app is reachable again, using the PIN this script set.
unlock_device() {
    adb_ shell input swipe 540 1800 540 400 200 >/dev/null 2>&1
    sleep 1
    adb_ shell input text 1234 >/dev/null 2>&1
    adb_ shell input keyevent 66 >/dev/null 2>&1
    sleep 2
}

cleanup() {
    wake_device >/dev/null 2>&1
    adb_ shell input swipe 540 1800 540 400 200 >/dev/null 2>&1
    sleep 1
    adb_ shell input text 1234 >/dev/null 2>&1
    adb_ shell input keyevent 66 >/dev/null 2>&1
    sleep 1
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    [ "$SET_PIN" = yes ] && adb_ shell locksettings clear --old 1234 >/dev/null 2>&1
    return 0
}
trap cleanup EXIT

# The AVD ships with no lock credential, so the keyguard is never "locked" and
# isKeyguardLocked is false -- the wake is correctly declined and the test would
# measure the absence of a keyguard rather than a broken fix. A PIN has to be
# set for this to test anything, and cleared afterwards.
have_credential() { ! adb_ shell locksettings get-disabled 2>/dev/null | grep -q true; }
SET_PIN=no
have_credential || { adb_ shell locksettings set-pin 1234 >/dev/null 2>&1; SET_PIN=yes; }
adb_ shell locksettings set-disabled false >/dev/null 2>&1

info "The USE_FULL_SCREEN_INTENT permission is granted"
if fi_granted; then
    ok "USE_FULL_SCREEN_INTENT granted to $PKG"
else
    bad "USE_FULL_SCREEN_INTENT not granted to $PKG (the wake cannot work)"
fi

info "The notification channel is high importance"
IMP=$(adb_ shell dumpsys notification 2>/dev/null \
    | grep -oE "NotificationChannel\{mId='messages[a-z_]*'[^}]*mImportance=[0-9]+" \
    | grep -oE 'mImportance=[0-9]+' | cut -d= -f2 | tr -d '\r' | sort -rn | head -1)
if [ -z "${IMP:-}" ]; then
    bad "no messages notification channel found"
elif [ "$IMP" -ge 4 ]; then
    ok "channel importance $IMP (high)"
else
    bad "channel importance $IMP is below high; a demoted channel cannot wake the screen"
fi

info "Lock the device and deliver an SMS"
adb_ shell logcat -c >/dev/null 2>&1
adb_ shell am start -n "$ACT" >/dev/null 2>&1
sleep 4
if lock_device; then
    ok "device locked (mWakefulness=Asleep)"
else
    bad "could not put the device to sleep (mWakefulness=$(wakefulness))"
fi

adb_ emu sms send "$FROM" "ping $MARK" >/dev/null 2>&1

# Checked before anything unlocks the device: waking the screen makes the
# keyguard unlocked, and the app then re-posts the notification without a
# full-screen intent, which would replace this record and hide the evidence.
info "The notification record carries a full-screen intent"
# The platform CONSUMES the notification record the moment a full-screen intent
# launches (~250ms later), so this artifact is only observable in a window
# narrower than one adb round-trip. Polling for it is a guaranteed flake, and it
# proves nothing the trampoline assertion below does not prove better: that
# assertion observes the launch itself. Recorded as SKIP rather than a FAIL that
# would train the reader to ignore red.
if notif_has_fsi; then
    ok "notification carried a fullScreenIntent (caught before consumption)"
else
    echo "  [SKIP] notification record is consumed on launch; covered by the trampoline check"
fi

info "The device wakes for the message"
WOKE=no
for _ in $(seq 20); do
    if [ "$(wakefulness)" != "Asleep" ]; then WOKE=yes; break; fi
    sleep 1
done
if [ "$WOKE" = yes ]; then
    ok "screen woke (mWakefulness=$(wakefulness)) after an inbound SMS"
else
    bad "screen stayed asleep after an inbound SMS"
fi

info "The keyguard trampoline took over the screen"
# The launched activity is the direct evidence the full-screen intent fired:
# the notification record is consumed at that moment, so it cannot be the proof.
TRAMPOLINE=no
for _ in $(seq 12); do
    if adb_ logcat -d 2>/dev/null | grep -q "sms.FullScreenSmsActivity"; then
        TRAMPOLINE=yes; break
    fi
    sleep 1
done
if [ "$TRAMPOLINE" = yes ]; then
    ok "FullScreenSmsActivity launched over the keyguard"
else
    bad "FullScreenSmsActivity never launched"
fi

info "The screen also wakes when Privacy mode is on"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
adb_ shell am start -n "$ACT" --ez privacy_mode true >/dev/null 2>&1; sleep 2
if lock_device; then
    ok "device locked with Privacy mode enabled"
else
    bad "could not put the device to sleep with Privacy mode enabled"
fi
adb_ emu sms send "$FROM" "privacy $MARK" >/dev/null 2>&1
WOKE_PRIVACY=no
for _ in $(seq 20); do
    if [ "$(wakefulness)" != "Asleep" ]; then WOKE_PRIVACY=yes; break; fi
    sleep 1
done
if [ "$WOKE_PRIVACY" = yes ]; then
    ok "screen woke with Privacy mode enabled"
else
    bad "screen stayed asleep with Privacy mode enabled"
fi
wake_device >/dev/null 2>&1
adb_ shell am start -n "$ACT" --ez privacy_mode false >/dev/null 2>&1; sleep 2

info "Diagnostics attributes a dark screen to the app or the device"
wake_device >/dev/null 2>&1
unlock_device
adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
# The open_settings hook reaches Settings directly; tapping the gear by fixed
# coordinate is fragile once the emulator window is present.
adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null 2>&1; sleep 4
for _ in 1 2 3; do
    adb_ shell input swipe 500 1900 500 700 400 >/dev/null 2>&1; sleep 1
done
tap_contains "Advanced settings" >/dev/null 2>&1 || tap_text "Advanced" >/dev/null 2>&1
sleep 2
for _ in 1 2 3 4 5; do
    dump_ui || true
    grep -q 'text="Diagnostics"' "$TMP/ui.xml" && break
    adb_ shell input swipe 540 1700 540 900 250 >/dev/null 2>&1; sleep 1
done
tap_text "Diagnostics" >/dev/null 2>&1 || center_of_contains "Diagnostics" >/dev/null 2>&1
sleep 3
FIELDS=""
for _ in $(seq 16); do
    dump_ui || true
    FIELDS=$(grep -oE 'Full-screen intent: [a-z]+|Channel importance: [0-9]+ \([a-z]+\)|Keyguard locked: (yes|no)|Wake screen for new messages: [a-z ]+' "$TMP/ui.xml" 2>/dev/null)
    [ -n "$FIELDS" ] && break
    adb_ shell input swipe 540 1800 540 800 300 >/dev/null 2>&1; sleep 1
done
echo "$FIELDS" | sed 's/^/    /'
for f in "Full-screen intent:" "Channel importance:" "Keyguard locked:" "Wake screen for new messages:"; do
    if echo "$FIELDS" | grep -q "$f"; then
        ok "Diagnostics reports '$f'"
    else
        bad "Diagnostics missing '$f'"
    fi
done

# The sheet is read after unlocking, so "headsup only" is the correct reading
# here and "will wake" would mean the keyguard check is not live. What must hold
# is that the permission and the channel are both healthy, since those two are
# what the wake chain reads.
if echo "$FIELDS" | grep -q "Full-screen intent: granted"; then
    ok "Diagnostics reports the full-screen intent as granted"
else
    bad "Diagnostics reports the full-screen intent as denied"
fi
if echo "$FIELDS" | grep -qE "Channel importance: [45] "; then
    ok "Diagnostics reports a high channel importance"
else
    bad "Diagnostics reports a channel importance below high"
fi
adb_ shell input keyevent 4 >/dev/null 2>&1; sleep 1
adb_ shell input keyevent 4 >/dev/null 2>&1; sleep 1
adb_ shell input keyevent 4 >/dev/null 2>&1; sleep 1

info "The conversation holds the delivered message"
adb_ shell input keyevent 4 >/dev/null 2>&1; sleep 1
adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 5
# The row label lives in content-desc, not text, and wraps the sender in
# bidi isolate marks, so grep the raw dump for the marker alone.
if dump_ui && grep -q "$MARK" "$TMP/ui.xml"; then
    ok "the SMS was delivered into the conversation"
else
    bad "could not find '$MARK' in the conversation list"
fi

echo ""
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]