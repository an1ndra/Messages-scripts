#!/usr/bin/env bash
# Regression for #340: several conversations can be picked at once and deleted
# together.
#
# Long-press is the entry point (it used to open the per-conversation sheet).
# The assertion is on the database afterwards: a selection bar that says "2
# selected" while deleting only one thread is the failure this catches, and a
# dump of the toolbar alone cannot tell the two apart.
#
# Both conversation lists carry the bar - the redesigned one and the legacy one,
# which is still the default - so run this with either UI selected.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

MARK="multi$(date +%s)$$"
A="+1555971${MARK: -4}"
B="+1555972${MARK: -4}"

adb_ root >/dev/null 2>&1; adb_ wait-for-device; sleep 1
sql() { adb_ shell "sqlite3 /data/data/$PKG/databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r'; }

cleanup() {
    sql "DELETE FROM messages WHERE body LIKE '%$MARK%';" >/dev/null 2>&1
    sql "DELETE FROM conversations WHERE address IN ('$A','$B');" >/dev/null 2>&1
}
trap cleanup EXIT

for p in READ_SMS RECEIVE_SMS SEND_SMS READ_CONTACTS POST_NOTIFICATIONS; do
    adb_ shell pm grant "$PKG" "android.permission.$p" >/dev/null 2>&1
done
adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1 || true

info "Seed two conversations"
TS=$(date +%s000)
for pair in "$A:alpha" "$B:beta"; do
    N=${pair%%:*}; TAG=${pair##*:}
    sql "INSERT INTO conversations(address,name,snippet,timestamp,unread_count) VALUES('$N','$MARK-$TAG','$MARK $TAG',$TS,0);" >/dev/null 2>&1
    CID=$(sql "SELECT id FROM conversations WHERE address='$N';")
    sql "INSERT INTO messages(conversation_id,body,timestamp,status) VALUES($CID,'$MARK $TAG',$TS,'received');" >/dev/null 2>&1
done
CA=$(sql "SELECT id FROM conversations WHERE address='$A';")
CB=$(sql "SELECT id FROM conversations WHERE address='$B';")
if [ -n "$CA" ] && [ -n "$CB" ]; then
    ok "two conversations seeded (A=$CA B=$CB)"
else
    bad "seeding failed (A=${CA:-none} B=${CB:-none})"; exit 1
fi

info "Launch the list"
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 6
dump_ui

# Every helper reads $TMP/ui.xml, written by env.sh's dump_ui.
NODE_CENTRE=$(cat <<'PY'
import re, sys
xml = open(sys.argv[1], encoding='utf-8', errors='replace').read()
needle, exact, clickable = sys.argv[2], sys.argv[3] == "exact", sys.argv[4] == "clickable"
for m in re.finditer(r'<node\b[^>]*>', xml):
    tag = m.group(0)
    if clickable and 'clickable="true"' not in tag:
        continue
    if exact:
        hit = re.search(r'content-desc="([^"]*)"', tag)
        if not hit or hit.group(1) != needle:
            continue
    elif needle not in tag:
        continue
    b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', tag)
    if b:
        x1, y1, x2, y2 = map(int, b.groups())
        print((x1 + x2) // 2, (y1 + y2) // 2)
        raise SystemExit(0)
PY
)

# Centre of the clickable row whose semantics label carries the marker. The row
# keeps the whole label in content-desc and is the clickable node itself, so its
# own bounds are used - looking for a preceding clickable node would find the
# toolbar button above it.
row_centre() { python3 -c "$NODE_CENTRE" "$TMP/ui.xml" "$1" substring clickable; }

# Centre of the icon whose content-desc is exactly $1 (toolbar actions).
icon_centre() { python3 -c "$NODE_CENTRE" "$TMP/ui.xml" "$1" exact any; }

POS_A=$(row_centre "$MARK alpha")
POS_B=$(row_centre "$MARK beta")
if [ -z "$POS_A" ] || [ -z "$POS_B" ]; then
    bad "seeded rows are not on screen (A='$POS_A' B='$POS_B')"
    echo ""; echo "=== RESULTS: $PASS passed, $FAIL failed ==="; exit 1
fi
ok "both seeded rows are listed"

info "Long-press starts a selection"
set -- $POS_A
adb_ shell input swipe "$1" "$2" "$1" "$2" 800 >/dev/null 2>&1
sleep 2
dump_ui
if grep -qE 'text="1 selected"' "$TMP/ui.xml"; then
    ok "long-press selects one conversation"
else
    bad "long-press did not start a selection (no '1 selected')"
fi

info "Tapping a second row extends it"
# The selection bar replaces the title row and is a different height, so the rows
# move: re-locate B instead of reusing its pre-selection coordinates.
POS_B=$(row_centre "$MARK beta")
if [ -z "$POS_B" ]; then
    bad "second row is not on screen once the selection bar is up"
else
    set -- $POS_B
    adb_ shell input tap "$1" "$2" >/dev/null 2>&1
    sleep 2
    dump_ui
    if grep -qE 'text="2 selected"' "$TMP/ui.xml"; then
        ok "second tap extends the selection to 2"
    else
        bad "selection did not extend (expected '2 selected')"
    fi
fi

info "Deleting the selection moves both to Trash"
del=$(icon_centre "Delete")
if [ -n "$del" ]; then
    set -- $del
    adb_ shell input tap "$1" "$2" >/dev/null 2>&1
    sleep 2
    ok "selection toolbar exposes a Delete action"
else
    bad "no Delete action in the selection toolbar"
fi

for _ in $(seq 1 8); do
    DA=$(sql "SELECT deleted_at FROM conversations WHERE id=$CA;")
    DB=$(sql "SELECT deleted_at FROM conversations WHERE id=$CB;")
    [ "${DA:-0}" != "0" ] && [ "${DB:-0}" != "0" ] && break
    sleep 1
done
[ "${DA:-0}" != "0" ] && ok "conversation A moved to Trash" || bad "conversation A still in the inbox"
[ "${DB:-0}" != "0" ] && ok "conversation B moved to Trash" || bad "conversation B still in the inbox"

info "The selection bar is gone"
dump_ui
if grep -qE 'text="[0-9]+ selected"' "$TMP/ui.xml"; then
    bad "selection bar still visible after deleting"
else
    ok "selection bar dismissed"
fi

echo ""
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
