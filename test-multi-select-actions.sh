#!/usr/bin/env bash
# Regression for the M3 multi-select toolbar: long-pressing a bubble enters
# selection mode, selecting several messages keeps Copy + Forward + Move to
# trash (Copy joins the selected bodies), and trashing moves the messages into
# Settings > Trash > Messages where they can be restored.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
info(){ echo -e "\n=== $* ==="; }

NUM="+15553454567"
TK="MSTA$(date +%s)"
NOW=$(date +%s)

# Seeded straight into the app database: this image's radio has no SIM, so
# `adb emu sms send` acknowledges the command and delivers nothing. The address
# and the cleanup pattern have to agree, or the script wipes one thread and
# looks for another.
#
# `messages.deleted_at` is INTEGER NOT NULL DEFAULT 0, so a live row carries 0
# and a trashed row a non-zero timestamp. `IS NULL` matches nothing.
local_query() { adb_ shell "run-as '$PKG' sqlite3 databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r'; }
live_count() {
    local n
    n=$(local_query "SELECT COUNT(*) FROM messages WHERE body LIKE '%$1%' AND deleted_at=0;")
    echo "${n:-0}"
}
trashed_count() {
    local n
    n=$(local_query "SELECT COUNT(*) FROM messages WHERE body LIKE '%$1%' AND deleted_at>0;")
    echo "${n:-0}"
}

cleanup() {
    local_query "DELETE FROM messages WHERE body LIKE '%$TK%';" >/dev/null 2>&1
    local_query "DELETE FROM conversations WHERE address='$NUM';" >/dev/null 2>&1
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
}
trap cleanup EXIT

# Each seed check proves the row exists, so a missing row cannot later be
# mistaken for "not trashed".
seed() {
    cleanup
    local_query "INSERT INTO conversations(address,name,snippet,timestamp) VALUES('$NUM','$TK','$TK three',${NOW}000);" >/dev/null 2>&1
    local cid t body
    cid=$(local_query "SELECT id FROM conversations WHERE address='$NUM' ORDER BY id DESC LIMIT 1;")
    [ -z "$cid" ] && return 1
    for body in one two three; do
        t=$((NOW + RANDOM % 600))
        local_query "INSERT INTO messages(conversation_id,body,timestamp,is_me,status) VALUES($cid,'$TK $body',${t}000,0,'received');" >/dev/null 2>&1
    done
    [ "$(live_count "$TK one")" -ge 1 ] &&
        [ "$(live_count "$TK two")" -ge 1 ] &&
        [ "$(live_count "$TK three")" -ge 1 ]
}

# Long-press the left padding of the bubble containing $1.
long_press_bubble() {
    local q b x1 y1 y2 lx ly
    q=$(re_escape "$1")
    dump_ui || return 1
    b=$(grep -oE "(text|content-desc)=\"[^\"]*$q[^\"]*\"[^>]*bounds=\"\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]\"" \
        "$TMP/ui.xml" 2>/dev/null | head -1 | grep -oE '\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]' | head -1)
    [ -z "$b" ] && return 1
    x1=$(sed -E 's/\[([0-9]+),([0-9]+)\].*/\1/' <<< "$b")
    y1=$(sed -E 's/\[[0-9]+,([0-9]+)\].*/\1/' <<< "$b")
    y2=$(sed -E 's/.*\]\[[0-9]+,([0-9]+)\]/\1/' <<< "$b")
    lx=$((x1 - 25)); [ $lx -lt 32 ] && lx=32
    ly=$(( (y1 + y2) / 2 ))
    # A zero-distance swipe with a hold duration is what registers as a
    # long-press on current emulator images; raw DOWN/UP no longer does.
    adb_ shell input swipe $lx $ly $lx $ly 800; sleep 1.5
}

tap_bubble_nth() {
    local q b x1 y1 y2 tx ty n="${2:-1}"
    q=$(re_escape "$1")
    dump_ui || return 1
    b=$(grep -oE "(text|content-desc)=\"[^\"]*$q[^\"]*\"[^>]*bounds=\"\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]\"" \
        "$TMP/ui.xml" 2>/dev/null | grep -oE '\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]' | sed -n "${n}p")
    [ -z "$b" ] && return 1
    x1=$(sed -E 's/\[([0-9]+),([0-9]+)\].*/\1/' <<< "$b")
    y1=$(sed -E 's/\[[0-9]+,([0-9]+)\].*/\1/' <<< "$b")
    y2=$(sed -E 's/.*\]\[[0-9]+,([0-9]+)\]/\1/' <<< "$b")
    tx=$((x1 + 20)); [ $tx -lt 32 ] && tx=32
    ty=$(( (y1 + y2) / 2 ))
    adb_ shell input tap $tx $ty; sleep 1.2
}

has_desc() { dump_ui >/dev/null 2>&1; grep -q "content-desc=\"$1\"" "$TMP/ui.xml"; }

adb_ shell su -c "cmd role add-role-holder android.app.role.SMS $PKG" >/dev/null 2>&1 || \
    adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1
adb_ shell pm grant "$PKG" android.permission.RECEIVE_SMS 2>/dev/null

info "Seed 3 messages and open the conversation"
if seed; then
    ok "seeded three messages"
else
    bad "could not seed the conversation"
fi
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" --es open_conversation_address "$NUM" >/dev/null 2>&1; sleep 4

info "A. Long-press enters selection with Copy/Forward/Trash for one message"
long_press_bubble "$TK one" || bad "could not long-press a bubble"
has_desc "Cancel selection" && ok "selection toolbar shown" || bad "selection toolbar missing"
has_desc "Copy" && ok "Copy offered for a single message" || bad "Copy missing for single"
has_desc "Forward" && ok "Forward offered" || bad "Forward missing"
has_desc "Move to trash" && ok "Trash offered" || bad "Trash missing"

info "B. Selecting a second message keeps Copy, Forward and Trash"
tap_bubble_nth "$TK three" 1 || bad "could not tap a second bubble"
dump_ui
grep -q 'text="2"' "$TMP/ui.xml" && ok "count = 2" || bad "count is not 2"
# Multi-select Copy joins the selected bodies with newlines (SelectionToolbar
# .showCopy is count >= 1, asserted by SelectionToolbarTest).
has_desc "Copy" && ok "Copy kept for multi-select" || bad "Copy missing for multi"
has_desc "Forward" && ok "Forward kept for multi-select" || bad "Forward missing for multi"
has_desc "Move to trash" && ok "Trash kept for multi-select" || bad "Trash missing for multi"

info "C. Move to trash soft-deletes the selected messages"
c=$(center_of_contains "Move to trash") || c=""
[ -n "$c" ] && adb_ shell input tap $c; sleep 2
[ "$(trashed_count "$TK one")" -ge 1 ] && ok "first message soft-deleted" || bad "first message not trashed"
[ "$(trashed_count "$TK three")" -ge 1 ] && ok "second message soft-deleted" || bad "second message not trashed"
[ "$(live_count "$TK two")" -ge 1 ] && ok "unselected message untouched" || bad "unselected message was trashed"

info "D. Trashed messages appear under Trash > Messages"
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null 2>&1; sleep 3
for i in $(seq 1 8); do
    dump_ui
    grep -q 'Trash' "$TMP/ui.xml" && break
    adb_ shell input swipe 540 1700 540 900 300 >/dev/null 2>&1; sleep 0.7
done
c=$(center_of_contains "Trash") && adb_ shell input tap $c; sleep 2
tap_text "Messages" >/dev/null 2>&1; sleep 1.5
dump_ui
grep -q "$TK one" "$TMP/ui.xml" && ok "trashed message listed under Messages tab" \
    || bad "trashed message not listed"

info "E. Restore returns the trashed messages to the chat"
# Both selected messages are in the trash list, and the first Restore button
# belongs to the newest row — which is not necessarily the one this check
# names. Restore until the list runs out, then assert both are live again.
for i in 1 2 3; do
    tap_text "Restore" >/dev/null 2>&1 || break
    sleep 2
done
[ "$(live_count "$TK one")" -ge 1 ] && ok "first message restored" || bad "first message still trashed"
[ "$(live_count "$TK three")" -ge 1 ] && ok "second message restored" || bad "second message still trashed"

echo ""
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
