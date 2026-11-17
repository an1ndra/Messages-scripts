#!/usr/bin/env bash
# Regression for #487: whatever IME inset the platform reports, the composer
# sits on the keyboard and the conversation stays on screen.
#
# MIUI 14 with an enlarged display size hands an edge-to-edge window an IME
# inset far larger than the real keyboard (the issue's video shows the input
# row pinned to the top of the screen with the reserved height blank below it,
# and the chat gone with it). The fix clamps the reported inset to what the
# window's own visible display frame says the keyboard covers — the number the
# OEM itself places its UI by — so a dishonest report can only lose.
#
# The emulator reports honest insets, so the dishonest state is driven through
# the debug probe: `--ei ime_probe_reported_bottom <px>` makes the app read
# that number as the platform's reported inset, the role MIUI plays in
# production. On a build that only carries the probe the composer rides the
# fake inset to the top of the screen; with the clamp it stays on the keyboard.
#
# Run: scripts/test-keyboard-ime-guard.sh
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

POLLS=20
FAKE_INSET=2200
MARK="ime$(date +%s)$$"
NUM="+1555984${MARK: -4}"
BODY="IME guard probe $MARK"

adb_ root >/dev/null 2>&1; adb_ wait-for-device; sleep 1
# A stored crash report opens its own dialog over the app on the next launch,
# which no seeded flow can get past. Cleared here so a run starts clean.
adb_su "rm -f $PKG/files/crash_reports/*" >/dev/null 2>&1 || true
sql() { adb_ shell "sqlite3 /data/data/$PKG/databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r'; }

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM');" >/dev/null 2>&1
    sql "DELETE FROM conversations WHERE address='$NUM';" >/dev/null 2>&1
}
trap cleanup EXIT

for p in READ_SMS RECEIVE_SMS READ_CONTACTS POST_NOTIFICATIONS READ_PHONE_STATE; do
    adb_ shell pm grant "$PKG" "android.permission.$p" >/dev/null 2>&1
done
adb_su "cmd role add-role-holder android.app.role.SMS $PKG" >/dev/null 2>&1 || true

info "Seed a conversation with a message on it"
TS=$(date +%s000)
sql "INSERT INTO conversations(address,name,snippet,timestamp,unread_count) VALUES('$NUM','$MARK','$BODY',$TS,0);" >/dev/null 2>&1
CID=$(sql "SELECT id FROM conversations WHERE address='$NUM';")
[ -z "$CID" ] && { bad "could not seed a conversation"; exit 1; }
sql "INSERT INTO messages(conversation_id,body,timestamp,status) VALUES($CID,'$BODY',$TS,'received');" >/dev/null 2>&1
ok "conversation seeded"

kb_shown() { adb_ shell dumpsys input_method 2>/dev/null | tr -d '\r' | grep -qE "mInputShown=true"; }

wait_kb() {
    local i
    for i in $(seq 1 "$POLLS"); do
        if [ "$1" = "up" ] && kb_shown; then return 0; fi
        if [ "$1" = "down" ] && ! kb_shown; then return 0; fi
        sleep 0.3
    done
    return 1
}

screen_height() { adb_ shell wm size 2>/dev/null | tr -d '\r' | grep -oE '[0-9]+$'; }

# Bounds of the composer's field: "[x1,y1][x2,y2]".
composer_bounds() {
    dump_ui >/dev/null 2>&1 || return 1
    grep -oE 'class="android.widget.EditText"[^>]*bounds="\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]"' \
        "$TMP/ui.xml" 2>/dev/null | head -1 \
        | grep -oE '\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]'
}

# The chat counts as open when its composer exists in the layout: a build that
# reserves nearly the whole screen for the keyboard squeezes the message list
# to nothing, so a body text is not something a broken build can show.
chat_open() {
    [ -n "$(composer_bounds)" ]
}

# The composer has to sit in the bottom of the screen, clear of the status
# bar, with the conversation still readable above it. A build that trusts a
# dishonest inset pins the composer to the top of the window instead — behind
# the header, where a tap lands on the contact sheet, and the keyboard that
# was reserved all that space for never comes up at all.
check_anchored() {
    local label="$1" CB H y1 y2
    tap_edittext >/dev/null 2>&1
    if wait_kb up; then
        ok "$label: tapping the composer brings the keyboard up"
    else
        bad "$label: the composer never brought the keyboard up"
    fi
    sleep 2
    CB=$(composer_bounds) || { bad "$label: the composer is not on screen"; return 1; }
    H=$(screen_height)
    y1=$(sed -E 's/^\[[0-9]+,([0-9]+)\].*$/\1/' <<< "$CB")
    if [ "$y1" -gt 63 ]; then
        ok "$label: the composer clears the status bar"
    else
        bad "$label: composer top $y1 is pinned under the status bar"
    fi
    if [ "$y1" -gt $((H / 4)) ]; then
        ok "$label: the composer is in the bottom half of the screen"
    else
        bad "$label: composer top $y1 is pinned near the screen top"
    fi
    if ui_has "$BODY"; then
        ok "$label: the conversation is still on screen"
    else
        bad "$label: the conversation disappeared"
    fi
}

info "Honest insets: the guard changes nothing on a truthful report"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
adb_ shell am start -n "$ACT" --es open_conversation_address "$NUM" >/dev/null 2>&1
if wait_for_text "$BODY" 14; then ok "conversation opened"; else bad "conversation did not open"; exit 1; fi
tap_edittext >/dev/null 2>&1
check_anchored "honest insets"

info "The MIUI report: a fake inset nearly as tall as the screen"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
adb_ shell am start -n "$ACT" --es open_conversation_address "$NUM" --ei ime_probe_reported_bottom $FAKE_INSET >/dev/null 2>&1
local_open_polls=20
i=0
while [ $i -lt $local_open_polls ]; do
    chat_open && break
    sleep 1
    i=$((i + 1))
done
if chat_open; then ok "conversation opened with the probe"; else bad "conversation did not open with the probe"; exit 1; fi
tap_edittext >/dev/null 2>&1
check_anchored "forced MIUI-style report"

adb_ shell am force-stop "$PKG" >/dev/null 2>&1

echo ""
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
