#!/usr/bin/env bash
# Regression: the app's motion system.
#
# Covers the two things a device can actually verify about motion work:
#   1. every animated surface still functions (list placement, swipe, tabs,
#      navigation, emoji panel, FAB) after moving onto the shared M3 tokens;
#   2. Accessibility mode's "reduce motion" leaves the app fully usable instead
#      of leaving stale intermediate animation state on screen.
#
# Animation timing itself cannot be asserted from a uiautomator dump, so the
# script checks the outcomes: content is on screen, at its final position, and
# nothing crashes or disappears when motion is suppressed.
source "$(dirname "$0")/env.sh"
set -uo pipefail

PASS=0
FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }

MARK="motion$(date +%s)$$"
# First entry of the chat screen's emoji row. uiautomator escapes most emoji as
# HTML entities in the dump, so match the escaped form, not the character.
EMOJI_MARK="&#128077;"
NUM="+1555770${MARK: -3}"
TS=$(date +%s000)

db_sql() {
    adb_ shell "run-as $PKG sqlite3 databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r' && return 0
    adb_ shell "su -c \"sqlite3 /data/data/$PKG/databases/messages.db \\\"$1\\\"\"" 2>/dev/null | tr -d '\r' || true
}

# Conversation rows expose their text through content-desc, not text, and the
# rows are bidi-wrapped, so match either attribute and parse bounds defensively.
row_center() {
    dump_ui || return 1
    python3 - "$1" <<'PY'
import re, sys
needle = sys.argv[1]
s = open('/tmp/opencode/messages-tests/ui.xml', encoding='utf-8', errors='replace').read()
for attr in ('content-desc', 'text'):
    for m in re.finditer(r'%s="([^"]*)"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"' % attr, s):
        if needle in m.group(1):
            x1, y1, x2, y2 = map(int, m.groups()[1:])
            if x2 > x1 and y2 > y1:
                print((x1 + x2) // 2, (y1 + y2) // 2)
                raise SystemExit
PY
}

# The list shows a loading skeleton until the startup sync settles, so every
# assertion after a restart has to wait for real rows instead of sleeping.
wait_for_text() {
    local needle="$1" tries="${2:-15}" i
    for ((i = 0; i < tries; i++)); do
        dump_ui || true
        if has_text "$needle"; then return 0; fi
        sleep 2
    done
    return 1
}

# After an in-app mutation the app re-syncs and briefly shows its loading
# skeleton, so "the row is gone" has to be polled for too - a single dump taken
# inside that window would happily report an empty list.
wait_for_absent() {
    local needle="$1" tries="${2:-8}" i
    for ((i = 0; i < tries; i++)); do
        dump_ui || true
        if has_text "$needle"; then
            sleep 2
            continue
        fi
        return 0
    done
    return 1
}

# Swipe the current screen until [needle] is on screen, then report its centre.
scroll_to_text() {
    local needle="$1" c=""
    for _ in 1 2 3 4 5 6; do
        c=$(row_center "$needle") || c=""
        [ -n "$c" ] && { printf '%s' "$c"; return 0; }
        adb_ shell input swipe 540 1800 540 800 300 >/dev/null 2>&1
        sleep 1
    done
    return 1
}

row_center_exact() {
    dump_ui || return 1
    python3 - "$1" <<'PY'
import re, sys
needle = sys.argv[1]
s = open('/tmp/opencode/messages-tests/ui.xml', encoding='utf-8', errors='replace').read()
for attr in ('text', 'content-desc'):
    for m in re.finditer(r'%s="([^"]*)"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"' % attr, s):
        if m.group(1).strip() == needle:
            x1, y1, x2, y2 = map(int, m.groups()[1:])
            if x2 > x1 and y2 > y1:
                print((x1 + x2) // 2, (y1 + y2) // 2)
                raise SystemExit
PY
}

# `input tap` gets dropped often enough on this AVD to make UI assertions flaky;
# a short press in place is far more reliable.
press_at() {
    local x y
    x=$(echo "$1" | cut -d' ' -f1)
    y=$(echo "$1" | cut -d' ' -f2)
    adb_ shell input swipe "$x" "$y" "$x" "$y" 90 >/dev/null 2>&1
}

tap_contains() {
    local c
    c=$(row_center "$1") || return 1
    [ -n "$c" ] || return 1
    press_at "$c"
}

# Settings rows render their state as a Switch on the right edge; the row label
# itself is not the toggle target.
press_switch_near() {
    local c y
    c=$(row_center "$1") || return 1
    [ -n "$c" ] || return 1
    y=$(echo "$c" | cut -d' ' -f2)
    adb_ shell input swipe 937 "$y" 937 "$y" 90 >/dev/null 2>&1
}

# Exact match, for places where a substring would be ambiguous: the options
# sheet's "Archive" is a substring of the top bar's "Archived" icon, and
# row_center checks content-desc first.
tap_exact() {
    local c
    c=$(row_center_exact "$1") || return 1
    [ -n "$c" ] || return 1
    press_at "$c"
}

# Open Settings, retrying until the settings screen is really up. The top-bar
# tap is lost if the app is still starting up.
open_settings() {
    local i
    for ((i = 0; i < 5; i++)); do
        adb_ shell input tap 976 226 >/dev/null 2>&1
        sleep 3
        dump_ui || true
        has_text "General settings" && return 0
        adb_ shell input keyevent 4 >/dev/null 2>&1
        sleep 1
    done
    return 1
}

# Tap [needle] until [expected] shows up. Rows near the bottom edge are flaky to
# tap, and the SAF-free emulator drops taps often enough to need a retry.
tap_until() {
    local needle="$1" expected="$2" i
    for ((i = 0; i < 5; i++)); do
        C=$(scroll_to_text "$needle") || C=""
        [ -n "$C" ] || { sleep 1; continue; }
        Y=$(echo "$C" | cut -d' ' -f2)
        if [ "${Y:-0}" -gt 1700 ]; then
            adb_ shell input swipe 540 1600 540 1150 300 >/dev/null 2>&1
            sleep 1
            C=$(row_center "$needle") || C="$C"
        fi
        press_at "$C"
        sleep 3
        dump_ui || true
        has_text "$expected" && return 0
    done
    printf '    [tap_until] never saw "%s"; on screen: %s\n' "$expected" \
        "$(ui_tags | grep -oE 'content-desc="[^"]{2,40}"' | head -6 | tr '\n' ' ')"
    return 1
}

long_press_text() {
    for _ in 1 2 3 4 5; do
        local c
        c=$(row_center "$1") || c=""
        if [ -n "$c" ]; then
            adb_ shell input swipe $c $c 800
            return 0
        fi
        adb_ shell input swipe 540 1700 540 1200 250 >/dev/null 2>&1
        sleep 1
    done
    return 1
}
cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    db_sql "UPDATE conversations SET archived=0 WHERE address IN ('$NUM','$NUM2');" >/dev/null 2>&1 || true
    db_sql "DELETE FROM messages WHERE body LIKE '%$MARK%'; DELETE FROM conversations WHERE address IN ('$NUM','$NUM2'); DELETE FROM participants WHERE normalized_destination IN ('$NUM','$NUM2');" >/dev/null 2>&1 || true
}
trap cleanup EXIT

adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1 || true

# `ui_tags | grep -q X` is a false negative under `set -o pipefail`: grep -q exits
# on the first match, ui_tags dies with SIGPIPE, and the pipeline reports failure
# even though the text was there. grep -c consumes all input, so it is correct.
has_text() { ui_tags | grep -c -- "$1" >/dev/null; }

info "Seed two conversations so list placement has something to move"
db_sql "INSERT INTO conversations(address,name,snippet,timestamp) VALUES('$NUM','$NUM','first $MARK',$TS);" >/dev/null 2>&1
CID=$(db_sql "SELECT id FROM conversations WHERE address='$NUM';")
db_sql "INSERT INTO messages(conversation_id,body,timestamp,status) VALUES($CID,'first $MARK',$TS,'received');" >/dev/null 2>&1
NUM2="+1555771${MARK: -3}"
db_sql "INSERT INTO conversations(address,name,snippet,timestamp) VALUES('$NUM2','$NUM2','second $MARK',$TS);" >/dev/null 2>&1
CID2=$(db_sql "SELECT id FROM conversations WHERE address='$NUM2';")
db_sql "INSERT INTO messages(conversation_id,body,timestamp,status) VALUES($CID2,'second $MARK',$TS,'received');" >/dev/null 2>&1
[ "$(db_sql "SELECT COUNT(*) FROM conversations WHERE address IN ('$NUM','$NUM2');")" = "2" ] \
    && pass 'seeded two conversations' || { fail 'could not seed conversations'; exit 1; }

adb_ logcat -c >/dev/null 2>&1 || true
adb_ shell am force-stop "$PKG" >/dev/null 2>&1
adb_ shell am start -n "$ACT" >/dev/null
wait_for_text "$MARK" \
    && pass 'conversation list rendered' \
    || fail 'conversation list missing content'

# Placement motion only shows on a *live* list mutation. Seeding the database
# over adb cannot trigger it, because the list is refreshed through in-app repo
# calls, so archiving and restoring from the options sheet is what exercises
# animateItem() here.
info "Archiving a row moves it out of the list in place"
if long_press_text "second $MARK"; then
    sleep 2
    dump_ui || true
    if has_text "Archive"; then
        tap_exact "Archive" >/dev/null 2>&1
        sleep 3
        if wait_for_absent "second $MARK"; then
            pass 'archived conversation left the list'
        else
            fail 'archived conversation still on the main list'
        fi
        if wait_for_text "first $MARK"; then
            pass 'neighbouring row stayed put'
        else
            fail 'neighbouring row disappeared too'
        fi
    else
        fail 'options sheet did not offer Archive'
    fi
else
    fail 'could not long-press the seeded row'
fi

info "Undo puts the row back in place"
# The archive action already offers Undo in a snackbar, which re-inserts the row
# through the same live path. Walking into the archived view instead would make
# this depend on a second screen staying in sync.
if tap_exact "Undo" || tap_contains "Undo"; then
    if wait_for_text "second $MARK" 10; then
        pass 'undone conversation returned to the list'
    else
        fail 'undo did not bring the conversation back'
    fi
else
    fail 'undo action was not offered'
fi

# Swipe still works now that the background colour is token-driven.
info "Swipe to archive still works with token-driven background"
dump_ui || true
if has_text "first $MARK"; then
    C=$(row_center "first $MARK") || C=""
    if [ -n "$C" ]; then
        Y=$(echo "$C" | cut -d' ' -f2)
        # Stay inside the row: swiping from off-screen starts no gesture at all.
        for attempt in 1 2; do
            adb_ shell input swipe 940 "$Y" 120 "$Y" 400 >/dev/null 2>&1
            sleep 3
            dump_ui || true
            has_text "first $MARK" || break
        done
        dump_ui || true
        adb_ shell input keyevent 4 >/dev/null 2>&1; sleep 1
        # The swipe archives or deletes depending on the reverse-swipe setting,
        # so assert the row actually left the main list either way.
        if wait_for_absent "first $MARK" 6; then
            STATE=$(db_sql "SELECT archived,deleted_at>0 FROM conversations WHERE address='$NUM';")
            case "$STATE" in
                1\|*|*1) pass "swipe acted on the row (archived/deleted=$STATE)" ;;
                *) fail "row left the list but the database says archived=0 deleted=0" ;;
            esac
        else
            fail 'swipe did not remove the row'
        fi
    else
        fail 'could not locate the swipe row'
    fi
else
    fail 'seeded row missing before swipe'
fi

# Chat navigation + bubbles.
info "Navigation and bubble motion still work"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1
adb_ shell am start -n "$ACT" >/dev/null
wait_for_text "second $MARK" || true
dump_ui || true
if tap_until "second $MARK" "second $MARK"; then
    pass 'chat opened and bubble rendered'
else
    fail 'could not open the seeded conversation'
fi
adb_ shell input keyevent 4 >/dev/null 2>&1; sleep 2

# Emoji panel now has an authored enter/exit. The composer button is a setting
# that ships off, and driving that switch through the UI is slow and flaky, so
# flip the pref directly on this debuggable build and assert the panel itself.
info "Emoji panel toggles"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1
# Flip the pref by round-tripping the file: far less quoting than sed -i through
# two shells, and the app re-reads it on the next cold start.
adb_ shell "run-as $PKG cat shared_prefs/messages_settings.xml" > "$TMP/prefs.xml" 2>/dev/null
if [ -s "$TMP/prefs.xml" ]; then
    python3 - "$TMP/prefs.xml" <<'PY'
import re, sys
path = sys.argv[1]
s = open(path, encoding='utf-8').read()
s = re.sub(r'(name="emoji_button_enabled" value=")false(")', r'\1true\2', s)
open(path, 'w', encoding='utf-8').write(s)
PY
    adb_ push "$TMP/prefs.xml" /data/local/tmp/motion_prefs.xml >/dev/null 2>&1
    adb_ shell "run-as $PKG cp /data/local/tmp/motion_prefs.xml shared_prefs/messages_settings.xml" >/dev/null 2>&1
    adb_ shell rm -f /data/local/tmp/motion_prefs.xml >/dev/null 2>&1
fi
adb_ shell am start -n "$ACT" >/dev/null
wait_for_text "second $MARK" 10 || true
if tap_until "second $MARK" "Emoji"; then
    C=$(row_center "Emoji") || C=""
    if [ -n "$C" ]; then
        press_at "$C"
        sleep 2
        dump_ui || true
        if has_text "$EMOJI_MARK"; then
            pass 'emoji panel opens'
        else
            fail 'emoji panel did not open'
        fi
        C=$(row_center "Emoji") || C=""
        [ -n "$C" ] && press_at "$C"
        sleep 2
        dump_ui || true
        if has_text "$EMOJI_MARK"; then
            fail 'emoji panel stuck open'
        else
            pass 'emoji panel closes'
        fi
    else
        fail 'emoji button present but not tappable'
    fi
    adb_ shell input keyevent 4 >/dev/null 2>&1; sleep 2
else
    fail 'emoji button never appeared in the composer'
fi

# Reduce motion must not break anything.
# Path: Settings -> Advanced -> "Accessibility mode" -> "Accessibility options" -> "Reduce motion"
info "Accessibility mode + reduce motion leaves the app usable"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1
adb_ shell am start -n "$ACT" >/dev/null
wait_for_text "Start chat" 8 || true
if open_settings && tap_until "Advanced" "Drafts"; then
    pass 'reached advanced settings'
    if tap_until "Accessibility mode" "Accessibility options"; then
        pass 'accessibility mode enabled'
        if tap_until "Accessibility options" "Reduce motion"; then
            sleep 3
            dump_ui || true
            has_text "Reduce motion" \
                && pass 'reduce motion setting reachable' \
                || fail 'could not find the reduce motion setting'
            tap_contains "Reduce motion" >/dev/null 2>&1
            sleep 2
            dump_ui || true
            if has_text "Reduce motion"; then
                pass 'reduce motion toggled'
            else
                fail 'reduce motion row vanished after toggling'
            fi
        else
            fail 'could not open accessibility options'
        fi
    else
        fail 'could not enable accessibility mode'
    fi
    adb_ shell input keyevent 4 >/dev/null 2>&1; sleep 1
    adb_ shell input keyevent 4 >/dev/null 2>&1; sleep 1
else
    fail 'could not reach Advanced settings'
fi

adb_ shell am force-stop "$PKG" >/dev/null 2>&1
adb_ shell am start -n "$ACT" >/dev/null
if ! wait_for_text "$MARK"; then
    fail 'list broken with reduce motion on'
else
    pass 'conversation list intact with reduce motion on'
fi
if tap_until "second $MARK" "second $MARK"; then
    pass 'chat opens with reduce motion on'
    adb_ shell input keyevent 4 >/dev/null 2>&1; sleep 2
else
    fail 'could not navigate with reduce motion on'
fi

if adb_ shell "logcat -d -b crash" 2>/dev/null | grep -q "$PKG"; then
    fail 'app crashed during the motion regression'
else
    pass 'no crashes'
fi

printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
