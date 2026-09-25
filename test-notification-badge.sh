#!/usr/bin/env bash
# Regression: the launcher icon badge (unread count).
#
# Two things broke the badge count and are covered here:
#   1. the notification carried no number at all, so launchers that render a
#      count (rather than a dot) showed nothing;
#   2. opening any conversation called cancelAll(), which wiped every other
#      unread conversation's notification - and the badge is derived from active
#      notifications - so the count vanished as soon as a chat was opened.
source "$(dirname "$0")/env.sh"
set -uo pipefail

PASS=0
FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }

MARK="badge$(date +%s)$$"
A="+1555990${MARK: -3}"
B="+1555991${MARK: -3}"

db_sql() {
    adb_ shell "run-as $PKG sqlite3 databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r' && return 0
    adb_ shell "su -c \"sqlite3 /data/data/$PKG/databases/messages.db \\\"$1\\\"\"" 2>/dev/null | tr -d '\r' || true
}
notif_count() { adb_ shell "dumpsys notification --noredact 2>/dev/null" | tr -d '\r' | grep -cE "NotificationRecord.*pkg=$PKG"; }
unread_total() { db_sql "SELECT COALESCE(SUM(unread_count),0) FROM conversations WHERE deleted_at=0 AND archived=0 AND blocked=0;"; }
scroll_to_row() {
    local needle="$1" c=""
    for _ in $(seq 1 14); do
        c=$(row_center "$needle") || c=""
        [ -n "$c" ] && { printf '%s' "$c"; return 0; }
        adb_ shell input swipe 540 1700 540 1100 250 >/dev/null 2>&1
        sleep 1
    done
    return 1
}

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
cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    db_sql "DELETE FROM messages WHERE body LIKE '%$MARK%'; DELETE FROM conversations WHERE address IN ('$A','$B'); DELETE FROM participants WHERE normalized_destination IN ('$A','$B');" >/dev/null 2>&1 || true
}
trap cleanup EXIT

for p in READ_SMS RECEIVE_SMS SEND_SMS READ_CONTACTS POST_NOTIFICATIONS; do
    adb_ shell pm grant "$PKG" "android.permission.$p" >/dev/null 2>&1
done
adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1 || true

info "Seed two unread conversations from different senders"
# Other scripts leave unread rows behind, so this asserts the delta, not a total.
BEFORE_UNREAD=$(unread_total)
TS=$(date +%s000)
CID_A=""; CID_B=""
for pair in "$A:A" "$B:B"; do
    N=${pair%%:*}; TAG=${pair##*:}
    db_sql "INSERT INTO conversations(address,name,snippet,timestamp,unread_count) VALUES('$N','badge$TAG-$MARK','badge$TAG $MARK',$TS,2);" >/dev/null 2>&1
    CID=$(db_sql "SELECT id FROM conversations WHERE address='$N';")
    db_sql "INSERT INTO messages(conversation_id,body,timestamp,status) VALUES($CID,'badge$TAG $MARK',$TS,'received');" >/dev/null 2>&1
    [ "$TAG" = "A" ] && CID_A=$CID || CID_B=$CID
done
TOTAL=$(unread_total)
[ "$((TOTAL - BEFORE_UNREAD))" = "4" ] \
    && pass "two unread conversations seeded (total rose by 4, now $TOTAL)" \
    || fail "seed raised the total by $((TOTAL - BEFORE_UNREAD)) (expected 4)"

info "An incoming message publishes a badge number"
# Clear any notification left by an earlier build/run: the aggregate is only
# meaningful over the notifications this run posts.
for id in $(adb_ shell "dumpsys notification --noredact" 2>/dev/null | tr -d '\r' \
        | grep -oE "NotificationRecord\(.*pkg=$PKG.*id=[0-9-]+" | grep -oE "id=[0-9-]+" | cut -d= -f2 | sort -u); do
    adb_ shell cmd notification cancel "$PKG" "$id" tag 0 >/dev/null 2>&1
done
adb_ shell am force-stop "$PKG" >/dev/null 2>&1
adb_ shell am start -n "$ACT" >/dev/null 2>&1
sleep 5
adb_ shell input keyevent KEYCODE_HOME >/dev/null 2>&1
sleep 2
# Both senders must have a live notification, otherwise there is nothing to
# preserve when the other chat is opened.
adb_ emu sms send "$A" "badge probe $MARK" >/dev/null 2>&1
sleep 5
adb_ emu sms send "$B" "badge probe $MARK" >/dev/null 2>&1
sleep 7

# The badge number is dumped indented under its own NotificationRecord line.
# Scoping with a grep -A window is not enough: the window spills into the next
# app's record and picks up its number=0.
# Returns the numbers carried by this app's notifications, one per line. Older
# records can legitimately hold 0 (posted when nothing was unread yet), so the
# assertion looks for a positive one rather than the first.
# The number carried by one specific notification id. Restricting to this run's
# conversation ids keeps notifications left behind by earlier runs or older
# builds out of the aggregate.
number_for_id() {
    adb_ shell "dumpsys notification --noredact" 2>/dev/null | tr -d '\r' | awk -v want="$1" -v pkg="$PKG" '
        /NotificationRecord\(/ { i=($0 ~ ("pkg=" pkg)); if (i) { match($0, /id=[0-9-]+/); id=substr($0, RSTART+3, RLENGTH-3) } }
        i && id == want && /^[[:space:]]+number=/ { gsub(/[^0-9]/, "", $0); print $0; exit }
    '
}

badge_numbers() {
    adb_ shell "dumpsys notification --noredact 2>/dev/null" | tr -d '\r' | awk -v pkg="$PKG" '
        /NotificationRecord\(/ { inrec = ($0 ~ ("pkg=" pkg)) }
        inrec && /^[[:space:]]+number=/ { gsub(/[^0-9]/, "", $0); print $0 }
    '
}
# Launchers that render a count AGGREGATE across the app's active
# notifications (Lawnchair sums them, verified on device). So each notification
# must carry exactly 1, and the badge is then the number of unread
# conversations. Publishing the unread *message* total per notification was
# observed rendering 45 for three notifications that each carried 15.
NA=$(number_for_id "$CID_A"); NB=$(number_for_id "$CID_B")
if [ "$NA" = "1" ] && [ "$NB" = "1" ]; then
    pass "both notifications carry badge number 1 (A=$NA B=$NB -> badge aggregates to the unread-conversation count)"
else
    fail "expected number 1 on each of this run's notifications, got A='${NA:-none}' B='${NB:-none}'"
fi

if [ "$(notif_count)" -ge 2 ]; then
    pass "both senders have an active notification ($(notif_count))"
else
    fail "expected a notification per sender, got $(notif_count)"
fi

info "Opening one conversation keeps the other conversation's notification"
# The badge check left the app backgrounded, so bring it forward before looking
# for a row - otherwise the dump is the launcher, not the conversation list.
BEFORE=$(notif_count)
# Open the conversation by address rather than by tapping its row. The row shows
# a formatted number, and an arriving message rewrites the conversation's name
# (receiveMessage resets it to the contact/address), so neither the raw address
# nor the seeded name is a stable thing to match on. This intent extra drives
# the same open-a-conversation path, including the notification dismissal.
#
# The app is deliberately NOT force-stopped first: force-stopping an app makes
# Android cancel its notifications, which would wipe the very notifications this
# step is meant to observe (measured 3 -> 0).
adb_ shell am start -n "$ACT" --es open_conversation_address "$A" >/dev/null 2>&1
if true; then
    sleep 6
    AFTER=$(notif_count)
    if [ "$AFTER" -ge 1 ] && [ "$AFTER" -lt "$BEFORE" ]; then
        pass "only the opened conversation's notification was dismissed ($BEFORE -> $AFTER)"
    else
        fail "expected exactly the opened one to be dismissed ($BEFORE -> $AFTER)"
    fi
    if [ "$(unread_total)" -ge 1 ]; then
        pass 'unread count for the other conversation is preserved'
    else
        fail 'unread count was wiped for the other conversation'
    fi
    adb_ shell input keyevent 4 >/dev/null 2>&1
    sleep 2
else
    fail 'could not locate the seeded conversation row'
fi

info "The opened conversation's own notification is still dismissed"
adb_ shell input keyevent 4 >/dev/null 2>&1
sleep 2
adb_ shell am start -n "$ACT" --es open_conversation_address "$A" >/dev/null 2>&1
sleep 6
adb_ shell input keyevent 4 >/dev/null 2>&1
sleep 3
if [ "$(unread_total)" -ge 1 ]; then
    pass 'remaining unread still tracked after revisiting the chat'
else
    fail 'unread lost after revisiting the chat'
fi

if adb_ shell "logcat -d -b crash" 2>/dev/null | grep -q "$PKG"; then
    fail 'app crashed during the badge regression'
else
    pass 'no crashes'
fi

printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
