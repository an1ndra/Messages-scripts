#!/usr/bin/env bash
# Regression for voice messages (#364).
#
# The reporter asked for Google Messages' behaviour: with nothing typed, the
# send circle records instead of sending, and a recording can be cancelled
# before it leaves. This pins the whole round trip — the composer swaps to the
# mic, holding it records, releasing sends, sliding cancels, the sent note plays
# back, and Diagnostics reports how many bytes the recorder actually produced.
#
# The emulator must be started WITH audio: the standing AVD recipe passes
# -no-audio, and MediaRecorder cannot open the microphone there. The preflight
# below says so instead of letting the run report a feature as broken.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

NUM="+15559442222"
SRC="$PROJECT_DIR/app/src/main/java/com/anindra/messages"

info "Preflight: an emulator with audio"
NOAUDIO=$(ps -eo args 2>/dev/null | grep -m1 "[q]emu-system.*-avd" | grep -c -- "-no-audio")
if [ "$NOAUDIO" != "0" ]; then
    echo "  This emulator was started with -no-audio, so MediaRecorder cannot open"
    echo "  the microphone. Restart it without that flag, e.g.:"
    echo "    ~/android/emulator/emulator -avd <avd> -port <port> -no-boot-anim -gpu swiftshader_indirect &"
    bad "emulator has no audio input"
    echo "  [FAIL] preflight"
    exit 1
fi
ok "emulator was started with audio enabled"

info "The recorder is wired in, not just drawn"
if grep -q 'android.permission.RECORD_AUDIO' "$PROJECT_DIR/app/src/main/AndroidManifest.xml"; then
    ok "RECORD_AUDIO is declared"
else
    bad "RECORD_AUDIO is not declared"
fi
if grep -q 'android.hardware.microphone' "$PROJECT_DIR/app/src/main/AndroidManifest.xml" &&
   sed -n '/android.hardware.microphone/,+1p' "$PROJECT_DIR/app/src/main/AndroidManifest.xml" |
       grep -q 'required="false"'; then
    ok "the microphone is optional, so a tablet still installs"
else
    bad "the microphone is not an optional feature"
fi
if grep -q "VoiceRecorder" "$SRC/ui/ChatScreen.kt" && grep -q "MediaRecorder.AudioEncoder.AAC" "$SRC/voice/VoiceRecorder.kt"; then
    ok "the composer records AAC through VoiceRecorder"
else
    bad "no recorder is wired into the composer"
fi
if grep -q 'const val MIME = "audio/mp4"' "$SRC/voice/VoiceNotePolicy.kt" &&
   grep -q "AudioEncoder.AAC" "$SRC/voice/VoiceRecorder.kt"; then
    ok "the recorded container is the one the PDU declares (audio/mp4)"
else
    bad "recorder output and declared MIME disagree"
fi

info "Setup: permissions, role, a probe conversation"
for p in SEND_SMS RECEIVE_SMS READ_SMS READ_CONTACTS READ_PHONE_STATE POST_NOTIFICATIONS RECORD_AUDIO; do
    adb_ shell pm grant "$PKG" android.permission.$p 2>/dev/null
done
adb_ root >/dev/null 2>&1; sleep 1
sql() { adb_ shell "sqlite3 /data/data/$PKG/databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r'; }

# Only the probe's messages are removed. Deleting the conversation as well means
# the next open re-creates it through the participants UPSERT, which API 29's
# bundled SQLite (3.22) cannot parse — a separate, pre-existing defect that this
# script must not trip over.
cleanup() {
    sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM');" >/dev/null 2>&1
}
trap cleanup EXIT
cleanup
if [ -z "$(sql "SELECT id FROM conversations WHERE address='$NUM';")" ]; then
    sql "INSERT INTO conversations(address,name,snippet,timestamp,unread_count) VALUES('$NUM','Voice probe','',$(date +%s000),0);" >/dev/null 2>&1
fi
[ -z "$(sql "SELECT id FROM conversations WHERE address='$NUM';")" ] && { bad "could not seed a conversation"; exit 1; }

open_chat() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
    adb_ shell logcat -c >/dev/null 2>&1
    adb_ shell am start -n "$ACT" --es open_conversation_address "$NUM" >/dev/null 2>&1
    local i
    for i in $(seq 1 10); do
        sleep 1
        dump_ui >/dev/null 2>&1 || continue
        if grep -qF 'content-desc="Record voice message"' "$TMP/ui.xml"; then return 0; fi
        # A first launch can sit behind the permission dialogs.
        if grep -q 'text="Allow"' "$TMP/ui.xml"; then
            c=$(center_of "Allow" 2>/dev/null) && adb_ shell input tap $c >/dev/null 2>&1
        fi
    done
    return 1
}

mic_center() { center_of "Record voice message"; }

# "true" while the IME is on screen. The recording bar is drawn over the text
# field rather than replacing it, because removing the field from the
# composition drops its focus and closes the keyboard under the user's finger.
ime_shown() {
    adb_ shell dumpsys input_method 2>/dev/null | tr -d '\r' |
        grep -m1 'mInputShown=' | sed 's/.*mInputShown=//'
}

sent_notes() { grep -c 'D VoiceNote: sent' "$TMP/logcat.txt" 2>/dev/null || true; }

info "The first run explains the gesture, once"
adb_ shell pm clear "$PKG" >/dev/null 2>&1
for p in SEND_SMS RECEIVE_SMS READ_SMS READ_CONTACTS READ_PHONE_STATE POST_NOTIFICATIONS RECORD_AUDIO; do
    adb_ shell pm grant "$PKG" android.permission.$p 2>/dev/null
done
adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" 2>/dev/null
open_chat
if grep -qF 'text="Send a voice message"' "$TMP/ui.xml"; then
    ok "a fresh install is told what the record button does"
else
    bad "no first-run guide on a fresh install"
fi
if grep -qF 'Swipe up to lock' "$TMP/ui.decoded.xml"; then
    ok "the guide names the lock gesture"
else
    bad "the guide does not mention the lock"
fi
tap_text "Got it" >/dev/null 2>&1
# The card goes away on the next frame; poll so a slow dump cannot read the
# screen that was there when the button was tapped.
DISMISSED=0
for _ in 1 2 3 4 5 6; do
    sleep 0.4
    dump_ui >/dev/null 2>&1 || continue
    if ! grep -qF 'text="Send a voice message"' "$TMP/ui.xml"; then DISMISSED=1; break; fi
done
if [ "$DISMISSED" = "1" ]; then
    ok "the guide closes when dismissed"
else
    bad "the guide stayed after being dismissed"
fi
adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
adb_ shell am start -n "$ACT" --es open_conversation_address "$NUM" >/dev/null 2>&1
sleep 4
dump_ui >/dev/null 2>&1
if grep -qF 'text="Send a voice message"' "$TMP/ui.xml"; then
    bad "the guide came back on the next open"
else
    ok "the guide does not come back"
fi

info "An empty composer shows the mic; typing brings Send back"
open_chat && ok "the conversation opened" || bad "could not open the conversation"
if dump_ui >/dev/null 2>&1 && grep -qF 'content-desc="Record voice message"' "$TMP/ui.xml"; then
    ok "an empty composer offers the voice button"
else
    bad "an empty composer still shows Send (or nothing)"
fi
tap_edittext >/dev/null 2>&1
sleep 0.5
type_text "hello"
sleep 1
if dump_ui >/dev/null 2>&1 && grep -qF 'content-desc="Send"' "$TMP/ui.xml" &&
   ! grep -qF 'content-desc="Record voice message"' "$TMP/ui.xml"; then
    ok "typing swaps the circle back to Send"
else
    bad "the circle did not return to Send with a draft"
fi
for _ in 1 2 3 4 5; do adb_ shell input keyevent KEYCODE_DEL >/dev/null 2>&1; done
sleep 1

info "The record disc matches Google Messages' palette"
adb_ shell logcat -d > "$TMP/logcat.txt" 2>/dev/null || true
VB=$(grep -o "VoiceButton: fill=#[0-9A-F]* ink=#[0-9A-F]* pill=#[0-9A-F]* recording=false" "$TMP/logcat.txt" | tail -1)
FILL=$(sed -n 's/.*fill=#\([0-9A-F]*\).*/\1/p' <<< "$VB")
INK=$(sed -n 's/.*ink=#\([0-9A-F]*\).*/\1/p' <<< "$VB")
PILL=$(sed -n 's/.*pill=#\([0-9A-F]*\).*/\1/p' <<< "$VB")
if [ -n "$FILL" ] && [ "$FILL" = "$PILL" ]; then
    ok "idle, the record disc is the composer's own fill"
else
    bad "the idle record disc does not match the composer fill (fill=$FILL pill=$PILL)"
fi
if [ -n "$INK" ] && [ "$INK" != "$FILL" ]; then
    ok "its glyph uses a different ink than the disc"
else
    bad "the glyph and the disc are painted the same colour"
fi

info "Recording leaves an open keyboard open"
tap_edittext >/dev/null 2>&1
sleep 1.5
if [ "$(ime_shown)" = "true" ]; then
    ok "the keyboard opened on the composer"
else
    bad "the keyboard did not open, so this check cannot say anything"
fi
C=$(mic_center) || { bad "voice button has no bounds"; exit 1; }
(adb_ shell input swipe $C $C 4500 >/dev/null 2>&1) &
SWIPE_PID=$!
# The bar is only up while the finger is down, and a uiautomator dump costs a
# second or two, so poll for it rather than sampling once.
BAR=0
for _ in 1 2 3 4 5; do
    sleep 0.3
    dump_ui >/dev/null 2>&1 || continue
    if grep -qF 'text="Slide to cancel"' "$TMP/ui.xml"; then BAR=1; break; fi
done
if [ "$BAR" = "1" ]; then
    ok "holding the mic started a recording with the keyboard up"
else
    bad "no recording bar appeared while the keyboard was open"
fi
# Google Messages draws the bin mid-hold as the target the slide is aimed at,
# but it is not a button until the recording is locked; a clickable-looking bin
# under a held finger is the thing that read as broken.
bin_clickable() {
    grep -oE 'content-desc="Cancel recording"[^>]*clickable="[^"]+"' "$TMP/ui.xml" |
        grep -oE 'clickable="[^"]+"' | head -1 | cut -d'"' -f2
}
if grep -qF 'text="Lock"' "$TMP/ui.xml" &&
   grep -qF 'text="Slide to cancel"' "$TMP/ui.xml"; then
    ok "the bar names both exits: slide to cancel and lock"
else
    bad "the recording bar does not show the lock hint"
fi
if grep -qF 'content-desc="Cancel recording"' "$TMP/ui.xml"; then
    if [ "$(bin_clickable)" = "false" ]; then
        ok "the bin is drawn mid-hold but is not clickable yet"
    else
        bad "the bin is a live button under a finger that is still holding"
    fi
else
    bad "the discard bin is missing from the recording bar"
fi
if [ "$(ime_shown)" = "true" ]; then
    ok "starting a recording does not dismiss the keyboard"
else
    bad "the keyboard was dismissed when recording started"
fi
wait $SWIPE_PID 2>/dev/null
sleep 1
if [ "$(ime_shown)" = "true" ]; then
    ok "the keyboard is still up after the note is sent"
else
    bad "the keyboard closed after the note was sent"
fi
# Closing the IME must not cost the chat: BACK on an open keyboard only hides it.
adb_ shell input keyevent 4 >/dev/null 2>&1
sleep 1
if ! dump_ui >/dev/null 2>&1 || ! grep -qF 'content-desc="Record voice message"' "$TMP/ui.xml"; then
    open_chat || true
fi

info "Hold the mic to record, release to send"
C=$(mic_center) || { bad "voice button has no bounds"; exit 1; }
adb_ shell input swipe $C $C 2000 >/dev/null 2>&1
sleep 2
dump_ui >/dev/null 2>&1
# The bubble shows the clip's length, the way Google Messages labels one; a
# timestamp ("11:08 AM") has more after the minutes and does not match.
if grep -qE 'text="[0-9]+:[0-9]{2}"' "$TMP/ui.decoded.xml"; then
    ok "a voice bubble appeared with its length"
else
    bad "no voice bubble after recording"
fi
if grep -qF 'content-desc="Play voice message"' "$TMP/ui.xml"; then
    ok "the bubble offers playback"
else
    bad "the bubble has no play control"
fi
adb_ shell logcat -d > "$TMP/logcat.txt" 2>/dev/null || true
BYTES=$(sed -n 's/.*VoiceNote: sent bytes=\([0-9]*\).*/\1/p' "$TMP/logcat.txt" | tail -1)
if [ -n "$BYTES" ] && [ "$BYTES" -gt 0 ]; then
    ok "the recorder produced $BYTES bytes of audio/mp4"
else
    bad "nothing was recorded (is the emulator running with audio?)"
fi
if grep -q "VoiceNote: sent .* mime=audio/mp4" "$TMP/logcat.txt"; then
    ok "the note is sent as audio/mp4"
else
    bad "the note is not sent as audio/mp4"
fi

info "Sliding left cancels instead of sending"
COUNT_BEFORE=$(grep -c 'content-desc="Play voice message"' "$TMP/ui.xml" 2>/dev/null)
LAST_BEFORE=$(sed -n 's/.*VoiceNote: sent bytes=\([0-9]*\).*/\1/p' "$TMP/logcat.txt" | tail -1)
C=$(mic_center) || { bad "voice button vanished"; exit 1; }
X=${C% *}; Y=${C#* }
adb_ shell input swipe "$X" "$Y" "$((X - 320))" "$Y" 1200 >/dev/null 2>&1
sleep 2
dump_ui >/dev/null 2>&1
COUNT_AFTER=$(grep -c 'content-desc="Play voice message"' "$TMP/ui.xml" 2>/dev/null)
adb_ shell logcat -d > "$TMP/logcat.txt" 2>/dev/null || true
LAST_AFTER=$(sed -n 's/.*VoiceNote: sent bytes=\([0-9]*\).*/\1/p' "$TMP/logcat.txt" | tail -1)
if [ "$COUNT_AFTER" = "$COUNT_BEFORE" ] && [ "$LAST_AFTER" = "$LAST_BEFORE" ]; then
    ok "a slide-left cancelled the recording without sending it"
else
    bad "the cancelled recording was sent anyway"
fi
if dump_ui >/dev/null 2>&1 && grep -qF 'content-desc="Record voice message"' "$TMP/ui.xml"; then
    ok "the mic came back after the cancel"
else
    bad "the composer did not return to the mic after cancelling"
fi

info "Swiping up locks the recording hands-free"
COUNT_BEFORE=$(grep -c 'content-desc="Play voice message"' "$TMP/ui.xml" 2>/dev/null)
C=$(mic_center) || { bad "voice button vanished before the lock test"; exit 1; }
X=${C% *}; Y=${C#* }
adb_ shell input swipe "$X" "$Y" "$X" "$((Y - 400))" 1500 >/dev/null 2>&1
sleep 1.5
dump_ui >/dev/null 2>&1
if grep -qF 'content-desc="Cancel recording"' "$TMP/ui.xml" &&
   grep -qE 'text="[0-9]{2}:[0-9]{2}"' "$TMP/ui.decoded.xml"; then
    ok "the swipe locked the recording while the finger was released"
else
    bad "the recording did not survive the finger being lifted"
fi
if [ "$(bin_clickable)" = "true" ]; then
    ok "the bin becomes a button once the recording is locked"
else
    bad "the bin stayed inert after locking"
fi
if grep -qF 'content-desc="Send"' "$TMP/ui.xml"; then
    ok "a locked recording offers Send on the circle"
else
    bad "no way to send a locked recording"
fi
adb_ shell logcat -d > "$TMP/logcat.txt" 2>/dev/null || true
LOCKED_BYTES=$(sed -n 's/.*VoiceNote: sent bytes=\([0-9]*\).*/\1/p' "$TMP/logcat.txt" | tail -1)

info "The bin drops a locked recording"
tap_text "Cancel recording" >/dev/null 2>&1
sleep 1.5
dump_ui >/dev/null 2>&1
COUNT_AFTER=$(grep -c 'content-desc="Play voice message"' "$TMP/ui.xml" 2>/dev/null)
adb_ shell logcat -d > "$TMP/logcat.txt" 2>/dev/null || true
AFTER_BYTES=$(sed -n 's/.*VoiceNote: sent bytes=\([0-9]*\).*/\1/p' "$TMP/logcat.txt" | tail -1)
if [ "$COUNT_AFTER" = "$COUNT_BEFORE" ] && [ "$AFTER_BYTES" = "$LOCKED_BYTES" ]; then
    ok "the bin discarded the locked recording instead of sending it"
else
    bad "a discarded locked recording was sent anyway"
fi

info "A locked recording sends from the circle"
C=$(mic_center) || { bad "voice button vanished after the discard"; exit 1; }
X=${C% *}; Y=${C#* }
adb_ shell input swipe "$X" "$Y" "$X" "$((Y - 400))" 1500 >/dev/null 2>&1
sleep 1.5
dump_ui >/dev/null 2>&1
if grep -qF 'content-desc="Send"' "$TMP/ui.xml"; then
    adb_ shell logcat -d > "$TMP/logcat.txt" 2>/dev/null || true
    BYTES_BEFORE=$(sed -n 's/.*VoiceNote: sent bytes=\([0-9]*\).*/\1/p' "$TMP/logcat.txt" | tail -1)
    tap_text "Send" >/dev/null 2>&1
    # The bubble and the log line are both evidence; poll rather than sampling
    # once, because the row only appears after the recorder has closed the file.
    POSTED=0
    for _ in 1 2 3 4 5 6; do
        sleep 0.5
        dump_ui >/dev/null 2>&1 || continue
        COUNT_SENT=$(grep -c 'content-desc="Play voice message"' "$TMP/ui.xml" 2>/dev/null)
        if [ "$COUNT_SENT" -gt "$COUNT_BEFORE" ]; then POSTED=1; break; fi
        adb_ shell logcat -d > "$TMP/logcat.txt" 2>/dev/null || true
        BYTES_NOW=$(sed -n 's/.*VoiceNote: sent bytes=\([0-9]*\).*/\1/p' "$TMP/logcat.txt" | tail -1)
        if [ -n "$BYTES_NOW" ] && [ "$BYTES_NOW" != "$BYTES_BEFORE" ]; then POSTED=1; break; fi
    done
    [ "$POSTED" = "1" ] && ok "tapping Send posted the locked recording" \
        || bad "the locked recording was not posted"
else
    bad "the locked recording never offered Send"
fi

info "The recorded note plays back"
c=$(center_of "Play voice message" 2>/dev/null) || { bad "no play control to tap"; c=""; }
if [ -n "$c" ]; then
    adb_ shell input tap $c >/dev/null 2>&1
    # A short note can finish while the dump is being taken, so poll instead of
    # sampling once: either state proves the player opened it.
    STARTED=0
    for _ in 1 2 3 4 5 6 7 8; do
        sleep 0.3
        dump_ui >/dev/null 2>&1 || continue
        if grep -qF 'content-desc="Pause voice message"' "$TMP/ui.xml"; then
            STARTED=1; break
        fi
        # The clip already reached its end: the bubble then reads "0:02 / 0:02".
        if grep -qE 'text="[0-9]+:[0-9]{2} / [0-9]+:[0-9]{2}"' "$TMP/ui.decoded.xml"; then
            STARTED=1; break
        fi
    done
    [ "$STARTED" = "1" ] && ok "tapping play starts playback" || bad "playback did not start"
fi

info "Diagnostics reports the voice-note cap and the last note"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null 2>&1; sleep 3
adb_ shell input swipe 500 1900 500 700 400 >/dev/null 2>&1; sleep 0.5
adb_ shell input swipe 500 1900 500 700 400 >/dev/null 2>&1; sleep 1
tap_text "Advanced settings" >/dev/null 2>&1 || true
sleep 1.5
FOUND=0
for i in 1 2 3 4 5; do
    dump_ui >/dev/null 2>&1 || true
    if grep -q 'text="Diagnostics"' "$TMP/ui.xml"; then FOUND=1; break; fi
    adb_ shell input swipe 540 1700 540 900 250 >/dev/null 2>&1; sleep 0.4
done
if [ "$FOUND" = "1" ]; then
    tap_text "Diagnostics" >/dev/null 2>&1
    sleep 2
    dump_ui >/dev/null 2>&1
    if grep -q "Voice note: audio/mp4" "$TMP/ui.decoded.xml"; then
        ok "the report names the recorder's format and cap"
    else
        bad "the report has no voice-note line"
    fi
    if grep -qE "Last voice note: [1-9][0-9]* B" "$TMP/ui.decoded.xml"; then
        ok "the report names the last note's size"
    else
        bad "the report does not report the recorded size"
    fi
else
    bad "could not reach Diagnostics"
fi

echo
echo "=== Result: $PASS passed, $FAIL failed ==="
[ "$FAIL" = "0" ] || exit 1
