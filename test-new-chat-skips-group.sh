#!/usr/bin/env bash
# Tapping someone who is only in a group must open a private chat with them,
# not that group.
#
# A group carries its primary contact's address, so "Alex" and the "Roadtrip"
# thread shared a row. Opening Alex from the picker found that row and dropped
# the user into the group -- there was no private thread for it to find, and the
# lookup then fell back to the only conversation that had his address.
#
# Asserted end to end: open the picker, choose Alex, and the chat that comes up
# must be a private one -- no participant list, no group name.
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

PASS=0; FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }
info() { printf '\n=== %s ===\n' "$1"; }

sql() { echo "$1" | adb_ shell "run-as $PKG sqlite3 databases/messages.db"; }
q()   { sql "$1" | tr -d '\r'; }

ALEX="+1555771030"
BOB="+1555771040"
CYD="+1555771050"

# The AVD drops taps and uiautomator intermittently, so each step is retried
# rather than trusted once.
tap_retry() {
    local label="$1" tries=0 c
    while [ $tries -lt 3 ]; do
        c=$(center_of "$label" 2>/dev/null) || c=""
        if [ -n "$c" ]; then
            adb_ shell input tap $c; sleep 4
            return 0
        fi
        tries=$((tries+1)); sleep 2
    done
    return 1
}

cleanup() {
    sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$ALEX');" >/dev/null
    sql "DELETE FROM conversation_recipients WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$ALEX');" >/dev/null
    sql "DELETE FROM conversations WHERE address='$ALEX';" >/dev/null
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# --- Arrange: Alex exists only inside a group, and has no private thread ----
sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$ALEX');" >/dev/null
sql "DELETE FROM conversation_recipients WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$ALEX');" >/dev/null
sql "DELETE FROM conversations WHERE address='$ALEX';" >/dev/null

sql "INSERT INTO conversations(address,name,snippet,timestamp,last_is_me,group_title) VALUES('$ALEX','Alex','roadtrip talk',$(date +%s)000,1,'Roadtrip');" >/dev/null
GROUP_ID=$(q "select id from conversations where address='$ALEX'" || true); GROUP_ID=${GROUP_ID:--1}
for m in "$ALEX" "$BOB" "$CYD"; do
    sql "INSERT INTO conversation_recipients(conversation_id,address) VALUES($GROUP_ID,'$m');" >/dev/null
done
sql "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,media_type) VALUES($GROUP_ID,'roadtrip talk',$(date +%s)000,1,'sent','text');" >/dev/null

info "seeded group $GROUP_ID (Roadtrip) with Alex, Bob, Cyrus"
if [ "$(q "select count(*) from conversations where address='$ALEX'")" = "1" ] \
   && [ "$(q "select count(*) from conversation_recipients where conversation_id=$GROUP_ID")" = "3" ]; then
    pass 'Alex starts with no private thread, only a group'
else
    fail 'could not seed the group'
fi

# --- Act: pick Alex from the new-chat picker --------------------------------
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 8

if tap_retry "Start chat"; then
    pass 'opened the new-chat picker'
else
    fail 'could not open the new-chat picker'
    dump_ui >/dev/null 2>&1
    grep -oE 'content-desc="[^"]*"' "$TMP/ui.xml" | sort -u | head -12
    echo ""
    echo "=== Results: $PASS passed, $FAIL failed ==="
    cleanup; trap - EXIT; exit 1
fi

if tap_retry "Enter name or phone number"; then
    adb_ shell input text "$ALEX"; sleep 4
else
    fail 'could not focus the picker search field'
fi

# After typing the number the row may be labelled with the number rather than
# the name, so either is accepted.
if tap_retry "Alex" || tap_retry "1030"; then
    pass 'chose Alex from the picker'
else
    fail 'could not find Alex in the picker'
    dump_ui >/dev/null 2>&1
    grep -oE '(text|content-desc)="[^"]*"' "$TMP/ui.xml" | sort -u | head -15
fi
sleep 4

# --- Assert: a private chat, not the group ---------------------------------
dump_ui >/dev/null 2>&1
if grep -q 'text="Roadtrip"' "$TMP/ui.xml"; then
    fail 'picking Alex opened the Roadtrip group'
    info "what actually opened:"
    grep -oE 'text="[^"]*"' "$TMP/ui.xml" | sort -u | head -20
else
    pass 'picking Alex did not open the Roadtrip group'
fi

# A private chat has a message field; a group adds the participant strip above
# it, naming the other members.
if grep -q 'text="Bob"' "$TMP/ui.xml" || grep -q 'text="Cyrus"' "$TMP/ui.xml"; then
    fail 'the chat that opened still shows the group members'
else
    pass 'the chat that opened is private'
fi

CHAT_ID=$(q "select id from conversations where address='$ALEX' and id<>$GROUP_ID" || true); CHAT_ID=${CHAT_ID:--1}
if [ "$CHAT_ID" != "-1" ]; then
    pass "a private thread with Alex was created ($CHAT_ID)"
else
    fail 'no private thread was created for Alex'
fi
if [ "$CHAT_ID" != "-1" ] \
   && [ "$(q "select count(*) from conversation_recipients where conversation_id=$CHAT_ID")" = "1" ]; then
    pass 'the new thread has Alex alone in it'
else
    fail 'the new thread is not a 1:1'
fi
# The group must be untouched by any of this.
if [ "$(q "select group_title from conversations where id=$GROUP_ID")" = "Roadtrip" ] \
   && [ "$(q "select count(*) from conversation_recipients where conversation_id=$GROUP_ID")" = "3" ]; then
    pass 'the group still has all three members'
else
    fail 'opening Alex disturbed the group'
fi
# And the private thread must not have inherited the group's history.
if [ "$(q "select count(*) from messages where conversation_id=$CHAT_ID")" = "0" ]; then
    pass "Alex's private thread starts empty"
else
    fail "Alex's private thread inherited the group's messages"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]