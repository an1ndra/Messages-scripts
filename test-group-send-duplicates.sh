#!/usr/bin/env bash
# Issue: sending one message in a group produced N bubbles for one tap.
#
# Group text goes out as one SMS per recipient, so a single send leaves N rows
# in the system Sent box. `messages.sys_id` records only one of them, so sync
# adopted the first onto the local row and imported the rest as brand-new
# messages. `message_provider_ids` now records the full set.
#
# Asserts the local row count directly: one tap to a two-member group must
# leave exactly one message, and re-syncing must not grow it.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

PRIMARY="+15551230010"
SECOND="+1555773010"
CID=""
BODY="GroupSendProbe$(date +%s)"

sql() { echo "$1" | adb_ shell "run-as $PKG sqlite3 databases/messages.db"; }
q()   { sql "$1" | tr -d '\r'; }

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    [ -n "$CID" ] || return 0
    # The provider rows this created would otherwise be re-imported later and
    # look like a fresh 1:1 with this number.
    sql "DELETE FROM messages WHERE conversation_id=$CID AND body='$BODY'" >/dev/null 2>&1
    sql "DELETE FROM message_provider_ids WHERE message_id NOT IN (SELECT id FROM messages)" >/dev/null 2>&1
    sql "DELETE FROM conversation_recipients WHERE conversation_id=$CID
           AND address NOT IN ('$PRIMARY','$SECOND')" >/dev/null 2>&1
    sql "UPDATE conversations SET group_title='' WHERE id=$CID" >/dev/null 2>&1
}
trap cleanup EXIT

adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1
bash ./grant-permissions.sh >/dev/null 2>&1 || true

info "Preparing a two-member group"
# Make sure the thread exists, then pin it to exactly two recipients.
adb_ shell am start -a android.intent.action.SENDTO -d "smsto:$PRIMARY" "$PKG" >/dev/null 2>&1
sleep 3
cleanup
CID=$(q "SELECT id FROM conversations WHERE address='$PRIMARY'")
[ -n "$CID" ] || { bad "no conversation for $PRIMARY"; exit 1; }
sql "INSERT OR IGNORE INTO conversation_recipients(conversation_id,address)
     VALUES($CID,'$PRIMARY')" >/dev/null 2>&1
sql "INSERT OR IGNORE INTO conversation_recipients(conversation_id,address)
     VALUES($CID,'$SECOND')" >/dev/null 2>&1
sql "DELETE FROM conversation_recipients WHERE conversation_id=$CID
       AND address NOT IN ('$PRIMARY','$SECOND')" >/dev/null 2>&1
MEMBERS=$(q "SELECT count(*) FROM conversation_recipients WHERE conversation_id=$CID")
[ "$MEMBERS" = "2" ] && ok "group has 2 members" || bad "group has $MEMBERS members, expected 2"

info "Sending one message to the group"
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" --es open_conversation_address "$PRIMARY" >/dev/null 2>&1; sleep 5
tap_edittext >/dev/null 2>&1 || true
adb_ shell input text "$BODY"; sleep 1
dump_ui >/dev/null 2>&1 || true
if tap_text "Send" >/dev/null 2>&1; then
    ok "send button tapped"
else
    bad "could not tap Send"
    exit 1
fi
sleep 4

info "The provider holds one row per recipient (expected)"
# This is the shape that used to produce the duplicate: one tap, two Sent rows.
adb_ shell content query --uri content://sms --projection _id:body:type 2>/dev/null \
    | grep -c "body=$BODY" | tr -d '\r' > "$TMP/prov.txt"
PROV=$(cat "$TMP/prov.txt")
[ "${PROV:-0}" -ge 2 ] \
    && ok "one provider row per recipient ($PROV)" \
    || bad "expected >=2 provider rows, got ${PROV:-0} — cannot prove the fix here"

info "Re-syncing and counting local messages"
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 8
LOCAL=$(q "SELECT count(*) FROM messages WHERE conversation_id=$CID AND body='$BODY'")
if [ "${LOCAL:-0}" = "1" ]; then
    ok "one tap produced exactly 1 message"
else
    bad "one tap produced ${LOCAL:-0} messages, expected 1"
fi

info "Every provider row is mapped to that one message"
MAPPED=$(q "SELECT count(*) FROM message_provider_ids p JOIN messages m
           ON m.id=p.message_id WHERE m.body='$BODY' AND p.transport='sms'")
[ "${MAPPED:-0}" -ge 2 ] \
    && ok "all $MAPPED provider ids map to the single message" \
    || bad "only ${MAPPED:-0} provider id(s) mapped; the rest would re-import"

info "A second sync must not grow it"
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 8
AGAIN=$(q "SELECT count(*) FROM messages WHERE conversation_id=$CID AND body='$BODY'")
[ "$AGAIN" = "$LOCAL" ] \
    && ok "count stable across a further sync ($AGAIN)" \
    || bad "count grew from $LOCAL to ${AGAIN:-0} on re-sync"

echo ""
info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))