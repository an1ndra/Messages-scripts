#!/usr/bin/env bash
# Issue #284: opening a thread from the home search must land on the hit, and
# scrolling afterwards must not drag the view back to it.
#
# The chat kept snapping up to the search result while the user scrolled down.
# The scroll effect was keyed on the hit's row *index*, and the chat pager
# prepends older messages in 40-message chunks, so every chunk load shifted the
# index and re-fired scrollToItem. The seed below is longer than one chunk for
# exactly that reason.
source "$(dirname "$0")/env.sh"

NAME="ScrollJumpTest"
NUM="+15558808801"
KW="scrolljump$(date +%s)"
TOTAL=120
# Inside the newest INITIAL_CHUNK (messages 81..120) but near its older edge, so
# the hit is present the moment the chat opens and scrolling down moves past it.
# A hit older than one chunk would instead be found late by the pager, which is
# a different behaviour from the snap-back under test.
HIT=$((TOTAL - 35))
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

# First visible and last visible filler index on screen, or "-" when empty.
visible_range() {
    dump_ui >/dev/null 2>&1 || { echo "-"; return; }
    python3 - "$TMP/ui.decoded.xml" <<'PY'
import re, sys
try:
    data = open(sys.argv[1], encoding="utf-8", errors="replace").read()
except OSError:
    print("-"); raise SystemExit
idx = sorted({int(n) for n in re.findall(r'text="filler (\d+)"', data)})
print("%s-%s" % (idx[0], idx[-1]) if idx else "-")
PY
}

hit_on_screen() {
    dump_ui >/dev/null 2>&1 || return 1
    grep -qF "the $KW lives here" "$TMP/ui.decoded.xml"
}

info "Seed a $TOTAL-message thread whose only keyword hit is message $HIT"
cleanup
sql "INSERT INTO conversations(address,name,snippet,timestamp,last_is_me) VALUES('$NUM','$NAME','tail',$TS,0);" >/dev/null
for i in $(seq 1 $TOTAL); do
    if [ "$i" -eq "$HIT" ]; then body="the $KW lives here"; else body="filler $i"; fi
    sql "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,media_type) SELECT id,'$body',$((TS + i * 60000)),0,'received','text' FROM conversations WHERE address='$NUM';" >/dev/null
done

info "Search the keyword and open the thread"
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 5
if ! tap_text "Search" >/dev/null 2>&1; then bad "no Search button"; exit 1; fi
sleep 1
type_text "$KW" >/dev/null 2>&1; sleep 3
if ! ui_has "$NAME"; then bad "thread not found by its buried keyword"; exit 1; fi
ok "thread listed by a mid-thread keyword"
C=$(center_of_contains "$NAME")
[ -n "$C" ] || { bad "could not tap the thread row"; exit 1; }
adb_ shell input tap $C
sleep 5

if hit_on_screen; then ok "chat opened on the matching message ($(visible_range))"
else bad "chat did not open on the matching message"; exit 1; fi
adb_ shell input keyevent 4; sleep 2   # hide the IME so swipes reach the list
if dump_ui >/dev/null 2>&1 && grep -q 'content-desc="Search result"' "$TMP/ui.decoded.xml"; then
    ok "matching message marked as the search result"
else
    bad "matching message has no search-result marker"
fi

info "Scroll down past the hit: it must not come back into view"
# The hit sits just above where the chat opens, so scrolling down leaves it
# behind. Re-entering it later means the view was dragged back up.
for i in 1 2 3 4 5 6 7 8; do
    adb_ shell input swipe 540 1600 540 700 250
    sleep 1.3
    if [ "$i" -ge 2 ] && hit_on_screen; then
        bad "view snapped back up to the hit after scroll $i ($(visible_range))"
        SNAPPED=1
        break
    fi
done
[ -n "${SNAPPED:-}" ] || ok "view kept moving down and never returned to the hit ($(visible_range))"

sleep 3
if hit_on_screen; then bad "view snapped back to the hit after idling"; else ok "view still away from the hit after idling"; fi

echo ""
info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))