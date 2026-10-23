#!/usr/bin/env bash
# Regression: per-conversation notification channels (#339).
#
# The app used to keep one channel, chosen by the global sound setting. A
# per-chat channel is the only way Android offers per-chat sound/vibration/
# importance knobs, so every conversation now owns one, titled after the chat
# and posted to for every message. The three category channels remain as the
# default for senders with no conversation row yet.
#
# Invariants asserted here:
#   - an incoming message creates messages_convo_<id> and posts on it
#   - the conversation channel is named after the chat, not the id
#   - the three category channels still exist
#   - the pre-category single channel ids are deleted, not left behind
#   - existing conversations get their channel at launch, before any message
#   - a conversation's sound override is applied when its channel is created
#
# Channel state is read from `dumpsys notification`; rows are seeded with
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
SEEDED="+1555777${MARK: -3}"
OVERRIDE="+1555666${MARK: -3}"

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

# The display name Android shows for one channel. dumpsys prints it unquoted
# (mName=Sarah, mDescription=...), and an absent description is the token
# "hasDescription" being missing entirely, so anchor on the next field.
channel_name() {
    adb_ shell "dumpsys notification --noredact" 2>/dev/null | tr -d '\r' \
        | grep -F "NotificationChannel{mId='$1'" | grep -v "mDeleted=true" | head -1 \
        | grep -oE "mName=[^,]*, mDescription=" | head -1 \
        | sed -E "s/^mName=//; s/, mDescription=$//"
}

# The sound Android plays for one channel.
channel_sound() {
    adb_ shell "dumpsys notification --noredact" 2>/dev/null | tr -d '\r' \
        | grep -F "NotificationChannel{mId='$1'" | grep -v "mDeleted=true" | head -1 \
        | grep -oE "mSound=[^,]*" | head -1 | cut -d= -f2-
}

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

# The NotificationRecord block for one conversation id. Sending returns as
# soon as the row is stored, which is before notify() runs, so this retries until
# the record is actually there rather than reading an empty block.
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

launch() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
    adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 5
}

cleanup() {
    for addr in "$FROM" "$SEEDED" "$OVERRIDE"; do
        sql "DELETE FROM conversations WHERE address='$addr';" >/dev/null 2>&1
    done
    adb_ shell input keyevent 4 >/dev/null 2>&1
}
trap cleanup EXIT

info "The app starts and posts a message"
launch
send_wait "$FROM" "${MARK}a" || { fail "the first message never arrived"; exit 1; }
CID=$(convo_id "$FROM")
[ -n "$CID" ] && pass "conversation resolved ($CID)" || { fail "no conversation for $FROM"; exit 1; }

info "The conversation owns a channel, without any sound override"
convo_ch() { live_channels | grep "^messages_convo_${1}_" | head -1; }
CONVO_CH=""
for _ in 1 2 3; do CONVO_CH=$(convo_ch "$CID"); [ -n "$CONVO_CH" ] && break; sleep 1; done
[ -n "$CONVO_CH" ] && pass "$CONVO_CH exists" || fail "no messages_convo_${CID}_* channel was created"
block=$(record_block "$CID" || true)
printf '%s' "$block" | grep -q "messages_convo_${CID}_" \
    && pass "the record posts on its own conversation channel" \
    || fail "the record does not use its own conversation channel"

name=$(channel_name "$CONVO_CH")
echo "  channel name: ${name:-<empty>}"
{ [ -n "$name" ] && [ "$name" != "$CONVO_CH" ]; } \
    && pass "the channel is named after the chat" \
    || fail "the channel is not named after the chat ('$name')"

info "Three category channels still exist"
for cat in direct group unknown; do
    live_channels | grep -q "^messages_${cat}_" \
        && pass "messages_${cat}_* channel exists" \
        || fail "no messages_${cat}_* channel"
done

info "The pre-category single channel is gone"
has_channel "messages" \
    && fail "legacy 'messages' channel was not deleted" \
    || pass "legacy single channel is gone"
for stale in messages_default messages_app messages_dragon messages_uf09 messages_uf062 messages_silent; do
    has_channel "$stale" && fail "stale channel $stale survived" || true
done

info "Existing conversations get a channel at launch, before any message"
sql "INSERT INTO conversations(address,name,timestamp) VALUES('$SEEDED','Seed chat',strftime('%s','now')*1000);" >/dev/null 2>&1
SEED_ID=$(convo_id "$SEEDED")
[ -n "$SEED_ID" ] && pass "seeded conversation ($SEED_ID)" || fail "could not seed a conversation"
sql "INSERT OR IGNORE INTO conversation_notifications(conversation_id,sound) VALUES($SEED_ID,'app_sound');" >/dev/null 2>&1
sql "UPDATE conversation_notifications SET sound='app_sound' WHERE conversation_id=$SEED_ID;" >/dev/null 2>&1
sql "INSERT INTO conversations(address,name,timestamp) VALUES('$OVERRIDE','Tone chat',strftime('%s','now')*1000);" >/dev/null 2>&1
launch
SEED_CH=""
for _ in 1 2 3 4 5; do SEED_CH=$(convo_ch "$SEED_ID"); [ -n "$SEED_CH" ] && break; sleep 1; done
[ -n "$SEED_CH" ] && pass "$SEED_CH was created at launch" || fail "no messages_convo_${SEED_ID}_* channel was created at launch"
name=$(channel_name "$SEED_CH")
[ "$name" = "Seed chat" ] \
    && pass "the channel carries the conversation name" \
    || fail "channel name is '${name:-<empty>}' instead of 'Seed chat'"
sound=$(channel_sound "$SEED_CH")
echo "  channel sound: ${sound:-<none>}"
case "$sound" in
    android.resource://*) pass "the per-conversation sound override is applied at creation" ;;
    *) fail "the sound override was ignored ($sound)" ;;
esac
category_sound=$(channel_sound "$(live_channels | grep '^messages_unknown_' | head -1)")
[ -n "$sound" ] && [ -n "$category_sound" ] && [ "$sound" != "$category_sound" ] \
    && pass "the override differs from the category channel's sound" \
    || fail "the override did not change the channel sound ('$sound' vs '$category_sound')"

info "No crashes"
adb_ shell "logcat -d -b crash" 2>/dev/null | grep -c "$PKG" >/dev/null \
    && fail "crash logged for $PKG" \
    || pass "no crashes"

printf '\n=== RESULTS: %s passed, %s failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
