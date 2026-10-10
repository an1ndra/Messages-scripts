#!/usr/bin/env bash
# In-chat search (overflow menu -> Search): the query matches only the open
# conversation, the newest hit is focused, and the previous/next buttons walk
# the matches (the same flash highlight as the home-list handoff is reused).
source "$(dirname "$0")/env.sh"

KW="koala$(date +%s)"
NUM="+15559990301"
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

info "Seed a conversation with two keyword hits, far apart"
cleanup
sql "INSERT INTO conversations(address,name,snippet,timestamp,last_is_me) VALUES('$NUM','InChatSearch','tail',$TS,0);"
sql "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,media_type) SELECT id,'first $KW hit',$TS,0,'received','text' FROM conversations WHERE address='$NUM';"
for i in $(seq 1 20); do
    sql "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,media_type) SELECT id,'filler-$i',$((TS + i * 60000)),0,'received','text' FROM conversations WHERE address='$NUM';"
done
sql "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,media_type) SELECT id,'second $KW hit',$((TS + 21 * 60000)),0,'received','text' FROM conversations WHERE address='$NUM';"
for i in $(seq 22 30); do
    sql "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,media_type) SELECT id,'filler-$i',$((TS + i * 60000)),0,'received','text' FROM conversations WHERE address='$NUM';"
done

info "Open the chat and start search from the overflow menu"
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" --es open_conversation_address "$NUM" >/dev/null 2>&1; sleep 4
if ! tap_text "More options" >/dev/null 2>&1; then bad "no overflow menu"; exit 1; fi
sleep 1
if ! tap_text "Search" >/dev/null 2>&1; then bad "no Search menu item"; exit 1; fi
sleep 2
dump_ui >/dev/null 2>&1
if ui_has "Search in chat"; then ok "search bar opened"; else bad "search bar missing"; fi

info "Type the keyword: the newest hit is focused"
type_text "$KW" >/dev/null 2>&1
sleep 3
dump_ui >/dev/null 2>&1
COUNTER=$(grep -o 'text="[0-9]* of [0-9]*"' "$TMP/ui.decoded.xml" | head -1 | sed -E 's/text="//; s/"//')
if [ "$COUNTER" = "2 of 2" ]; then ok "counter starts at the newest hit ($COUNTER)"; else bad "counter expected '2 of 2', got '$COUNTER'"; fi
if ui_has "second $KW hit"; then ok "newest hit scrolled into view"; else bad "newest hit not visible"; fi

info "Previous walks to the older hit"
tap_text "Previous match" >/dev/null 2>&1
sleep 2
dump_ui >/dev/null 2>&1
COUNTER=$(grep -o 'text="[0-9]* of [0-9]*"' "$TMP/ui.decoded.xml" | head -1 | sed -E 's/text="//; s/"//')
if [ "$COUNTER" = "1 of 2" ]; then ok "counter moved to the older hit ($COUNTER)"; else bad "counter expected '1 of 2', got '$COUNTER'"; fi
if ui_has "first $KW hit"; then ok "older hit scrolled into view"; else bad "older hit not visible"; fi

info "Next walks back to the newer hit"
tap_text "Next match" >/dev/null 2>&1
sleep 2
dump_ui >/dev/null 2>&1
COUNTER=$(grep -o 'text="[0-9]* of [0-9]*"' "$TMP/ui.decoded.xml" | head -1 | sed -E 's/text="//; s/"//')
if [ "$COUNTER" = "2 of 2" ]; then ok "counter returned to the newer hit ($COUNTER)"; else bad "counter expected '2 of 2', got '$COUNTER'"; fi
if ui_has "second $KW hit"; then ok "newer hit scrolled into view"; else bad "newer hit not visible"; fi

info "Close search"
tap_text "Close search" >/dev/null 2>&1
sleep 2
dump_ui >/dev/null 2>&1
if ui_has "Search in chat"; then bad "search bar still open"; else ok "search bar closed"; fi

echo ""
info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
