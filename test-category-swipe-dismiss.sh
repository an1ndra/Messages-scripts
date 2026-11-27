#!/usr/bin/env bash
# The category row is a thing you ask for: pull the list down to reveal it,
# swipe up on the row itself to put it away. Hiding it also drops the filter,
# so the inbox is back to showing everything.
#
# What it asserts:
#   * pulling down reveals the row,
#   * swiping up over the row hides it and restores All,
#   * pulling down again brings the row back.
#
# Run: scripts/test-category-swipe-dismiss.sh
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

OTP_ADDR="+15559330001"
PER_ADDR="+15559330002"
OTP_BODY="Your verification code is 739204 SWIPETEST"
PER_BODY="dinner at eight SWIPETEST"

dbq() { adb_su "run-as $PKG sqlite3 databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r'; }

# A failed dump leaves the last screen in ui.xml; chip bounds from that file
# land on a conversation row instead of the chip.
fresh_dump() {
    rm -f "$TMP/ui.xml" "$TMP/ui.decoded.xml"
    dump_ui
}

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    for a in "$OTP_ADDR" "$PER_ADDR"; do
        dbq "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$a');" >/dev/null 2>&1 || true
        dbq "DELETE FROM conversations WHERE address='$a';" >/dev/null 2>&1 || true
    done
}
trap cleanup EXIT

for a in "$OTP_ADDR" "$PER_ADDR"; do
    dbq "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$a');" >/dev/null 2>&1
    dbq "DELETE FROM conversations WHERE address='$a';" >/dev/null 2>&1
done

info "Two threads, one OTP and one personal"
NOW=$(date +%s000)
for spec in "$OTP_ADDR|$OTP_BODY" "$PER_ADDR|$PER_BODY"; do
    a=${spec%%|*}; body=${spec#*|}
    dbq "INSERT INTO conversations(address,name,snippet,timestamp,category,archived,deleted_at,pinned) VALUES('$a','$a','$body',$NOW,'',0,0,0);" >/dev/null
    cid=$(dbq "SELECT id FROM conversations WHERE address='$a';")
    [ -n "$cid" ] || { bad "could not seed $a"; exit 1; }
    dbq "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,sub_id,transport,address) VALUES($cid,'$body',$NOW,0,'received',1,'sms','$a');" >/dev/null
done
ok "seeded both threads"

adb_ shell am force-stop "$PKG" >/dev/null 2>&1
adb_ shell am start -n "$ACT" >/dev/null 2>&1
if ! wait_for_text "$OTP_BODY" 24; then
    bad "the inbox never showed the seeded threads"
    exit 1
fi

pull_down() {
    for _ in 1 2 3; do
        adb_ shell input swipe 540 700 540 1500 300 >/dev/null 2>&1
        sleep 1
    done
    # Let the fling settle before tapping or swiping the row.
    sleep 4
}

chip_centre() {
    python3 - "$TMP/ui.xml" "$1" <<'PY'
import re, sys, html
xml = open(sys.argv[1], encoding='utf-8', errors='replace').read()
for tag in re.findall(r'<node[^>]*>', xml):
    text = re.search(r'text="([^"]*)"', tag)
    bounds = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', tag)
    if not (text and bounds) or html.unescape(text.group(1)) != sys.argv[2]:
        continue
    x1, y1, x2, y2 = map(int, bounds.groups())
    if y1 < 400:
        print((x1 + x2) // 2, (y1 + y2) // 2)
        break
PY
}

info "Pull down reveals the row"
pull_down
fresh_dump >/dev/null 2>&1 || true
if grep -qF 'text="OTP"' "$TMP/ui.xml"; then
    ok "the pull revealed the category row"
else
    bad "no category row after pulling down"
fi

info "Swipe up on the row hides it and restores All"
fresh_dump >/dev/null 2>&1 || true
centre=$(chip_centre "OTP")
if [ -z "$centre" ]; then
    bad "could not find the row to swipe"
else
    x=${centre% *}; y=${centre#* }
    adb_ shell input swipe "$x" "$y" "$x" 100 450 >/dev/null 2>&1
    sleep 3
    fresh_dump >/dev/null 2>&1 || true
    if grep -qF 'text="All"' "$TMP/ui.xml" || grep -qF 'text="OTP"' "$TMP/ui.xml"; then
        bad "the category row stayed on screen after the swipe"
    else
        ok "the upward swipe hid the category row"
    fi
    if grep -qF "$OTP_BODY" "$TMP/ui.xml" && grep -qF "$PER_BODY" "$TMP/ui.xml"; then
        ok "hiding the row brought back All"
    else
        bad "the filter stayed on after the row was hidden"
    fi
fi

info "Pulling down again brings the row back"
pull_down
fresh_dump >/dev/null 2>&1 || true
if grep -qF 'text="OTP"' "$TMP/ui.xml" && grep -qF 'text="Transactions"' "$TMP/ui.xml"; then
    ok "the row can be revealed again"
else
    bad "the row never came back"
fi

echo
echo "  PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && echo "=== OK ===" || echo "=== FAILED ==="
exit $((FAIL > 0))
