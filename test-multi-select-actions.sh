#!/usr/bin/env bash
# Regression for the M3 multi-select toolbar: long-pressing a bubble enters
# selection mode, selecting several messages offers Forward + Move to trash
# (Copy is single-message only), and trashing moves the messages into
# Settings > Trash > Messages where they can be restored.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
info(){ echo -e "\n=== $* ==="; }

NUM="15551234567"
TK="MSTA$(date +%s)"
CONV_ADDR="345-4567"

db() { adb_ shell "run-as $PKG sh -c 'sqlite3 databases/messages.db \"$1\"'" 2>/dev/null | tr -d '\r'; }
body_deleted() {
    db "SELECT deleted_at FROM messages WHERE body LIKE '%$1%' ORDER BY id DESC LIMIT 1;"
}
db_count() {
    db "SELECT COUNT(*) FROM messages WHERE body LIKE '%$1%';"
}

cleanup() {
    db "DELETE FROM messages WHERE body LIKE '%$TK%';" >/dev/null 2>&1
    db "DELETE FROM conversations WHERE address LIKE '%3454567%';" >/dev/null 2>&1
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
}
trap cleanup EXIT

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
    adb_ shell input motionevent DOWN $lx $ly; sleep 1.2
    adb_ shell input motionevent UP $lx $ly; sleep 2
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

adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1
adb_ shell pm grant "$PKG" android.permission.RECEIVE_SMS 2>/dev/null

info "Seed 3 messages and open the conversation"
for t in one two three; do
    adb_ emu sms send "$NUM" "$TK $t" >/dev/null 2>&1; sleep 1.5
done
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 6
for i in 1 2 3 4 5 6; do
    c=$(center_of_contains "$CONV_ADDR") && { adb_ shell input tap $c; sleep 3; break; }
    adb_ shell input swipe 500 1600 500 700 300; sleep 0.8
done

info "A. Long-press enters selection with Copy/Forward/Trash for one message"
long_press_bubble "$TK one" || bad "could not long-press a bubble"
has_desc "Cancel selection" && ok "selection toolbar shown" || bad "selection toolbar missing"
has_desc "Copy" && ok "Copy offered for a single message" || bad "Copy missing for single"
has_desc "Forward" && ok "Forward offered" || bad "Forward missing"
has_desc "Move to trash" && ok "Trash offered" || bad "Trash missing"

info "B. Selecting a second message hides Copy but keeps Forward/Trash"
tap_bubble_nth "$TK three" 1 || bad "could not tap a second bubble"
dump_ui
grep -q 'text="2"' "$TMP/ui.xml" && ok "count = 2" || bad "count is not 2"
has_desc "Copy" && bad "Copy should be hidden for multi-select" || ok "Copy hidden for multi-select"
has_desc "Forward" && ok "Forward kept for multi-select" || bad "Forward missing for multi"
has_desc "Move to trash" && ok "Trash kept for multi-select" || bad "Trash missing for multi"

info "C. Move to trash soft-deletes the selected messages"
c=$(center_of_contains "Move to trash") || c=""
[ -n "$c" ] && adb_ shell input tap $c; sleep 2
[ "$(body_deleted "$TK one")" != "0" ] && ok "first message soft-deleted" || bad "first message not trashed"
[ "$(body_deleted "$TK three")" != "0" ] && ok "second message soft-deleted" || bad "second message not trashed"
[ "$(body_deleted "$TK two")" = "0" ] && ok "unselected message untouched" || bad "unselected message was trashed"

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

info "E. Restore returns the message to the chat"
tap_text "Restore" >/dev/null 2>&1; sleep 2
[ "$(body_deleted "$TK one")" = "0" ] && ok "message restored" || bad "message still trashed"

echo ""
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
