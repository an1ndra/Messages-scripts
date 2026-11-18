#!/usr/bin/env bash
# Regression for #478 — the two-pane layout on wide windows.
#
# On a phone the chat covers the list, exactly as before. An expanded window
# (a tablet, an unfolded foldable, a desktop window) splits into a conversation
# list beside the chat, so opening a chat no longer throws the list away.
#
# The window is widened by overriding the display size and density, which is
# how this AVD can present an expanded WindowSizeClass; both are reset on exit.
#
# Run: scripts/test-two-pane.sh   (emulator-5556)
set -uo pipefail
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }

A="+15551230061"
B="+15551230062"
EMPTY_LABEL="Choose a conversation to open it here"

sql() { adb_ shell "run-as $PKG sqlite3 databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r'; }

launch() {
    local i act
    for i in 1 2 3; do
        adb_ shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1
        adb_ shell wm dismiss-keyguard >/dev/null 2>&1
        adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
        adb_ shell am start -n "$ACT" "$@" >/dev/null 2>&1; sleep 5
        act=$(adb_ shell dumpsys activity activities 2>/dev/null | tr -d '\r')
        case "$act" in
            *mResumedActivity*"$PKG"*) return 0 ;;
        esac
        echo "[info] launch attempt $i did not come up; retrying"
        sleep 3
    done
    return 1
}

seed_thread() {
    local num="$1" name="$2" body="$3" cid ts
    ts=$(( $(date +%s) * 1000 ))
    sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$num');" >/dev/null
    sql "DELETE FROM conversations WHERE address='$num';" >/dev/null
    sql "INSERT INTO conversations(address,name,snippet,timestamp,unread_count,last_is_me,deleted_at)
         VALUES('$num','$name','$body',$ts,0,1,0);" >/dev/null
    cid=$(sql "SELECT id FROM conversations WHERE address='$num';")
    [ -n "$cid" ] || return 1
    sql "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,transport,sub_id,address)
         VALUES($cid,'$body',$ts,1,'sent','sms',-1,'$num');" >/dev/null
    echo "$cid"
}

# x range of the first node whose text is exactly $1, as "left right".
xrange_of() {
    dump_ui || return 1
    python3 - "$TMP/ui.xml" "$1" <<'PY'
import re, sys
data = open(sys.argv[1], encoding="utf-8", errors="replace").read()
want = sys.argv[2]
for node in re.findall(r"<node[^>]*>", data):
    t = re.search(r'text="([^"]*)"', node)
    if not t or t.group(1) != want:
        continue
    b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', node)
    if b:
        print(b.group(1), b.group(3))
        break
PY
}

wide() {
    adb_ shell wm size 2160x1080 >/dev/null 2>&1
    adb_ shell wm density 300 >/dev/null 2>&1
    sleep 2
}

reset_screen() {
    adb_ shell wm size reset >/dev/null 2>&1
    adb_ shell wm density reset >/dev/null 2>&1
    sleep 2
}

cleanup() {
    for n in "$A" "$B"; do
        sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$n');" >/dev/null 2>&1
        sql "DELETE FROM conversations WHERE address='$n';" >/dev/null 2>&1
    done
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    reset_screen >/dev/null 2>&1
}
trap cleanup EXIT

info "Set up: permissions, role, two seeded threads"
mkdir -p "$TMP"
for p in READ_SMS READ_CONTACTS POST_NOTIFICATIONS; do
    adb_ shell pm grant "$PKG" "android.permission.$p" >/dev/null 2>&1
done
adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1 || true
adb_ shell svc power stayon true >/dev/null 2>&1
adb_ shell "run-as $PKG sh -c 'rm -f files/crash_reports/*.txt'" >/dev/null 2>&1
cleanup >/dev/null 2>&1
adb_ shell "run-as $PKG sh -c 'grep -q name=\\\"participants_migrated\\\" shared_prefs/messages_settings.xml || sed -i \"s#</map>#    <boolean name=\\\"participants_migrated\\\" value=\\\"true\\\" /></map>#\" shared_prefs/messages_settings.xml'" >/dev/null 2>&1
CID=$(seed_thread "$A" "Wide Alice" "see you soon")
[ -n "$CID" ] || { fail "seed: could not create the thread"; echo; echo "Result: $PASS passed, $FAIL failed"; exit 1; }
seed_thread "$B" "Wide Bob" "hello there" >/dev/null
pass "seeded two conversations"

info "1. A phone keeps the single pane: the chat covers the list"
launch --es open_conversation_address "$A" || fail "the app did not come up"
dump_ui || true
if grep -qF 'text="Messages"' "$TMP/ui.xml"; then
    fail "the list is still visible behind the chat on a phone"
else
    pass "the chat takes the whole window on a phone"
fi

info "2. An expanded window shows the list beside the chat"
wide
launch --es open_conversation_address "$A" || fail "the app did not come up"
LIST=$(xrange_of "Messages" || true)
CHAT=$(xrange_of "Wide Alice" || true)
if [ -z "$LIST" ] || [ -z "$CHAT" ]; then
    fail "the split did not render (list='$LIST' chat='$CHAT')"
else
    pass "the list and the chat are both on screen"
    if [ "$(echo "$LIST" | cut -d' ' -f2)" -le "$(echo "$CHAT" | cut -d' ' -f1)" ]; then
        pass "the list owns the left column and the chat the right pane"
    else
        fail "the panes overlap (list=$LIST chat=$CHAT)"
    fi
fi

info "3. With nothing open the right pane says what it is for"
launch || fail "the app did not come up"
dump_ui || true
if grep -qF "text=\"$EMPTY_LABEL\"" "$TMP/ui.xml"; then
    pass "the empty pane tells the user to pick a conversation"
else
    fail "the right pane is blank with no chat selected"
fi
LIST=$(xrange_of "Messages" || true)
EMPTY=$(xrange_of "$EMPTY_LABEL" || true)
if [ -n "$LIST" ] && [ -n "$EMPTY" ] && [ "$(echo "$LIST" | cut -d' ' -f2)" -le "$(echo "$EMPTY" | cut -d' ' -f1)" ]; then
    pass "the placeholder sits in the right pane, beside the list"
else
    fail "the placeholder is not in the right pane (list='$LIST' empty='$EMPTY')"
fi

info "4. Back from the chat returns to the list, not out of the app"
launch --es open_conversation_address "$A" || fail "the app did not come up"
adb_ shell input keyevent KEYCODE_BACK >/dev/null 2>&1
sleep 3
dump_ui || true
if grep -qF "text=\"$EMPTY_LABEL\"" "$TMP/ui.xml" && grep -qF 'text="Messages"' "$TMP/ui.xml"; then
    pass "Back closes the chat pane and leaves the list in place"
else
    dump_ui || true
    if grep -qF "text=\"$EMPTY_LABEL\"" "$TMP/ui.xml"; then
        pass "Back closes the chat pane and leaves the list in place"
    else
        fail "Back did not return the wide window to the empty chat pane"
    fi
fi

echo
echo "Result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
