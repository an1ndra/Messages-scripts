#!/usr/bin/env bash
# Regression for #188: long-press a message to attach a local emoji reaction,
# shown as a chip on the bubble and stored on the message row. An SMS fallback
# carries readable text to the other side; that is not asserted here, because a
# single emulator cannot receive its own outbound SMS.
#
# The chat is opened with the app's `open_conversation_address` hook rather than
# by tapping the list, which is flaky on this AVD.
source "$(dirname "$0")/env.sh"

MARK="react$(date +%s)"
NUM="+1555000$(( (RANDOM % 9000) + 1000 ))"
TS=$(( $(date +%s) * 1000 ))

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

sql() { echo "$1" | adb_ shell "run-as $PKG sqlite3 databases/messages.db"; }

cleanup() {
    sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM');"
    sql "DELETE FROM conversations WHERE address='$NUM';"
    sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='ALPHA-1234');"
    sql "DELETE FROM conversations WHERE address='ALPHA-1234';"
}
trap cleanup EXIT

adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1
adb_ shell pm grant "$PKG" android.permission.SEND_SMS 2>/dev/null
adb_ shell pm grant "$PKG" android.permission.READ_SMS 2>/dev/null

info "Seed a conversation + message"
sql "INSERT INTO conversations(address,name,snippet,timestamp,last_is_me) VALUES('$NUM','ReactTest','$MARK',$TS,0);"
sql "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,media_type) SELECT id,'$MARK',$TS,0,'received','text' FROM conversations WHERE address='$NUM';"

info "Open the conversation"
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" --es open_conversation_address "$NUM" >/dev/null 2>&1; sleep 4
if ui_has "$MARK"; then ok "chat opened"; else bad "chat not opened"; exit 1; fi

info "Long-press the message -> reaction bar -> thumbs up"
M=$(center_of_contains "$MARK") || { bad "message not found"; exit 1; }
MX=${M% *}; MY=${M#* }
adb_ shell input swipe $MX $MY $((MX + 2)) $MY 1200; sleep 1.5
if ui_has "👍"; then ok "reaction bar shown"; else bad "no reaction bar"; fi
E=$(center_of "👍") || { bad "thumbs up not found in the bar"; exit 1; }
adb_ shell input tap $E; sleep 2
if ui_has "👍"; then ok "reaction chip shown on the bubble"; else bad "reaction chip missing"; fi
REACT=$(sql "SELECT reactions FROM messages WHERE body='$MARK';" | tr -d '\r')
if [ "$REACT" = "👍:1" ]; then ok "reaction stored ($REACT)"; else bad "reaction not stored (got '$REACT')"; fi

info "Long-press again -> thumbs up removes it"
M=$(center_of_contains "$MARK") || { bad "message not found (remove)"; exit 1; }
MX=${M% *}; MY=${M#* }
adb_ shell input swipe $MX $MY $((MX + 2)) $MY 1200; sleep 1.5
E=$(center_of "👍") || { bad "thumbs up not found (remove)"; exit 1; }
adb_ shell input tap $E; sleep 2
REACT=$(sql "SELECT reactions FROM messages WHERE body='$MARK';" | tr -d '\r')
if [ -z "$REACT" ]; then ok "reaction removed"; else bad "reaction still stored (got '$REACT')"; fi

info "No reaction bar where a message cannot be sent (alphanumeric sender)"
ANUM="ALPHA-1234"
AMARK="reactalpha$(date +%s)"
sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$ANUM');"
sql "DELETE FROM conversations WHERE address='$ANUM';"
sql "INSERT INTO conversations(address,name,snippet,timestamp,last_is_me) VALUES('$ANUM','AlphaSender','$AMARK',$TS,0);"
sql "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,media_type) SELECT id,'$AMARK',$TS,0,'received','text' FROM conversations WHERE address='$ANUM';"
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" --es open_conversation_address "$ANUM" >/dev/null 2>&1; sleep 4
M=$(center_of_contains "$AMARK") || { bad "alphanumeric message not found"; exit 1; }
MX=${M% *}; MY=${M#* }
adb_ shell input swipe $MX $MY $((MX + 2)) $MY 1200; sleep 2
if ui_has "👍"; then
    bad "reaction bar offered where a message cannot be sent"
else
    ok "no reaction bar for a non-replyable sender"
fi

echo ""
info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
