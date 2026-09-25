#!/usr/bin/env bash
# Regression for GM-like "Spam & blocked": blocking a number moves its
# conversation out of the inbox into the Spam & blocked folder, later messages
# from that number are kept there (no notification), and Unblock restores it.
source "$(dirname "$0")/env.sh"

TAIL=$(printf '%04d' $((RANDOM % 10000)))
SENDER="+1555123$TAIL"
PROBE="spam-probe-$TAIL"
SECOND="spam-second-$TAIL"

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

db() { adb_ shell "run-as $PKG sh -c 'sqlite3 databases/messages.db \"$1\"'" 2>/dev/null | tr -d '\r'; }
conv_blocked() {
    adb_ shell "run-as $PKG sh -c 'sqlite3 databases/messages.db \"SELECT address,blocked FROM conversations;\"'" 2>/dev/null \
        | tr -d '\r' | awk -F'|' -v t="$TAIL" 'index($1,t) {print $2; exit}'
}
msg_count() {
    adb_ shell "run-as $PKG sh -c 'sqlite3 databases/messages.db \"SELECT COUNT(*) FROM messages WHERE body LIKE \\\"%$1%\\\";\"'" 2>/dev/null | tr -d '\r'
}
blocked_count() {
    adb_ shell "run-as $PKG sh -c 'sqlite3 databases/messages.db \"SELECT COUNT(*) FROM blocked_numbers WHERE number LIKE \\\"%$TAIL%\\\";\"'" 2>/dev/null | tr -d '\r'
}

lowest_text_center() {
    dump_ui || return 1
    python3 - "$1" <<'PY2'
import re, sys
s = open('/tmp/opencode/messages-tests/ui.xml', encoding='utf-8', errors='replace').read()
best = None
for m in re.finditer(r'<node[^>]*text="%s"[^>]*>' % re.escape(sys.argv[1]), s):
    b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', m.group(0))
    if not b:
        continue
    x1, y1, x2, y2 = map(int, b.groups())
    if best is None or y1 > best[0]:
        best = (y1, (x1 + x2) // 2, (y1 + y2) // 2)
print(f"{best[1]} {best[2]}" if best else "")
PY2
}

# wait_for_text does not scroll, and the list is long once earlier scripts have
# left rows behind, so the restored conversation can sit below the fold.
wait_for_text_scrolling() {
    local target="$1" tries="${2:-10}" i
    for i in $(seq 1 "$tries"); do
        dump_ui >/dev/null 2>&1 || true
        if grep -c "$target" "$TMP/ui.xml" >/dev/null 2>&1; then
            return 0
        fi
        adb_ shell input swipe 540 1700 540 1100 250 >/dev/null 2>&1
        sleep 1
    done
    return 1
}

cleanup() {
    adb_ shell "run-as $PKG sh -c 'sqlite3 databases/messages.db \"DELETE FROM blocked_numbers WHERE number LIKE \\\"%$TAIL%\\\";\"'" >/dev/null 2>&1
    local ids
    ids=$(adb_ shell "run-as $PKG sh -c 'sqlite3 databases/messages.db \"SELECT id,address FROM conversations;\"'" 2>/dev/null \
        | tr -d '\r' | awk -F'|' -v t="$TAIL" 'index($2,t) {print $1}' | paste -sd, -)
    [ -n "$ids" ] && adb_ shell "run-as $PKG sh -c 'sqlite3 databases/messages.db \"DELETE FROM conversations WHERE id IN ($ids);\"'" >/dev/null 2>&1
    adb_ shell "run-as $PKG sh -c 'sqlite3 databases/messages.db \"DELETE FROM messages WHERE body LIKE \\\"%$PROBE%\\\" OR body LIKE \\\"%$SECOND%\\\";\"'" >/dev/null 2>&1
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
}
trap cleanup EXIT

adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1
adb_ shell pm grant "$PKG" android.permission.RECEIVE_SMS 2>/dev/null
adb_ shell pm grant "$PKG" android.permission.POST_NOTIFICATIONS 2>/dev/null

info "Seed a conversation from $SENDER"
adb_ emu sms send "$SENDER" "$PROBE" >/dev/null 2>&1; sleep 4
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 6

info "Block via the long-press sheet"
c=$(center_of_contains "$TAIL") || { bad "seed row not on list"; echo "Results: $PASS passed, $FAIL failed"; exit 1; }
xy=($c)
adb_ shell input swipe "${xy[0]}" "${xy[1]}" "${xy[0]}" "${xy[1]}" 900; sleep 1.2
tap_text "Block" >/dev/null 2>&1; sleep 1.5
[ "$(blocked_count)" = "1" ] && ok "number stored in the blocklist" || bad "number not in the blocklist"
[ "$(conv_blocked)" = "1" ] && ok "conversation flagged blocked" || bad "conversation not flagged blocked"

info "Blocked conversation leaves the main list"
dump_ui
grep -q "$TAIL" "$TMP/ui.xml" \
    && bad "blocked conversation still in the main list" \
    || ok "blocked conversation hidden from the main list"

info "A later message from the blocked number is kept (no notification)"
adb_ emu sms send "$SENDER" "$SECOND" >/dev/null 2>&1; sleep 4
[ "$(msg_count "$SECOND")" = "1" ] && ok "blocked SMS kept in the database" || bad "blocked SMS missing"
NOTIF=$(adb_ shell dumpsys notification --noredact 2>/dev/null | grep -c "$SECOND")
[ "$NOTIF" = "0" ] && ok "no notification for the blocked SMS" || bad "notification posted ($NOTIF)"

info "Settings > Spam & blocked lists it"
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null 2>&1; sleep 3
for i in $(seq 1 8); do
    dump_ui
    grep -q 'Spam &amp; Blocked' "$TMP/ui.xml" && break
    adb_ shell input swipe 540 1700 540 900 300 >/dev/null 2>&1; sleep 0.7
done
c=$(center_of_contains "Spam &amp; Blocked") && adb_ shell input tap $c
sleep 1.5
dump_ui
grep -q "$TAIL" "$TMP/ui.xml" \
    && ok "blocked conversation listed in Spam & blocked" \
    || bad "blocked conversation not in Spam & blocked"
grep -q 'content-desc="[^"]*Blocked' "$TMP/ui.xml" \
    && ok "row exposed as blocked to accessibility services" \
    || bad "blocked designation missing"

info "Unblock restores it to the inbox"
tap_text "Unblock" >/dev/null 2>&1; sleep 1.5
[ "$(conv_blocked)" = "0" ] && ok "conversation unblocked" || bad "conversation still blocked"
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 4
# Poll: the list renders a loading skeleton while the startup sync settles, so a
# single dump after a fixed sleep races it and the row is simply absent.
wait_for_text_scrolling "$TAIL" 14 \
    && ok "conversation back in the inbox" \
    || bad "conversation not restored to the inbox"

info "Deleting a blocked message sticks even if you leave straight away (#219)"
DTAIL=$(printf '%04d' $((RANDOM % 10000)))
DSENDER="+1555124$DTAIL"
DPROBE="spam-del-$DTAIL"
DPROBE2="spam-del2-$DTAIL"
NOW=$(($(date +%s) * 1000))
blocked_msgs() { db "SELECT COUNT(*) FROM messages WHERE blocked_reason!=\\\"\\\" AND body LIKE \\\"%$DTAIL%\\\";"; }
conv_blocked_flag() { db "SELECT blocked FROM conversations WHERE address=\\\"$DSENDER\\\";"; }

# Seed the blocked state directly: the bugs are in the screen's actions, and
# seeding keeps this independent of the long-press block flow above.
adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
db "INSERT INTO conversations(address,name,snippet,timestamp,unread_count,blocked) VALUES(\\\"$DSENDER\\\",\\\"$DSENDER\\\",\\\"$DPROBE\\\",$NOW,0,1);" >/dev/null
db "INSERT INTO blocked_numbers(number,timestamp) VALUES('$DSENDER',$NOW);" >/dev/null
db "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,deleted_at,blocked_reason) SELECT id,\\\"$DPROBE\\\",$NOW,0,\\\"received\\\",$NOW,\\\"keyword\\\" FROM conversations WHERE address=\\\"$DSENDER\\\";" >/dev/null
db "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,deleted_at,blocked_reason) SELECT id,\\\"$DPROBE2\\\",$NOW,0,\\\"received\\\",$NOW,\\\"keyword\\\" FROM conversations WHERE address=\\\"$DSENDER\\\";" >/dev/null
[ "$(blocked_msgs)" = "2" ] && ok "seeded two blocked messages" || bad "could not seed blocked messages"

open_spam_blocked() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
    adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null 2>&1; sleep 3
    for i in $(seq 1 8); do
        dump_ui
        grep -q 'Spam &amp; Blocked' "$TMP/ui.xml" && break
        adb_ shell input swipe 540 1700 540 900 300 >/dev/null 2>&1; sleep 0.7
    done
    c=$(center_of_contains "Spam &amp; Blocked") && adb_ shell input tap $c
    sleep 2
}

open_spam_blocked
tap_text "Messages" >/dev/null 2>&1; sleep 2
dump_ui
grep -q "$DTAIL" "$TMP/ui.xml" \
    && ok "blocked messages listed in the Messages tab" \
    || bad "blocked messages missing from the Messages tab"

# Tap delete, then leave well inside the snackbar window: the old code only issued
# the delete from a coroutine that leaving the screen cancelled.
c=$(center_of_contains "Delete") && adb_ shell input tap $c
sleep 1
adb_ shell input keyevent 4 >/dev/null 2>&1
sleep 3
[ "$(blocked_msgs)" = "1" ] \
    && ok "the delete was applied even though the screen was left" \
    || bad "the delete was cancelled by leaving the screen (still $(blocked_msgs))"

info "Empty clears the Messages tab"
open_spam_blocked
tap_text "Messages" >/dev/null 2>&1; sleep 2
dump_ui
grep -q 'text="Empty"' "$TMP/ui.xml" \
    && ok "an Empty action is offered" \
    || bad "no Empty action in the app bar"
tap_text "Empty" >/dev/null 2>&1; sleep 1.5
dump_ui
c=$(lowest_text_center "Empty")
[ -n "$c" ] && adb_ shell input tap $c
sleep 1.5
# the confirm dialog's own Empty button is the lowest one on screen
c=$(lowest_text_center "Empty")
[ -n "$c" ] && adb_ shell input tap $c
sleep 2.5
[ "$(blocked_msgs)" = "0" ] \
    && ok "Empty removed every blocked message" \
    || bad "Empty left $(blocked_msgs) blocked messages"

info "A blocked conversation can be deleted, not just unblocked"
open_spam_blocked
tap_text "Conversations" >/dev/null 2>&1; sleep 2
dump_ui
grep -q 'text="Delete"' "$TMP/ui.xml" \
    && ok "a Delete action is offered on the blocked conversation" \
    || bad "no Delete action on the blocked conversation"
c=$(center_of_contains "Delete") && adb_ shell input tap $c
sleep 2.5
[ "$(conv_blocked_flag)" = "0" ] \
    && ok "deleting the conversation cleared the block" \
    || bad "conversation still blocked after delete"

# leave nothing behind
adb_ shell am force-stop "$PKG" >/dev/null 2>&1
db "DELETE FROM blocked_numbers WHERE number='$DSENDER';" >/dev/null 2>&1
db "DELETE FROM conversations WHERE address='$DSENDER';" >/dev/null 2>&1
db "DELETE FROM messages WHERE body LIKE '%$DTAIL%';" >/dev/null 2>&1

echo ""
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
