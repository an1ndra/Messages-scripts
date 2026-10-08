#!/usr/bin/env bash
# Issue #284: searching the conversation list by phone number.
#
# Three faults, all in AddressIdentity.matchesNumber:
#   1. a number query also LIKE-scanned every message body, so every chat that
#      merely mentioned the number was listed, and opening one scrolled to and
#      highlighted that message;
#   2. only a suffix test ran, so a contact appeared once nearly the whole
#      number had been typed;
#   3. the address was stripped to digits first, so an alphanumeric sender ID
#      like "X1-SRB" became "1" and the reverse endsWith test matched every
#      query ending in 1 — flickering on and off per keystroke.
#
# Asserts:
#   1. "X1-SRB" is absent for 101, 1010 and 10101 alike (no flicker);
#   2. the first digits of a number find its conversation straight away;
#   3. a chat that only mentions the number is not listed, and opening the real
#      contact neither scrolls to nor highlights anything;
#   4. 1–2 digits leave the list unfiltered rather than blanking it;
#   5. a text query still matches a name containing digits, a snippet and a hit
#      buried in an old message.
#
# Fails before the fix, passes after. Run: scripts/test-number-search.sh
source "$(dirname "$0")/env.sh"

STAMP="$(date +%s)"
KW="numsearch$STAMP"
# The sender ID from issue #207. Its digits are exactly the flicker case.
SENDER="X1-SRB"
# Distinct from the emulator's own +155512300xx range.
NUMBER="+447700900${STAMP: -3}"
# The same number as the user types it nationally, so containment is required.
NATIONAL="07700900${STAMP: -3}"
# A different conversation that merely mentions the number in a message body.
MENTIONER="+1555880${STAMP: -2}3"
TS=$(( $(date +%s) * 1000 ))
DB="databases/messages.db"

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

sql() { echo "$1" | adb_ shell "run-as $PKG sqlite3 $DB" 2>/dev/null | tr -d '\r'; }

cleanup() {
    sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address IN ('$NUMBER','$MENTIONER','$SENDER'));"
    sql "DELETE FROM conversations WHERE address IN ('$NUMBER','$MENTIONER','$SENDER');"
}
trap cleanup EXIT

seed() {
    cleanup
    sql "INSERT INTO conversations(address,name,snippet,timestamp,last_is_me) VALUES
        ('$NUMBER','NumberTarget','tail $KW',$TS,0),
        ('$MENTIONER','MentionOnly','tail',$TS,0),
        ('$SENDER','$SENDER','tail',$TS,0);" >/dev/null
    # The mentioner has no number in its address or name — only in a message body.
    sql "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,media_type)
        SELECT id,'ring me on $NATIONAL please',$((TS + 60000)),0,'received','text'
        FROM conversations WHERE address='$MENTIONER';" >/dev/null
    # A buried hit, so the text-query check has something old to find.
    sql "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,media_type)
        SELECT id,'oldest note $KW here',$((TS + 1000)),0,'received','text'
        FROM conversations WHERE address='$NUMBER';" >/dev/null
}

# Added only once check 2 has run. It puts the number inside a message of its own
# thread, which is what makes check 4 discriminating: before the fix the number
# query was handed to the chat, which scrolled to and highlighted this message.
# Check 2 must run without it, or the body match would mask a broken address
# match and the check would pass on broken code.
seed_self_number() {
    sql "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,media_type)
        SELECT id,'my number is $NATIONAL',$((TS + 60000)),0,'received','text'
        FROM conversations WHERE address='$NUMBER';" >/dev/null
}

open_search() {
    # Retry the cold start: right after an install the first launch can restore a
    # saved route (New conversation) or still be running the startup sync, so a
    # single tap misses the Search button.
    local found=""
    for _ in 1 2 3; do
        adb_ shell am force-stop "$PKG"; sleep 1
        adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 5
        if tap_text "Search" >/dev/null 2>&1; then found=1; break; fi
        adb_ shell input keyevent 4 >/dev/null 2>&1; sleep 2
    done
    [ -n "$found" ] || { bad "no Search button"; exit 1; }
    sleep 1
}

# Replace whatever is in the search field with $1.
set_query() {
    adb_ shell input keyevent KEYCODE_MOVE_END >/dev/null 2>&1
    for _ in $(seq 1 24); do adb_ shell input keyevent KEYCODE_DEL >/dev/null 2>&1; done
    type_text "$1" >/dev/null 2>&1
    sleep 3
}

info "Seed: '$SENDER', a thread addressed '$NUMBER', and one that only mentions it"
seed
[ -n "$(sql "SELECT id FROM conversations WHERE address='$NUMBER';")" ] \
    || { bad "seed failed"; exit 1; }

# --- 1. an alphanumeric sender must not appear for any digit length ----------

info "1. Sender ID '$SENDER' must never match a number query"
for q in 101 1010 10101; do
    open_search
    set_query "$q"
    if ui_has "$SENDER"; then
        bad "'$SENDER' was listed for query '$q'"
    else
        ok "'$SENDER' absent for query '$q'"
    fi
    adb_ shell input keyevent 4 >/dev/null 2>&1; sleep 1
done

# --- 2. a partial number finds its conversation -----------------------------

info "2. The first digits of a number find its conversation"
# 7 digits, well short of the full number, and nationally formatted.
PARTIAL="${NATIONAL:0:7}"
open_search
set_query "$PARTIAL"
if ui_has "NumberTarget"; then
    ok "partial number '$PARTIAL' listed the conversation"
else
    bad "partial number '$PARTIAL' did not list the conversation"
fi
if ui_has "$SENDER"; then bad "'$SENDER' leaked into a number query"; else ok "sender still absent"; fi
adb_ shell input keyevent 4 >/dev/null 2>&1; sleep 1

# --- 3. a mention is not a match, and opening neither scrolls nor highlights --

info "3. A chat that only mentions the number is not listed"
seed_self_number
open_search
set_query "$NATIONAL"
if ui_has "NumberTarget"; then
    ok "the real contact is listed"
else
    bad "the real contact is missing"
fi
if ui_has "MentionOnly"; then
    bad "'MentionOnly' listed: its message body mentions the number"
else
    ok "'MentionOnly' not listed"
fi

info "4. Opening the contact neither scrolls to nor highlights a message"
C=$(center_of_contains "NumberTarget")
[ -n "$C" ] || { bad "could not tap the contact row"; exit 1; }
adb_ shell input tap $C
sleep 5
if dump_ui >/dev/null 2>&1 && grep -q 'content-desc="[^"]*Search result"' "$TMP/ui.decoded.xml"; then
    bad "a message is marked as a search result for a number query"
else
    ok "no search-result marker in the chat"
fi
adb_ shell input keyevent 4; sleep 2

# --- 5. one and two digits must not blank the list --------------------------

info "5. One and two digits leave the list unfiltered"
for q in 1 10; do
    open_search
    set_query "$q"
    if ui_has "NumberTarget" || ui_has "MentionOnly" || ui_has "$SENDER"; then
        ok "query '$q' left the list populated"
    else
        bad "query '$q' blanked the list"
    fi
    adb_ shell input keyevent 4 >/dev/null 2>&1; sleep 1
done

# --- 6. text search is unchanged ---------------------------------------------

info "6. A text query still matches name, snippet and a buried hit"
open_search
set_query "X1"
if ui_has "$SENDER"; then ok "a sender name with digits is still findable by name"; else bad "'X1' did not match the sender name"; fi
adb_ shell input keyevent 4 >/dev/null 2>&1; sleep 1

open_search
set_query "ring me"
if ui_has "MentionOnly"; then ok "a snippet is still matched by text"; else bad "'ring me' did not match the snippet"; fi
adb_ shell input keyevent 4 >/dev/null 2>&1; sleep 1

info "7. A keyword buried in an old message still surfaces its thread"
open_search
set_query "$KW"
if ui_has "NumberTarget"; then ok "buried keyword surfaced the thread"; else bad "buried keyword did not surface the thread"; fi

echo ""
info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))