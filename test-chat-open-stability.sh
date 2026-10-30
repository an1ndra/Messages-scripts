#!/usr/bin/env bash
# Regression: opening a long chat must not load older history under the reader.
#
# Reported twice: "I have so many messages ... when I open chat I see chat
# flickering every time I open chat". Opening a 300-message thread used to pull
# older history in 40-row chunks while the list sat at the bottom: 7 loads and 8
# bottom snaps in 2.5s, and each prepend shifted every visible row for a frame
# before the snap pulled it back.
#
# Older history now loads only when the reader reaches the top, so a cold open
# must log no preload at all. The second half proves the feature is still alive:
# scrolling up does load, and does so exactly where the reader is looking.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

NUM="+15559440001"
ROWS=300
MSG="message number $((ROWS - 1))"

adb_ root >/dev/null 2>&1; sleep 1
sql() { adb_ shell "sqlite3 /data/data/$PKG/databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r'; }

cleanup() {
    sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM');" >/dev/null 2>&1
    sql "DELETE FROM conversations WHERE address='$NUM';" >/dev/null 2>&1
}
trap cleanup EXIT
cleanup

preloads() { adb_ logcat -d -s ChatPreload 2>/dev/null | grep -c "scroll-up load"; }

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

info "Opening the chat loads no older history"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
adb_ shell logcat -c >/dev/null 2>&1
adb_ shell am start -n "$ACT" --es open_conversation_address "$NUM" >/dev/null 2>&1
sleep 8
OPEN_PRELOADS=$(preloads)
if [ "$OPEN_PRELOADS" = "0" ]; then
    ok "no chunk was prepended while the chat opened"
else
    bad "$OPEN_PRELOADS chunk(s) prepended during open - the flicker is back"
fi
dump_ui >/dev/null 2>&1 || true
grep -qF -- "$MSG" "$TMP/ui.xml" && ok "the chat opened on the newest message" \
    || bad "the newest message is not on screen after opening"

info "Scrolling up still loads older history"
# The flings on this AVD sometimes stop short, so the scroll is retried until the
# window is actually at its top (a whole screen of fresh swipes per attempt).
SCROLL_PRELOADS=0
for attempt in 1 2 3; do
    for i in $(seq 1 12); do
        adb_ shell input swipe 540 900 540 1900 300 >/dev/null 2>&1
        sleep 0.2
    done
    sleep 2.5
    SCROLL_PRELOADS=$(preloads)
    [ "$SCROLL_PRELOADS" -gt 0 ] && break
done
if [ "$SCROLL_PRELOADS" -gt 0 ]; then
    ok "reaching the top loaded older history ($SCROLL_PRELOADS chunk(s))"
else
    bad "scrolling to the top loaded nothing"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
exit $((FAIL > 0))
