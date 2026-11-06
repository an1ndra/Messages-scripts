#!/usr/bin/env bash
# Issue #406: a long thread stopped loading older history at an AUTO_CAP of 400
# rows, so scrolling to the top of a longer chat dead-ended in the middle of the
# conversation. A search hit below the cap was reached only by walking the
# history in fixed 200-row steps, each behind the scroll-up settling delay.
#
# The pager is gone: the chat now loads the whole thread in one query on open.
# That removes the chunk stops, the prepend anchor race that used to strand the
# spinner, and the multi-step search jump in one go.
#
# Asserts:
#   1. opening a 1,500-message thread fetches all 1,500 rows;
#   2. scrolling from the bottom to the top reaches the oldest message without a
#      single page request or loading spinner;
#   3. a search hit 1,198 rows back opens directly on the hit, with the thread's
#      full history loaded too.
# The app logs the query's row count under the `ChatLoad` tag.
source "$(dirname "$0")/env.sh"

NAME_A="Long History"
NUM_A="+15558808611"
TOTAL_A=1500
NAME_B="Buried Search Hit"
NUM_B="+15558808612"
TOTAL_B=1200
KW="pagingneedle$(date +%s)"
TS=$(( $(date +%s) * 1000 ))
PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

sql() { echo "$1" | adb_ shell "run-as $PKG sqlite3 databases/messages.db"; }

cleanup() {
    for NUM in "$NUM_A" "$NUM_B"; do
        sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM');" >/dev/null 2>&1
        sql "DELETE FROM conversations WHERE address='$NUM';" >/dev/null 2>&1
    done
}
trap cleanup EXIT

seed() {
    # seed <address> <name> <count> <special-index> <special-body>
    local num="$1" name="$2" count="$3" special="$4" body="$5" q=""
    sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$num'); DELETE FROM conversations WHERE address='$num';" >/dev/null
    q="INSERT INTO conversations(address,name,snippet,timestamp,unread_count,last_is_me,archived) VALUES('$num','$name','tail',$((TS + count * 60000)),0,0,0);"
    local i b
    for i in $(seq 1 "$count"); do
        if [ "$i" -eq "$special" ]; then b="$body"; else b="filler $i"; fi
        q="$q INSERT INTO messages(conversation_id,body,timestamp,is_me,status,media_type) SELECT id,'$b',$((TS + i * 60000)),0,'received','text' FROM conversations WHERE address='$num';"
    done
    sql "$q" >/dev/null
}

open_chat() {
    adb_ shell am force-stop "$PKG"; sleep 1
    adb_ shell am start -n "$ACT" --es open_conversation_address "$1" >/dev/null 2>&1
    sleep 6
    wait_layout_has "Message" 8 || true
    sleep 1
}

full_rows() {
    # full_rows <total> -> number of ChatLoad lines reporting that row count
    adb_ shell logcat -d -s ChatLoad:D 2>/dev/null | tr -d '\r' \
        | grep -cE "rows=$1( |$)"
}

saw_marker() { layout_has "$1"; }

info "Hold the default SMS role"
adb_su "cmd role add-role-holder android.app.role.SMS $PKG" >/dev/null 2>&1

info "Part 1: a $TOTAL_A-message thread opens with its entire history"
seed "$NUM_A" "$NAME_A" "$TOTAL_A" 1 "the oldest history marker"
adb_ shell logcat -c
open_chat "$NUM_A"

ROWS=$(full_rows "$TOTAL_A")
if [ "$ROWS" -gt 0 ]; then
    ok "opening the thread loaded all $TOTAL_A messages in one query"
else
    bad "the open query never returned all $TOTAL_A rows"
fi

# Tight swipes with no per-swipe UI dumps, so the whole thread is traversed in
# one run; the probe at the end checks the first message has been reached.
for i in $(seq 1 120); do
    adb_ shell input swipe 540 700 540 1950 80
    sleep 0.20
done
sleep 2
if saw_marker "the oldest history marker"; then
    ok "scrolling reached the first message of a $TOTAL_A-message thread"
else
    bad "scrolling never reached the first message of the thread"
fi

# No pager means no page requests and no spinner at the top. Both are reported
# live by the app, so a reintroduced pager shows up here immediately.
PAGING=$(adb_ shell logcat -d -s ChatPaging:D ChatPreload:D 2>/dev/null | tr -d '\r' \
    | grep -cE 'scroll-up load|search jump')
if [ "$PAGING" = "0" ]; then
    ok "scrolling up issued no page request (the thread was already loaded)"
else
    bad "the pager is back: $PAGING page request(s) during scroll-up"
fi
if layout_has "Load earlier messages"; then
    bad "loading spinner is on screen at the top of a fully loaded list"
else
    ok "no loading spinner at the top"
fi

info "Part 2: a search hit ~1,200 rows back opens directly on the hit"
seed "$NUM_B" "$NAME_B" "$TOTAL_B" 2 "the $KW needle"
adb_ shell logcat -c
adb_ shell am force-stop "$PKG"; sleep 1
FOUND=""
for _ in 1 2 3; do
    adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 5
    if tap_layout "Search" >/dev/null 2>&1; then FOUND=1; break; fi
    adb_ shell input keyevent 4 >/dev/null 2>&1; sleep 2
done
if [ -z "$FOUND" ]; then bad "no Search button"; echo ""; info "Results: $PASS passed, $FAIL failed"; exit 1; fi
sleep 1
type_text "$KW" >/dev/null 2>&1; sleep 4
# The row titles with the address, not the seeded `name` column: the app
# resolves display names from contacts and falls back to the number here.
if ! layout_has "$NUM_B"; then
    bad "thread not listed by its buried keyword"
else
    ok "thread listed by a keyword hit 1,198 rows back"
fi
C=$(layout_center "$NUM_B")
if [ -z "$C" ]; then
    bad "could not tap the thread row"
else
    adb_ shell input tap $C
    sleep 8
    if saw_marker "the $KW needle"; then
        ok "search opened on the buried hit"
    else
        bad "search did not reach the buried hit"
    fi
    SEARCH_ROWS=$(full_rows "$TOTAL_B")
    if [ "$SEARCH_ROWS" -gt 0 ]; then
        ok "the searched thread also opened with its whole $TOTAL_B-message history"
    else
        bad "the searched thread did not load all $TOTAL_B rows"
    fi
fi

echo ""
info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
