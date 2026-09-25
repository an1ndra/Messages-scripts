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
    adb_ emu sms send "$A" "${MARK}$i" >/dev/null 2>&1
    sleep 3
done
sleep 2
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
    adb_ emu sms send "$A" "${MARK}$i" >/dev/null 2>&1
    sleep 2
done
sleep 2
n=$(line_count "$IDA")
[ "$n" = "5" ] \
    && pass "history is capped at 5 lines (got $n)" \
    || fail "expected 5 lines after 8 messages, got $n"
newest=$(block_for_id "$IDA" | grep -o "text=$MARK[0-9]*" | tail -1)
[ "$newest" = "text=${MARK}8" ] \
    && pass "the newest message is the last line" \
    || fail "newest line is '$newest', expected text=${MARK}8"

info "A second sender gets its own separate record"
adb_ emu sms send "$B" "${MARK}1" >/dev/null 2>&1
sleep 4
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

info "No crashes"
adb_ shell "logcat -d -b crash" 2>/dev/null | grep -c "$PKG" >/dev/null \
    && fail "crash logged for $PKG" \
    || pass "no crashes"

adb_ shell input keyevent 4 >/dev/null 2>&1
printf '\n=== RESULTS: %s passed, %s failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
