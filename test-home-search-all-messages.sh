#!/usr/bin/env bash
# Issue #284 feedback: the home search only matched the newest message (the
# snippet). A word buried in an older message must still surface its thread,
# and opening it must land on the matching message.
source "$(dirname "$0")/env.sh"

KW="buried$(date +%s)"
NAME="AllMsgSearch"
NUM="+15559990501"
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

info "Seed a thread whose only keyword is in an old message"
cleanup
sql "INSERT INTO conversations(address,name,snippet,timestamp,last_is_me) VALUES('$NUM','$NAME','latest tail',$TS,0);"
sql "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,media_type) SELECT id,'the $KW lives here',$TS,0,'received','text' FROM conversations WHERE address='$NUM';"
for i in $(seq 1 30); do
    sql "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,media_type) SELECT id,'filler-$i',$((TS + i * 60000)),0,'received','text' FROM conversations WHERE address='$NUM';"
done

info "Search the home list for the buried word"
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 5
if ! tap_text "Search" >/dev/null 2>&1; then bad "no Search button"; exit 1; fi
sleep 1
type_text "$KW" >/dev/null 2>&1
sleep 3
if ui_has "$NAME"; then ok "thread with the old match is listed"; else bad "thread not found by a buried message"; exit 1; fi

info "Open it: the matching message is scrolled to and marked"
C=$(center_of_contains "$NAME")
[ -n "$C" ] || { bad "could not tap the thread row"; exit 1; }
adb_ shell input tap $C
sleep 5
dump_ui >/dev/null 2>&1
MATCH=$(grep -o 'text="the '"$KW"' lives here"[^>]*bounds="[^"]*"' "$TMP/ui.decoded.xml" 2>/dev/null | head -1)
if [ -n "$MATCH" ]; then ok "matching message auto-scrolled into view"; else bad "matching message not visible"; fi
if echo "$MATCH" | grep -q 'content-desc="Search result"'; then
    ok "matching message marked as the search result"
else
    bad "matching message has no search-result marker"
fi

echo ""
info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
