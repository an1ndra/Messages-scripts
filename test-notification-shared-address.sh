#!/usr/bin/env bash
# Regression (#524): a private text from someone you also share a group with
# must notify on the private chat, not on the group.
#
# A group started from a 1:1 carries that contact's address, so two conversation
# rows answer to the same number. Filing an inbound message already knew the
# private chat outranks the group, but the notifier asked the same question with
# its own query and took whichever row came first — the older group. The
# reporter saw one person's texts pop the family group's notification, and it
# outlived deleting the group's messages, because the group was still the row
# being notified on.
#
# Invariants:
#   - the message is filed into the private chat
#   - the notification exists under the private chat's id and carries the message
#   - no notification exists under the group's id
#
# Run: scripts/test-notification-shared-address.sh
source "$(dirname "$0")/env.sh"
set -uo pipefail

PASS=0
FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
info() { printf '\n=== %s ===\n' "$1"; }

MARK="sh$(date +%s)$$"
A="+1555844${MARK: -3}"
B="+1555845${MARK: -3}"
TITLE="Shared $MARK"

dumps() { adb_ shell "dumpsys notification --noredact 2>/dev/null" | tr -d '\r'; }
sql() {
    adb_ shell "run-as $PKG sqlite3 databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r' && return 0
    adb_ shell "su -c \"sqlite3 /data/data/$PKG/databases/messages.db \\\"$1\\\"\"" 2>/dev/null | tr -d '\r' || true
}
num() { tr -d '\r\n' | head -1; }

block_for_id() {
    dumps | awk -v want="$1" -v pkg="$PKG" '
        /NotificationRecord/ { inblk = 0 }
        /NotificationRecord/ && index($0, "pkg=" pkg) && $0 ~ ("id=" want "([^0-9]|$)") { inblk = 1 }
        inblk { print }
    '
}
# grep -q closes the pipe on its first match, which kills awk upstream and makes
# the pipeline non-zero under `set -o pipefail`; -c reads the whole input.
record_exists() { block_for_id "$1" | grep -c "NotificationRecord" >/dev/null; }
blk_has() { block_for_id "$1" | grep -c "$2" >/dev/null; }

cancel_id() {
    for _ in 1 2 3; do
        record_exists "$1" || return 0
        adb_ shell cmd notification cancel "$PKG" "$1" tag 0 >/dev/null 2>&1
        sleep 1
    done
}

adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1 || true

info "Seed the group first, so it is the older row for that address"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
NOW=$(( $(date +%s) * 1000 ))
sql "INSERT INTO conversations(address,name,snippet,timestamp,unread_count,group_title)
     VALUES('$A','$TITLE','${MARK}old',$((NOW - 6000)),0,'$TITLE');" >/dev/null
GRP=$(sql "SELECT id FROM conversations WHERE group_title='$TITLE';" | num)
sql "INSERT OR IGNORE INTO conversation_recipients(conversation_id,address) VALUES($GRP,'$A');" >/dev/null
sql "INSERT OR IGNORE INTO conversation_recipients(conversation_id,address) VALUES($GRP,'$B');" >/dev/null
sql "INSERT INTO messages(conversation_id,body,timestamp,is_me,status)
     VALUES($GRP,'${MARK}old',$((NOW - 6000)),0,'received');" >/dev/null
sql "INSERT INTO conversations(address,name,snippet,timestamp,unread_count)
     VALUES('$A','$A','${MARK}old',$((NOW - 5000)),0);" >/dev/null
# A real 1:1 owns exactly one recipient row; that is what outranks the group.
# Without it the tie-break sees a member-less row and the group wins.
sql "INSERT OR IGNORE INTO conversation_recipients(conversation_id,address)
     VALUES((SELECT id FROM conversations WHERE address='$A' AND group_title=''),
            '$A');" >/dev/null

if [ -z "$GRP" ]; then
    fail "could not seed the group conversation"
    printf '\n=== RESULTS: %s passed, %s failed ===\n' "$PASS" "$FAIL"
    exit 1
fi
PRIV=$(sql "SELECT id FROM conversations WHERE address='$A' AND id<>$GRP;" | num)
if [ -z "$PRIV" ]; then
    fail "could not seed the private conversation"
    printf '\n=== RESULTS: %s passed, %s failed ===\n' "$PASS" "$FAIL"
    exit 1
fi
[ "$GRP" -lt "$PRIV" ] \
    && pass "group ($GRP) is the older row, private chat is $PRIV" \
    || fail "seed order is wrong: group=$GRP private=$PRIV"

info "A text arrives from that person"
adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 5
cancel_id "$GRP"
cancel_id "$PRIV"

sent=0
for try in 1 2 3; do
    adb_ emu sms send "$A" "${MARK}priv" >/dev/null 2>&1
    for _ in $(seq 1 20); do
        if [ "$(sql "SELECT count(*) FROM messages WHERE conversation_id=$PRIV AND body='${MARK}priv';" | num)" = "1" ]; then
            sent=1; break 2
        fi
        sleep 1
    done
done
[ "$sent" = "1" ] \
    && pass "the message was filed into the private chat ($PRIV)" \
    || fail "the message never landed in the private chat"
[ "$(sql "SELECT count(*) FROM messages WHERE conversation_id=$GRP AND body='${MARK}priv';" | num)" = "0" ] \
    && pass "the group did not receive it" \
    || fail "the message was filed into the group as well"

info "The notification follows the message"
record_exists "$PRIV" \
    && pass "a notification exists under the private chat's id" \
    || fail "no notification record with id=$PRIV (the private chat)"
blk_has "$PRIV" "${MARK}priv" \
    && pass "it carries the new message" \
    || fail "the private chat's record does not carry ${MARK}priv"
record_exists "$GRP" \
    && fail "a notification exists under the group's id ($GRP) — that is the reported bug" \
    || pass "no notification under the group's id"

info "No crashes"
adb_ shell "logcat -d -b crash" 2>/dev/null | grep -c "$PKG" >/dev/null \
    && fail "crash logged for $PKG" \
    || pass "no crashes"

cancel_id "$GRP"
cancel_id "$PRIV"
sql "DELETE FROM messages WHERE conversation_id IN ($GRP,$PRIV);" >/dev/null
sql "DELETE FROM conversation_recipients WHERE conversation_id=$GRP;" >/dev/null
sql "DELETE FROM conversations WHERE id IN ($GRP,$PRIV);" >/dev/null

printf '\n=== RESULTS: %s passed, %s failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
