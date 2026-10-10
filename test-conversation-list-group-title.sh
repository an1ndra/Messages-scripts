#!/usr/bin/env bash
# A group is listed and announced by its own name, not by whoever it started
# with.
#
# A group's `address` is its primary contact's, so the ordinary "known contact
# shows their name" rule files "Sarah + Dad" under "Sarah". It reached the
# visible row title and the label a screen reader announces for the row.
#
# The redesigned conversation list never had the group branch -- the legacy one
# did -- so the two disagreed. Both now call ContactDetails.listLabel, and this
# asserts the rendered list under either UI flag.
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

PASS=0; FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }
info() { printf '\n=== %s ===\n' "$1"; }

sql() { echo "$1" | adb_ shell "run-as $PKG sqlite3 databases/messages.db"; }
q()   { sql "$1" | tr -d '\r'; }

SARAH="+15551230010"
DAD="+1555771010"

set_new_ui() {
    case "$1" in
      on)  from=false; to=true ;;
      off) from=true;  to=false ;;
    esac
    adb_ shell "run-as $PKG sh -c 'sed -i \"s#name=\\\"use_new_ui\\\" value=\\\"$from\\\"#name=\\\"use_new_ui\\\" value=\\\"$to\\\"#\" shared_prefs/messages_settings.xml'" >/dev/null 2>&1
}

pin_new_ui() {
    adb_ shell "run-as $PKG sh -c 'touch shared_prefs/messages_settings.xml'" >/dev/null 2>&1
    adb_ shell "run-as $PKG sh -c 'grep -q use_new_ui shared_prefs/messages_settings.xml || echo \"<?xml version=\\\"1.0\\\" encoding=\\\"utf-8\\\" standalone=\\\"yes\\\" ?><map><boolean name=\\\"use_new_ui\\\" value=\\\"true\\\" /></map>\" > shared_prefs/messages_settings.xml'" >/dev/null 2>&1
    set_new_ui "$1"
}

cleanup() {
    # A private chat and a group both belong to the primary contact, so leaving
    # either behind makes the address ambiguous for the next script to run.
    sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$SARAH');" >/dev/null
    sql "DELETE FROM conversation_recipients WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$SARAH');" >/dev/null
    sql "DELETE FROM conversations WHERE address='$SARAH';" >/dev/null
    pin_new_ui on
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# --- Arrange: a 1:1 with Sarah, and a group she is in -----------------------
sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$SARAH');" >/dev/null
sql "DELETE FROM conversation_recipients WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$SARAH');" >/dev/null
sql "DELETE FROM conversations WHERE address='$SARAH';" >/dev/null

sql "INSERT INTO conversations(address,name,snippet,timestamp,last_is_me) VALUES('$SARAH','Sarah','private words',$(($(date +%s)-100))000,0);" >/dev/null
CHAT_ID=$(q "select id from conversations where address='$SARAH'" || true); CHAT_ID=${CHAT_ID:--1}
sql "INSERT INTO conversation_recipients(conversation_id,address) VALUES($CHAT_ID,'$SARAH');" >/dev/null
sql "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,media_type) VALUES($CHAT_ID,'private words',$(date +%s)000,0,'received','text');" >/dev/null

sql "INSERT INTO conversations(address,name,snippet,timestamp,last_is_me,group_title) VALUES('$SARAH','Sarah','group talk',$(date +%s)000,1,'Sarah +Dad');" >/dev/null
GROUP_ID=$(q "select id from conversations where address='$SARAH' AND id<>$CHAT_ID" || true); GROUP_ID=${GROUP_ID:--1}
sql "INSERT INTO conversation_recipients(conversation_id,address) VALUES($GROUP_ID,'$SARAH');" >/dev/null
sql "INSERT INTO conversation_recipients(conversation_id,address) VALUES($GROUP_ID,'$DAD');" >/dev/null
sql "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,media_type) VALUES($GROUP_ID,'group talk',$(date +%s)000,1,'sent','text');" >/dev/null

info "seeded 1:1=$CHAT_ID group=$GROUP_ID"

# --- Assert: the group row carries the group's own name ---------------------
for mode in off on; do
    pin_new_ui "$mode"
    adb_ shell am force-stop "$PKG"; sleep 1
    adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 8
    dump_ui >/dev/null 2>&1

    got=$(adb_ shell "run-as $PKG cat shared_prefs/messages_settings.xml" 2>/dev/null \
        | grep -o 'use_new_ui" value="[a-z]*"' | head -1 | tr -d '\r')

    # The row announces itself as one content-desc: "<title>. <snippet>. <time>".
    row=$(python3 -c "
import re
xml=open('$TMP/ui.xml').read()
for n in re.findall(r'<node[^>]*>',xml):
    d=re.search(r'content-desc=\"([^\"]+)\"',n)
    if d and 'group talk' in d.group(1):
        print(d.group(1)); break
")
    if [ -z "$row" ]; then
        fail "no group row on screen with use_new_ui=$got"
        grep -oE 'content-desc="[^"]*"' "$TMP/ui.xml" | sort -u | head -12
        continue
    fi

    title=${row%%.*}
    if [ "$title" = "Sarah +Dad" ]; then
        pass "the group row is titled by its members (use_new_ui=$got)"
    else
        fail "the group row is titled '$title', expected 'Sarah +Dad' (use_new_ui=$got)"
    fi

    # And the private chat must still be titled by the contact, not the group.
    chat_row=$(python3 -c "
import re
xml=open('$TMP/ui.xml').read()
for n in re.findall(r'<node[^>]*>',xml):
    d=re.search(r'content-desc=\"([^\"]+)\"',n)
    if d and 'private words' in d.group(1):
        print(d.group(1)); break
")
    if [ "${chat_row%%.*}" = "Sarah" ]; then
        pass "the private chat is still titled by the contact (use_new_ui=$got)"
    else
        fail "the private chat row is '${chat_row:-missing}', expected 'Sarah' (use_new_ui=$got)"
    fi
done

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]