#!/usr/bin/env bash
# Issue #406: a long thread stopped loading older history at an AUTO_CAP of 400
# rows, so scrolling to the top of a longer chat dead-ended in the middle of the
# conversation. A search hit below the cap was reached only by walking the
# history in fixed 200-row steps, each behind the scroll-up settling delay.
#
# Asserts:
#   1. a 460-message thread can be scrolled past row 400 all the way to its
#      oldest message;
#   2. a search hit ~1,200 rows back is reached by one direct page, reported as
#      a `ChatPaging ... search jump ... limit=<n>` line.
# The app logs both loads under the `ChatPaging` tag.
source "$(dirname "$0")/env.sh"

NAME_A="Long History"
NUM_A="+15558808611"
TOTAL_A=460
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

last_limit() {
    adb_ shell logcat -d -s ChatPaging:D 2>/dev/null \
        | grep -oE 'limit=[0-9]+' | tail -1 | cut -d= -f2 | tr -d '\r'
}

saw_marker() { layout_has "$1"; }

info "Hold the default SMS role"
adb_su "cmd role add-role-holder android.app.role.SMS $PKG" >/dev/null 2>&1

info "Part 1: scroll a $TOTAL_A-message thread past the old 400-row cap"
seed "$NUM_A" "$NAME_A" "$TOTAL_A" 1 "the oldest history marker"
adb_ shell logcat -c
open_chat "$NUM_A"

SEEN=""
for i in $(seq 1 160); do
    adb_ shell input swipe 540 700 540 1950 90
    sleep 0.25
    if [ $((i % 3)) -eq 0 ] && saw_marker "the oldest history marker"; then SEEN=1; break; fi
done
sleep 2
if saw_marker "the oldest history marker"; then
    ok "scrolling reached the first message of a $TOTAL_A-message thread"
else
    LIM=$(last_limit)
    bad "scrolling dead-ended before the first message (loaded limit ${LIM:-unknown} of $TOTAL_A)"
fi

LIM=$(last_limit)
if [ -n "$LIM" ] && [ "$LIM" -gt 400 ]; then
    ok "pager grew past the old 400-row cap (limit=$LIM)"
else
    bad "pager never grew past 400 rows (limit ${LIM:-unknown})"
fi

# Informational: the spinner is only on screen while a page is in flight, and a
# local DB load is fast, so a dump usually misses it. Not a failure either way.
if layout_has "Load earlier messages"; then
    echo "[info] loading spinner observed at the top of the list"
else
    echo "[info] loading spinner not sampled (loads completed between dumps)"
fi

info "Part 2: a search hit ~1,200 rows back is one direct page"
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
type_text "$KW" >/dev/null 2>&1; sleep 3
if ! layout_has "$NAME_B"; then
    bad "thread not listed by its buried keyword"
else
    ok "thread listed by a keyword hit 1,198 rows back"
fi
C=$(layout_center "$NAME_B")
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
    JUMP=$(adb_ shell logcat -d -s ChatPaging:D 2>/dev/null | grep -oE 'search jump newer=[0-9]+ limit=[0-9]+' | tail -1 | tr -d '\r')
    if [ -n "$JUMP" ]; then
        J_LIMIT=$(sed -E 's/.*limit=([0-9]+)/\1/' <<< "$JUMP")
        if [ "$J_LIMIT" -gt 1000 ]; then
            ok "search used one direct page ($JUMP)"
        else
            bad "search page was too small: $JUMP"
        fi
    else
        bad "no direct search page in the log — the pager still walked the history in steps"
    fi
fi

echo ""
info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
