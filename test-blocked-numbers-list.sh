#!/usr/bin/env bash
# Regression for the #405 follow-up: every blocked number is reachable.
#
# Inbox settings counts `blockedNumbers.size` and the dialog iterates the same
# list, so a report of "it says 164 blocked but the list shows 14 and has no
# next page" can only be a rendering problem. The dialog's text slot was a
# plain Column: rows past the available height are measured with a zero
# height, so they exist in the tree but can never be scrolled to.
#
# This seeds 40 blocked senders, opens the dialog, and requires the oldest row
# to be invisible at first and reachable by scrolling. On the pre-fix build the
# swipe moves nothing and that last check fails.
#
# Run: scripts/test-blocked-numbers-list.sh
set -uo pipefail
cd "$(dirname "$0")"
source ./env.sh

PASS=0
FAIL=0
ok()  { echo "  [PASS] $*"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $*"; FAIL=$((FAIL + 1)); }

PREFIX="+1555000"
TOTAL=40
NEWEST_TAIL=$(printf '%04d' "$TOTAL")
OLDEST_TAIL=$(printf '%04d' 1)

dbq() {
    printf '%s' "$1" | adb_ shell "run-as $PKG sqlite3 databases/messages.db" 2>/dev/null | tr -d '\r'
}

cleanup() {
    dbq "DELETE FROM blocked_numbers WHERE number LIKE '$PREFIX%';" >/dev/null 2>&1
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
}
trap cleanup EXIT

# "x y w h off" for the first node whose text/content-desc contains $1.
layout_box() {
    local q="$1" i out
    for i in 1 2 3; do
        layout_json || { sleep 1; continue; }
        out=$(python3 - "$TMP/layout.json" "$q" <<'PY'
import json, sys, re
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
q = sys.argv[2]
found = None
def walk(n):
    global found
    if found is not None:
        return
    if isinstance(n, list):
        for c in n:
            walk(c)
    elif isinstance(n, dict):
        vals = (n.get("text"), n.get("content-desc"), n.get("contentDesc"))
        if any(isinstance(v, str) and q in v for v in vals):
            m = re.match(r"\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]", n.get("bounds") or "")
            if m:
                x1, y1, x2, y2 = map(int, m.groups())
                off = n.get("off-screen")
                if isinstance(off, str):
                    off = off.lower() == "true"
                found = (x1, y1, x2 - x1, y2 - y1, 1 if off else 0)
                return
        for key in ("content", "children"):
            for c in (n.get(key) or []):
                walk(c)
walk(data)
if found:
    print(*found)
else:
    sys.exit(1)
PY
)
        [ -n "$out" ] && { echo "$out"; return 0; }
        sleep 1
    done
    return 1
}

# A row the user can actually see: not off-screen and with a non-zero box.
visible() {
    local box x y w h off
    box=$(layout_box "$1") || return 1
    read -r x y w h off <<< "$box"
    [ "$off" = "0" ] && [ "$w" -gt 0 ] && [ "$h" -gt 0 ]
}

info "Seed $TOTAL blocked numbers"
sql=""
for i in $(seq 1 "$TOTAL"); do
    number=$(printf '%s%04d' "$PREFIX" "$i")
    sql="${sql}INSERT OR REPLACE INTO blocked_numbers(number,timestamp) VALUES('$number',$((1000000 + i)));"
done
dbq "$sql" >/dev/null
stored=$(dbq "SELECT COUNT(*) FROM blocked_numbers WHERE number LIKE '$PREFIX%';")
[ "$stored" = "$TOTAL" ] && ok "seeded $stored blocked numbers" \
    || bad "seed wrote $stored rows, expected $TOTAL"

info "Launch the app and open Settings -> Inbox settings"
adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1
adb_ shell am force-stop "$PKG"
sleep 1
adb_ shell am start -n "$ACT" >/dev/null 2>&1
sleep 5
# The Settings avatar carries no label, so it can only be located by position.
adb_ shell input tap 976 164
sleep 2
if scroll_to_layout "Inbox settings" && tap_layout "Inbox settings"; then
    ok "opened Inbox settings"
else
    bad "could not open Inbox settings"
fi
sleep 2

info "The row counts the same list the dialog will show"
scroll_to_layout "Number blocking" >/dev/null 2>&1
if layout_has "$TOTAL blocked"; then
    ok "the row says \"$TOTAL blocked\""
else
    bad "the row does not show \"$TOTAL blocked\""
fi

if tap_layout "Number blocking"; then
    ok "opened the blocked-numbers dialog"
else
    bad "could not tap the Number blocking row"
fi
sleep 1
if wait_layout_has "Blocked numbers" 6; then
    ok "the dialog is open"
else
    bad "the blocked-numbers dialog did not open"
fi

info "The newest row is visible, the oldest is not"
if visible "$NEWEST_TAIL"; then
    ok "the newest blocked number is on screen"
else
    bad "the newest blocked number is not on screen"
fi
if visible "$OLDEST_TAIL"; then
    bad "the oldest blocked number starts on screen (expected below the fold)"
else
    ok "the oldest blocked number starts below the first screenful"
fi

info "Scrolling reaches the oldest blocked number"
reached=no
for _ in $(seq 1 12); do
    adb_ shell input swipe 540 1450 540 650 300
    sleep 1
    if visible "$OLDEST_TAIL"; then
        reached=yes
        break
    fi
done
if [ "$reached" = "yes" ]; then
    ok "scrolling reaches the last blocked number"
else
    bad "the last blocked number cannot be reached by scrolling"
fi

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
