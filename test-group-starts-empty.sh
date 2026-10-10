#!/usr/bin/env bash
# A group started from a 1:1 must be its own, empty thread -- and the 1:1 must
# keep its history.
#
# Adding people used to convert the conversation in place, so the group began
# as that chat, history and all. Worse, the empty replacement was then swept up
# by two sync passes that read "no messages" and "shared an address" as debris.
#
# Everything is asserted against the database, so there is no screenshot to read.
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

sql() { echo "$1" | adb_ shell "run-as $PKG sqlite3 databases/messages.db"; }
q()   { sql "$1" | tr -d '\r'; }

SARAH="+15551230010"
DAD="+1555771010"

cleanup() {
    # Leaving these behind makes the address ambiguous for the next script: a
    # private chat and a group both belong to the primary contact, so "the
    # conversation for this number" stops having one answer.
    sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$SARAH');" >/dev/null
    sql "DELETE FROM conversation_recipients WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$SARAH');" >/dev/null
    sql "DELETE FROM conversations WHERE address='$SARAH';" >/dev/null
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
}
trap cleanup EXIT
PASS=0; FAIL=0
ok()   { echo "[PASS] $1"; PASS=$((PASS+1)); }
bad()  { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

# --- Arrange: a 1:1 with Sarah that has real history in it -------------------
sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$SARAH');" >/dev/null
sql "DELETE FROM conversation_recipients WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$SARAH');" >/dev/null
sql "DELETE FROM conversations WHERE address='$SARAH';" >/dev/null
sql "INSERT INTO conversations(address,name,snippet,timestamp,last_is_me) VALUES('$SARAH','Sarah','old history',$(date +%s)000,0);" >/dev/null
sql "INSERT INTO conversation_recipients(conversation_id,address) SELECT id,'$SARAH' FROM conversations WHERE address='$SARAH';" >/dev/null
for i in 1 2; do
  sql "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,media_type) SELECT id,'old-$i',$(date +%s)000,0,'received','text' FROM conversations WHERE address='$SARAH';" >/dev/null
done

check "the 1:1 starts with two messages" \
  "$(q "select count(*) from messages m join conversations c on c.id=m.conversation_id where c.address='$SARAH'")" "2"

# --- Act: start a group from it, the way the Add people button does ----------
tap_text() {
  dump_ui >/dev/null 2>&1
  python3 -c "
import re
xml=open('$TMP/ui.xml').read()
for n in re.findall(r'<node[^>]*>',xml):
    if re.search('text=\"$1\"',n):
        b=re.search(r'bounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"',n)
        x1,y1,x2,y2=(int(g) for g in b.groups()); print((x1+x2)//2,(y1+y2)//2); break
"
}

adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" --es open_conversation_address "$SARAH" >/dev/null 2>&1; sleep 6
adb_ shell input tap 358 220; sleep 4
adb_ shell input tap "$(tap_text 'Add people')"; sleep 4
adb_ shell input tap "$(tap_text 'Dad')"; sleep 2
adb_ shell input tap "$(tap_text 'Create group')"; sleep 6

# --- Assert: two threads, and neither has borrowed from the other -----------
check "the group is a separate thread" \
  "$(q "select count(*) from conversations where address='$SARAH'")" "2"

GROUP_ID=$(q "select id from conversations where address='$SARAH' and id not in (select conversation_id from messages)" || true)
GROUP_ID=${GROUP_ID:--1}
CHAT_ID=$(q "select id from conversations where address='$SARAH' and id in (select conversation_id from messages)" || true)
CHAT_ID=${CHAT_ID:--1}

if [ -n "$GROUP_ID" ]; then ok "the group was created"; else bad "no new group conversation was created"; fi

check "the group has both members" \
  "$(q "select count(*) from conversation_recipients where conversation_id=$GROUP_ID")" "2"
check "the group starts empty" \
  "$(q "select count(*) from messages where conversation_id=$GROUP_ID")" "0"
check "the group is named" \
  "$(q "select case when group_title<>'' then 'yes' else 'no' end from conversations where id=$GROUP_ID")" "yes"
check "the 1:1 keeps its history" \
  "$(q "select count(*) from messages where conversation_id=$CHAT_ID")" "2"
check "the 1:1 is still a 1:1" \
  "$(q "select count(*) from conversation_recipients where conversation_id=$CHAT_ID")" "1"

# --- Assert: sync must not reclaim the empty group -------------------------
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 7

check "the empty group survives a restart" \
  "$(q "select count(*) from conversations where address='$SARAH'")" "2"
check "and is still empty" \
  "$(q "select count(*) from messages where conversation_id=$GROUP_ID")" "0"
check "and the 1:1 still has its messages" \
  "$(q "select count(*) from messages where conversation_id=$CHAT_ID")" "2"

# --- Assert: a new chat with Sarah opens the 1:1, not the group ------------
adb_ shell input tap "$(tap_text 'Start chat')"; sleep 4
adb_ shell input tap "$(tap_text 'Enter name or phone number')"; sleep 2
adb_ shell input text "$SARAH"; sleep 3
adb_ shell input tap "$(tap_text 'Sarah')"; sleep 5
dump_ui >/dev/null 2>&1
OPENED=$(python3 -c "
import re
xml=open('$TMP/ui.xml').read()
print('yes' if 'old-1' in xml else 'no')
")
check "new chat with Sarah shows the 1:1 history" "$OPENED" "yes"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]