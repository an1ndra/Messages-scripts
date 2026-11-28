#!/usr/bin/env bash
# Regression for #483 — one-tap suggested replies.
#
# A thread that is waiting on us used to start from an empty composer. The
# chips above it are a local heuristic over the newest inbound message: a yes/no
# question offers Yes and No, thanks offers a welcome, an arrival offers a
# position, and a plain statement offers nothing.
#
# The chips are opt-in, so the first check is that a build nobody has configured
# shows none of them.
#
# Picking a chip fills the message box; it never sends on its own.
#
# Run: scripts/test-suggested-replies.sh   (emulator-5556)
set -uo pipefail
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }

QUESTION="+15551230041"   # "Are we still on for dinner?" — a yes/no question
PLAIN="+15551230042"      # a statement: nothing to suggest

PREFS="shared_prefs/messages_settings.xml"

sql() { adb_ shell "run-as $PKG sqlite3 databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r'; }

launch() {
    local i act
    for i in 1 2 3; do
        adb_ shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1
        adb_ shell wm dismiss-keyguard >/dev/null 2>&1
        adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
        adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 4
        act=$(adb_ shell dumpsys activity activities 2>/dev/null | tr -d '\r')
        case "$act" in
            *mResumedActivity*"$PKG"*) return 0 ;;
        esac
        echo "[info] launch attempt $i did not come up; retrying"
        sleep 3
    done
    return 1
}

open_chat() {
    adb_ shell am start -n "$ACT" --es open_conversation_address "$1" >/dev/null 2>&1
    sleep 3
}

seed_thread() {
    local num="$1" name="$2" body="$3" cid ts
    ts=$(( $(date +%s) * 1000 ))
    sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$num');" >/dev/null
    sql "DELETE FROM conversations WHERE address='$num';" >/dev/null
    sql "INSERT INTO conversations(address,name,snippet,timestamp,unread_count,last_is_me,deleted_at)
         VALUES('$num','$name','$body',$ts,0,0,0);" >/dev/null
    cid=$(sql "SELECT id FROM conversations WHERE address='$num';")
    [ -n "$cid" ] || return 1
    sql "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,transport,sub_id,address)
         VALUES($cid,'$body',$ts,0,'received','sms',-1,'$num');" >/dev/null
    echo "$cid"
}

pref_bool() {
    local key="$1" value="$2" xml
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
    xml=$(adb_ shell "run-as $PKG cat $PREFS" 2>/dev/null | tr -d '\r')
    case "$xml" in *'<map>'*) : ;; *) xml='<map>' ;; esac
    xml=$(printf '%s\n' "$xml" | grep -v "name=\"$key\"")
    xml=$(printf '%s\n' "$xml" | sed "s|^</map>|    <boolean name=\"$key\" value=\"$value\" />\n</map>|")
    printf '%s\n' "$xml" >"$TMP/prefs.xml"
    adb_ shell "run-as $PKG sh -c 'cat > $PREFS'" <"$TMP/prefs.xml"
}

has_text() { dump_ui || return 1; grep -qF "text=\"$1\"" "$TMP/ui.xml"; }

wait_text() {
    local t="$1" i
    for i in $(seq 1 10); do
        has_text "$t" && return 0
        sleep 2
    done
    return 1
}

cleanup() {
    for n in "$QUESTION" "$PLAIN"; do
        sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$n');" >/dev/null 2>&1
        sql "DELETE FROM conversations WHERE address='$n';" >/dev/null 2>&1
    done
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    adb_ shell "run-as $PKG sh -c 'sed -i \"/name=\\\"suggested_replies_enabled\\\"/d\" $PREFS'" >/dev/null 2>&1 || true
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
# This image's SQLite predates the participant upsert; mark the migration done
# so an unrelated startup pass cannot abort the process.
adb_ shell "run-as $PKG sh -c 'grep -q name=\\\"participants_migrated\\\" $PREFS || sed -i \"s#</map>#    <boolean name=\\\"participants_migrated\\\" value=\\\"true\\\" /></map>#\" $PREFS'" >/dev/null 2>&1

CID=$(seed_thread "$QUESTION" "Old Friend" "Are we still on for dinner?")
[ -n "$CID" ] || { fail "seed: could not create the question thread"; echo; echo "Result: $PASS passed, $FAIL failed"; exit 1; }
seed_thread "$PLAIN" "Quiet Friend" "I'll be at the office until six" >/dev/null
pass "seeded a yes/no question and a plain statement"

info "1. An install that never opted in shows no chips"
launch || fail "the app did not come up"
open_chat "$QUESTION"
sleep 2
dump_ui || true
if grep -qF 'text="Yes"' "$TMP/ui.xml" || grep -qF 'text="Sounds good"' "$TMP/ui.xml"; then
    fail "chips appeared without the switch being turned on"
else
    pass "the chips are opt-in: a fresh install suggests nothing"
fi

info "2. Turning the switch on offers Yes and No for a yes/no question"
pref_bool suggested_replies_enabled true
launch || fail "the app did not come up"
open_chat "$QUESTION"
if wait_text "Yes"; then
    pass "the chips appear above the composer once enabled"
else
    fail "no suggestion chips for an unanswered question"
fi
if has_text "No"; then
    pass "both answers of a yes/no question are offered"
else
    fail "the second answer is missing"
fi

info "3. Picking a chip fills the message box and sends nothing"
C=$(center_of "Yes" || true)
if [ -n "$C" ]; then
    adb_ shell input tap $C >/dev/null 2>&1
    sleep 2
    dump_ui || true
    if grep -qE 'class="android.widget.EditText"[^>]*text="Yes"' "$TMP/ui.xml" \
        || grep -qE 'text="Yes"[^>]*class="android.widget.EditText"' "$TMP/ui.xml"; then
        pass "the picked reply is in the composer"
    else
        fail "the composer did not take the suggestion"
    fi
    SENT=$(sql "SELECT count(*) FROM messages WHERE is_me=1 AND body='Yes';")
    if [ "${SENT:-0}" = "0" ]; then
        pass "nothing was sent: a suggestion is text, not a message"
    else
        fail "a suggestion was sent without being confirmed"
    fi
    if has_text "No"; then
        fail "the chips stayed up over a filled composer"
    else
        pass "the chips stand down once the field has text"
    fi
else
    fail "could not locate the Yes chip"
fi

info "4. A plain statement suggests nothing"
launch || fail "the app did not come up"
open_chat "$PLAIN"
sleep 2
dump_ui || true
if grep -qF 'text="Yes"' "$TMP/ui.xml" || grep -qF 'text="Sounds good"' "$TMP/ui.xml"; then
    fail "a plain statement was answered with a suggestion"
else
    pass "no chips where there is nothing to answer"
fi

info "5. The switch removes them everywhere again"
pref_bool suggested_replies_enabled false
launch || fail "the app did not come up"
open_chat "$QUESTION"
sleep 2
dump_ui || true
if grep -qF 'text="Yes"' "$TMP/ui.xml"; then
    fail "chips survived the switch being off"
else
    pass "turning the setting off takes the chips away"
fi

echo
echo "Result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
