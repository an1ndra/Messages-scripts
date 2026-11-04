#!/usr/bin/env bash
# Regression for #363: the message-details dialog names the Gregorian date when
# dates render in another calendar, and drops that row once Gregorian is back.
#
# Seeds one conversation whose message sits at a fixed instant (2026-10-26T12:00Z
# = 1405-08-04 Jalali) so the expected strings never drift with the run date,
# then edits the calendar preference directly (the app is force-stopped first,
# as scripts/test-calendar.sh does) and opens the message details:
#   - Jalali chosen: Sent reads Jalali, and a "Gregorian date" row reads the
#     same instant in Gregorian;
#   - Gregorian chosen: no companion row, and Sent is Gregorian.
#
# Run: scripts/test-363-gregorian-companion.sh
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh

PASS=0
FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }

TS=1793016000000   # 2026-10-26T12:00Z
NUM="+1555943${TS: -4}"
MARK="gregprobe$(date +%s)$$"
PREFS="shared_prefs/messages_settings.xml"

adb_ root >/dev/null 2>&1 || true
adb_ wait-for-device
sleep 1

sql() { { adb_ shell "sqlite3 /data/data/$PKG/databases/messages.db \"$1\"" 2>/dev/null || true; } | tr -d '\r'; }

set_calendar() {   # $1 = storage value; "auto" removes the key
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    if [ "$1" = "auto" ]; then
        adb_ shell "run-as $PKG sh -c \"sed -i '/calendar_system/d' $PREFS\"" >/dev/null 2>&1 || true
    else
        adb_ shell "run-as $PKG sh -c 'if grep -q name=\"calendar_system\" $PREFS; then sed -i \"s#name=\\\"calendar_system\\\"[^<]*<#name=\\\"calendar_system\\\">$1<#\" $PREFS; else sed -i \"s#</map>#    <string name=\\\"calendar_system\\\">$1</string>\\n</map>#\" $PREFS; fi'" >/dev/null 2>&1 || true
    fi
    sleep 1
}

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM');" >/dev/null 2>&1 || true
    sql "DELETE FROM conversations WHERE address='$NUM';" >/dev/null 2>&1 || true
    set_calendar auto || true
}
trap cleanup EXIT

for p in READ_SMS RECEIVE_SMS READ_CONTACTS POST_NOTIFICATIONS CALL_PHONE; do
    adb_ shell pm grant "$PKG" "android.permission.$p" >/dev/null 2>&1 || true
done
adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1 || true
cleanup

info "Seed a conversation dated $TS"
# A fresh install has no database until the app first builds it.
for _attempt in 1 2 3; do
    adb_ shell "sqlite3 /data/data/$PKG/databases/messages.db 'SELECT 1 FROM conversations LIMIT 1;'" \
        >/dev/null 2>&1 && break
    adb_ shell am start -n "$ACT" >/dev/null 2>&1
    sleep 12
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    sleep 2
done
sql "INSERT INTO conversations(address,name,snippet,timestamp,unread_count,pinned) VALUES('$NUM','$MARK','gregorian probe',$TS,0,1);" >/dev/null 2>&1
CID=$(sql "SELECT id FROM conversations WHERE address='$NUM';")
[ -z "$CID" ] && { fail "could not seed a conversation"; exit 1; }
sql "INSERT INTO messages(conversation_id,body,timestamp,status) VALUES($CID,'gregorian probe',$TS,'received');" >/dev/null 2>&1
pass "seeded conversation $CID"

open_chat() {
    adb_ shell am force-stop "$PKG"; sleep 1
    adb_ shell am start -n "$ACT" --es open_conversation_address "$NUM" >/dev/null 2>&1
    sleep 5
    dump_ui >/dev/null 2>&1 || return 1
    grep -q 'class="android.widget.EditText"' "$TMP/ui.xml"
}

long_press_bubble() {
    local q b x1 y1 y2 lx ly
    q=$(re_escape "$1")
    dump_ui || return 1
    b=$(grep -oE "text=\"[^\"]*$q[^\"]*\"[^>]*bounds=\"\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]\"" \
        "$TMP/ui.xml" 2>/dev/null | head -1 | grep -oE '\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]' | head -1)
    [ -z "$b" ] && return 1
    x1=$(sed -E 's/\[([0-9]+),([0-9]+)\].*/\1/' <<< "$b")
    y1=$(sed -E 's/\[[0-9]+,([0-9]+)\].*/\1/' <<< "$b")
    y2=$(sed -E 's/.*\]\[[0-9]+,([0-9]+)\]/\1/' <<< "$b")
    lx=$((x1 - 25))
    [ "$lx" -lt 32 ] && lx=32
    ly=$(( (y1 + y2) / 2 ))
    adb_ shell input motionevent DOWN "$lx" "$ly"; sleep 1.2
    adb_ shell input motionevent UP "$lx" "$ly"; sleep 1.5
}

open_details() {
    local i c
    for i in 1 2 3; do
        open_chat || continue
        long_press_bubble "gregorian probe" || continue
        c=$(center_of_contains "More options") || c=""
        [ -n "$c" ] || continue
        adb_ shell input tap $c; sleep 1
        c=$(center_of "View details") || c=""
        [ -n "$c" ] || continue
        adb_ shell input tap $c; sleep 1.5
        dump_ui >/dev/null 2>&1 || continue
        grep -q 'text="Message details"' "$TMP/ui.xml" && return 0
        adb_ shell input keyevent 4 >/dev/null 2>&1 || true
    done
    return 1
}

info "Jalali: the dialog adds the Gregorian date"
set_calendar persian
if open_details; then
    pass "message details opened"
    grep -q 'text="Gregorian date"' "$TMP/ui.xml" \
        && pass "the companion row is present" \
        || fail "the Gregorian date row is missing"
    grep -qF 'text="Aban 4, 1405' "$TMP/ui.xml" \
        && pass "Sent still renders Jalali" \
        || fail "Sent is not Jalali"
    grep -qF 'text="Oct 26, 2026"' "$TMP/ui.xml" \
        && pass "the companion reads the instant in Gregorian" \
        || fail "the companion value is missing"
    adb_ shell input keyevent 4 >/dev/null 2>&1 || true
else
    fail "could not open message details (Jalali)"
fi

info "Gregorian: the companion row disappears"
set_calendar gregorian
if open_details; then
    grep -q 'text="Gregorian date"' "$TMP/ui.xml" \
        && fail "the companion row is still present" \
        || pass "the companion row is gone"
    grep -qF 'text="Oct 26, 2026' "$TMP/ui.xml" \
        && pass "Sent renders Gregorian" \
        || fail "Sent is not Gregorian"
    grep -qF 'text="Aban 4, 1405' "$TMP/ui.xml" \
        && fail "Jalali leaked into the Gregorian dialog" \
        || pass "no Jalali text remains"
    adb_ shell input keyevent 4 >/dev/null 2>&1 || true
else
    fail "could not open message details (Gregorian)"
fi

printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
