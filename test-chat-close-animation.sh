#!/usr/bin/env bash
# Regression: closing a chat keeps its exit-animation window.
#
# Reported: "When click back button or swap back in phone Close chat screen not
# showing animation but opening chat screen showing animation". The fade that was
# removed from the opening (so the list could not show through the rising chat)
# was still on the closing, which made it dissolve instead of move.
#
# The fade/position decision is pinned by ChatTransitionTest. What only a device
# can answer is whether the chat *survives long enough to animate at all*: a route
# change that disposes the chat in the same frame leaves nothing to draw. The app
# marks both moments (NavTransition "chat to list" and "chat closed") and this
# script measures the gap.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

NUM="+15559443333"

adb_ root >/dev/null 2>&1; sleep 1
sql() { adb_ shell "sqlite3 /data/data/$PKG/databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r'; }

cleanup() {
    sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM');" >/dev/null 2>&1
    sql "DELETE FROM conversations WHERE address='$NUM';" >/dev/null 2>&1
}
trap cleanup EXIT
cleanup

sql "INSERT INTO conversations(address,name,snippet,timestamp,unread_count) VALUES('$NUM','closeprobe','last',$(date +%s000),0);" >/dev/null 2>&1
CID=$(sql "SELECT id FROM conversations WHERE address='$NUM';")
[ -z "$CID" ] && { bad "could not seed a conversation"; exit 1; }
sql "INSERT INTO messages(conversation_id,body,timestamp,status,is_me) VALUES($CID,'last message',$(date +%s000),'sent',1);" >/dev/null 2>&1

info "Open the chat, then press Back"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
adb_ shell logcat -c >/dev/null 2>&1
adb_ shell am start -n "$ACT" --es open_conversation_address "$NUM" >/dev/null 2>&1
sleep 6
# A first launch can sit behind the SMS-role dialog.
for i in 1 2 3; do
    dump_ui >/dev/null 2>&1 || true
    if grep -q 'text="ALLOW"' "$TMP/ui.xml"; then
        c=$(center_of "ALLOW" 2>/dev/null) && adb_ shell input tap $c >/dev/null 2>&1
        sleep 1.5
    else
        break
    fi
done
dump_ui >/dev/null 2>&1 || true
grep -q 'class="android.widget.EditText"' "$TMP/ui.xml" \
    && ok "the chat opened" || bad "the chat did not open"
adb_ shell input keyevent 4 >/dev/null 2>&1
sleep 3

OPENING=$(adb_ shell logcat -d -s NavTransition 2>/dev/null | tr -d '\r' | grep -c "chat to list")
[ "$OPENING" -gt 0 ] && ok "closing selected the chat-to-list transition" \
    || bad "the chat-to-list transition never ran"

# Milliseconds between the route change and the chat being disposed. The slide is
# 300ms; anything under ~220ms means the content was gone before it could move.
GAP=$(adb_ shell logcat -d -s NavTransition 2>/dev/null | tr -d '\r' | python3 -c '
import re, sys
start = closed = None
for line in sys.stdin:
    m = re.match(r"\d+-\d+ (\d+):(\d+):(\d+)\.(\d+)", line)
    if not m:
        continue
    ms = int(m.group(1)) * 3600000 + int(m.group(2)) * 60000 + int(m.group(3)) * 1000 + int(m.group(4))
    if "chat to list" in line:
        start = ms
    elif "chat closed" in line and start is not None:
        closed = ms
if start is not None and closed is not None:
    print(closed - start)
')
if [ -z "$GAP" ]; then
    bad "the chat close was never reported"
elif [ "$GAP" -ge 220 ]; then
    ok "the chat lived ${GAP}ms through the exit animation"
else
    bad "the chat was torn down after only ${GAP}ms - nothing to animate"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
exit $((FAIL > 0))
