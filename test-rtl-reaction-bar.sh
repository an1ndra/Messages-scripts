#!/usr/bin/env bash
# Issue #408 (RTL): the reaction bar was placed by `isMe` alone, so in RTL it
# hugged the wrong physical edge and the first emoji were drawn outside the
# window. The bar must stay inside the bubble's own edge in every direction.
source "$(dirname "$0")/env.sh"

NAME="RTL Reaction"
NUM="+15558808602"
TS=$(( $(date +%s) * 1000 ))
PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

sql() { echo "$1" | adb_ shell "run-as $PKG sqlite3 databases/messages.db"; }

cleanup() {
    sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM');" >/dev/null 2>&1
    sql "DELETE FROM conversations WHERE address='$NUM';" >/dev/null 2>&1
}
trap cleanup EXIT

info "Ensure the device is RTL"
LOC=$(adb_ shell getprop persist.sys.locale | tr -d '\r')
case "$LOC" in
    ar-*|fa-*|he-*|ur-*) ok "device locale is RTL ($LOC)" ;;
    *) bad "device locale is '$LOC', not RTL — set persist.sys.locale and restart zygote first"
       echo ""; info "Results: $PASS passed, $FAIL failed"; exit 1 ;;
esac
W=$(adb_ shell wm size | sed -E 's/.*: ([0-9]+)x([0-9]+).*/\1/' | tr -d '\r')
[ -n "$W" ] || W=1080

info "Hold the default SMS role"
adb_su "cmd role add-role-holder android.app.role.SMS $PKG" >/dev/null 2>&1

info "Seed one received message"
cleanup
sql "INSERT INTO conversations(address,name,snippet,timestamp,unread_count,last_is_me,archived) VALUES('$NUM','$NAME','react me',$TS,1,0,0);" >/dev/null
sql "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,media_type) SELECT id,'reaction target message',$TS,0,'received','text' FROM conversations WHERE address='$NUM';" >/dev/null
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 5

info "Open the thread"
C=$(layout_center "$NAME") || { bad "seeded conversation not listed"; echo ""; info "Results: $PASS passed, $FAIL failed"; exit 1; }
adb_ shell input tap $C
sleep 4

info "Long-press the received bubble"
layout_json || { bad "could not dump the chat"; echo ""; info "Results: $PASS passed, $FAIL failed"; exit 1; }
B=$(python3 - "$TMP/layout.json" "reaction target message" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
q = sys.argv[2]
found = [None]
def walk(n):
    if found[0] is not None:
        return
    if isinstance(n, list):
        for c in n: walk(c)
    elif isinstance(n, dict):
        if n.get("text") == q and not n.get("off-screen"):
            b = n.get("bounds", "")
            m = __import__("re").match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", b)
            if m:
                x = (int(m.group(1)) + int(m.group(3))) // 2
                y = (int(m.group(2)) + int(m.group(4))) // 2
                found[0] = (x, y)
                return
        for key in ("content", "children"):
            for c in (n.get(key) or []): walk(c)
walk(data)
print("%s %s" % found[0] if found[0] else "")
PY
)
[ -n "$B" ] || { bad "message bubble not found"; echo ""; info "Results: $PASS passed, $FAIL failed"; exit 1; }
adb_ shell input swipe $B $B 900
sleep 2

info "The reaction bar must sit inside the screen"
layout_json || { bad "could not dump the reaction bar"; echo ""; info "Results: $PASS passed, $FAIL failed"; exit 1; }
REPORT=$(python3 - "$TMP/layout.json" "$W" <<'PY'
import json, re, sys
data = json.load(open(sys.argv[1]))
width = int(sys.argv[2])
emoji = ["👍", "😂", "❤️", "🔥", "😢", "😮", "🙏", "🎉"]
bounds = {}
def walk(n):
    if isinstance(n, list):
        for c in n: walk(c)
    elif isinstance(n, dict):
        t = n.get("text")
        if t in emoji and t not in bounds:
            m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", n.get("bounds", ""))
            if m:
                bounds[t] = (int(m.group(1)), int(m.group(3)))
        for key in ("content", "children"):
            for c in (n.get(key) or []): walk(c)
walk(data)
bad = ["%s [%d..%d]" % (e, b[0], b[1]) for e, b in bounds.items()
       if b[0] < 0 or b[1] > width]
print("seen=%d" % len(bounds))
for b in bad:
    print("out=%s" % b)
PY
)
SEEN=$(sed -n 's/^seen=//p' <<< "$REPORT")
OUT=$(sed -n 's/^out=//p' <<< "$REPORT")
if [ "${SEEN:-0}" -lt 8 ]; then
    bad "reaction bar is incomplete or clipped (saw ${SEEN:-0} of 8 emoji)"
else
    ok "all 8 reaction emoji are on screen"
fi
if [ -n "$OUT" ]; then
    bad "emoji drawn outside the ${W}px screen: $OUT"
else
    ok "every emoji stayed inside the screen bounds"
fi

echo ""
info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
