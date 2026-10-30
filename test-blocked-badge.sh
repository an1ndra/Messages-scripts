#!/usr/bin/env bash
# Regression: blocking a number drops its thread out of the launcher badge.
#
# The badge aggregates the numbers of the app's live notifications. Blocking
# used to leave the thread's notification alive with its unread number: new
# messages for a blocked sender never post a replacement, so the count never
# fell and blocked unread messages stayed in the icon total (#345).
source "$(dirname "$0")/env.sh"
set -uo pipefail

P=0; F=0
pass() { echo "[PASS] $1"; P=$((P + 1)); }
fail() { echo "[FAIL] $1"; F=$((F + 1)); }
info() { echo; echo "=== $* ==="; }

MARK="blockedbadge$(date +%s)$$"
SEND="+1555810${MARK: -3}"
TS=$(date +%s000)

db_sql() {
    adb_ shell "run-as $PKG sqlite3 databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r'
}

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    db_sql "DELETE FROM messages WHERE body LIKE '%$MARK%'; \
            DELETE FROM conversations WHERE address='$SEND'; \
            DELETE FROM blocked_numbers WHERE number='$SEND';" >/dev/null 2>&1 || true
}
trap cleanup EXIT

for p in READ_SMS RECEIVE_SMS SEND_SMS READ_CONTACTS POST_NOTIFICATIONS; do
    adb_ shell pm grant "$PKG" "android.permission.$p" >/dev/null 2>&1
done
adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1 || true

info "Seed the sender, keep it foregrounded-on-home so nothing reads it"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1
adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 4

live_ids() {
    adb_ shell "dumpsys notification --noredact" 2>/dev/null | tr -d '\r' \
        | grep -oE "NotificationRecord\(.*pkg=$PKG.*id=[0-9-]+" | grep -oE "id=[0-9-]+" | cut -d= -f2
}
# The number carried by one specific notification id, per the badge script.
number_for_id() {
    adb_ shell "dumpsys notification --noredact" 2>/dev/null | tr -d '\r' | awk -v want="$1" -v pkg="$PKG" \
        '/NotificationRecord\(/ { i=($0 ~ ("pkg=" pkg)); if (i) { match($0, /id=[0-9-]+/); id=substr($0, RSTART+3, RLENGTH-3) } }
         i && id == want && /^[[:space:]]+number=/ { gsub(/[^0-9]/, "", $0); print $0; exit }'
}

info "Receive two messages, then leave the app so one notification is live"
adb_ shell input keyevent KEYCODE_HOME >/dev/null 2>&1; sleep 1
adb_ emu sms send "$SEND" "blocked badge probe c $MARK" >/dev/null 2>&1; sleep 5
adb_ emu sms send "$SEND" "blocked badge probe d $MARK" >/dev/null 2>&1; sleep 6
CID=$(db_sql "SELECT id FROM conversations WHERE address='$SEND';")
if [ -z "$CID" ]; then
    fail "conversation row missing for $SEND (receiver did not run)"
    echo "Results: $P passed, $F failed"; exit 1
fi
NOTIF_NUM=$(number_for_id "$(( CID ))")
UNREAD=$(db_sql "SELECT unread_count FROM conversations WHERE address='$SEND';")
if [ "${UNREAD:-0}" -ge 2 ] && [ "${NOTIF_NUM:-0}" -eq "${UNREAD:-0}" ]; then
    pass "live notification carries the unread count ($NOTIF_NUM of $UNREAD)"
else
    fail "expected notification number == unread count, got ${NOTIF_NUM:-none} of ${UNREAD:-none}"
fi

info "Block the sender from the conversation row sheet - the notification stays live"
# Opening the chat would mark the thread read and dismiss its notification,
# which would mask the fix; blocking from the row sheet is what keeps the
# notification alive while the address moves to the block list.
adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 4
ROW_C=""
for _ in 1 2 3 4 5 6 7 8; do
    # The row's a11y desc carries the raw number with no formatting, so the
    # unformatted digits are what a tap lookup must match.
    ROW_C=$(center_of_contains "810${MARK: -3}") || ROW_C=$(center_of_contains "$SEND") || ROW_C=""
    if [ -n "$ROW_C" ]; then break; fi
    adb_ shell input swipe 540 1700 540 1100 250 >/dev/null 2>&1; sleep 1
done
if [ -n "$ROW_C" ]; then
    # Long press opens the row's bottom sheet: $ROW_C is "x y", used twice to
    # give input swipe the start and end points, 800ms held as press-to-open.
    adb_ shell input swipe $ROW_C $ROW_C 800 >/dev/null 2>&1
    sleep 2
    dump_ui >/dev/null 2>&1
    B=$(python3 - <<PY
import re
xml = open('/tmp/opencode/messages-tests/ui.xml', encoding='utf-8', errors='replace').read()
for attr in ('text', 'content-desc'):
    for m in re.finditer(r'%s="([^"]*)"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"' % attr, xml):
        if m.group(1) == 'Block':
            x1, y1, x2, y2 = map(int, m.groups()[1:])
            print((x1 + x2) // 2, (y1 + y2) // 2)
            raise SystemExit
PY
    )
    if [ -n "$B" ]; then
        adb_ shell input tap $B; sleep 2.5
    fi
fi
BLOCKED=$(db_sql "SELECT COUNT(*) FROM blocked_numbers WHERE number='$SEND';")
if [ "${BLOCKED:-0}" -ge 1 ]; then
    pass "sender is on the block list"
else
    fail "could not block $SEND from the row sheet - cannot exercise the fix"
    echo "Results: $P passed, $F failed"; exit 1
fi
sleep 3

info "The live notification is gone after the block"
LEFT=$(live_ids | grep -c "^${CID}$" || true)
[ "${LEFT:-0}" = "0" ] && pass "blocked thread's notification cancelled (badge drops its number)" \
                       || fail "notification for id $CID still live after blocking"

info "Later messages from the blocked sender never re-badge the icon"
adb_ emu sms send "$SEND" "blocked badge probe f $MARK" >/dev/null 2>&1; sleep 6
AFTER=$(number_for_id "$CID")
[ -z "$AFTER" ] && pass "no notification posted for a blocked sender" \
                 || fail "blocked sender's new message posted number=${AFTER:-none}"

info "Blocking hides the thread from the badge, not the messages from the user"
# The messages stay in Spam & Blocked: the two seeded ones plus the one that
# arrived after the block. A blocked conversation is deliberately not counted
# as unread (spam is not an inbox), so the count is allowed to reset - what
# must not happen is the thread losing content or the flag.
KEPT=$(db_sql "SELECT COUNT(*) FROM messages m JOIN conversations c ON c.id=m.conversation_id WHERE c.address='$SEND';")
[ "${KEPT:-0}" -ge 3 ] && pass "all messages kept in the blocked conversation ($KEPT)" \
                       || fail "blocked conversation lost messages ($KEPT of 3)"
FLAG=$(db_sql "SELECT blocked FROM conversations WHERE address='$SEND';")
[ "${FLAG:-0}" = "1" ] && pass "conversation flagged blocked=1" || fail "blocked flag not set"

echo
echo "Results: $P passed, $F failed"
exit $((F > 0))
