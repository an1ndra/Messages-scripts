#!/usr/bin/env bash
# Issue #546: long-pressing the number in conversation details copies it.
# The clipboard is asserted through the UI by pasting into the home search
# field, so the script needs no screenshot and no clipboard service dump.
source "$(dirname "$0")/env.sh"

NUM="+1555$(date +%s | tail -c 6)"
TAIL="${NUM: -4}"
NAME="CopyProbe"
SID="copyprobe$(date +%s)"
MESSAGE="copy number $(date +%s)"
TS=$(( $(date +%s) * 1000 ))
PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

sql() { echo "$1" | adb_ shell "run-as $PKG sqlite3 databases/messages.db" >/dev/null 2>&1; }

kill_stale_ui() {
    local pid
    pid=$(adb_ shell ps -A 2>/dev/null | awk '/com.android.cli.interact.instrumentation/{print $2}' | head -1 | tr -d '\r')
    [ -n "$pid" ] && adb_su "kill -9 $pid" >/dev/null 2>&1 || true
}

dump_clean() {
    kill_stale_ui
    dump_ui "$@"
}

center_in_dump() {
    python3 - "$TMP/ui.decoded.xml" "$1" <<'PY'
import re, sys
xml = open(sys.argv[1], encoding="utf-8", errors="replace").read()
q = sys.argv[2]
for node in re.findall(r'<node[^>]*>', xml):
    if 'text="' + q + '"' not in node and 'content-desc="' + q + '"' not in node:
        continue
    b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', node)
    if not b:
        continue
    x1, y1, x2, y2 = (int(g) for g in b.groups())
    print((x1 + x2) // 2, (y1 + y2) // 2)
    break
PY
}

seed_contact() {
    adb_ shell "content insert --uri content://com.android.contacts/raw_contacts --bind account_name:s:demo --bind account_type:s:com.local --bind sourceid:s:$SID" >/dev/null 2>&1
    local rid
    rid=$(adb_ shell "content query --uri content://com.android.contacts/raw_contacts --projection _id --where \"sourceid='$SID'\"" 2>/dev/null | grep -oE '_id=[0-9]+' | head -1 | cut -d= -f2 | tr -d '\r')
    [ -z "$rid" ] && return 1
    adb_ shell "content insert --uri content://com.android.contacts/data --bind raw_contact_id:l:$rid --bind mimetype:s:vnd.android.cursor.item/name --bind data1:s:$NAME" >/dev/null 2>&1
    adb_ shell "content insert --uri content://com.android.contacts/data --bind raw_contact_id:l:$rid --bind mimetype:s:vnd.android.cursor.item/phone_v2 --bind data1:s:$NUM --bind data2:l:0" >/dev/null 2>&1
}

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM'); DELETE FROM conversations WHERE address='$NUM';"
    local rid
    rid=$(adb_ shell "content query --uri content://com.android.contacts/raw_contacts --projection _id --where \"sourceid='$SID'\"" 2>/dev/null | grep -oE '_id=[0-9]+' | head -1 | cut -d= -f2 | tr -d '\r')
    [ -n "$rid" ] && adb_ shell "content delete --uri content://com.android.contacts/raw_contacts --where '_id=$rid'" >/dev/null 2>&1 || true
}
trap cleanup EXIT

number_bounds() {
    dump_clean >/dev/null 2>&1 || return 1
    python3 - "$TMP/ui.decoded.xml" "$TAIL" <<'PY'
import re, sys
xml = open(sys.argv[1], encoding="utf-8", errors="replace").read()
tail = sys.argv[2]
for node in re.findall(r'<node[^>]*>', xml):
    if tail not in node:
        continue
    b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', node)
    if not b:
        continue
    x1, y1, x2, y2 = (int(g) for g in b.groups())
    print((x1 + x2) // 2, (y1 + y2) // 2)
    break
PY
}

info "Seed a saved contact and an incoming message"
cleanup
seed_contact || { bad "could not seed the contact"; exit 1; }
adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1 || true
bash "$(dirname "$0")/grant-permissions.sh" >/dev/null 2>&1 || true
sql "INSERT INTO conversations(address,name,snippet,timestamp,last_is_me) VALUES('$NUM','$NAME','$MESSAGE',$TS,0); INSERT INTO messages(conversation_id,body,timestamp,is_me,status,media_type) SELECT id,'$MESSAGE',$TS,0,'received','text' FROM conversations WHERE address='$NUM';"
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" --es open_conversation_address "$NUM" >/dev/null 2>&1; sleep 6

info "Open conversation details"
dump_clean >/dev/null 2>&1 || true
c=$(center_in_dump "More options") || { bad "no chat menu"; exit 1; }
adb_ shell input tap $c; sleep 1
dump_clean >/dev/null 2>&1 || true
c=$(center_in_dump "Details") || { bad "no Details row"; exit 1; }
adb_ shell input tap $c; sleep 3
dump_clean >/dev/null 2>&1 || true
grep -q 'text="Notification profile"' "$TMP/ui.decoded.xml" \
    && ok "details screen opened" || { bad "details screen did not open"; exit 1; }
grep -q "$TAIL" "$TMP/ui.decoded.xml" \
    && ok "details screen shows the number" || { bad "details screen hides the number"; exit 1; }

info "Long-press the number"
C=$(number_bounds) || { bad "could not locate the number row"; exit 1; }
adb_ shell input swipe $C $C 900
sleep 1
adb_ shell dumpsys window windows 2>/dev/null | grep -q 'u0 Toast' \
    && ok "copy confirmation toast appeared" || bad "no copy confirmation toast appeared"

info "Paste into the home search field"
adb_ shell input keyevent KEYCODE_BACK; sleep 1
adb_ shell input keyevent KEYCODE_BACK; sleep 2
dump_clean >/dev/null 2>&1 || true
c=$(center_in_dump "Search") || { bad "no Search button"; exit 1; }
adb_ shell input tap $c || true
sleep 1
adb_ shell input keyevent KEYCODE_PASTE >/dev/null 2>&1
sleep 2
dump_clean >/dev/null 2>&1 || true
grep -qF "text=\"$NUM\"" "$TMP/ui.decoded.xml" \
    && ok "clipboard holds the conversation number" || bad "clipboard did not receive the number"

echo ""
info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
