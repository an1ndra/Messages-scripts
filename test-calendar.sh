#!/usr/bin/env bash
# Regression for #363: dates follow the calendar the user picks.
#
# Seeds one pinned conversation whose message sits at a fixed instant
# (2026-10-26T12:00Z, far enough back that the list and the chat show a date
# rather than a clock), then:
#   - on the default (Automatic, English device) every label is Gregorian;
#   - after choosing Persian (Jalali) the chat label, the conversation-list date
#     and the Diagnostics sample all read Jalali;
#   - after choosing Islamic (Umm al-Qura) they read Hijri;
#   - Automatic again restores Gregorian.
#
# Before the feature there is no Calendar row and no Diagnostics calendar line,
# so every Jalali/Hijri assertion fails. The fixed instant keeps the expected
# strings constant: seeding relative to "now" would make them depend on the day
# the script runs.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()   { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad()  { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

# 2026-10-26T12:00:00Z — that day is 1405-08-04 Jalali and 1448-05-15 Umm al-Qura.
TS=1793016000000
NUM="+1555943${TS: -4}"
MARK="calprobe$(date +%s)$$"

adb_ root >/dev/null 2>&1; adb_ wait-for-device; sleep 1
sql() { adb_ shell "sqlite3 /data/data/$PKG/databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r'; }

PREFS="shared_prefs/messages_settings.xml"

# Which settings surface the app renders: true = redesigned, false = legacy.
set_new_ui() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    adb_ shell "run-as $PKG sh -c 'if grep -q name=\"use_new_ui\" $PREFS; then sed -i \"s#name=\\\"use_new_ui\\\" value=\\\"[^\\\"]*\\\"#name=\\\"use_new_ui\\\" value=\\\"$1\\\"#\" $PREFS; else sed -i \"s#</map>#    <boolean name=\\\"use_new_ui\\\" value=\\\"$1\\\" />\\n</map>#\" $PREFS; fi'" >/dev/null 2>&1
    sleep 1
}

cleanup() {
    sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM');" >/dev/null 2>&1
    sql "DELETE FROM conversations WHERE address='$NUM';" >/dev/null 2>&1
    set_new_ui true
}
trap cleanup EXIT

for p in READ_SMS RECEIVE_SMS READ_CONTACTS POST_NOTIFICATIONS CALL_PHONE; do
    adb_ shell pm grant "$PKG" "android.permission.$p" >/dev/null 2>&1
done
cleanup

# The script asserts from a known starting point instead of trusting whatever
# an earlier run left behind.
reset_calendar() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
    adb_ shell "run-as $PKG sh -c \"sed -i '/calendar_system/d' shared_prefs/messages_settings.xml\"" \
        >/dev/null 2>&1
}
reset_calendar

# Taps the clickable row carrying a label. Rows at the bottom of a settings list
# sit under the navigation inset, where the label's own centre reports a point
# between two rows; the enclosing clickable node does not.
tap_row() {
    local label="$1" c
    dump_ui >/dev/null 2>&1 || return 1
    c=$(python3 - "$TMP/ui.decoded.xml" "$label" <<'PY'
import re, sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
label = sys.argv[2]

def center(node):
    m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", node.get("bounds", ""))
    if not m:
        return None
    return ((int(m.group(1)) + int(m.group(3))) // 2,
            (int(m.group(2)) + int(m.group(4))) // 2)

def walk(node):
    for child in node:
        text = (child.get("text") or child.get("content-desc") or "")
        if text == label or text.startswith(label):
            holder = child
            if holder.get("clickable") != "true":
                holder = node if node.get("clickable") == "true" else None
            point = center(holder) if holder is not None else None
            if point:
                return point
        found = walk(child)
        if found:
            return found
    return None

point = walk(root)
if not point:
    sys.exit(1)
print(point[0], point[1])
PY
    ) || return 1
    adb_ shell input tap $c >/dev/null 2>&1
    return 0
}

# A first launch can sit behind a system permission dialog (owning the SMS role
# asks for phone access on API 30), which would hide every assertion behind it.
dismiss_dialogs() {
    local i
    for i in 1 2 3 4; do
        dump_ui >/dev/null 2>&1 || return 0
        if grep -q 'text="ALLOW"' "$TMP/ui.xml"; then
            tap_text "ALLOW" >/dev/null 2>&1
        elif grep -q 'text="Not now"' "$TMP/ui.xml"; then
            # API 30 asks to become the default SMS app; the assertions read the
            # app's own database, so the role is not needed here.
            tap_text "Not now" >/dev/null 2>&1
        else
            return 0
        fi
        sleep 1.5
    done
}

open_chat() {
    adb_ shell am force-stop "$PKG"; sleep 1
    adb_ shell am start -n "$ACT" --es open_conversation_address "$NUM" >/dev/null 2>&1
    sleep 6
    dismiss_dialogs
    dump_ui >/dev/null 2>&1 || { bad "uiautomator dump failed"; return 1; }
    grep -q 'class="android.widget.EditText"' "$TMP/ui.xml" \
        || { bad "did not land in the seeded chat"; return 1; }
    return 0
}

expect_in_chat() {
    local want="$1" what="$2" i
    for i in 1 2 3; do
        open_chat || return 1
        if grep -qF -- "$want" "$TMP/ui.xml"; then ok "$what"; return 0; fi
        sleep 2
    done
    bad "$what (expected '$want')"
    return 1
}

expect_absent_in_chat() {
    local unwanted="$1" what="$2"
    if grep -qF -- "$unwanted" "$TMP/ui.xml"; then
        bad "$what (found '$unwanted')"
    else
        ok "$what"
    fi
}

open_settings() {
    adb_ shell am force-stop "$PKG"; sleep 1
    adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null 2>&1; sleep 4
    dismiss_dialogs
    dump_ui >/dev/null 2>&1 || { bad "settings did not open"; return 1; }
    return 0
}

open_list() {
    adb_ shell am force-stop "$PKG"; sleep 1
    adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 6
    dismiss_dialogs
    dump_ui >/dev/null 2>&1 || { bad "conversation list did not open"; return 1; }
    return 0
}

open_advanced() {
    local i
    open_settings || return 1
    for i in 1 2 3 4 5 6 7 8; do
        dump_ui >/dev/null 2>&1 || continue
        if tap_row "Advanced settings"; then
            sleep 2
            return 0
        fi
        adb_ shell input swipe 540 1700 540 800 400 >/dev/null 2>&1; sleep 1
    done
    bad "could not open Advanced settings"
    return 1
}

open_calendar_picker() {
    local i
    open_advanced || return 1
    for i in 1 2 3 4 5 6 7 8; do
        dump_ui >/dev/null 2>&1 || continue
        if tap_row "Calendar"; then
            sleep 1.5
            dump_ui >/dev/null 2>&1
            grep -q 'text="Choose calendar"' "$TMP/ui.xml" && return 0
        fi
        adb_ shell input swipe 540 1700 540 800 400 >/dev/null 2>&1; sleep 1
    done
    bad "no Calendar row in Advanced settings"
    return 1
}

pick_calendar() {
    local label="$1" i
    for i in 1 2 3; do
        tap_row "$label" && break
        # Nine calendars do not always fit the dialog's height cap.
        adb_ shell input swipe 540 1500 540 1000 300 >/dev/null 2>&1; sleep 0.8
    done
    if [ "$i" = "3" ]; then bad "picker has no '$label' option"; return 1; fi
    sleep 1
    tap_row "OK" >/dev/null 2>&1 || tap_text "OK" >/dev/null 2>&1 || true
    sleep 1.5
    return 0
}

# The platform date grid only speaks Gregorian; holding Send opens it, and the
# app adds a line naming the picked day in the reader's calendar.
hold_send() {
    local send
    dump_ui >/dev/null 2>&1 || return 1
    send=$(python3 - "$TMP/ui.decoded.xml" <<'PY'
import re, sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
for node in root.iter("node"):
    if node.get("content-desc") == "Send":
        m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", node.get("bounds", ""))
        if m:
            print((int(m.group(1)) + int(m.group(3))) // 2,
                  (int(m.group(2)) + int(m.group(4))) // 2)
            break
PY
    ) || return 1
    [ -z "$send" ] && return 1
    set -- $send
    adb_ shell input swipe "$1" "$2" "$1" "$2" 900 >/dev/null 2>&1
    return 0
}

open_diagnostics() {    local i
    open_advanced || return 1
    for i in 1 2 3 4 5 6 7 8; do
        dump_ui >/dev/null 2>&1 || continue
        if grep -q 'text="Diagnostics"' "$TMP/ui.xml"; then
            tap_row "Diagnostics" && sleep 2.5 && return 0
        fi
        adb_ shell input swipe 540 1700 540 800 400 >/dev/null 2>&1; sleep 1
    done
    bad "could not open Diagnostics"
    return 1
}

info "Seed a pinned conversation dated $TS"
# A fresh install has no database until the app first builds it.
if ! adb_ shell "test -f /data/data/$PKG/databases/messages.db" >/dev/null 2>&1; then
    adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 8
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
fi
sql "INSERT INTO conversations(address,name,snippet,timestamp,unread_count,pinned) VALUES('$NUM','$MARK','calendar probe',$TS,0,1);" >/dev/null 2>&1
CID=$(sql "SELECT id FROM conversations WHERE address='$NUM';")
[ -z "$CID" ] && { bad "could not seed a conversation"; exit 1; }
sql "INSERT INTO messages(conversation_id,body,timestamp,status) VALUES($CID,'calendar probe',$TS,'received');" >/dev/null 2>&1
ok "seeded conversation $CID"

info "Automatic on an English device renders Gregorian"
expect_in_chat "October 26" "chat group label is Gregorian" || true
expect_absent_in_chat "Aban" "no Jalali month while the calendar is Gregorian"
open_list
grep -qF -- "Oct 26" "$TMP/ui.xml" && ok "conversation list date is Gregorian" \
    || bad "conversation list date is not Gregorian"

info "Choose Persian (Jalali)"
open_calendar_picker || exit 1
grep -q "Choose calendar" "$TMP/ui.xml" && ok "calendar picker opened" || bad "calendar picker did not open"
pick_calendar "Persian (Jalali)" || exit 1
dump_ui >/dev/null 2>&1 || true
grep -q "Persian (Jalali)" "$TMP/ui.xml" && ok "row subtitle names the chosen calendar" \
    || bad "row subtitle did not update"

expect_in_chat "Aban 4" "chat group label renders Jalali" || true
expect_absent_in_chat "October 26" "the Gregorian date is gone from the chat"
open_list
grep -qF -- "Aban 4" "$TMP/ui.xml" && ok "conversation list date renders Jalali" \
    || bad "conversation list date is not Jalali"

# The schedule grid is Gregorian, so the picked day is named alongside it.
draft_and_hold() {
    local i
    # A space-free draft: "input text" turns spaces into %s and some builds drop
    # them. The typed text is asserted before holding, so a composer that never
    # took focus cannot look like a picker failure.
    for i in 1 2 3; do
        open_chat || return 1
        tap_edittext >/dev/null 2>&1 || continue
        sleep 1
        type_text "calendardraft" >/dev/null 2>&1
        sleep 2
        dump_ui >/dev/null 2>&1 || continue
        grep -q 'text="calendardraft"' "$TMP/ui.xml" || continue
        grep -q 'content-desc="Send"' "$TMP/ui.xml" || continue
        hold_send && return 0
    done
    return 1
}

JALALI="Farvardin|Ordibehesht|Khordad|Tir|Mordad|Shahrivar|Mehr|Aban|Azar|Dey|Bahman|Esfand"

if draft_and_hold; then
    sleep 3
    dump_ui >/dev/null 2>&1 || true
    # The grid itself is the reader's calendar now, and the line under it names
    # the picked day in Gregorian instead.
    grep -qE "text=\"($JALALI) [0-9]{3,4}\"" "$TMP/ui.xml" \
        && ok "the schedule grid draws Jalali months" \
        || bad "the schedule grid does not draw Jalali months"
    grep -qE "content-desc=\"[^\"]*($JALALI) [0-9]+, [0-9]{4}\"" "$TMP/ui.xml" \
        && ok "the schedule grid draws Jalali days" \
        || bad "the schedule grid does not draw Jalali days"
    grep -q 'text="Gregorian: ' "$TMP/ui.xml" \
        && ok "the picked day is echoed in Gregorian" \
        || bad "the picked day is not echoed in Gregorian"
    adb_ shell input keyevent 4 >/dev/null 2>&1; sleep 1
else
    bad "holding Send did not reach the picker"
fi

info "Diagnostics reports the resolved calendar"
open_diagnostics || true
dump_ui >/dev/null 2>&1 || true
grep -qF -- "Calendar: persian (chosen explicitly)" "$TMP/ui.xml" \
    && ok "diagnostics names the resolved calendar" \
    || bad "diagnostics calendar line missing"
# DayWithYear, rendered from a constant instant inside the report.
grep -qF -- "Calendar sample: Aban 4, 1405" "$TMP/ui.xml" \
    && ok "diagnostics sample renders the Jalali date" \
    || bad "diagnostics sample is not Jalali"

info "Switch to Islamic (Umm al-Qura)"
open_calendar_picker || exit 1
pick_calendar "Islamic" || exit 1
expect_in_chat "Jumada I 15" "chat group label renders Hijri" || true

info "Automatic restores Gregorian for an English device"
open_calendar_picker || exit 1
pick_calendar "Automatic" || exit 1
dump_ui >/dev/null 2>&1 || true
grep -q "Gregorian" "$TMP/ui.xml" && ok "automatic resolves to Gregorian on en" \
    || bad "automatic did not resolve to Gregorian"
expect_in_chat "October 26" "the Gregorian date is back" || true

info "Legacy settings offer the same Calendar row"
set_new_ui false
if open_settings; then
    dump_ui >/dev/null 2>&1 || true
    grep -q 'text="Calendar"' "$TMP/ui.xml" \
        && ok "legacy settings render the Calendar row" \
        || bad "legacy settings have no Calendar row"
    if tap_row "Calendar"; then
        sleep 1.5
        dump_ui >/dev/null 2>&1 || true
        grep -q 'text="Choose calendar"' "$TMP/ui.xml" \
            && ok "legacy settings open the same picker" \
            || bad "legacy Calendar row did not open the picker"
    else
        bad "legacy Calendar row is not tappable"
    fi
    adb_ shell input keyevent 4 >/dev/null 2>&1; sleep 1
else
    bad "legacy settings did not open"
fi
set_new_ui true

info "Result: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
