#!/usr/bin/env bash
# Regression: a chat opens with its whole history already in place.
#
# Reported twice: "I have so many messages ... when I open chat I see chat
# flickering every time I open chat". That originated in chunked loading: opening
# a 300-message thread pulled older history in 40-row chunks while the list sat at
# the bottom (7 loads, 8 bottom snaps in 2.5s), and each prepend shifted every
# visible row for a frame before the follow-bottom snap pulled it back.
#
# The pager is gone. The chat now requests the whole thread in one query, so a
# cold open must log a single full-size load (`ChatLoad ... rows=<total>`) and no
# prepend at all, and scrolling to the top must find the first message already on
# screen instead of triggering a page request.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

NUM="+15559440001"
ROWS=300
MSG="message number $((ROWS - 1))"
OLDEST="message number 0"

adb_ root >/dev/null 2>&1; sleep 1
sql() { adb_ shell "sqlite3 /data/data/$PKG/databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r'; }

cleanup() {
    sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM');" >/dev/null 2>&1
    sql "DELETE FROM conversations WHERE address='$NUM';" >/dev/null 2>&1
}
trap cleanup EXIT
cleanup

full_loads() {
    adb_ logcat -d -s ChatLoad 2>/dev/null | tr -d '\r' \
        | grep -cE "rows=$ROWS( |$)"
}
paging_requests() { adb_ logcat -d -s ChatPaging:D ChatPreload:D 2>/dev/null | grep -cE "scroll-up load|search jump"; }

info "Seed a $ROWS-message conversation"
sql "INSERT INTO conversations(address,name,snippet,timestamp,unread_count) VALUES('$NUM','longthread','$MSG',$(date +%s000),0);" >/dev/null 2>&1
CID=$(sql "SELECT id FROM conversations WHERE address='$NUM';")
[ -z "$CID" ] && { bad "could not seed a conversation"; exit 1; }
python3 - "$CID" "$ROWS" > /tmp/opencode/chat-open-seed.sql <<'PY'
import sys
cid, count = int(sys.argv[1]), int(sys.argv[2])
base = 1793000000000
for i in range(count):
    is_me = 1 if i % 3 == 0 else 0
    print(f"INSERT INTO messages(conversation_id,body,timestamp,status,is_me) "
          f"VALUES({cid},'message number {i}',{base + i * 60000},'received',{is_me});")
PY
adb_ push /tmp/opencode/chat-open-seed.sql /data/local/tmp/chat-open-seed.sql >/dev/null 2>&1
adb_ shell "sqlite3 /data/data/$PKG/databases/messages.db < /data/local/tmp/chat-open-seed.sql" >/dev/null 2>&1
SEEDED=$(sql "SELECT count(*) FROM messages WHERE conversation_id=$CID;")
[ "$SEEDED" = "$ROWS" ] && ok "seeded $SEEDED messages" || bad "seeded only $SEEDED messages"

info "Opening the chat loads the whole thread, in one window"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
adb_ shell logcat -c >/dev/null 2>&1
adb_ shell am start -n "$ACT" --es open_conversation_address "$NUM" >/dev/null 2>&1
sleep 8
LOADS=$(full_loads)
if [ "$LOADS" -gt 0 ]; then
    ok "opened with all $ROWS messages loaded (query returned rows=$ROWS)"
else
    bad "open never fetched the whole $ROWS-message thread"
fi
OPEN_PAGING=$(paging_requests)
if [ "$OPEN_PAGING" = "0" ]; then
    ok "no chunk was prepended while the chat opened"
else
    bad "$OPEN_PAGING paging request(s) during open - the flicker can come back"
fi
# Poll rather than sample once: the list paints at the top for a frame before
# the open scroll lands, and a dump taken during that frame (or while a busy
# emulator is still settling) would report a false failure.
if wait_layout_has "$MSG" 12; then
    ok "the chat opened on the newest message"
else
    bad "the newest message is not on screen after opening"
fi

info "Scrolling up finds the first message without a page request"
# The flings on this AVD sometimes stop short, so the scroll is retried until the
# oldest message is actually on screen (a whole screen of fresh swipes per try).
SCROLL_PAGING=0
REACHED=""
# The flings on this AVD sometimes stop short, so the scroll is retried until the
# oldest message is actually on screen (a whole screen of fresh swipes per try).
for attempt in $(seq 1 8); do
    for i in $(seq 1 12); do
        adb_ shell input swipe 540 900 540 1900 300 >/dev/null 2>&1
        sleep 0.2
    done
    sleep 1.5
    if wait_layout_has "$OLDEST" 4; then REACHED=1; break; fi
    SCROLL_PAGING=$(paging_requests)
done
if [ -n "$REACHED" ]; then
    ok "the first message of the thread was already loaded"
else
    bad "scrolling to the top never showed the first message"
fi
[ "$SCROLL_PAGING" = "0" ] && ok "scrolling up asked for no extra page" \
    || bad "scrolling up still paged history ($SCROLL_PAGING request(s))"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
exit $((FAIL > 0))
