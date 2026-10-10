#!/usr/bin/env bash
# Refreshes the F-Droid screenshots against the current build.
#
# Curated set of 8 shots in the app's light theme, using dummy contacts and
# conversations. The output directory is emptied first so superseded shots do
# not accumulate.
#
# Requires the demo data seeders:
#   bash scripts/insert-demo-contacts.sh     # phone book, with monogram photos
#   bash scripts/seed-demo-conversations.sh  # inbox history
#
# Run from the scripts submodule:
#   ANDROID_SERIAL=emulator-5554 bash take-fdroid-screenshots.sh
#
# All tap targets come from live uiautomator dumps. Sizes assume 1080x2400 @ 420dpi.
set -uo pipefail
cd "$(dirname "$0")"
source ./env.sh
source ./demo-data.sh

SHOTS="$PROJECT_DIR/fastlane/metadata/android/en-US/images/phoneScreenshots"
mkdir -p "$SHOTS"
rm -f "$SHOTS"/*.png

FAILED=0

dbq() { printf '%s' "$1" | adb_ shell "run-as $PKG sqlite3 databases/messages.db" 2>/dev/null | tr -d '\r'; }

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

require_device() {
    adb_ shell true >/dev/null 2>&1 && return 0
    echo "ABORT: $ANDROID_SERIAL stopped responding; the captured shots cannot be trusted."
    exit 2
}

launch() {
    adb_ shell am force-stop "$PKG" >/dev/null; sleep 1
    adb_ shell am start -n "$ACT" "$@" >/dev/null; sleep 5
    dismiss_anr
}

back() { adb_ shell input keyevent KEYCODE_BACK; sleep 1.5; }

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

scroll_list_to_top() {
    for _ in 1 2 3; do
        adb_ shell input swipe 540 800 540 2000 250 >/dev/null 2>&1
        sleep 0.7
    done
}

center_of_attr() {
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
textxy() { center_of_attr text "$1"; }

tapxy() {
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

verify() {
    dump_ui >/dev/null
    if python3 - "$TMP/ui.decoded.xml" "$1" <<'PY'
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
        if python3 - "$TMP/ui.decoded.xml" "$m" <<'PY'
import re, sys
sys.exit(0 if re.search(r'(?:text|content-desc)="[^"]*' + re.escape(sys.argv[2]) + r'[^"]*"', open(sys.argv[1]).read()) else 1)
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

drop_thread() {
    dbq "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$1');"
    dbq "DELETE FROM conversations WHERE address='$1';"
    dbq "DELETE FROM participants WHERE normalized_destination='$1';"
    adb_ shell "su 0 content delete --uri content://sms --where \"address='$1'\"" >/dev/null 2>&1
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
}

clear_draft() {
    dbq "UPDATE conversations SET draft='', draft_date=0 WHERE address='$1';"
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
}

long_press_text() {
    local c mx my
    c=$(center_of_contains "$1") || { echo "  !! text '$1' not found"; FAILED=1; return 1; }
    mx=${c% *}; my=${c#* }
    adb_ shell input swipe "$mx" "$my" "$((mx + 2))" "$my" 1200
    sleep 1.5
}

open_chat_menu() {
    local c
    c=$(cdxy "More options") || { echo "  !! chat menu button not found"; FAILED=1; return 1; }
    tapxy ${c% *} ${c#* }
}

# ============ Setup ============
light() { adb_ shell cmd uimode night no >/dev/null; sleep 2; }
light
sweep_stray_threads

# ============ 1. Home conversation list (new UI) ============
launch; dismiss_onboarding; ensure_home
screencap_to 01-home.png
verify "Messages"

# ============ 2. Settings screen ============
tap_settings; screencap_to 02-settings.png
verify_any "General settings" "Notifications"
back; ensure_home

# ============ 3. Chat thread ============
open_chat "Dad"; screencap_to 03-chat.png
verify "Message"

# ============ 4. Contact details ============
tap_chat_avatar; screencap_to 04-contact.png
verify "Add people"
back; back; ensure_home

# ============ 5. Message reaction / like button ============
open_chat "Dad"
# Long-press the most recent incoming message from Dad.
long_press_text "It is on the kitchen table."
screencap_to 05-reaction.png
verify "👍"
back; ensure_home

# ============ 6. Typing composer ============
open_chat "Dad"
focus_input; clear_input
adb_ shell input text "On%smy%sway,%swill%spick%sup%smilk" >/dev/null
sleep 1
screencap_to 06-typing.png
verify "pick up milk"
clear_draft "+1555771010"
back; ensure_home

# ============ 7. SIM switcher (fake dual-SIM) ============
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" --ez fake_dual_sim true >/dev/null; sleep 5
dismiss_anr; dismiss_onboarding; ensure_home
open_chat "Dad"
open_chat_menu
screencap_to 07-sim-switcher.png
verify_any "SIM 1" "SIM 2"
adb_ shell input keyevent KEYCODE_BACK; sleep 1
back; ensure_home

# ============ 8. New Chat / contact picker ============
tap_desc "Start chat"; screencap_to 08-new-chat.png
verify_any "Enter name or phone" "New conversation"
back; ensure_home

echo
echo "=== DONE (failed checks: $FAILED) ==="
ls -1 "$SHOTS"
exit $((FAILED > 0))
