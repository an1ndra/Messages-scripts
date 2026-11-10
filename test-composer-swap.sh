#!/usr/bin/env bash
# Regression for the composer's WhatsApp-style swap (#364 follow-up).
#
# WhatsApp keeps one accent-filled circle whether the composer is empty (record)
# or has a draft (send); only the glyph changes, and the disc only turns red for
# the length of a note. The composer used to paint the record disc with the
# input pill's fill, so the button changed shape and colour as it swapped. This
# pins the palette, the mode and the glyph, and checks the circle does not move.
#
# Run on either standing AVD; no microphone is opened, so -no-audio is fine.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

NUM="+15559443333"

info "Setup: permissions, role, a probe conversation"
# The emulator keeps data across branches, and a debug build from another branch
# can have a newer schema; the app refuses to downgrade and dies on launch.
adb_ shell pm clear "$PKG" >/dev/null 2>&1
for p in SEND_SMS RECEIVE_SMS READ_SMS READ_CONTACTS READ_PHONE_STATE POST_NOTIFICATIONS; do
    adb_ shell pm grant "$PKG" android.permission.$p 2>/dev/null
done
adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1
adb_ root >/dev/null 2>&1; sleep 1

# One launch creates the database, so the seed below has a table to write to.
adb_ shell am start -n "$ACT" >/dev/null 2>&1
sleep 4
adb_ shell am force-stop "$PKG" >/dev/null 2>&1

sql() { adb_ shell "sqlite3 /data/data/$PKG/databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r'; }

cleanup() {
    sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM');" >/dev/null 2>&1
}
trap cleanup EXIT
cleanup
if [ -z "$(sql "SELECT id FROM conversations WHERE address='$NUM';")" ]; then
    sql "INSERT INTO conversations(address,name,snippet,timestamp,unread_count) VALUES('$NUM','Swap probe','',$(date +%s000),0);" >/dev/null 2>&1
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
        if grep -q 'text="Allow"' "$TMP/ui.xml"; then
            c=$(center_of "Allow" 2>/dev/null) && adb_ shell input tap $c >/dev/null 2>&1
        fi
    done
    return 1
}

# The last resolved composer-button state, as the app reports it. Reading the
# target values rather than the animated ones keeps the assertion stable while
# the colour is still travelling.
voice_state() {
    adb_ shell logcat -d > "$TMP/logcat.txt" 2>/dev/null || true
    grep -o 'VoiceButton: .*' "$TMP/logcat.txt" | tail -1
}
field() { sed -n "s/.*$1=\([^ ]*\).*/\1/p" <<< "$2"; }

open_chat && ok "the conversation opened" || { bad "could not open the conversation"; exit 1; }
[ -s "$TMP/ui.xml" ] || dump_ui

info "No first-run guide over the composer"
if grep -qF 'text="Send a voice message"' "$TMP/ui.xml"; then
    bad "the removed voice guide is still shown on a fresh install"
else
    ok "a fresh install opens straight to the composer"
fi

info "An empty composer is one accent-filled record circle"
STATE=$(voice_state)
FILL=$(field fill "$STATE")
INK=$(field ink "$STATE")
PILL=$(field pill "$STATE")
ACCENT=$(field accent "$STATE")
MODE=$(field mode "$STATE")
GLYPH=$(field glyph "$STATE")
if [ "$MODE" = "Record" ] && [ "$GLYPH" = "Wave" ]; then
    ok "the empty composer is the record circle, drawing the wave"
else
    bad "unexpected idle state (mode=$MODE glyph=$GLYPH)"
fi
if [ -n "$ACCENT" ] && [ "$FILL" = "$ACCENT" ]; then
    ok "its disc uses the same accent as the send circle"
else
    bad "the record disc is not the accent (fill=$FILL accent=$ACCENT)"
fi
if [ -n "$FILL" ] && [ "$FILL" != "$PILL" ]; then
    ok "it no longer borrows the input pill's fill"
else
    bad "the record disc still matches the pill (fill=$FILL pill=$PILL)"
fi
if [ -n "$INK" ] && [ "$INK" != "$FILL" ]; then
    ok "the glyph is inked against the disc"
else
    bad "the glyph and the disc are painted the same colour"
fi

IDLE_CENTER=$(center_of "Record voice message")

info "Typing turns that same circle into Send"
tap_edittext >/dev/null 2>&1
sleep 0.5
type_text "hello"
sleep 1
dump_ui >/dev/null 2>&1
if grep -qF 'content-desc="Send"' "$TMP/ui.xml"; then
    ok "the circle now sends"
else
    bad "no Send circle after typing"
fi
STATE=$(voice_state)
MODE=$(field mode "$STATE")
GLYPH=$(field glyph "$STATE")
FILL=$(field fill "$STATE")
ACCENT=$(field accent "$STATE")
PILL=$(field pill "$STATE")
if [ "$MODE" = "Send" ] && [ "$GLYPH" = "Send" ]; then
    ok "the app reports the Send mode and glyph"
else
    bad "unexpected send state (mode=$MODE glyph=$GLYPH)"
fi
if [ -n "$ACCENT" ] && [ "$FILL" = "$ACCENT" ]; then
    ok "the send disc is the same accent, so the swap recolours nothing"
else
    bad "the send disc changed colour (fill=$FILL accent=$ACCENT)"
fi
if [ -n "$FILL" ] && [ "$FILL" != "$PILL" ]; then
    ok "the send circle stays off the pill fill"
else
    bad "the send circle fell back to the pill fill (fill=$FILL pill=$PILL)"
fi
# The keyboard lifts the composer, so the column is what has to survive the
# swap: a second widget at another x would read as a different button appearing.
SEND_CENTER=$(center_of "Send")
if [ -n "$IDLE_CENTER" ] && [ "${SEND_CENTER% *}" = "${IDLE_CENTER% *}" ]; then
    ok "the circle keeps its column through the swap (x=${SEND_CENTER% *})"
else
    bad "the circle jumped columns: record=$IDLE_CENTER send=$SEND_CENTER"
fi

info "Clearing the draft brings the record circle back"
for _ in 1 2 3 4 5; do adb_ shell input keyevent KEYCODE_DEL >/dev/null 2>&1; done
sleep 1
dump_ui >/dev/null 2>&1
STATE=$(voice_state)
MODE=$(field mode "$STATE")
GLYPH=$(field glyph "$STATE")
if [ "$MODE" = "Record" ] && [ "$GLYPH" = "Wave" ] &&
   grep -qF 'content-desc="Record voice message"' "$TMP/ui.xml"; then
    ok "the idle circle is back, with the wave and the record label"
else
    bad "the composer did not swap back (mode=$MODE glyph=$GLYPH)"
fi
CENTER=$(center_of "Record voice message")
if [ -n "$SEND_CENTER" ] && [ "${CENTER% *}" = "${SEND_CENTER% *}" ]; then
    ok "it returned to the same column (x=${CENTER% *})"
else
    bad "the circle moved on the way back: send=$SEND_CENTER record=$CENTER"
fi

echo -e "\n$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
