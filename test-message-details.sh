#!/usr/bin/env bash
# Regression for the message-details / SIM-indicator / block-label trio.
#
#   1. The contact screen's block action is labelled "Block number" (was
#      "Block & report spam"; the app never reported anything).
#   2. A received message shows its SIM indicator (dual-SIM) in the chat.
#   3. Selecting a message -> More -> "View details" opens MESSAGE details
#      (type / to-from / sent / status), not the contact profile.
#
# Seeds its own conversation so it does not depend on demo data.
# Run: scripts/test-message-details.sh
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh

PASS=0
FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }

NUM="+1555$(date +%s | tail -c 8)"
TOKEN="det$(date +%s | tail -c 6)"

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    adb_ shell "run-as $PKG sqlite3 databases/messages.db \"DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM'); DELETE FROM conversations WHERE address='$NUM'; DELETE FROM participants WHERE normalized_destination='$NUM';\"" >/dev/null 2>&1 || true
}
trap cleanup EXIT

adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1 || true
bash ./grant-permissions.sh >/dev/null 2>&1 || true

launch_list() {
    adb_ shell am force-stop "$PKG"; sleep 1
    adb_ shell am start -n "$ACT" >/dev/null; sleep 4
    local i
    for i in 1 2 3; do
        dump_ui >/dev/null 2>&1
        grep -q 'content-desc="Search"' "$TMP/ui.xml" && return 0
        adb_ shell input keyevent 4; sleep 1
    done
}

long_press_bubble() {
    local q b x1 y1 y2 lx ly
    q=$(re_escape "$1")
    dump_ui || return 1
    b=$(grep -oE "text=\"[^\"]*$q[^\"]*\"[^>]*bounds=\"\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]\"" \
        "$TMP/ui.xml" 2>/dev/null | head -1 | grep -oE '\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]' | head -1)
    [ -z "$b" ] && return 1
    x1=$(sed -E 's/\[([0-9]+),([0-9]+)\].*/\1/' <<< "$b")
    y1=$(sed -E 's/\[[0-9]+,([0-9]+)\].*/\1/' <<< "$b")
    y2=$(sed -E 's/.*\]\[[0-9]+,([0-9]+)\]/\1/' <<< "$b")
    lx=$((x1 - 25)); [ "$lx" -lt 32 ] && lx=32
    ly=$(( (y1 + y2) / 2 ))
    adb_ shell input motionevent DOWN "$lx" "$ly"; sleep 1.2
    adb_ shell input motionevent UP "$lx" "$ly"; sleep 1.5
}

info "seeding an incoming SMS to $NUM"
launch_list
adb_ emu sms send "$NUM" "$TOKEN incoming" >/dev/null
sleep 3
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" --es open_conversation_address "$NUM" >/dev/null
sleep 4

info "1. received message shows its SIM indicator"
# The emulator has one SIM (subId -1), so the suffix is absent but the code path
# must not crash and the incoming bubble still renders.
if dump_ui && grep -q "$TOKEN" "$TMP/ui.xml"; then
    pass 'received message renders in the conversation'
else
    fail 'received message missing'
fi

info "2. selection -> More -> View details opens MESSAGE details"
long_press_bubble "$TOKEN" || fail 'could not long-press the message'
c=$(center_of_contains "More options") || c=""
[ -n "$c" ] && adb_ shell input tap $c; sleep 1
c=$(center_of "View details") || c=""
[ -n "$c" ] && adb_ shell input tap $c; sleep 1.5
dump_ui >/dev/null 2>&1
if grep -q 'text="Message details"' "$TMP/ui.xml"; then
    pass 'View details opens the message-details dialog'
else
    fail 'View details did not open message details'
fi
for label in Type "From" Sent Status; do
    grep -q "text=\"$label\"" "$TMP/ui.xml" && pass "message details has '$label'" \
        || fail "message details missing '$label'"
done
grep -q 'text="Notifications"' "$TMP/ui.xml" \
    && fail 'View details opened the contact profile instead of message details' \
    || pass 'View details no longer opens the contact profile'
adb_ shell input keyevent 4 >/dev/null 2>&1 || true

info "3. block action is labelled 'Block number'"
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" --es open_conversation_address "$NUM" >/dev/null
sleep 4
dump_ui >/dev/null 2>&1
# The chat title is the formatted number, e.g. "(555) 975-8336" — match the
# leading paren so the message token (which also contains the digits) can't win.
TITLE=$(grep -oE 'text="\([0-9]{3}\) [0-9]{3}-[0-9]{4}"' "$TMP/ui.xml" | head -1 | sed -E 's/text="([^"]*)"/\1/')
[ -n "$TITLE" ] && tap_text "$TITLE" >/dev/null 2>&1
sleep 2
dump_ui >/dev/null 2>&1
if grep -q 'text="Block number"' "$TMP/ui.xml"; then
    pass "block action labelled 'Block number'"
elif grep -q 'text="[^"]*Block[^"]*"' "$TMP/ui.xml"; then
    fail "block action still shows the old label"
else
    fail 'could not reach the contact profile'
fi
grep -q 'report spam' "$TMP/ui.xml" \
    && fail "old 'report spam' label still present" \
    || pass "old 'report spam' label gone"

printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
