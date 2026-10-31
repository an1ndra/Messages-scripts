#!/usr/bin/env bash
# Regression for the follow-up on #363: the schedule date sheet draws the
# calendar the user picked, and the day tapped on it is the day scheduled.
#
# Before the change the sheet was Material's DatePicker, which only speaks
# Gregorian: the grid showed October's days, and the Jalali name of the picked
# day could only appear as a hint line underneath ("In your calendar: ...").
# Every assertion here therefore fails on that build — there is no Jalali month
# in the header, no Jalali day in a cell, and no Gregorian echo line.
#
# The Jalali reference pair is pinned, not read off the clock: 4 Aban 1405 is
# 2026-10-26, the same instant test-calendar.sh pins its labels with.
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

PASS=0; FAIL=0
ok()   { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad()  { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { printf '\n=== %s ===\n' "$1"; }

TS=1793016000000            # 2026-10-26T12:00:00Z = 4 Aban 1405
NUM="+1555943${TS: -4}"
MARK="schedcal$(date +%s)$$"
PREFS="shared_prefs/messages_settings.xml"

JALALI="Farvardin|Ordibehesht|Khordad|Tir|Mordad|Shahrivar|Mehr|Aban|Azar|Dey|Bahman|Esfand"
GREGORIAN="January|February|March|April|May|June|July|August|September|October|November|December"

adb_ root >/dev/null 2>&1; adb_ wait-for-device; sleep 1
sql() { adb_ shell "sqlite3 /data/data/$PKG/databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r'; }

set_calendar() {   # auto|gregorian|persian|...
    local value="$1"
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    adb_ shell "run-as $PKG sh -c 'if grep -q name=\"calendar_system\" $PREFS; then sed -i \"s#name=\\\"calendar_system\\\" value=\\\"[^\\\"]*\\\"#name=\\\"calendar_system\\\" value=\\\"$value\\\"#\" $PREFS; else sed -i \"s#</map>#    <string name=\\\"calendar_system\\\">$value</string>\\n</map>#\" $PREFS; fi'" >/dev/null 2>&1
    sleep 1
}

set_scheduling() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    adb_ shell "run-as $PKG sh -c 'if grep -q name=\"scheduled_messages_enabled\" $PREFS; then sed -i \"s#name=\\\"scheduled_messages_enabled\\\" value=\\\"[^\\\"]*\\\"#name=\\\"scheduled_messages_enabled\\\" value=\\\"$1\\\"#\" $PREFS; else sed -i \"s#</map>#    <boolean name=\\\"scheduled_messages_enabled\\\" value=\\\"$1\\\" />\\n</map>#\" $PREFS; fi'" >/dev/null 2>&1
    sleep 1
}

cleanup() {
    adb_ shell input keyevent 4 >/dev/null 2>&1
    sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM');" >/dev/null 2>&1
    sql "DELETE FROM scheduled_messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM');" >/dev/null 2>&1
    sql "DELETE FROM conversations WHERE address='$NUM';" >/dev/null 2>&1
    set_calendar auto
    set_scheduling true
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
}
trap cleanup EXIT

# Any node whose text or content-description matches the python regex; prints
# the centre of the nearest enclosing clickable node, or of the node itself.
tap_match() {
    local pattern="$1"
    dump_ui >/dev/null 2>&1 || return 1
    local point
    point=$(python3 - "$TMP/ui.decoded.xml" "$pattern" <<'PY'
import re, sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
pattern = re.compile(sys.argv[2])

def center(node):
    m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", node.get("bounds", ""))
    if not m:
        return None
    return ((int(m.group(1)) + int(m.group(3))) // 2,
            (int(m.group(2)) + int(m.group(4))) // 2)

def walk(node):
    for child in node:
        text = child.get("text") or child.get("content-desc") or ""
        if pattern.search(text):
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
    adb_ shell input tap $point >/dev/null 2>&1
    return 0
}

has()  { grep -qE -- "$1" "$TMP/ui.xml"; }
dump_() { dump_ui >/dev/null 2>&1 || true; }

dismiss_dialogs() {
    local i
    for i in 1 2 3 4; do
        dump_ui >/dev/null 2>&1 || return 0
        if grep -q 'text="ALLOW"' "$TMP/ui.xml"; then tap_match '^ALLOW$' >/dev/null 2>&1
        elif grep -q 'text="Not now"' "$TMP/ui.xml"; then tap_match '^Not now$' >/dev/null 2>&1
        else return 0
        fi
        sleep 1.5
    done
}

open_chat_with_draft() {
    local i
    for i in 1 2 3; do
        adb_ shell am force-stop "$PKG"; sleep 1
        adb_ shell am start -n "$ACT" --es open_conversation_address "$NUM" >/dev/null 2>&1
        sleep 6
        dismiss_dialogs
        dump_ui >/dev/null 2>&1 || continue
        grep -q 'class="android.widget.EditText"' "$TMP/ui.xml" || continue
        tap_match '^Message$' >/dev/null 2>&1 || adb_ shell input tap 460 2109 >/dev/null 2>&1
        sleep 1.5
        type_text "$MARK" >/dev/null 2>&1
        sleep 2
        dump_ui >/dev/null 2>&1 || continue
        grep -q "text=\"$MARK\"" "$TMP/ui.xml" || continue
        return 0
    done
    return 1
}

hold_send() {
    dump_ui >/dev/null 2>&1 || return 1
    local send
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

open_picker() {
    open_chat_with_draft || { bad "could not open the chat with a draft"; return 1; }
    hold_send || { bad "could not find the Send button"; return 1; }
    local i
    for i in 1 2 3 4 5 6; do
        sleep 1.5
        dump_ui >/dev/null 2>&1 || continue
        grep -q 'text="Select date"' "$TMP/ui.xml" && return 0
    done
    bad "the date sheet did not open"
    return 1
}

close_sheet() { adb_ shell input keyevent 4 >/dev/null 2>&1; sleep 1; }

# The month label sits in the header button: "Aban 1405", "October 2026".
header_text() {
    python3 - "$TMP/ui.decoded.xml" <<'PY'
import re, sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
pattern = re.compile(r"^([A-Z][A-Za-z\u00C0-\u024F.]*)\s(\d{3,4})$")
for node in root.iter("node"):
    text = node.get("text") or ""
    if pattern.match(text):
        print(text)
        break
PY
}

info "Seed a pinned conversation dated $TS"
# The file can exist while the schema does not — a cold boot interrupted
# before the first launch leaves an empty database behind, and seeding then
# fails with "no such table".
for _attempt in 1 2 3; do
    sql "SELECT 1 FROM conversations LIMIT 1;" >/dev/null 2>&1 && break
    adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 12
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 2
done
sql "DELETE FROM conversations WHERE address='$NUM';" >/dev/null 2>&1
sql "INSERT INTO conversations(address,name,snippet,timestamp,unread_count,pinned) VALUES('$NUM','$MARK','schedule calendar probe',$TS,0,1);" >/dev/null 2>&1
CID=$(sql "SELECT id FROM conversations WHERE address='$NUM';")
[ -z "$CID" ] && { bad "could not seed a conversation"; exit 1; }
sql "INSERT INTO messages(conversation_id,body,timestamp,status) VALUES($CID,'probe',$TS,'received');" >/dev/null 2>&1
set_scheduling true
ok "seeded conversation $CID"

info "Gregorian: the sheet draws Gregorian months"
set_calendar gregorian
if open_picker; then
    dump_
    header=$(header_text)
    if [[ "$header" =~ ^($GREGORIAN)[[:space:]][0-9]{3,4}$ ]]; then
        ok "the grid header is a Gregorian month ($header)"
    else
        bad "the grid header is not Gregorian (got '${header:-nothing}')"
    fi
    has "content-desc=\"[^\"<]*($GREGORIAN) [0-9]+, [0-9]{4}\"" \
        && ok "day cells are announced as Gregorian dates" \
        || bad "day cells are not announced as Gregorian dates"
    has 'text="Gregorian: ' && bad "a Gregorian echo line was drawn for a Gregorian grid" \
        || ok "no Gregorian echo line while the grid is Gregorian"
    close_sheet
fi

info "Persian: the sheet draws Jalali months and days"
set_calendar persian
if open_picker; then
    dump_
    header=$(header_text)
    if [[ "$header" =~ ^($JALALI)[[:space:]][0-9]{3,4}$ ]]; then
        ok "the grid header is a Jalali month ($header)"
    else
        bad "the grid header is not Jalali (got '${header:-nothing}')"
    fi
    has "content-desc=\"[^\"<]*($JALALI) [0-9]+, [0-9]{4}\"" \
        && ok "day cells are announced as Jalali dates" \
        || bad "day cells are not announced as Jalali dates"
    has 'text="Gregorian: ' && ok "the picked day is echoed in Gregorian" \
        || bad "no Gregorian echo for the picked day"

    # Jump to a pinned Jalali month so the expected Gregorian day is a constant.
    tap_match "^($JALALI) [0-9]{3,4}$" >/dev/null 2>&1
    sleep 1.5; dump_
    grep -q 'text="1405"' "$TMP/ui.xml" && ok "the year picker opens at the year on screen" \
        || bad "the year picker does not offer the current year first"
    tap_match '^1405$' >/dev/null 2>&1
    sleep 1.5; dump_
    header=$(header_text)
    index=-1
    months=(Farvardin Ordibehesht Khordad Tir Mordad Shahrivar Mehr Aban Azar Dey Bahman Esfand)
    for i in "${!months[@]}"; do
        case "$header" in "${months[$i]}"\ *) index=$i ;; esac
    done
    if [ "$index" -lt 0 ]; then
        bad "lost track of the month after picking a year (got '${header:-nothing}')"
    else
        # Aban is month 7, counting from zero: step to it without wrapping the year.
        if [ "$index" -le 7 ]; then
            for _ in $(seq $((7 - index))); do tap_match '^Next month$' >/dev/null 2>&1 || true; sleep 0.6; done
        else
            for _ in $(seq $((index - 7))); do tap_match '^Previous month$' >/dev/null 2>&1 || true; sleep 0.6; done
        fi
        dump_
        header=$(header_text)
        [ "$header" = "Aban 1405" ] && ok "stepping the months reached Aban 1405" \
            || bad "stepping the months landed on '${header:-nothing}' instead of Aban 1405"
    fi

    if tap_match "Aban 4, 1405" >/dev/null 2>&1; then
        sleep 1.2; dump_
        # The headline is Material's 32sp line naming the picked day, drawn in
        # the grid's calendar rather than the platform's Gregorian.
        grep -q 'text="Aban 4, 1405"' "$TMP/ui.xml" \
            && ok "the headline names the picked day in Jalali" \
            || bad "the headline does not name the picked day in Jalali"
        grep -q 'text="Gregorian: Oct 26, 2026"' "$TMP/ui.xml" \
            && ok "4 Aban 1405 is echoed as 2026-10-26" \
            || bad "4 Aban 1405 is not echoed as 2026-10-26"
    else
        bad "no Aban 4 cell to tap"
    fi

    if tap_match '^Next$' >/dev/null 2>&1; then
        sleep 1.5; dump_
        grep -q 'text="Select time"' "$TMP/ui.xml" \
            && ok "the picked day carries into the time sheet" \
            || bad "the date sheet did not continue to the time sheet"
    else
        bad "no Next button in the date sheet"
    fi

    # The whole chain, not just the sheet: the time accepted by default, then
    # the row the scheduler stores. The picked day is in the past, so the
    # scheduler must clamp it forward rather than store a time that has gone.
    sql "DELETE FROM scheduled_messages WHERE conversation_id=$CID;" >/dev/null 2>&1
    before=$(adb_ shell date +%s | tr -d '\r')
    if tap_match '^Schedule$' >/dev/null 2>&1; then
        sleep 3
        after=$(adb_ shell date +%s | tr -d '\r')
        stored=$(sql "SELECT timestamp FROM scheduled_messages WHERE conversation_id=$CID ORDER BY timestamp DESC LIMIT 1;")
        if [ -z "$stored" ]; then
            bad "scheduling stored no row at all"
        else
            secs=$((stored / 1000))
            if [ "$secs" -ge "$((before - 2))" ] && [ "$secs" -le "$((after + 5))" ]; then
                ok "the picked day is scheduled at the clamped instant ($secs)"
            else
                bad "stored instant $secs is outside [$before, $((after + 5))]"
            fi
            body=$(sql "SELECT body FROM scheduled_messages WHERE conversation_id=$CID ORDER BY timestamp DESC LIMIT 1;")
            [ "$body" = "$MARK" ] && ok "the scheduled row carries the draft" \
                || bad "the scheduled row carries '${body:-nothing}' instead of the draft"
        fi
    else
        bad "no Schedule button in the time sheet"
    fi
    close_sheet
fi

info "A future Jalali day is scheduled on that day, at that time"
set_calendar persian
if open_picker; then
    # The next month is always ahead, so nothing has to be clamped forward and
    # the stored instant must be exactly the day and minute that were picked.
    tap_match '^Next month$' >/dev/null 2>&1; sleep 1.2; dump_
    if tap_match "($JALALI) 1, [0-9]{4}" >/dev/null 2>&1; then
        sleep 1.2; dump_
        echoed=$(grep -o 'text="Gregorian: [^"]*"' "$TMP/ui.xml" | head -1 \
            | sed -e 's/text="Gregorian: //' -e 's/"$//')
        if [ -z "$echoed" ]; then
            bad "no Gregorian echo for the day that was tapped"
        else
            expected=$(LC_ALL=C date -d "$echoed" +%F)
            tap_match '^Next$' >/dev/null 2>&1; sleep 1.5
            now=$(adb_ shell date +%s | tr -d '\r')
            tap_match '^Schedule$' >/dev/null 2>&1; sleep 3
            stored=$(sql "SELECT timestamp FROM scheduled_messages WHERE conversation_id=$CID ORDER BY timestamp DESC LIMIT 1;")
            if [ -z "$stored" ]; then
                bad "scheduling a future day stored no row"
            else
                secs=$((stored / 1000))
                tz=$(adb_ shell getprop persist.sys.timezone | tr -d '\r')
                got=$(TZ="$tz" date -d "@$secs" +%F)
                [ "$got" = "$expected" ] \
                    && ok "the Jalali day is scheduled on $expected" \
                    || bad "scheduled $got instead of $expected"
                [ $((secs % 60)) -eq 0 ] \
                    && ok "and at the minute that was picked, not clamped to now" \
                    || bad "the time was rewritten to a clamped instant ($((secs % 60))s past the minute)"
                [ "$secs" -gt "$now" ] \
                    && ok "and it is in the future" \
                    || bad "the stored instant is not in the future"
            fi
        fi
    else
        bad "no first-of-month cell to tap after stepping a month"
    fi
    close_sheet
fi

info "Result: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
