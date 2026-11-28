#!/usr/bin/env bash
# Issue #531: a new SMS from a sender whose conversation is in Trash must not
# bring the deleted history back into the Inbox. Google Messages, QKSMS and
# Fossify all start a fresh thread; this app restored the whole conversation.
source "$(dirname "$0")/env.sh"

STAMP=$(date +%s)
NUM="+1555$(printf '%06d' $((STAMP % 1000000)))"
NAME="FreshThread"
OLD1="old one $STAMP"
OLD2="old two $STAMP"
NEW="fresh after delete $STAMP"
TS=$((STAMP * 1000))
PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

sql() { echo "$1" | adb_ shell "run-as $PKG sqlite3 databases/messages.db" 2>/dev/null | tr -d '\r'; }
psql() { adb_su "sqlite3 /data/data/com.android.providers.telephony/databases/mmssms.db \"$1\"" 2>/dev/null | tr -d '\r'; }

kill_stale_ui() {
    local pid
    pid=$(adb_ shell ps -A 2>/dev/null | awk '/com.android.cli.interact.instrumentation/{print $2}' | head -1 | tr -d '\r')
    [ -n "$pid" ] && adb_su "kill -9 $pid" >/dev/null 2>&1 || true
}

dump_clean() {
    kill_stale_ui
    dump_ui "$@"
}

center_in_dump() {
    python3 - "$TMP/ui.decoded.xml" "$1" <<'PY'
import re, sys
xml = open(sys.argv[1], encoding="utf-8", errors="replace").read()
q = sys.argv[2]
for node in re.findall(r'<node[^>]*>', xml):
    if 'text="' + q + '"' not in node and 'content-desc="' + q + '"' not in node:
        continue
    b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', node)
    if not b:
        continue
    x1, y1, x2, y2 = (int(g) for g in b.groups())
    print((x1 + x2) // 2, (y1 + y2) // 2)
    break
PY
}

center_containing() {
    python3 - "$TMP/ui.decoded.xml" "$1" <<'PY'
import re, sys
xml = open(sys.argv[1], encoding="utf-8", errors="replace").read()
q = sys.argv[2]
for node in re.findall(r'<node[^>]*>', xml):
    if q not in node:
        continue
    b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', node)
    if not b:
        continue
    x1, y1, x2, y2 = (int(g) for g in b.groups())
    print((x1 + x2) // 2, (y1 + y2) // 2)
    break
else:
    sys.exit(1)
PY
}

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    sql "DELETE FROM message_provider_ids WHERE message_id IN (SELECT id FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM')); DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM'); DELETE FROM conversations WHERE address='$NUM';" >/dev/null 2>&1
    psql "DELETE FROM sms WHERE address='$NUM';" >/dev/null 2>&1
}
trap cleanup EXIT

info "Seed a conversation with two old messages"
cleanup
adb_su "cmd role add-role-holder android.app.role.SMS $PKG" >/dev/null 2>&1
sql "INSERT INTO conversations(address,name,snippet,timestamp,last_is_me) VALUES('$NUM','$NAME','$OLD2',$TS,0); INSERT INTO messages(conversation_id,body,timestamp,is_me,status,media_type) SELECT id,'$OLD1',$TS,0,'received','text' FROM conversations WHERE address='$NUM'; INSERT INTO messages(conversation_id,body,timestamp,is_me,status,media_type) SELECT id,'$OLD2',$TS+1,0,'received','text' FROM conversations WHERE address='$NUM';"
CID=$(sql "SELECT id FROM conversations WHERE address='$NUM' LIMIT 1;")
[ -n "$CID" ] || { bad "could not seed the conversation"; exit 1; }

adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 6
dump_clean >/dev/null 2>&1 || true
grep -qF "$OLD2" "$TMP/ui.decoded.xml" && ok "old conversation is on the home list" || bad "old conversation is missing from the home list"

info "Delete it through the real long-press action"
C=$(center_containing "$OLD2") || { bad "could not locate the old conversation row"; exit 1; }
read -r X Y <<< "$C"
adb_ shell input swipe "$X" "$Y" "$X" "$Y" 900 >/dev/null 2>&1
sleep 2
dump_clean >/dev/null 2>&1 || true
DELETE_LABEL=$(res_string sheet_delete)
C=$(center_in_dump "$DELETE_LABEL") || { bad "no Delete action in the menu"; exit 1; }
read -r X Y <<< "$C"
adb_ shell input tap "$X" "$Y" >/dev/null 2>&1
sleep 2
DELETED=$(sql "SELECT deleted_at FROM conversations WHERE id=$CID;")
[ -n "$DELETED" ] && [ "$DELETED" != "0" ] && ok "long-press Delete moved the conversation to Trash" || bad "conversation was not deleted (deleted_at='$DELETED')"

info "Send a new SMS from the same sender"
for attempt in 1 2 3; do
    adb_ emu sms send "$NUM" "$NEW" >/dev/null 2>&1
    for _ in $(seq 1 15); do
        SEEN=$(sql "SELECT count(*) FROM messages WHERE body='$NEW';")
        [ "$SEEN" = "1" ] && break
        sleep 1
    done
    [ "$SEEN" = "1" ] && break
done
[ "$SEEN" = "1" ] && ok "inbound SMS was stored" || { bad "inbound SMS never reached the app"; exit 1; }

ACTIVE=$(sql "SELECT count(*) FROM conversations WHERE address='$NUM' AND deleted_at=0;")
TRASHED=$(sql "SELECT count(*) FROM conversations WHERE address='$NUM' AND deleted_at>0;")
[ "$ACTIVE" = "1" ] && ok "one active conversation exists" || bad "active conversation count is $ACTIVE"
[ "$TRASHED" = "1" ] && ok "the deleted conversation is still in Trash" || bad "trashed conversation count is $TRASHED"

NEW_CID=$(sql "SELECT id FROM conversations WHERE address='$NUM' AND deleted_at=0 LIMIT 1;")
if [ -n "$NEW_CID" ] && [ "$NEW_CID" != "$CID" ]; then
    ok "the new message opened a new conversation"
else
    bad "the new message reused the deleted conversation (id '$NEW_CID')"
fi

IN_ACTIVE=$(sql "SELECT group_concat(body) FROM messages WHERE conversation_id=$NEW_CID AND deleted_at=0;")
case "$IN_ACTIVE" in
    *"$NEW"*) ok "the active conversation contains the new message" ;;
    *) bad "the active conversation is missing the new message" ;;
esac
case "$IN_ACTIVE" in
    *"$OLD1"*|*"$OLD2"*) bad "the active conversation restored the deleted history" ;;
    *) ok "the active conversation has no deleted history" ;;
esac

IN_TRASH=$(sql "SELECT group_concat(body) FROM messages WHERE conversation_id=$CID;")
case "$IN_TRASH" in
    *"$OLD1"*|*"$OLD2"*) ok "Trash still holds the old messages" ;;
    *) bad "Trash lost the old messages" ;;
esac

info "Open the new chat and read its bubbles"
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 5
C=""
for _ in $(seq 1 10); do
    dump_clean >/dev/null 2>&1 || true
    C=$(center_containing "$NEW") || C=""
    [ -n "$C" ] && break
    sleep 2
done
[ -n "$C" ] || { bad "could not find the new conversation on the home list"; exit 1; }
read -r X Y <<< "$C"
adb_ shell input tap "$X" "$Y" >/dev/null 2>&1
sleep 3
dump_clean >/dev/null 2>&1 || true
grep -qF "$NEW" "$TMP/ui.decoded.xml" && ok "new message is visible in the chat" || bad "new message is not visible in the chat"
grep -qF "$OLD1" "$TMP/ui.decoded.xml" && bad "old message is visible in the chat" || ok "no old message is visible in the chat"

echo ""
info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
