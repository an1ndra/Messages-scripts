#!/usr/bin/env bash
# Regression for #484 — the nudge for an unanswered message.
#
# Unread counts only cover messages nobody opened. The thread worth a reminder
# is the opposite one: read, meant to be answered, forgotten. With the switch
# on, a thread whose newest message is inbound, already read and a day old gets
# one quiet card; replying, and switching the feature off, take it away.
#
# The switch is seeded in the app's own preferences rather than tapped through
# Settings, so this exercises the selection rule and the shade rather than the
# settings list (that wiring is asserted in ReplyNudgePolicyTest). Preferences
# are read when the process starts, so every write happens with the app stopped.
#
# Run: scripts/test-reply-nudge.sh   (emulator-5556)
set -uo pipefail
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }

TAG="nudge"
OLD="+15551230031"       # read, unanswered, two days old
FRESH="+15551230032"     # read, unanswered, an hour old
ANSWERED="+15551230033"  # the newest message is ours

BODY="Are we still on for dinner?"
REPLY="on my way"

PREFS="shared_prefs/messages_settings.xml"
SHADE="$TMP/nudge-shade.txt"
LIVE="$TMP/nudge-live.txt"

mkdir -p "$TMP"

shade() {
    adb_ shell dumpsys notification --noredact >"$SHADE.raw" 2>/dev/null
    tr -d '\r' <"$SHADE.raw" >"$SHADE"
    # Live list only: the archive keeps one line per retired card, which would
    # read as "still posted" after Cancel.
    awk '/Notification List:/{f=1} /mArchive=/{f=0} f' "$SHADE" >"$LIVE"
}

cards() {
    shade
    local n
    n=$(grep -c "tag=$TAG" "$LIVE" 2>/dev/null)
    echo "${n:-0}"
}

sql() { adb_ shell "run-as $PKG sqlite3 databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r'; }

launch() {
    local i act
    for i in 1 2 3; do
        adb_ shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1
        adb_ shell wm dismiss-keyguard >/dev/null 2>&1
        adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
        adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 5
        # This AVD occasionally loses a process at start; the launch looks
        # accepted but nothing ran.
        act=$(adb_ shell dumpsys activity activities 2>/dev/null | tr -d '\r')
        case "$act" in
            *mResumedActivity*"$PKG"*) return 0 ;;
        esac
        echo "[info] launch attempt $i did not come up; retrying"
        sleep 3
    done
    return 1
}

# One conversation with one message, dated [age] hours ago.
seed_thread() {
    local num="$1" name="$2" body="$3" age="$4" mine="$5" cid ts
    ts=$(( ($(date +%s) - age * 3600) * 1000 ))
    sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$num');" >/dev/null
    sql "DELETE FROM conversations WHERE address='$num';" >/dev/null
    sql "INSERT INTO conversations(address,name,snippet,timestamp,unread_count,last_is_me,deleted_at)
         VALUES('$num','$name','$body',$ts,0,$mine,0);" >/dev/null
    cid=$(sql "SELECT id FROM conversations WHERE address='$num';")
    [ -n "$cid" ] || return 1
    sql "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,transport,sub_id,address)
         VALUES($cid,'$body',$ts,$mine,'received','sms',-1,'$num');" >/dev/null
    echo "$cid"
}

# This image ships SQLite 3.22, which predates `INSERT ... ON CONFLICT DO
# UPDATE`; the participant migration is the one startup pass that uses it, and
# an install where it has not run yet aborts the whole process on that syntax
# error. Marking it done keeps a migration unrelated to this feature out of the
# way, exactly as a used installation has it.
prefs_ensure_flags() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
    local xml key
    xml=$(adb_ shell "run-as $PKG cat $PREFS" 2>/dev/null | tr -d '\r')
    case "$xml" in *'<map>'*) : ;; *) xml='<map>' ;; esac
    for key in participants_migrated group_thread_repair_done first_import_done; do
        case "$xml" in
            *"name=\"$key\""*) : ;;
            *) xml=$(printf '%s\n' "$xml" | sed "s|^</map>|    <boolean name=\"$key\" value=\"true\" />\n</map>|") ;;
        esac
    done
    printf '%s\n' "$xml" >"$TMP/prefs.xml"
    adb_ shell "run-as $PKG sh -c 'cat > $PREFS'" <"$TMP/prefs.xml"
}

# The switch, while the app is stopped. Every run starts from a clean cap for
# the three threads this test owns; the extra once-a-day entries in $TMP/caps.xml
# keep the device's own conversations out of the way (see cap_others).
nudge_pref() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
    local on="$1" xml
    xml=$(adb_ shell "run-as $PKG cat $PREFS" 2>/dev/null | tr -d '\r')
    case "$xml" in
        *'<map>'*) : ;;
        *) xml='<map>' ;;
    esac
    xml=$(printf '%s\n' "$xml" | grep -v 'name="reply_nudge_at_' | grep -v 'name="reply_nudge_enabled"')
    if [ "$on" = "true" ]; then
        xml=$(printf '%s\n' "$xml" | sed "s|^</map>|    <boolean name=\"reply_nudge_enabled\" value=\"true\" />\n</map>|")
        if [ -s "$TMP/caps.xml" ]; then
            xml=$(CAPS_FILE="$TMP/caps.xml" python3 -c '
import os, sys
caps = open(os.environ["CAPS_FILE"]).read().rstrip("\n")
data = sys.stdin.read()
print(data.replace("</map>", caps + "\n</map>"), end="")
' <<<"$xml")
        fi
    fi
    printf '%s\n' "$xml" >"$TMP/prefs.xml"
    adb_ shell "run-as $PKG sh -c 'cat > $PREFS'" <"$TMP/prefs.xml"
}

# The rule is not "only this thread is unanswered" — the device has plenty of
# old read conversations, and every one of them is a correct nudge. Marking
# them as already nudged today is the card's own once-a-day cap doing its job,
# and it leaves this test's thread as the only one that can be posted now.
cap_others() {
    local now id
    now=$(( $(date +%s) * 1000 ))
    : >"$TMP/caps.xml"
    for id in $(sql "SELECT id FROM conversations
                      WHERE deleted_at=0 AND archived=0 AND blocked=0
                        AND unread_count=0 AND last_is_me=0"); do
        case " $OURS " in *" $id "*) continue ;; esac
        printf '    <long name="reply_nudge_at_%s" value="%s" />\n' "$id" "$now" >>"$TMP/caps.xml"
    done
}

# Waits until the card for [address] is posted (want=1) or gone (want=0).
# Counting all cards would not do: the device's other conversations qualify too.
card_for() { grep -qF "android.title=String (Reply to $1?)" "$LIVE"; }

# The whole record for one address: a card's block runs from its
# NotificationRecord line to the next one.
card_block() {
    awk -v t="android.title=String (Reply to $1?)" '
        index($0, "NotificationRecord(") { if (index(b, t)) { print b; exit } b = $0; next }
        { b = b "\n" $0 }
        END { if (index(b, t)) print b }' "$LIVE"
}

wait_card_for() {
    local addr="$1" want="$2" i
    for i in $(seq 1 20); do
        shade
        if [ "$want" = "1" ]; then
            card_for "$addr" && return 0
        else
            card_for "$addr" || return 0
        fi
        sleep 2
    done
    return 1
}

cleanup() {
    for n in "$OLD" "$FRESH" "$ANSWERED"; do
        sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$n');" >/dev/null 2>&1
        sql "DELETE FROM conversations WHERE address='$n';" >/dev/null 2>&1
        sql "DELETE FROM conversation_recipients WHERE address='$n';" >/dev/null 2>&1
    done
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    pref_off >/dev/null 2>&1 || true
}
pref_off() {
    adb_ shell "run-as $PKG sh -c 'sed -i \"/name=\\\"reply_nudge_enabled\\\"/d; /name=\\\"reply_nudge_at_/d\" $PREFS'" >/dev/null 2>&1 || true
}
trap cleanup EXIT

info "Set up: permissions, role, three seeded threads"
for p in READ_SMS READ_CONTACTS POST_NOTIFICATIONS; do
    adb_ shell pm grant "$PKG" "android.permission.$p" >/dev/null 2>&1
done
adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1 || true
adb_ shell svc power stayon true >/dev/null 2>&1
# A crash saved by an earlier run is replayed as a dialog at launch, which
# would sit on top of the screen this script drives.
adb_ shell "run-as $PKG sh -c 'rm -f files/crash_reports/*.txt'" >/dev/null 2>&1
cleanup >/dev/null 2>&1
prefs_ensure_flags >/dev/null 2>&1

CID=$(seed_thread "$OLD" "Old Friend" "$BODY" 48 0)
[ -n "$CID" ] || { fail "seed: could not create the old thread"; echo; echo "Result: $PASS passed, $FAIL failed"; exit 1; }
FRESH_ID=$(seed_thread "$FRESH" "Fresh Friend" "just sent, no rush" 1 0)
ANSWERED_ID=$(seed_thread "$ANSWERED" "Answered Friend" "talk later" 48 1)
OURS="$CID $FRESH_ID $ANSWERED_ID"
pass "seeded one old, one fresh and one answered thread"

info "1. With the switch off, nothing is posted"
nudge_pref ""
launch || fail "the app did not come up"
wait_card_for "$OLD" 0 || true
shade
if card_for "$OLD"; then
    fail "a nudge appeared while the feature was off"
else
    pass "off means off: no nudge for the unanswered thread"
fi

info "2. Only the read-and-forgotten thread is nudged"
cap_others
nudge_pref true
launch || fail "the app did not come up"
if wait_card_for "$OLD" 1; then
    pass "the thread that was read and forgotten is nudged"
else
    fail "no nudge for the unanswered thread"
    head -6 "$LIVE"
fi
shade
if card_for "$FRESH"; then
    fail "an hour-old message was nudged: the interval is not being honoured"
else
    pass "the fresh thread is left alone: not forgotten yet"
fi
if card_for "$ANSWERED"; then
    fail "the answered thread was nudged"
else
    pass "the answered thread is left alone"
fi
CARD=$(card_block "$OLD")
if printf '%s\n' "$CARD" | grep -q "channel=messages_nudge"; then
    pass "it rides its own quiet channel"
else
    fail "the nudge is not on the nudge channel"
fi
if printf '%s\n' "$CARD" | grep -q "category=reminder"; then
    pass "it is a reminder, not a new message"
else
    fail "the nudge is not a reminder"
fi
if printf '%s\n' "$CARD" | grep -q "android.text=String ($BODY)"; then
    pass "the body is the message that went unanswered"
else
    fail "the body is not the unanswered message"
fi
if printf '%s\n' "$CARD" | grep -q "vis=PRIVATE"; then
    pass "its content stays off the public lock screen"
else
    fail "the nudge has no private visibility"
fi

info "3. Tapping the card opens the chat it is about"
opened=0
for i in 1 2 3; do
    adb_ shell cmd statusbar collapse >/dev/null 2>&1
    sleep 1
    adb_ shell cmd statusbar expand-notifications >/dev/null 2>&1
    sleep 3
    # The shade renders the title, not the body; match the title this card is
    # expected to carry.
    C=$(center_of_contains "Reply to $OLD?" || true)
    [ -z "$C" ] && continue
    sleep 1
    adb_ shell input tap $C >/dev/null 2>&1
    sleep 4
    adb_ shell cmd statusbar collapse >/dev/null 2>&1
    dump_ui || true
    # The bubble wraps its text in bidi isolates.
    if strip_isolates <"$TMP/ui.xml" | grep -qF "text=\"$BODY\""; then opened=1; break; fi
done
if [ "$opened" = "1" ]; then
    pass "the tap landed in the conversation the nudge was about"
else
    fail "the tap did not open the conversation"
fi

info "4. Replying drops the nudge"
if [ "$opened" = "1" ] && tap_edittext >/dev/null 2>&1; then
    sleep 1
    type_text "$REPLY" >/dev/null 2>&1
    sleep 1
    tap_text "Send" >/dev/null 2>&1 || true
    if wait_card_for "$OLD" 0; then
        pass "the reply retired the card"
    else
        fail "the nudge survived a reply"
    fi
    if [ -n "$(sql "SELECT id FROM messages WHERE is_me=1 AND body='$REPLY';")" ]; then
        pass "the reply was stored in the thread"
    else
        fail "the reply never reached the database"
    fi
else
    fail "could not reach the composer to reply"
fi

info "5. Switching the feature off clears what is left"
seed_thread "$OLD" "Old Friend" "$BODY" 48 0 >/dev/null || fail "could not re-seed the old thread"
CID=$(sql "SELECT id FROM conversations WHERE address='$OLD';")
OURS="$CID $FRESH_ID $ANSWERED_ID"
cap_others
nudge_pref true
launch || fail "the app did not come up"
wait_card_for "$OLD" 1 || fail "could not re-arm a nudge for the switch-off check"
nudge_pref ""
launch || fail "the app did not come up"
if wait_card_for "$OLD" 0; then
    pass "turning the switch off drops the card"
else
    fail "the card outlived the switch"
fi

echo
echo "Result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
