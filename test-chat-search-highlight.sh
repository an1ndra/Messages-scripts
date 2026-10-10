#!/usr/bin/env bash
# Issue: searching the home list and tapping a conversation opened the chat at
# the bottom, so the user could not see where the keyword actually was. The
# query is now handed to the chat, which highlights the matching message and
# scrolls to it.
#
# The conversation is named with the keyword so the home search finds it by
# name, while the only matching *message* is the oldest one — off screen unless
# the chat scrolls to it. A pre-fix build lands on the tail and fails here.
source "$(dirname "$0")/env.sh"

KW="zebra$(date +%s)"
NUM="+15559990201"
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

info "Seed a conversation whose only keyword message is the oldest"
cleanup
sql "INSERT INTO conversations(address,name,snippet,timestamp,last_is_me) VALUES('$NUM','$KW','tail message',$TS,0);"
sql "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,media_type) SELECT id,'the $KW lives here',$TS,0,'received','text' FROM conversations WHERE address='$NUM';"
for i in $(seq 1 45); do
    sql "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,media_type) SELECT id,'filler-$i',$((TS + i * 60000)),0,'received','text' FROM conversations WHERE address='$NUM';"
done

info "Search the home list for the keyword"
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 5
if ! tap_text "Search" >/dev/null 2>&1; then bad "no Search button"; exit 1; fi
sleep 1
type_text "$KW" >/dev/null 2>&1
sleep 2
if ui_has "tail message"; then ok "conversation found by search"; else bad "conversation not in search results"; exit 1; fi

info "Open it and expect the matching message to be scrolled into view"
C=$(center_of_contains "tail message")
[ -n "$C" ] || { bad "could not tap the conversation row"; exit 1; }
adb_ shell input tap $C
sleep 5

dump_ui >/dev/null 2>&1
MATCH_LINE=$(grep -o 'text="the '"$KW"' lives here"[^>]*bounds="[^"]*"' "$TMP/ui.xml" 2>/dev/null | head -1)
if [ -z "$MATCH_LINE" ]; then
    dump_ui >/dev/null 2>&1
    MATCH_LINE=$(grep -o 'text="the '"$KW"' lives here"[^>]*bounds="[^"]*"' "$TMP/ui.xml" 2>/dev/null | head -1)
fi
if [ -n "$MATCH_LINE" ]; then
    ok "matching message auto-scrolled into view"
else
    bad "matching message not visible after opening from search"
fi

# Tap the chat's contact header, which opens contact details. Matched by
# geometry, not text: the header shows the address (no Contacts entry for this
# number) wrapped in bidi isolate marks, so no exact-text match can reach it.
# It is the clickable node between the Back button and the Call button.
tap_chat_header() {
    local c
    dump_ui || return 1
    c=$(python3 - "$TMP/ui.xml" <<'PY'
import re, sys
xml = open(sys.argv[1], encoding="utf-8", errors="replace").read()
best = None
for n in re.findall(r'<node[^>]*>', xml):
    if 'clickable="true"' not in n:
        continue
    b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', n)
    if not b:
        continue
    x1, y1, x2, y2 = (int(g) for g in b.groups())
    if y1 > 320:
        continue
    if x1 >= 140 and x2 <= 800:
        best = ((x1 + x2) // 2, (y1 + y2) // 2)
        break
if best:
    print(best[0], best[1])
PY
    ) || return 1
    [ -n "$c" ] || return 1
    adb_ shell input tap $c
    echo "[tap] chat header at ($c)"
}

if echo "$MATCH_LINE" | grep -q 'content-desc="[^"]*Search result"'; then
    ok "matching message marked as the search result"
else
    bad "matching message has no search-result marker"
fi

# Leaving for contact details consumes the handoff. ChatScreen is disposed by
# the route change, so on a build that kept `chatSearchQuery` set, coming back
# built a fresh chat that re-read the same query and replayed the highlight.
info "Open contact details and come back — the highlight must not replay"
if tap_chat_header >/dev/null 2>&1; then
    sleep 3
    dump_ui >/dev/null 2>&1 || true
    # "Block number" only exists on the contact details sheet. Checking for the
    # address instead is vacuous: the chat header shows it too, so the assertion
    # would pass without ever leaving the chat.
    if grep -q "Block number" "$TMP/ui.decoded.xml"; then
        ok "contact details opened"
    else
        bad "contact details did not open"
    fi
    adb_ shell input keyevent KEYCODE_BACK
    # Poll rather than reading one dump: the keyword message is the *oldest* of
    # the seeded thread, so re-scrolling to it makes the pager grow past the
    # first chunk. A single dump taken early sees neither the row nor its
    # marker and would pass a broken build for the wrong reason.
    REPLAY=0
    for i in $(seq 1 10); do
        sleep 2
        dump_ui >/dev/null 2>&1 || continue
        if grep -q "Search result" "$TMP/ui.decoded.xml"; then REPLAY=1; break; fi
    done
    if [ "$REPLAY" = "1" ]; then
        bad "highlight replayed after returning from contact details"
    else
        ok "no highlight replay after returning from contact details"
    fi
else
    bad "could not tap the chat header to open details"
fi

echo ""
info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
