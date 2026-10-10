#!/usr/bin/env bash
# Issue #188, app to app: a reaction sent by another of our devices arrives as
# text and must show as an ordinary message bubble — the receiving side does not
# parse the notice, so nothing is applied to the referenced message.
source "$(dirname "$0")/env.sh"

NUM="+15550008888"
# The marker makes the notice body unique per run, so an exact row count is a
# real assertion instead of one polluted by earlier runs.
STAMP=$(date +%s)
MSG="roundtrip hello world $STAMP"
TS=$(( STAMP * 1000 ))
PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

sql() { echo "$1" | adb_ shell "run-as $PKG sqlite3 databases/messages.db"; }
reactions_of() { sql "SELECT reactions FROM messages WHERE body='$MSG';" | tr -d '\r'; }

cleanup() {
    sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM');"
    sql "DELETE FROM conversations WHERE address='$NUM';"
}
trap cleanup EXIT

adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1
for p in READ_SMS RECEIVE_SMS SEND_SMS POST_NOTIFICATIONS; do
    adb_ shell pm grant "$PKG" android.permission.$p 2>/dev/null
done

info "Seed a conversation + message"
sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM');"
sql "DELETE FROM conversations WHERE address='$NUM';"
sql "INSERT INTO conversations(address,name,snippet,timestamp,last_is_me) VALUES('$NUM','RoundTrip','$MSG',$TS,0);"
sql "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,media_type) SELECT id,'$MSG',$TS,0,'received','text' FROM conversations WHERE address='$NUM';"

adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 4

info "Reacted <emoji> to <snippet> arrives as a message, not applied to the target"
adb_ emu sms send "$NUM" "Reacted 👍 to $MSG" >/dev/null 2>&1
sleep 5
# The emoji is matched loosely: `adb emu sms send` drops non-ASCII from the body
# it injects, so the stored text is "Reacted  to <snippet>".
if [ "$(sql "SELECT COUNT(*) FROM messages WHERE body LIKE 'Reacted%to $MSG';" | tr -d '\r')" = "1" ]; then
    ok "the reaction notice is stored as a message"
else
    bad "the reaction notice was consumed instead of stored"
fi
# The referenced message must be untouched — this is the behaviour 36f1adf
# introduced and that this script now pins as reverted.
if [ -z "$(reactions_of)" ]; then
    ok "no reaction was applied to the referenced message"
else
    bad "reaction was applied to the referenced message ('$(reactions_of)')"
fi

info "Removed <emoji> from <snippet> is a message too, and changes nothing"
adb_ emu sms send "$NUM" "Removed 👍 from $MSG" >/dev/null 2>&1
sleep 5
if [ "$(sql "SELECT COUNT(*) FROM messages WHERE body LIKE 'Removed%from $MSG';" | tr -d '\r')" = "1" ]; then
    ok "the removal notice is stored as a message"
else
    bad "the removal notice was consumed instead of stored"
fi
if [ -z "$(reactions_of)" ]; then
    ok "the referenced message still carries no reaction"
else
    bad "the referenced message gained a reaction ('$(reactions_of)')"
fi

info "An ordinary message is still stored"
adb_ emu sms send "$NUM" "just a normal reply $TS" >/dev/null 2>&1
sleep 4
# Matched on the unique body, not a LIKE prefix: rows from earlier runs (their
# conversations were deleted, their rowids later reused) would otherwise be
# counted and make the check lie.
ORD=$(sql "SELECT COUNT(*) FROM messages WHERE body='just a normal reply $TS';" | tr -d '\r')
if [ "$ORD" = "1" ]; then
    ok "ordinary text still stored"
else
    bad "ordinary text was not stored"
fi

echo ""
info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
