#!/usr/bin/env bash
# Regression: undoing an archive must not scroll the inbox.
#
# Archiving a chat removes it from `displayed`; Undo puts it back. The "reveal
# a new unread" effect compares each conversation to the previous emission, so
# the returning chat — absent from that snapshot — looked like a chat that had
# just received messages. It scrolled to that row, which pushed the newer chats
# above it off the top of the screen. A restored chat is not a fresh message:
# only a count that grew for a chat already in the list should move the list.
#
# Seed 14 conversations so the list overflows, with a three-line header (two
# newer read chats, then the unread target). Archive the target from its
# long-press sheet and tap Undo. The two chats above it must still be on screen.
# Before the fix they are scrolled off and the target sits at the top.
source "$(dirname "$0")/env.sh"
set -uo pipefail

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
info(){ echo -e "\n=== $* ==="; }

MARK="undo$(date +%s)$$"
BASE=$(( $(date +%s) * 1000 ))
COUNT=14
TARGET_ROW=3
ADDRS=()
for i in $(seq 1 "$COUNT"); do
    ADDRS+=("+1555${MARK: -6}$(printf '%02d' "$i")")
done

adb_ root >/dev/null 2>&1; adb_ wait-for-device; sleep 1
sql() { adb_ shell "sqlite3 /data/data/$PKG/databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r'; }

PREF_BAK="$TMP/undo-scroll-prefs.xml"
cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    if [ -s "$PREF_BAK" ]; then
        adb_ push "$PREF_BAK" /data/local/tmp/undo-scroll-prefs.xml >/dev/null 2>&1
        adb_ shell "run-as $PKG sh -c 'cat /data/local/tmp/undo-scroll-prefs.xml > shared_prefs/messages_settings.xml'" >/dev/null 2>&1
    fi
    for a in "${ADDRS[@]}"; do
        sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$a');" >/dev/null 2>&1
        sql "DELETE FROM conversations WHERE address='$a';" >/dev/null 2>&1
    done
}
trap cleanup EXIT

body_for() { [ "$1" -eq "$TARGET_ROW" ] && echo "undo-scroll-target" || echo "undo-scroll-row$(printf '%02d' "$1")"; }

# The list is newest-first by timestamp, so the seeded chats are the top 14 only
# while unread-at-top is off (the default). Pin it off so a user setting cannot
# shuffle the unread target to the top and hide the regression.
set_unread_at_top() {
    adb_ shell am force-stop "$PKG"; sleep 1
    adb_ exec-out run-as "$PKG" cat shared_prefs/messages_settings.xml > "$TMP/undo-prefs-in.xml" 2>/dev/null || true
    python3 - "$TMP/undo-prefs-in.xml" <<'PY'
import re, sys
path = sys.argv[1]
try:
    s = open(path).read()
except OSError:
    s = '<?xml version="1.0" encoding="utf-8" standalone="yes" ?>\n<map>\n</map>\n'
s = re.sub(r'\s*<boolean name="unread_at_top_enabled"[^>]*/>', '', s)
if '</map>' not in s:
    s = '<?xml version="1.0" encoding="utf-8" standalone="yes" ?>\n<map>\n</map>\n'
s = s.replace('</map>', '  <boolean name="unread_at_top_enabled" value="false" />\n</map>')
open('/tmp/opencode/undo-prefs-out.xml', 'w').write(s)
PY
    adb_ push /tmp/opencode/undo-prefs-out.xml /data/local/tmp/undo-prefs-out.xml >/dev/null 2>&1
    adb_ shell "run-as $PKG sh -c 'cat /data/local/tmp/undo-prefs-out.xml > shared_prefs/messages_settings.xml'" >/dev/null 2>&1
}

seed() {
    for a in "${ADDRS[@]}"; do
        sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$a');" >/dev/null
        sql "DELETE FROM conversations WHERE address='$a';" >/dev/null
    done
    for i in $(seq 1 "$COUNT"); do
        local a="${ADDRS[$((i - 1))]}" ts=$(( BASE - i * 60000 )) unread=0 body
        body=$(body_for "$i")
        [ "$i" -eq "$TARGET_ROW" ] && unread=3
        sql "INSERT INTO conversations(address,name,snippet,timestamp,unread_count,last_is_me,archived) VALUES('$a','$a','$body',$ts,$unread,0,0);" >/dev/null
        sql "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,media_type) SELECT id,'$body',$ts,0,'received','text' FROM conversations WHERE address='$a';" >/dev/null
    done
}

start_app() {
    adb_ shell am force-stop "$PKG"; sleep 1
    adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 7
}

# uiautomator can lose its UiAutomation registration; a failed dump is not a
# finding. Retry a few times before calling the screen unreadable.
dump_retry() {
    local i
    for i in 1 2 3 4 5; do
        dump_ui >/dev/null 2>&1 && return 0
        sleep 2
    done
    return 1
}

desc_center() {
    dump_retry || return 1
    python3 - "$TMP/ui.xml" "$1" <<'PY'
import re, sys
xml = open(sys.argv[1], encoding='utf-8', errors='replace').read()
q = sys.argv[2]
for tag in re.findall(r'<node[^>]*>', xml):
    d = re.search(r'content-desc="([^"]*)"', tag)
    b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', tag)
    if d and b and q in d.group(1):
        x1, y1, x2, y2 = map(int, b.groups())
        print((x1 + x2) // 2, (y1 + y2) // 2)
        sys.exit(0)
sys.exit(1)
PY
}

text_center() {
    dump_retry || return 1
    python3 - "$TMP/ui.xml" "$1" <<'PY'
import re, sys
xml = open(sys.argv[1], encoding='utf-8', errors='replace').read()
q = sys.argv[2]
for tag in re.findall(r'<node[^>]*>', xml):
    t = re.search(r'text="([^"]*)"', tag)
    b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', tag)
    if t and b and q in t.group(1):
        x1, y1, x2, y2 = map(int, b.groups())
        print((x1 + x2) // 2, (y1 + y2) // 2)
        sys.exit(0)
sys.exit(1)
PY
}

visible() {
    [ -f "$TMP/ui.xml" ] && grep -qF "$1" "$TMP/ui.xml"
}

open_inbox() {
    local i
    for i in 1 2 3 4; do
        dump_retry || true
        visible "undo-scroll-row01" && return 0
        adb_ shell input keyevent KEYCODE_BACK >/dev/null 2>&1
        sleep 2
    done
    return 1
}

info "Hold the default SMS role"
adb_su "cmd role add-role-holder android.app.role.SMS $PKG" >/dev/null 2>&1
sleep 1

info "Disable unread-at-top, back up prefs"
adb_ exec-out run-as "$PKG" cat shared_prefs/messages_settings.xml > "$PREF_BAK" 2>/dev/null || true
set_unread_at_top

info "Seed 14 conversations with an unread target third from the top"
seed
start_app
open_inbox || { bad "inbox with the seeded chats never rendered"; echo ""; echo "PASS=$PASS FAIL=$FAIL"; exit 1; }
ok "seeded inbox rendered"

if visible "undo-scroll-row01" && visible "undo-scroll-row02"; then
    ok "the two newer chats start on screen"
else
    bad "the seeded header is not on screen before the test"
    echo ""; echo "PASS=$PASS FAIL=$FAIL"; exit 1
fi

info "Archive the target and Undo"
ROW=$(desc_center "undo-scroll-target") || { bad "could not locate the target row"; echo ""; echo "PASS=$PASS FAIL=$FAIL"; exit 1; }
adb_ shell input swipe $ROW $ROW 900; sleep 2
ARCH=$(text_center "Archive") || { bad "the row sheet has no Archive action"; echo ""; echo "PASS=$PASS FAIL=$FAIL"; exit 1; }
adb_ shell input tap $ARCH; sleep 3
UNDO=$(text_center "Undo") || { bad "the archive snackbar has no Undo"; echo ""; echo "PASS=$PASS FAIL=$FAIL"; exit 1; }
adb_ shell input tap $UNDO; sleep 3
dump_retry || true

if visible "undo-scroll-target"; then
    ok "Undo put the conversation back"
else
    bad "Undo did not restore the conversation"
fi
if visible "undo-scroll-row01" && visible "undo-scroll-row02"; then
    ok "the list stayed put: the two newer chats are still on screen"
else
    bad "the list jumped to the restored row and scrolled the newer chats off"
fi

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
