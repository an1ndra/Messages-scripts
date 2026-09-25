#!/usr/bin/env bash
# Regression: notifications are grouped per conversation (#219).
#
# The reporter asked for "notification shows all messages of 1 person when we
# extend that notification instead of just showing last message". Each post used
# to replace the record with a BigTextStyle body, so expanding showed one long
# message and nothing of what came before it.
#
# A grouped notification has to be rebuilt on every post, because notify(id, ...)
# replaces the record rather than appending to it. The invariants that matter:
#   - one record per sender, carrying that sender's recent messages
#   - still number=1 per record, so the launcher badge is unaffected
#   - two senders never share or clobber each other's history
#   - dismissing one conversation leaves the other notification alone
#
# Assertions are scoped to the test's own conversation ids rather than counting
# every record the system holds, which includes unrelated notifications.
source "$(dirname "$0")/env.sh"
set -uo pipefail

PASS=0
FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
info() { printf '\n=== %s ===\n' "$1"; }

MARK="grp$(date +%s)$$"
A="+1555888${MARK: -3}"
B="+1555889${MARK: -3}"

dumps() { adb_ shell "dumpsys notification --noredact 2>/dev/null" | tr -d '\r'; }
sql() {
    adb_ shell "run-as $PKG sqlite3 databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r' && return 0
    adb_ shell "su -c \"sqlite3 /data/data/$PKG/databases/messages.db \\\"$1\\\"\"" 2>/dev/null | tr -d '\r' || true
}
convo_id() { sql "SELECT id FROM conversations WHERE address='$1';" | tr -d '\r\n'; }

# The console drops some `emu sms send` bursts, so a fixed sleep leaves the
# assertions reading a history that never arrived. Resend until the body is
# actually in the database.
send_wait() {
    local num="$1" body="$2" try
    for try in 1 2 3; do
        adb_ emu sms send "$num" "$body" >/dev/null 2>&1
        for _ in $(seq 1 20); do
            # Scoped to the sender: the two senders deliberately share body text, so
            # matching on body alone would return on the other sender's row.
            if [ "$(sql "SELECT count(*) FROM messages m JOIN conversations c ON c.id=m.conversation_id WHERE m.body='$body' AND c.address='$num';" | tr -d '\r\n')" != "0" ]; then
                return 0
            fi
            sleep 1
        done
    done
    return 1
}

# The NotificationRecord block for one id, so one sender's lines are never read
# out of another sender's record.
block_for_id() {
    dumps | awk -v want="$1" '
        /NotificationRecord/ { inblk = 0 }
        /NotificationRecord/ && $0 ~ ("id=" want "([^0-9]|$)") { inblk = 1 }
        inblk { print }
    '
}
record_exists() { blk_has "$1" "NotificationRecord"; }
line_count() { block_for_id "$1" | grep -o "text=$MARK[0-9]*" | sort -u | grep -c "text=$MARK" || true; }

# grep -q closes the pipe on its first match, which kills awk upstream and makes
# the whole pipeline non-zero under `set -o pipefail`. grep -c reads all input.
blk_has() { block_for_id "$1" | grep -c "$2" >/dev/null; }

cancel_id() {
    for _ in 1 2 3; do
        record_exists "$1" || return 0
        adb_ shell cmd notification cancel "$PKG" "$1" tag 0 >/dev/null 2>&1
        sleep 1
    done
}

info "Three messages from one sender become one grouped notification"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 5
for i in 1 2 3; do
    send_wait "$A" "${MARK}$i" || fail "message $i from the first sender never arrived"
done
IDA=$(convo_id "$A")
[ -n "$IDA" ] && pass "conversation for the first sender resolved ($IDA)" \
    || { fail "could not resolve the conversation id for $A"; exit 1; }

record_exists "$IDA" \
    && pass "one record exists for the sender" \
    || fail "no notification record for the sender"
n=$(line_count "$IDA")
[ "$n" = "3" ] \
    && pass "the record carries all three messages" \
    || fail "the record carries $n of 3 messages"
blk_has "$IDA" "MessagingStyle" \
    && pass "the record uses MessagingStyle" \
    || fail "the record is not a MessagingStyle"
blk_has "$IDA" "android.conversationTitle=" \
    && pass "the record names the conversation" \
    || fail "the record has no conversation title"
blk_has "$IDA" "number=1" \
    && pass "number is still 1 per conversation" \
    || fail "number is not 1, so the launcher badge would change"
blk_has "$IDA" "ranker_group" \
    && fail "a system ranker_group record was created" \
    || pass "no stray ranker_group record"

info "The history is capped, not unbounded"
for i in 4 5 6 7 8; do
    send_wait "$A" "${MARK}$i" || fail "message $i never arrived"
done
n=$(line_count "$IDA")
[ "$n" = "5" ] \
    && pass "history is capped at 5 lines (got $n)" \
    || fail "expected 5 lines after 8 messages, got $n"
newest=$(block_for_id "$IDA" | grep -o "text=$MARK[0-9]*" | tail -1)
[ "$newest" = "text=${MARK}8" ] \
    && pass "the newest message is the last line" \
    || fail "newest line is '$newest', expected text=${MARK}8"

info "A second sender gets its own separate record"
send_wait "$B" "${MARK}1" || fail "the second sender's message never arrived"
IDB=$(convo_id "$B")
if [ -z "$IDB" ]; then
    fail "could not resolve the conversation id for $B"
else
    record_exists "$IDB" \
        && pass "the second sender has its own record" \
        || fail "the second sender has no record"
    [ "$(line_count "$IDB")" = "1" ] \
        && pass "the second sender's record holds only its own message" \
        || fail "the second sender's record has $(line_count "$IDB") lines, expected 1"
    [ "$(line_count "$IDA")" = "5" ] \
        && pass "the first sender's history was not clobbered" \
        || fail "the first sender's history changed to $(line_count "$IDA") lines"
fi

info "Opening one conversation leaves the other alone"
adb_ shell am start -n "$ACT" --es open_conversation_address "$A" >/dev/null 2>&1
sleep 3
record_exists "$IDA" \
    && fail "the opened conversation's record was not dismissed" \
    || pass "the opened conversation's record was dismissed"
[ -n "$IDB" ] && { record_exists "$IDB" \
    && pass "the other sender's notification survives" \
    || fail "the other sender's notification was lost"; }

info "A read chat notifies with only the new message, and still names the sender"
# The reporter's complaint: expanding a chat whose last messages were all theirs
# showed the whole recent history, including their own replies. Read state lives
# only in conversations.unread_count, so a read backlog has to drop out of the
# notification. The AVD radio drops repeated `emu sms send` bursts, so the backlog
# is seeded into the database and only the message under test is injected.
C="+1555887${MARK: -3}"
NOW=$(($(date +%s) * 1000))
CID=$(sql "INSERT INTO conversations(address,name,timestamp,unread_count) VALUES('$C','$C',$NOW,0); SELECT id FROM conversations WHERE address='$C';" | tail -1 | tr -d '\r\n')
[ -n "$CID" ] || CID=$(convo_id "$C")
if [ -z "$CID" ]; then
    fail "could not seed a conversation for $C"
else
    for i in 1 2 3; do
        sql "INSERT INTO messages(conversation_id,body,timestamp,is_me,status) VALUES($CID,'${MARK}o$i',$((NOW + i)),0,'received');" >/dev/null
    done
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
    adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 5
    send_wait "$C" "${MARK}z" || fail "the message under test never arrived"
    u=$(sql "SELECT unread_count FROM conversations WHERE id=$CID;" | tr -d '\r\n')
    [ "$u" = "1" ] \
        && pass "the new message is the only unread one (unread=$u)" \
        || fail "unread is $u, expected 1"
    blk_has "$CID" "text=${MARK}z" \
        && pass "the notification carries the new message" \
        || fail "the notification does not carry the new message"
    blk_has "$CID" "${MARK}o1" \
        && fail "the notification still shows read messages from before" \
        || pass "read messages from before are not in the notification"
    blk_has "$CID" "$C" \
        && pass "the single-sender record still names the sender" \
        || fail "the record does not identify $C anywhere"
    sql "DELETE FROM conversations WHERE id=$CID;" >/dev/null
fi

info "No crashes"
adb_ shell "logcat -d -b crash" 2>/dev/null | grep -c "$PKG" >/dev/null \
    && fail "crash logged for $PKG" \
    || pass "no crashes"

adb_ shell input keyevent 4 >/dev/null 2>&1
printf '\n=== RESULTS: %s passed, %s failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
