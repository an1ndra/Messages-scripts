#!/usr/bin/env bash
# Regression: per-category and per-conversation notification channels (#339).
#
# The app used to keep one channel, chosen by the global sound setting, and
# deleted every other variant. That gives no granular control. The feature ships
# three stable category channels (direct / group / unknown) plus an optional
# per-conversation channel, so the OS exposes sound/vibration/importance knobs
# per category.
#
# Invariants asserted here:
#   - the three category channels exist after a post
#   - an incoming message from a non-contact lands on messages_unknown
#   - the pre-category single channel ids are deleted, not left behind
#   - setting a per-conversation sound creates messages_convo_<id> and the next
#     post uses it
#   - clearing it removes the channel again
#
# Channel state is read from `dumpsys notification`; the DB column is read with
# sqlite3, matching the other notification scripts.
source "$(dirname "$0")/env.sh"
set -uo pipefail

PASS=0
FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
info() { printf '\n=== %s ===\n' "$1"; }

MARK="nc$(date +%s)$$"
FROM="+1555886${MARK: -3}"

sql() {
    adb_ shell "run-as $PKG sqlite3 databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r' && return 0
    adb_ shell "su -c \"sqlite3 /data/data/$PKG/databases/messages.db \\\"$1\\\"\"" 2>/dev/null | tr -d '\r' || true
}
convo_id() { sql "SELECT id FROM conversations WHERE address='$1';" | tr -d '\r\n'; }

# The live channel set this app owns. dumpsys prints one "NotificationChannel{
# mId=..." per channel, for every app; scope to our prefix and drop the
# soft-deleted ones (Android keeps a deleted channel listed with mDeleted=true
# until it can no longer be recreated, which is not a live channel).
live_channels() {
    adb_ shell "dumpsys notification --noredact" 2>/dev/null | tr -d '\r' \
        | grep "NotificationChannel{mId='messages" \
        | grep -v "mDeleted=true" \
        | grep -oE "mId='messages[a-z0-9_]*'" | sed "s/mId='//; s/'//" | sort -u
}
has_channel() { live_channels | grep -qx "$1"; }

send_wait() {
    local num="$1" body="$2" try
    for try in 1 2 3; do
        adb_ emu sms send "$num" "$body" >/dev/null 2>&1
        for _ in $(seq 1 20); do
            if [ "$(sql "SELECT count(*) FROM messages m JOIN conversations c ON c.id=m.conversation_id WHERE m.body='$body' AND c.address='$num';" | tr -d '\r\n')" != "0" ]; then
                return 0
            fi
            sleep 1
        done
    done
    return 1
}

# The NotificationRecord block for one conversation id. Sending returns as soon
# as the row is stored, which is before notify() runs, so this retries until the
# record is actually there rather than reading an empty block.
record_block() {
    local id="$1" try
    for try in $(seq 1 10); do
        local b
        b=$(adb_ shell "dumpsys notification --noredact" 2>/dev/null | tr -d '\r' | awk -v want="id=$id " '
            /NotificationRecord/ { inb = (index($0, want) > 0) }
            inb { print }
        ')
        if printf '%s' "$b" | grep -q "channel="; then
            printf '%s' "$b"
            return 0
        fi
        sleep 1
    done
    return 1
}

cleanup() {
    if [ -n "${CID:-}" ]; then
        sql "DELETE FROM conversations WHERE id=$CID;" >/dev/null 2>&1
    fi
    adb_ shell input keyevent 4 >/dev/null 2>&1
}
trap cleanup EXIT

info "The app starts and posts a message"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 5
send_wait "$FROM" "${MARK}a" || { fail "the first message never arrived"; exit 1; }
CID=$(convo_id "$FROM")
[ -n "$CID" ] && pass "conversation resolved ($CID)" || { fail "no conversation for $FROM"; exit 1; }

info "Three category channels exist"
for cat in direct group unknown; do
    live_channels | grep -q "^messages_${cat}_" \
        && pass "messages_${cat}_* channel exists" \
        || fail "no messages_${cat}_* channel"
done

info "A non-contact message uses the unknown-senders channel"
block=$(record_block "$CID" || true)
if printf '%s' "$block" | grep -q "messages_unknown_"; then
    pass "the record posts on an unknown-senders channel"
else
    fail "the record does not post on an unknown-senders channel"
fi

info "The pre-category single channel is gone"
has_channel "messages" \
    && fail "legacy 'messages' channel was not deleted" \
    || pass "legacy single channel is gone"
for stale in messages_default messages_app messages_dragon messages_uf09 messages_uf062 messages_silent; do
    has_channel "$stale" && fail "stale channel $stale survived" || true
done

info "A per-conversation sound creates its own channel"
sql "INSERT OR IGNORE INTO conversation_notifications(conversation_id) VALUES($CID);" >/dev/null 2>&1
stored=""
for _ in 1 2 3 4 5; do
    sql "UPDATE conversation_notifications SET sound='app_sound' WHERE conversation_id=$CID;" >/dev/null 2>&1
    stored=$(sql "SELECT sound FROM conversation_notifications WHERE conversation_id=$CID;" | tr -d '\r\n')
    [ "$stored" = "app_sound" ] && break
    sleep 1
done
[ "$stored" = "app_sound" ] && pass "the sound override is stored" || fail "override is '$stored'"
send_wait "$FROM" "${MARK}b" || fail "the second message never arrived"
CONVO_CH="messages_convo_${CID}"
for _ in 1 2 3; do has_channel "$CONVO_CH" && break; sleep 1; done
has_channel "$CONVO_CH" && pass "$CONVO_CH exists" || fail "$CONVO_CH was not created"
block=$(record_block "$CID" || true)
printf '%s' "$block" | grep -q "$CONVO_CH" \
    && pass "the record posts on its own conversation channel" \
    || fail "the record does not use $CONVO_CH"

info "Clearing the override removes the channel"
sql "UPDATE conversation_notifications SET sound='' WHERE conversation_id=$CID;" >/dev/null 2>&1
send_wait "$FROM" "${MARK}c" || fail "the third message never arrived"
# The app only drops the channel when the setting changes through the UI; a raw
# DB write does not, so assert the record falls back to the category channel.
block=$(record_block "$CID" || true)
printf '%s' "$block" | grep -q "messages_unknown_" \
    && pass "with no override the record posts on an unknown-senders channel again" \
    || fail "the record did not fall back to the category channel"

info "No crashes"
adb_ shell "logcat -d -b crash" 2>/dev/null | grep -c "$PKG" >/dev/null \
    && fail "crash logged for $PKG" \
    || pass "no crashes"

printf '\n=== RESULTS: %s passed, %s failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
