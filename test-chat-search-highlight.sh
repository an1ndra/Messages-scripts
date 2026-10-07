#!/usr/bin/env bash
# Issue: searching the home list and tapping a conversation opened the chat at
# the bottom, so the user could not see where the keyword actually was. The
# query is now handed to the chat, which highlights the matching message and
# scrolls to it.
#
# The conversation is named with the keyword so the home search finds it by
# name, while the only matching *message* is the oldest one — off screen unless
# the chat scrolls to it. A pre-fix build lands on the tail and fails here.
source "$(dirname "$0")/env.sh"

KW="zebra$(date +%s)"
NUM="+15559990201"
TS=$(( $(date +%s) * 1000 ))
PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

sql() { echo "$1" | adb_ shell "run-as $PKG sqlite3 databases/messages.db"; }

adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1
for p in READ_SMS RECEIVE_SMS SEND_SMS POST_NOTIFICATIONS; do
    adb_ shell pm grant "$PKG" android.permission.$p 2>/dev/null
done

cleanup() {
    sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM');"
    sql "DELETE FROM conversations WHERE address='$NUM';"
}
trap cleanup EXIT

info "Seed a conversation whose only keyword message is the oldest"
cleanup
sql "INSERT INTO conversations(address,name,snippet,timestamp,last_is_me) VALUES('$NUM','$KW','tail message',$TS,0);"
sql "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,media_type) SELECT id,'the $KW lives here',$TS,0,'received','text' FROM conversations WHERE address='$NUM';"
for i in $(seq 1 45); do
    sql "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,media_type) SELECT id,'filler-$i',$((TS + i * 60000)),0,'received','text' FROM conversations WHERE address='$NUM';"
done

info "Search the home list for the keyword"
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 5
if ! tap_text "Search" >/dev/null 2>&1; then bad "no Search button"; exit 1; fi
sleep 1
type_text "$KW" >/dev/null 2>&1
sleep 2
if ui_has "tail message"; then ok "conversation found by search"; else bad "conversation not in search results"; exit 1; fi

info "Open it and expect the matching message to be scrolled into view"
C=$(center_of_contains "tail message")
[ -n "$C" ] || { bad "could not tap the conversation row"; exit 1; }
adb_ shell input tap $C
sleep 5

dump_ui >/dev/null 2>&1
MATCH_LINE=$(grep -o 'text="the '"$KW"' lives here"[^>]*bounds="[^"]*"' "$TMP/ui.xml" 2>/dev/null | head -1)
if [ -z "$MATCH_LINE" ]; then
    dump_ui >/dev/null 2>&1
    MATCH_LINE=$(grep -o 'text="the '"$KW"' lives here"[^>]*bounds="[^"]*"' "$TMP/ui.xml" 2>/dev/null | head -1)
fi
if [ -n "$MATCH_LINE" ]; then
    ok "matching message auto-scrolled into view"
else
    bad "matching message not visible after opening from search"
fi

if echo "$MATCH_LINE" | grep -q 'content-desc="[^"]*Search result"'; then
    ok "matching message marked as the search result"
else
    bad "matching message has no search-result marker"
fi

echo ""
info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
