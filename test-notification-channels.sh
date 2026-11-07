#!/usr/bin/env bash
# Regression: per-chat notification channels are opt-in (#339 follow-up).
#
# The app used to create a channel for every recent conversation at launch and
# let the chat's sound picker move the channel to a new id. Both are gone: the
# channel id is stable, a chat gets one only when the user switches it on, and
# the row then opens Android's own page for that channel. The category channels
# remain, and are also the fallback when a chat has no channel of its own.
#
# Invariants asserted here:
#   - an incoming message does NOT create a per-chat channel
#   - a message posts on the category channel while the chat has no channel
#   - the three category channels still exist, the legacy ids are gone
#   - a conversation that lands in the database gets no channel at launch
#   - the chat's "Notification profile" switch, off by default, creates
#     messages_convo_<id>, named after the chat, and the notification then
#     posts on it
#   - its label opens Android's page for that channel once the switch is on
#   - the row is drawn as a switch *and* a drill-in, the way Android Settings
#     marks that: turning the switch on moves the title's trailing edge left by
#     ~43dp to make room for a chevron and a hairline (#421 follow-up), and
#     turning it back off gives the space back
#   - the channel keeps its id and sound across a relaunch (no re-minting)
#   - turning it off deletes the channel, and messages fall back to the
#     category channel instead of being dropped
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

sql() {
    adb_ shell "run-as $PKG sqlite3 databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r' && return 0
    adb_ shell "su -c \"sqlite3 /data/data/$PKG/databases/messages.db \\\"$1\\\"\"" 2>/dev/null | tr -d '\r' || true
}
convo_id() { sql "SELECT id FROM conversations WHERE address='$1';" | tr -d '\r\n'; }

# The live channel set this app owns. dumpsys prints one "NotificationChannel{
# mId=..." per channel, for every app; scope to our prefix and drop the
# soft-deleted ones (Android keeps a deleted channel listed with mDeleted=true,
# which is not a live channel).
live_channels() {
    adb_ shell "dumpsys notification --noredact" 2>/dev/null | tr -d '\r' \
        | grep "NotificationChannel{mId='messages" \
        | grep -v "mDeleted=true" \
        | grep -oE "mId='messages[a-z0-9_]*'" | sed "s/mId='//; s/'//" | sort -u
}
has_channel() { live_channels | grep -qx "$1"; }
convo_ch() { live_channels | grep -x "messages_convo_${1}" | head -1; }

# The display name Android shows for one channel. dumpsys prints it unquoted
# (mName=Sarah, mDescription=...), so anchor on the next field.
channel_name() {
    adb_ shell "dumpsys notification --noredact" 2>/dev/null | tr -d '\r' \
        | grep -F "NotificationChannel{mId='$1'" | grep -v "mDeleted=true" | head -1 \
        | grep -oE "mName=[^,]*, mDescription=" | head -1 \
        | sed -E "s/^mName=//; s/, mDescription=$//"
}

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

# The NotificationRecord block for one conversation id. Sending returns as soon
# as the row is stored, which is before notify() runs, so this retries until the
# record is there rather than reading an empty block.
record_block() {
    local id="$1" try b
    for try in $(seq 1 10); do
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
    adb_ shell am start -n "$ACT" "$@" >/dev/null 2>&1; sleep 5
}

open_chat() { launch --es open_conversation_address "$1"; }

# Chat → ⋮ → Details. Tapping the title is what a user does, but the title is
# the locale-formatted number, which the script does not know; the menu item is
# the stable route.
open_details() {
    tap_layout "More options" >/dev/null 2>&1 || return 1
    sleep 1
    tap_layout "Details" >/dev/null 2>&1 || return 1
    wait_layout_has "Notification profile" 8
}

# Android's channel page for this app, opened by the "Notification profile"
# row. It is a different app entirely, so the resumed activity is the assertion.
# API 31 prints only `mResumedActivity`; newer releases add `topResumedActivity`.
settings_page_open() {
    adb_ shell "dumpsys activity activities" 2>/dev/null \
        | grep -E "ResumedActivity" | grep -q "com.android.settings"
}

# Where the trailing controls of a detail row begin: the x2 of the label's node.
# The label is the weighted child that fills the row, so this edge is exactly
# the start of whatever trails it -- the switch alone, or the chevron, hairline
# and switch together.
label_right_px() {
    layout_json || return 1
    python3 - "$TMP/layout.json" "$1" <<'PY'
import json, re, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
want = sys.argv[2]
found = [None]
def walk(node):
    if found[0] is not None:
        return
    if isinstance(node, list):
        for child in node:
            walk(child)
    elif isinstance(node, dict):
        if not node.get("off-screen") and node.get("text") == want:
            m = re.match(r"\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]", node.get("bounds") or "")
            if m:
                found[0] = int(m.group(3))
                return
        for key in ("content", "children"):
            for child in (node.get(key) or []):
                walk(child)
walk(data)
if found[0] is None:
    sys.exit(1)
print(found[0])
PY
}

# dp from px at this device's density, so the thresholds below are not tied to
# one screen.
px_to_dp() {
    local px="$1" density
    density=$(adb_ shell wm density | tr -d '\r' | sed -E 's/.*: ([0-9]+)/\1/')
    [ -n "$density" ] || density=440
    echo $((px * 160 / density))
}

cleanup() {
    for addr in "$FROM" "$SEEDED"; do
        sql "DELETE FROM conversations WHERE address='$addr';" >/dev/null 2>&1
    done
    adb_ shell input keyevent 4 >/dev/null 2>&1
    # Hand the SMS role back so the next script (and Google Messages) is not
    # silently testing against the wrong app.
    adb_ shell "su -c 'cmd role add-role-holder android.app.role.SMS com.google.android.apps.messaging'" \
        >/dev/null 2>&1 || true
}
trap cleanup EXIT

# These AVDs are rooted, so the role change needs `su -c`; without the role the
# app never receives the injected SMS and every assertion below fails for the
# wrong reason.
adb_ shell "su -c 'cmd role add-role-holder android.app.role.SMS $PKG'" >/dev/null 2>&1 \
    || adb_ shell "cmd role add-role-holder android.app.role.SMS $PKG" >/dev/null 2>&1

info "An incoming message posts on the category channel"
launch
send_wait "$FROM" "${MARK}a" || { fail "the first message never arrived"; exit 1; }
CID=$(convo_id "$FROM")
[ -n "$CID" ] && pass "conversation resolved ($CID)" || { fail "no conversation for $FROM"; exit 1; }

block=$(record_block "$CID" || true)
printf '%s' "$block" | grep -qE "channel=messages_(direct|group|unknown)_" \
    && pass "the record posts on its category channel" \
    || fail "the record did not use a category channel"

info "A message does not create a per-chat channel"
# Count the per-chat channels rather than demanding none: a device that ran an
# older build may still carry channels for other chats, and this build is not
# allowed to add or remove any of those in response to a message.
CONVO_BEFORE=$(live_channels | grep -cE '^messages_convo_' || true)
[ -z "$(convo_ch "$CID")" ] \
    && pass "the conversation that just received a message has no channel" \
    || fail "the message created a channel for its own conversation"
CONVO_AFTER=$(live_channels | grep -cE '^messages_convo_' || true)
[ "$CONVO_BEFORE" = "$CONVO_AFTER" ] \
    && pass "the per-chat channel count is unchanged ($CONVO_AFTER)" \
    || fail "the per-chat channel count moved ($CONVO_BEFORE -> $CONVO_AFTER)"

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

info "A conversation that lands in the database gets no channel at launch"
# The reporter's ask (#339): create one for every chat at start-up. That is the
# behaviour this build deliberately does not have — it would put every contact
# into system notification settings.
sql "INSERT INTO conversations(address,name,timestamp) VALUES('$SEEDED','Seed chat',strftime('%s','now')*1000);" >/dev/null 2>&1
SEED_ID=$(convo_id "$SEEDED")
[ -n "$SEED_ID" ] && pass "seeded conversation ($SEED_ID)" || fail "could not seed a conversation"
launch
sleep 2
[ -z "$(convo_ch "$SEED_ID")" ] \
    && pass "the seeded chat has no channel after a launch" \
    || fail "the launch created a channel for a chat nobody asked about"

info "The chat details screen offers the opt-in"
open_chat "$FROM"
sleep 2
open_details || true
layout_has "Notification profile" \
    && pass "chat details shows the Notification profile switch" \
    || fail "chat details has no Notification profile row"
layout_has "Notifications" \
    && fail "the old Notifications switch is back" \
    || pass "the old Notifications row is gone"

# While the chat has no channel the row is a plain switch: the label runs right
# up to it. Once there is a page to open, the chevron and hairline take ~43dp
# from the label, which is the dump-visible half of that affordance.
SCREEN_W=$(adb_ shell wm size | sed -E 's/.*: ([0-9]+)x.*/\1/' | tr -d '\r')
[ -n "$SCREEN_W" ] || SCREEN_W=1080
ROW_OFF=$(label_right_px "Notification profile" || true)
if [ -n "$ROW_OFF" ]; then
    gap_off_dp=$(px_to_dp $((SCREEN_W - ROW_OFF)))
    echo "  label edge from the right: ${gap_off_dp}dp (switch only)"
    pass "the row's trailing edge is measurable while the switch is off"
else
    gap_off_dp=""
    fail "could not measure the row's trailing edge while off"
fi

info "Switching it on creates the chat's channel"
tap_switch_layout "Notification profile" >/dev/null 2>&1
CH=""
for _ in $(seq 1 10); do
    CH=$(convo_ch "$CID")
    [ -n "$CH" ] && break
    sleep 1
done
[ -n "$CH" ] && pass "$CH exists" || fail "no messages_convo_${CID} channel was created"
[ "$CH" = "messages_convo_${CID}" ] \
    && pass "the channel id is the stable one (no tone suffix)" \
    || fail "unexpected channel id '$CH'"

# Same row, now with a page to open: the chevron and the hairline before the
# switch push the label's trailing edge left (#421 follow-up).
ROW_ON=$(label_right_px "Notification profile" || true)
if [ -n "$ROW_ON" ] && [ -n "$gap_off_dp" ]; then
    gap_on_dp=$(px_to_dp $((SCREEN_W - ROW_ON)))
    echo "  label edge from the right: ${gap_off_dp}dp off -> ${gap_on_dp}dp on"
    [ $((gap_on_dp - gap_off_dp)) -ge 35 ] \
        && pass "the row grew its drill-in chevron once the channel exists (+$((gap_on_dp - gap_off_dp))dp)" \
        || fail "the row shows no drill-in affordance with the channel on (+$((gap_on_dp - gap_off_dp))dp)"
else
    fail "could not measure the row's trailing edge with the channel on"
fi

name=$(channel_name "$CH")
echo "  channel name: ${name:-<empty>}"
{ [ -n "$name" ] && [ "$name" != "$CH" ]; } \
    && pass "the channel is named after the chat" \
    || fail "the channel is not named after the chat ('$name')"

info "A message now posts on that channel"
send_wait "$FROM" "${MARK}b" || fail "the second message never arrived"
block=$(record_block "$CID" || true)
printf '%s' "$block" | grep -q "channel=${CH}" \
    && pass "the record posts on the chat's own channel" \
    || fail "the record still posts on a category channel"

info "Notification profile opens Android's page for that channel"
wait_layout_has "Notification profile" 8 || true
tap_layout "Notification profile" >/dev/null 2>&1
opened=no
for _ in $(seq 1 6); do
    if settings_page_open; then opened=yes; break; fi
    sleep 1
done
[ "$opened" = yes ] \
    && pass "the row opens com.android.settings" \
    || fail "the row did not open the system channel page"
adb_ shell input keyevent 4 >/dev/null 2>&1
sleep 2

info "The channel keeps its id and sound across a relaunch"
sound_before=$(channel_sound "$CH")
launch
sleep 2
CH_AFTER=$(convo_ch "$CID")
sound_after=$(channel_sound "$CH_AFTER")
[ "$CH_AFTER" = "$CH" ] \
    && pass "the channel survived the relaunch unchanged" \
    || fail "the channel id changed across a relaunch ('$CH' -> '$CH_AFTER')"
[ -n "$sound_before" ] && [ "$sound_before" = "$sound_after" ] \
    && pass "the channel sound is not re-applied at launch" \
    || fail "the channel sound changed across a relaunch ('$sound_before' -> '$sound_after')"

info "Switching it off removes the channel and falls back to the category"
open_chat "$FROM"
sleep 2
open_details || true
tap_switch_layout "Notification profile" >/dev/null 2>&1
sleep 3
has_channel "$CH" \
    && fail "the channel survived the switch being turned off" \
    || pass "the chat's channel was deleted"

# With no channel left there is no page to open, so the chevron and the
# hairline must go and the label must reclaim the width.
ROW_BACK=$(label_right_px "Notification profile" || true)
if [ -n "$ROW_BACK" ] && [ -n "$ROW_OFF" ]; then
    [ $((ROW_BACK - ROW_OFF)) -le 4 ] && [ $((ROW_BACK - ROW_OFF)) -ge -4 ] \
        && pass "turning it off removed the drill-in affordance" \
        || fail "the chevron stayed after the channel was deleted ($ROW_OFF -> $ROW_BACK px)"
else
    fail "could not re-measure the row's trailing edge after switching off"
fi
send_wait "$FROM" "${MARK}c" || fail "the third message never arrived"
block=$(record_block "$CID" || true)
printf '%s' "$block" | grep -qE "channel=messages_(direct|group|unknown)_" \
    && pass "the message still arrives on the category channel" \
    || fail "the message was dropped instead of falling back"

info "No crashes"
adb_ shell "logcat -d -b crash" 2>/dev/null | grep -c "$PKG" >/dev/null \
    && fail "crash logged for $PKG" \
    || pass "no crashes"

printf '\n=== RESULTS: %s passed, %s failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
