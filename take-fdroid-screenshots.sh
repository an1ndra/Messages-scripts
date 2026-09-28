#!/usr/bin/env bash
# Refreshes the F-Droid/README screenshots against the current build.
#
# The set is curated: one coherent, numbered run in the app's own light theme,
# plus a dark pass over the three screens that matter most, so the gallery reads
# as one product rather than a pile of experiments. The output directory is
# emptied first, which is what keeps superseded shots from accumulating.
#
# Requires the demo data (both seeders):
#   bash scripts/insert-demo-contacts.sh     # phone book, with monogram photos
#   bash scripts/seed-demo-conversations.sh  # inbox history
#
# Run from the scripts submodule:
#   ANDROID_SERIAL=emulator-5554 bash take-fdroid-screenshots.sh
#
# All tap targets come from live uiautomator dumps, never hardcoded rows, so the
# sequence survives layout changes. Sizes assume 1080x2400 @ 420dpi.
set -uo pipefail
cd "$(dirname "$0")"
source ./env.sh
source ./demo-data.sh

SHOTS="$PROJECT_DIR/fastlane/metadata/android/en-US/images/phoneScreenshots"
mkdir -p "$SHOTS"
rm -f "$SHOTS"/*.png

FAILED=0

dbq() { printf '%s' "$1" | adb_ shell "run-as $PKG sqlite3 databases/messages.db" 2>/dev/null | tr -d '\r'; }

# `adb emu sms send` does not reliably keep the sender number it was given - the
# emulator often substitutes its own - so a throwaway thread from an earlier run
# can survive address-based cleanup and then sits at the top of the conversation
# list. Sweep anything that is not demo data before the first capture.
sweep_stray_threads() {
    local keep n
    keep=$(printf "'%s'," "${DEMO_CONTACTS[@]%%|*}")
    keep="${keep%,}"
    for n in $(dbq "SELECT address FROM conversations WHERE address NOT IN ($keep);"); do
        echo "  removing stray thread $n"
        drop_thread "$n"
    done
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
}

# The AVD drops off the bus under this much UI driving. Checking before every
# capture matters: without it the run keeps going against a dead device and
# quietly overwrites all the good shots with broken ones.
require_device() {
    adb_ shell true >/dev/null 2>&1 && return 0
    echo "ABORT: $ANDROID_SERIAL stopped responding; the captured shots cannot be trusted."
    echo "       Re-run once the emulator is back up."
    exit 2
}

launch() {
    adb_ shell am force-stop "$PKG" >/dev/null; sleep 1
    adb_ shell am start -n "$ACT" >/dev/null; sleep 5
    dismiss_anr
}
back() { adb_ shell input keyevent KEYCODE_BACK; sleep 1.5; }
dark() { adb_ shell cmd uimode night yes >/dev/null; sleep 2; }
light() { adb_ shell cmd uimode night no >/dev/null; sleep 2; }

# The AOSP emulator throws "system isn't responding" dialogs at random. Left
# alone one of them swallows every later tap, so the whole run silently captures
# the same screen over and over.
dismiss_anr() {
    for _ in 1 2 3; do
        dump_ui >/dev/null || return 0
        grep -q "isn.t responding" "$TMP/ui.xml" || return 0
        c=$(center_of_contains "Wait") || c=$(center_of_contains "Close app")
        [ -n "$c" ] && { adb_ shell input tap $c >/dev/null; sleep 2; }
    done
}

dismiss_onboarding() {
    for _ in 1 2 3; do
        dump_ui >/dev/null
        C=$(center_of_contains "Not now") && { adb_ shell input tap $C; sleep 1.5; continue; }
        C=$(center_of_contains "ALLOW") && { adb_ shell input tap $C; sleep 1.5; continue; }
        break
    done
    sleep 1
}

ensure_home() {
    for _ in 1 2 3 4 5; do
        dismiss_anr
        dump_ui >/dev/null
        if grep -q 'content-desc="Search"' "$TMP/ui.xml" || grep -q 'text="Messages"' "$TMP/ui.xml"; then
            scroll_list_to_top
            return 0
        fi
        back
    done
    echo "  !! could not get back to the conversation list"
    FAILED=1
    return 1
}

# The list keeps its scroll offset across a force-stop/relaunch, so a run that
# starts mid-list silently captures a half-scrolled home screen and cannot find
# the newest conversations. Always return to the top first.
scroll_list_to_top() {
    for _ in 1 2 3; do
        adb_ shell input swipe 540 800 540 2000 250 >/dev/null 2>&1
        sleep 0.7
    done
}

center_of_attr() { # $1 = attribute (text|content-desc), $2 = value (exact)
    dump_ui >/dev/null
    python3 - "$TMP/ui.xml" "$1" "$2" <<'PY'
import re, sys
xml = open(sys.argv[1]).read()
m = re.search(r'<node[^>]*' + sys.argv[2] + r'="' + re.escape(sys.argv[3]) + r'"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', xml)
if not m:
    sys.exit(1)
print((int(m.group(1)) + int(m.group(3))) // 2, (int(m.group(2)) + int(m.group(4))) // 2)
PY
}

# Conversation rows are exposed as a single accessibility label
# ("Alex. See you then.. Yesterday") rather than separate text nodes, so a row
# has to be found by prefix, not by an exact match on the contact name.
# (rowxy itself polls; see the comment on it.)
# The list renders a loading skeleton while the startup sync settles, and
# re-seeding outside the app means a row can be missing for a few seconds after
# a single dump. Poll before giving up, otherwise a shot silently lands on the
# wrong screen.
rowxy() {
    local i c
    for i in 1 2 3 4 5 6; do
        c=$(rowxy_once "$1")
        if [ -n "$c" ]; then echo "$c"; return 0; fi
        sleep 1.5
    done
    return 1
}

rowxy_once() {
    dump_ui >/dev/null
    python3 - "$TMP/ui.xml" "$1" <<'PY'
import re, sys
xml = open(sys.argv[1]).read()
name = sys.argv[2]
for m in re.finditer(r'<node[^>]*content-desc="([^"]*)"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', xml):
    label = m.group(1)
    if label == name or label.startswith(name + ".") or label.startswith(name + " "):
        print((int(m.group(2)) + int(m.group(4))) // 2, (int(m.group(3)) + int(m.group(5))) // 2)
        break
else:
    sys.exit(1)
PY
}
cdxy() { center_of_attr content-desc "$1"; }

# Settings rows are plain text nodes, unlike conversation rows, so they need
# their own matcher.
textxy() { center_of_attr text "$1"; }

tap_settings_row() { # $1 = row label
    tap_settings || return 1
    for _ in 1 2 3 4 5; do
        dump_ui >/dev/null
        textxy "$1" >/dev/null 2>&1 && break
        adb_ shell input swipe 540 1800 540 900 250 >/dev/null 2>&1
        sleep 1.5
    done
    local c
    c=$(textxy "$1") || { echo "  !! settings row '$1' not found"; FAILED=1; return 1; }
    tapxy ${c% *} ${c#* }
}
open_settings_row() { tap_settings_row "$1"; }

# Auto-delete (retention) lives on the Advanced screen, one level below Settings.
open_advanced_row() { # $1 = row label
    tap_settings_row "Advanced" || return 1
    sleep 1
    for _ in 1 2 3 4 5; do
        dump_ui >/dev/null
        textxy "$1" >/dev/null 2>&1 && break
        adb_ shell input swipe 540 1800 540 900 250 >/dev/null 2>&1
        sleep 1.5
    done
    local c
    c=$(textxy "$1") || { echo "  !! advanced row '$1' not found"; FAILED=1; return 1; }
    tapxy ${c% *} ${c#* }
}
tapxy() {
    # A failed lookup yields no coordinates; tapping empty strings would abort the
    # whole run under `set -u` and lose every shot captured so far.
    if [ $# -lt 2 ] || [ -z "$1" ] || [ -z "$2" ]; then
        echo "  !! tapxy called without coordinates"
        FAILED=1
        return 1
    fi
    adb_ shell input tap "$1" "$2"
    sleep 2
}

tap_text()  { local c; c=$(rowxy "$1") || { echo "  !! no row '$1'"; FAILED=1; return 1; }; tapxy ${c% *} ${c#* }; }
tap_desc()  { local c; c=$(cdxy "$1") || { echo "  !! no control '$1'"; FAILED=1; return 1; }; tapxy ${c% *} ${c#* }; }
open_chat() { tap_text "$1"; }

# The settings avatar sits just right of the Search icon in the home top bar.
tap_settings() {
    dump_ui >/dev/null
    local c
    c=$(python3 -c "
import re
xml = open('$TMP/ui.xml').read()
m = re.search(r'<node[^>]*content-desc=\"Search\"[^>]*bounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"', xml)
if m: print(int(m.group(3)) + 95, (int(m.group(2)) + int(m.group(4))) // 2)
") || true
    [ -z "$c" ] && { echo "  !! settings avatar not found"; FAILED=1; return 1; }
    tapxy ${c% *} ${c#* }
}

# Chat-header avatar: the clickable node to the right of the back arrow opens
# the contact details sheet. Polled, because the header can still be settling
# when the chat is opened.
tap_chat_avatar() {
    local i c
    for i in 1 2 3 4 5; do
        c=$(chat_avatar_xy) && { tapxy ${c% *} ${c#* }; return 0; }
        sleep 1.5
    done
    echo "  !! chat avatar not found"
    FAILED=1
    return 1
}

chat_avatar_xy() {
    dump_ui >/dev/null
    python3 -c "
import re, sys
xml = open('$TMP/ui.xml').read()
b = re.search(r'<node[^>]*content-desc=\"Back\"[^>]*bounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"', xml)
if not b: sys.exit(0)
bx2, by2 = int(b.group(3)), int(b.group(4))
for m in re.finditer(r'<node[^>]*clickable=\"true\"[^>]*bounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"', xml):
    x1, y1, x2, y2 = map(int, m.groups())
    if bx2 < x1 < bx2 + 340 and y2 <= by2 + 120:
        print((x1 + x2) // 2, (y1 + y2) // 2); break
"
}

screencap_to() {
    require_device
    adb_ exec-out screencap -p > "$SHOTS/$1"
    echo "  saved $1"
}

# Assert the current screen mentions $1 (text or content-desc), so a shot is
# never silently taken of the wrong screen.
verify() {
    dump_ui >/dev/null
    if python3 - "$TMP/ui.xml" "$1" <<'PY'
import re, sys
sys.exit(0 if re.search(r'(?:text|content-desc)="[^"]*' + re.escape(sys.argv[2]) + r'[^"]*"', open(sys.argv[1]).read()) else 1)
PY
    then echo "  ok   [$1]"
    else echo "  MISS [$1]"; FAILED=1
    fi
}

verify_any() {
    dump_ui >/dev/null
    for m in "$@"; do
        if python3 - "$TMP/ui.xml" "$m" <<'PY'
import re, sys
sys.exit(0 if re.search(r'text="[^"]*' + re.escape(sys.argv[2]) + r'[^"]*"', open(sys.argv[1]).read()) else 1)
PY
        then echo "  ok   [$m]"; return 0; fi
    done
    echo "  MISS [$*]"; FAILED=1; return 1
}

focus_input() {
    dump_ui >/dev/null
    read x y <<< "$(python3 -c "
import re
xml = open('$TMP/ui.xml').read()
m = re.search(r'<node[^>]*class=\"android.widget.EditText\"[^>]*bounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"', xml)
print((int(m.group(1)) + int(m.group(3))) // 2, (int(m.group(2)) + int(m.group(4))) // 2)")"
    adb_ shell input tap "$x" "$y"; sleep 1.5
}
clear_input() {
    adb_ shell input keyevent KEYCODE_MOVE_END
    for _ in $(seq 1 40); do adb_ shell input keyevent KEYCODE_DEL; done
    sleep 0.5
}

# Long-pressing Send with a non-empty draft opens the schedule picker.
open_schedule_picker() { # $1 = conversation name
    open_chat "$1" || return 1
    focus_input; clear_input
    adb_ shell input text "Pick%sup%smilk%son%sthe%sway%shome" >/dev/null
    sleep 1
    local c; c=$(cdxy "Send") || { echo "  !! no Send button"; FAILED=1; return 1; }
    adb_ shell input swipe ${c% *} ${c#* } ${c% *} ${c#* } 900
    sleep 2
}

# An expanded MessagingStyle notification, showing the grouped thread history.
shot_grouped_notification() { # $1 = output name
    launch; dismiss_onboarding; ensure_home
    local n="+1555900${RANDOM:0:4}"
    for i in 1 2 3; do
        adb_ emu sms send "$n" "Grouped line $i from the demo sender" >/dev/null 2>&1
        sleep 3
    done
    sleep 3
    adb_ shell cmd statusbar expand-notifications >/dev/null 2>&1; sleep 2
    # Leave the shade exactly as expand-notifications leaves it. Dragging it
    # further down opens the full quick-settings panel and pushes the
    # notification off the bottom; scrolling the list upward collapses the
    # shade instead. Neither is worth the risk.
    for _ in 1 2 3; do
        dump_ui >/dev/null
        grep -q "Grouped line" "$TMP/ui.xml" && break
        adb_ shell input swipe 540 1600 540 1200 300 >/dev/null 2>&1; sleep 1
    done
    screencap_to "$1"
    verify "Grouped line"
    adb_ shell cmd statusbar collapse >/dev/null 2>&1; sleep 1
    drop_thread "$n"
}

# Remove a throwaway thread. The system SMS row has to go too: syncFromSystem()
# re-imports it on the next launch and it reappears at the top of the list.
drop_thread() { # $1 = address
    dbq "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$1');"
    dbq "DELETE FROM conversations WHERE address='$1';"
    dbq "DELETE FROM participants WHERE normalized_destination='$1';"
    adb_ shell "su 0 content delete --uri content://sms --where \"address='$1'\"" >/dev/null 2>&1
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
}

# A draft saved by the schedule step would otherwise show up in the list preview
# and in the composer of every later shot. Clearing the text in the UI is not
# enough: the draft is already persisted on the conversation row.
clear_draft() { # $1 = address
    dbq "UPDATE conversations SET draft='', draft_date=0 WHERE address='$1';"
    dbq "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$1') AND body='Pick up milk on the way home';"
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
}

# ============ LIGHT: the bulk of the gallery ============
light
sweep_stray_threads
launch; dismiss_onboarding; ensure_home

screencap_to 01-conversations.png
verify "Messages"

open_chat "Dad"; screencap_to 02-chat.png
verify "Message"
tap_chat_avatar; screencap_to 03-contact-details.png
verify "Add people"
back; back; ensure_home

open_chat "Work Group"; screencap_to 04-group-chat.png
verify "Message"
back; ensure_home

tap_desc "Start chat"; screencap_to 05-new-chat.png
verify_any "Enter name or phone" "New conversation"
back; ensure_home

open_settings_row "Spam &amp; Blocked"; screencap_to 06-spam-blocked.png
verify "Conversations"
back; ensure_home

open_settings_row "Spam &amp; Blocked" && c=$(center_of_contains "Messages") && { adb_ shell input tap $c; sleep 2; }
screencap_to 07-spam-blocked-messages.png
verify_any "Restore" "Blocked" "Delete"
back; ensure_home

open_settings_row "Trash"; screencap_to 08-trash.png
verify "Empty trash"
back; back; ensure_home

open_schedule_picker "Mom"; screencap_to 09-schedule-send.png
verify "Select date"
back; back; ensure_home

open_advanced_row "Auto-delete"; screencap_to 10-auto-delete.png
verify_any "Auto-delete" "Delete after" "Blocked messages"
back; ensure_home

tap_settings; screencap_to 11-settings.png
verify_any "General settings" "Notifications"
back; ensure_home

shot_grouped_notification 12-notification-grouped.png

# ============ DARK: the three headline screens ============
light
# The schedule step left a draft in Mom's thread; drop it before the dark pass,
# or it shows as "Draft: ..." in the list preview and in the composer.
clear_draft "+1555771050"
dark
launch; dismiss_onboarding; ensure_home
screencap_to 13-conversations-dark.png
verify "Messages"

open_chat "Mom"; screencap_to 14-chat-dark.png
verify "Message"
back; ensure_home

tap_settings; screencap_to 15-settings-dark.png
verify_any "General settings" "Notifications"
back

light

echo
echo "=== DONE (failed checks: $FAILED) ==="
ls -1 "$SHOTS"
exit $((FAILED > 0))
