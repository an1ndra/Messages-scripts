#!/usr/bin/env bash
# Issue #284: opening a thread from the home search must not leave the search
# field holding focus.
#
# The conversation list is composed outside AnimatedContent so it keeps its
# scroll position, which means it stays alive *behind* the chat. A search
# TextField that still holds focus therefore keeps its IME connection and draws
# its cursor handle on top of the chat.
#
# The handle is a rendering artifact and does not appear in a uiautomator dump,
# so this asserts the cause instead: the IME must be released once the chat is
# showing. That is observable with dumpsys input_method, no screenshot needed.
source "$(dirname "$0")/env.sh"

NUM="+15558800088"
MARK="cursor$(date +%s)"
TS=$(( $(date +%s) * 1000 ))
PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

sql() { echo "$1" | adb_ shell "run-as $PKG sqlite3 databases/messages.db"; }

cleanup() {
    sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM');"
    sql "DELETE FROM conversations WHERE address='$NUM';"
}
trap cleanup EXIT

ime_shown() {
    adb_ shell dumpsys input_method 2>/dev/null | grep -o 'mInputShown=[a-z]*' | head -1
}

row_bounds() { # prints "x y" of the seeded row, or fails
    dump_ui || return 1
    python3 - "$TMP/ui.xml" "$MARK" <<'PY'
import re, sys
try:
    data = open(sys.argv[1], encoding="utf-8", errors="replace").read()
except OSError:
    sys.exit(1)
q = re.escape("Cursor" + sys.argv[2])
m = re.search(r'content-desc="[^"]*' + q + r'[^"]*"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', data)
if not m:
    sys.exit(1)
x1, y1, x2, y2 = (int(m.group(i)) for i in (1, 2, 3, 4))
print((x1 + x2) // 2, (y1 + y2) // 2)
PY
}

info "Seed a conversation"
cleanup
sql "INSERT INTO conversations(address,name,snippet,timestamp,last_is_me) VALUES('$NUM','Cursor$MARK','hello there',$TS,0);" >/dev/null
sql "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,media_type) SELECT id,'first msg',$TS,0,'received','text' FROM conversations WHERE address='$NUM';" >/dev/null
sql "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,media_type) SELECT id,'second msg',$((TS + 60000)),1,'sent','text' FROM conversations WHERE address='$NUM';" >/dev/null

info "Search, then open the result"
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 6
if ! tap_text "Search" >/dev/null 2>&1; then bad "no Search button"; exit 1; fi
sleep 1
type_text "880-0088" >/dev/null 2>&1
sleep 2
if [ "$(ime_shown)" = "mInputShown=true" ]; then
    ok "search field holds the IME while searching"
else
    bad "search field never took the IME (test cannot observe the leak)"
fi

C=$(row_bounds) || { bad "seeded row not found in results"; exit 1; }
adb_ shell input tap $C
sleep 4

if ui_has "Cursor$MARK"; then ok "chat opened for the searched thread"; else bad "chat did not open"; exit 1; fi

info "The IME must be released once the chat is showing"
sleep 2
if [ "$(ime_shown)" = "mInputShown=false" ]; then
    ok "no field still holding the IME (cursor handle cannot linger)"
else
    bad "IME still served after opening the chat — the search field kept focus"
fi

echo ""
info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))