#!/usr/bin/env bash
# Issue #405: a chat that was archived and then trashed must come back to the
# Inbox when it is revived, not to the Archived folder.
#
# Both revive paths are exercised:
#   1. Settings -> Trash -> Restore
#   2. a new inbound SMS for the trashed conversation
#
# Before the fix both cleared only deleted_at, so the conversation kept
# archived=1: new messages still notified and sends still worked, but the Inbox
# (and its search) never showed the chat again.
#
# Precondition: emulator booted (emulator-5558) and the app installed.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

# Fresh numbers and bodies per run: re-running must not inherit messages a
# previous run left behind (the chat would not be empty and never get trashed).
BASE=$(( $(date +%s) % 100000 ))
NUM=$(printf '1555%07d' "$BASE")
NUM2=$(printf '1555%07d' "$(( BASE + 1 ))")
ROWA="-${NUM:7}"    # home rows render the formatted number
ROWB="-${NUM2:7}"
TRASHA="${NUM:4}"  # trash rows print the stored address, e.g. +1555xxxxxxx
TAG="TA$(date +%s)$$"
MSG1="Only message $TAG A"
MSG2="Only message $TAG B"
MSG3="Reply $TAG B"

db_pull() { adb_ shell "run-as $PKG cat databases/messages.db" > "$TMP/ta.db" 2>/dev/null; }

# "<deleted_at> <archived> <visible_messages>" for the conversation whose
# address ends in $1 ("MISSING -1 -1" when there is no row).
conv_state() {
    python3 - "$1" "$TMP/ta.db" <<'PY'
import sqlite3, sys
tail, path = sys.argv[1], sys.argv[2]
con = sqlite3.connect(path)
rows = list(con.execute(
    "SELECT id, deleted_at, archived FROM conversations WHERE address LIKE ? ORDER BY id DESC",
    (f"%{tail}",)))
if not rows:
    print("MISSING -1 -1")
    raise SystemExit
cid, deleted_at, archived = rows[0]
n = con.execute(
    "SELECT COUNT(*) FROM messages WHERE conversation_id=? AND deleted_at=0", (cid,)).fetchone()[0]
print(f"{deleted_at} {archived} {n}")
PY
}

# Center "x y" of the first on-screen node below the app bar whose text or
# content-desc contains $1. The status bar repeats the sender number for its
# notification icon, so a whole-screen search long-presses that icon instead of
# the list row.
row_center() {
    layout_json || return 1
    python3 - "$TMP/layout.json" "$1" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
q = sys.argv[2]
found = [None]
def walk(node):
    if found[0]:
        return
    if isinstance(node, list):
        for child in node:
            walk(child)
    elif isinstance(node, dict):
        center = node.get("center")
        if center and not node.get("off-screen"):
            y = int(center.strip("[]").split(",")[1])
            for key in ("text", "content-desc", "contentDesc"):
                value = node.get(key)
                if isinstance(value, str) and q in value and y > 300:
                    found[0] = center
                    return
        for key in ("content", "children"):
            walk(node.get(key) or [])
walk(data)
if not found[0]:
    sys.exit(1)
print(found[0].strip("[]").replace(",", " "))
PY
}

# Long-press the home-list row showing $1, then pick exactly $2 from the sheet.
sheet_action() {
    local c
    c=$(row_center "$1") || { echo "[long-press] '$1' not found"; return 1; }
    adb_ shell input swipe $c $c 900
    sleep 1.5
    tap_layout_exact "$2"
}

# Center "x y" of the $2 button on the row showing $1. Several trash rows each
# carry a Restore icon, so an exact-label tap alone would restore the wrong one.
row_button() {
    layout_json || return 1
    python3 - "$TMP/layout.json" "$1" "$2" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
needle, label = sys.argv[2], sys.argv[3]
rows, buttons = [], []
def walk(node):
    if isinstance(node, list):
        for child in node:
            walk(child)
    elif isinstance(node, dict):
        center = node.get("center")
        if center and not node.get("off-screen"):
            x, y = (int(v) for v in center.strip("[]").split(","))
            for key in ("text", "content-desc", "contentDesc"):
                value = node.get(key)
                if not isinstance(value, str):
                    continue
                if value == label:
                    buttons.append((x, y))
                elif needle in value:
                    rows.append((x, y))
        for key in ("content", "children"):
            walk(node.get(key) or [])
walk(data)
if not rows or not buttons:
    sys.exit(1)
row_y = rows[0][1]
best = min(buttons, key=lambda b: abs(b[1] - row_y))
if abs(best[1] - row_y) > 120:
    sys.exit(1)
print(best[0], best[1])
PY
}

# True when the home list shows $1, scrolling down a few pages if needed.
home_has() {
    local i
    for i in 1 2 3 4 5; do
        row_center "$1" >/dev/null 2>&1 && return 0
        adb_ shell input swipe 540 1600 540 700 300; sleep 0.7
    done
    return 1
}

# Settings -> Trash. Returns non-zero when the Trash screen did not open.
open_trash() {
    adb_ shell am force-stop "$PKG"; sleep 1
    adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null
    sleep 3
    scroll_to_layout "Trash" >/dev/null 2>&1 || return 1
    tap_layout_exact "Trash" >/dev/null || return 1
    sleep 2
    # The Trash screen is the only place with these tabs/action.
    wait_layout_has "Conversations" 3 || wait_layout_has "Empty trash" 3
}

# Open a chat by address, delete its only message (long-press -> selection bar
# -> Move to trash), then leave it, which trashes the now-empty conversation.
empty_chat() {
    adb_ shell am start -n "$ACT" --es open_conversation_address "$1" >/dev/null
    sleep 3
    local c
    c=$(layout_center "$2") || { echo "[delete] bubble '$2' not found"; return 1; }
    adb_ shell input swipe $c $c 900
    sleep 1.5
    tap_layout_exact "Move to trash" >/dev/null || { adb_ shell input keyevent 4; return 1; }
    sleep 2
    adb_ shell input keyevent 4
    sleep 2.5
}

info "1. Seed a chat and archive it"
adb_ shell am force-stop "$PKG"; sleep 1
adb_ emu sms send "$NUM" "$MSG1" >/dev/null
sleep 3
db_pull
read -r d a n <<<"$(conv_state "$NUM")"
echo "seeded: deleted_at=$d archived=$a visible_msgs=$n"
[ "$d" = "0" ] && [ "$a" = "0" ] && [ "$n" -ge 1 ] \
    && pass "seeded chat is in the Inbox" \
    || fail "seed failed (deleted_at=$d archived=$a msgs=$n)"

adb_ shell am start -n "$ACT" >/dev/null
sleep 5
if sheet_action "$ROWA" "Archive"; then
    sleep 1.5
    db_pull
    read -r d a n <<<"$(conv_state "$NUM")"
    echo "after archive: deleted_at=$d archived=$a"
    [ "$a" = "1" ] && [ "$d" = "0" ] \
        && pass "chat moved to the Archived folder" \
        || fail "archive did not set archived=1 (deleted_at=$d archived=$a)"
else
    fail "could not archive the chat from the row sheet"
fi

info "2. Empty the archived chat; leaving it trashes the conversation"
if empty_chat "$NUM" "$MSG1"; then
    db_pull
    read -r d a n <<<"$(conv_state "$NUM")"
    echo "after leaving: deleted_at=$d archived=$a visible_msgs=$n"
    if [ "$d" != "0" ] && [ "$d" != "MISSING" ] && [ "$a" = "1" ]; then
        pass "archived chat is in the Trash with archived=1 (precondition)"
    else
        fail "could not reach the trashed+archived state (deleted_at=$d archived=$a)"
    fi
else
    fail "could not empty the archived chat"
fi

info "3. Restore from Trash puts it back in the Inbox, not the Archive"
if open_trash; then
    C=$(row_button "$TRASHA" "Restore") || { fail "the trashed chat is not listed with a Restore action"; C=""; }
    if [ -n "$C" ]; then
        pass "trashed chat is listed in Trash"
        adb_ shell input tap $C
        sleep 2
        db_pull
        read -r d a n <<<"$(conv_state "$NUM")"
        echo "after restore: deleted_at=$d archived=$a"
        [ "$d" = "0" ] && [ "$a" = "0" ] \
            && pass "Restore cleared both the trashed and the archived flag" \
            || fail "Restore left deleted_at=$d archived=$a — the chat is back in the Archived folder (#405)"
    fi
else
    fail "could not open Settings -> Trash"
fi

adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" >/dev/null
sleep 5
if home_has "$ROWA"; then
    pass "restored chat is visible on the Inbox list"
else
    fail "restored chat is missing from the Inbox list (it sits in Archived)"
fi

info "4. Seed, archive and trash a second chat for the inbound path"
adb_ shell am force-stop "$PKG"; sleep 1
adb_ emu sms send "$NUM2" "$MSG2" >/dev/null
sleep 3
adb_ shell am start -n "$ACT" >/dev/null
sleep 5
if sheet_action "$ROWB" "Archive"; then
    sleep 1.5
    empty_chat "$NUM2" "$MSG2" || fail "could not empty the second archived chat"
    db_pull
    read -r d a n <<<"$(conv_state "$NUM2")"
    echo "second chat: deleted_at=$d archived=$a visible_msgs=$n"
    if [ "$d" != "0" ] && [ "$d" != "MISSING" ] && [ "$a" = "1" ]; then
        pass "second chat is trashed while still archived (precondition)"
    else
        fail "second chat not in the trashed+archived state (deleted_at=$d archived=$a)"
    fi
else
    fail "could not archive the second chat"
fi

info "5. A new inbound message revives it into the Inbox"
adb_ emu sms send "$NUM2" "$MSG3" >/dev/null
sleep 4
db_pull
read -r d a n <<<"$(conv_state "$NUM2")"
echo "after inbound: deleted_at=$d archived=$a visible_msgs=$n"
[ "$d" = "0" ] && [ "$a" = "0" ] \
    && pass "inbound message restored the chat and cleared archived" \
    || fail "inbound left deleted_at=$d archived=$a — messages would be Inbox-invisible (#405)"

adb_ shell am start -n "$ACT" >/dev/null
sleep 5
if home_has "$ROWB"; then
    pass "revived chat is visible on the Inbox list"
else
    fail "revived chat is missing from the Inbox list (it sits in Archived)"
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
