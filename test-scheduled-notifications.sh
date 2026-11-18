#!/usr/bin/env bash
# Regression for #475 — the shade's countdown card for a queued message.
#
# A scheduled text used to be invisible between scheduling and sending. Now one
# ongoing card per pending row carries a countdown (a system chronometer, so it
# stays live without a ticker) and the row's two actions: Send now and Cancel.
#
# Everything here is asserted from `dumpsys notification` and the app's own
# database — the card is not a screen, so there is nothing to tap and no
# screenshot to argue about. The actions are driven through the same receiver
# their PendingIntents point at, with the same extras.
#
# The card is reconciled at app start, which is what lets the script seed a row
# and simply launch the app instead of steering the schedule picker.
#
# Run: scripts/test-scheduled-notifications.sh   (emulator-5556)
set -uo pipefail
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }

NUM="+15551230055"
NUM2="+15551230066"
BODY="queued reminder for the shade"
BODY2="second queued reminder"
TAG="scheduled"

SHADE="$TMP/scheduled-shade.txt"
LIVE="$TMP/scheduled-live.txt"
CARD="$TMP/scheduled-card.txt"

# Everything is grepped from files, never from an adb pipe: a `grep -q` that
# exits on its first match hands the producer SIGPIPE, and `pipefail` then
# reports a successful match as a failed pipeline.
shade() {
    mkdir -p "$TMP"
    adb_ shell dumpsys notification --noredact >"$SHADE.raw" 2>/dev/null
    tr -d '\r' <"$SHADE.raw" >"$SHADE"
    # Only the live list: the archive keeps one status line per retired card,
    # which would read as "still posted" after the row is gone. The first line
    # of the live list is a record, so it carries the tag to match on.
    awk '/Notification List:/{f=1} /mArchive=/{f=0} f' "$SHADE" >"$LIVE"
}

# Space-separated, sorted: `echo $out` collapses the newlines. Always re-reads
# the shade, so a caller never compares against a stale dump.
card_ids() {
    local out
    shade
    out=$(grep -oE "id=[0-9]+ tag=$TAG" "$LIVE" | grep -oE '[0-9]+' | sort -n)
    echo $out
}

count_ids() { set -- $1; echo $#; }

card_present() {
    grep -q "tag=$TAG" "$LIVE"
}

card_posted() {
    local i
    for i in 1 2 3 4 5; do
        shade
        if card_present; then return 0; fi
        sleep 2
    done
    return 1
}

card_gone() {
    local i
    for i in 1 2 3 4 5; do
        shade
        if ! card_present; then return 0; fi
        sleep 2
    done
    return 1
}

sql() { adb_ shell "run-as $PKG sqlite3 databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r'; }

launch() {
    local i act
    for i in 1 2 3; do
        adb_ shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1
        adb_ shell wm dismiss-keyguard >/dev/null 2>&1
        adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
        adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 6
        # This AVD occasionally loses a process at start ("failed to attach",
        # SIGSEGV before the app joins the activity manager); the launch looks
        # accepted but nothing ran, so check that the screen really is up.
        act=$(adb_ shell dumpsys activity activities 2>/dev/null | tr -d '\r')
        case "$act" in
            *mResumedActivity*"$PKG"*) return 0 ;;
        esac
        echo "[info] launch attempt $i did not come up; retrying"
        sleep 3
    done
    return 1
}

seed_row() {
    local num="$1" body="$2" cid ts id
    cid=$(sql "SELECT id FROM conversations WHERE address='$num';")
    ts=$(( ($(date +%s) + 300) * 1000 ))
    sql "INSERT INTO scheduled_messages(address,body,timestamp,conversation_id,sub_id) VALUES('$num','$body',$ts,${cid:--1},-1);" >/dev/null
    id=$(sql "SELECT id FROM scheduled_messages WHERE address='$num' ORDER BY id DESC LIMIT 1;")
    [ -n "$id" ] || return 1
    echo "$id"
}

# A schedule is always made from inside a chat, so the send path finds the
# thread. Seeding it also keeps the emulator's old SQLite (3.22, no upsert) out
# of the way: creating a conversation from scratch is not what this script is
# about.
seed_conversation() {
    local num="$1" cid
    cid=$(sql "SELECT id FROM conversations WHERE address='$num';")
    [ -n "$cid" ] && { echo "$cid"; return; }
    sql "INSERT INTO conversations(address,name,timestamp) VALUES('$num','$num',$(( $(date +%s) * 1000 )));" >/dev/null
    cid=$(sql "SELECT id FROM conversations WHERE address='$num';")
    [ -n "$cid" ] || return 1
    sql "INSERT OR IGNORE INTO conversation_recipients(conversation_id,address) VALUES($cid,'$num');" >/dev/null
    echo "$cid"
}

row_exists() {
    [ -n "$(sql "SELECT id FROM scheduled_messages WHERE id=$1;")" ]
}

delete_row() {
    local i
    for i in 1 2 3; do
        row_exists "$1" || return 0
        sql "DELETE FROM scheduled_messages WHERE id=$1;" >/dev/null
        sleep 1
    done
    ! row_exists "$1"
}

# ScheduledMessageSender is exported="false", so a plain shell broadcast is
# dropped on the floor; the receiver needs root adbd to hear it. Adbd can fall
# out of root on this image, so it is re-asserted before every action.
ensure_root() {
    local i
    adb_ root >/dev/null 2>&1 || true
    adb_ wait-for-device >/dev/null 2>&1
    for i in 1 2 3 4 5 6 7 8 9 10; do
        case "$(adb_ shell id 2>/dev/null | tr -d '\r')" in
            uid=0*) return 0 ;;
        esac
        sleep 2
    done
    return 1
}

send_action() {
    ensure_root || { fail "adbd never reached root, cannot deliver $1"; return 1; }
    adb_ shell "am broadcast -n $PKG/.sms.ScheduledMessageSender -a $1 --el scheduled_id $2" >/dev/null 2>&1
}

cleanup() {
    for n in "$NUM" "$NUM2"; do
        sql "DELETE FROM scheduled_messages WHERE address='$n';" >/dev/null 2>&1
        sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$n');" >/dev/null 2>&1
        sql "DELETE FROM conversations WHERE address='$n';" >/dev/null 2>&1
        sql "DELETE FROM participants WHERE normalized_destination='$n';" >/dev/null 2>&1
    done
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    adb_ unroot >/dev/null 2>&1 || true
}
trap cleanup EXIT

info "Set up: permission, role, screen, root adbd"
for p in READ_SMS READ_CONTACTS POST_NOTIFICATIONS; do
    adb_ shell pm grant "$PKG" "android.permission.$p" >/dev/null 2>&1
done
adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1 || true
adb_ shell svc power stayon true >/dev/null 2>&1
cleanup >/dev/null 2>&1
ensure_root || fail "adbd never reached root"
adb_ wait-for-device >/dev/null 2>&1

info "1. A pending row gets a card at app start"
ID=$(seed_row "$NUM" "$BODY")
[ -n "$ID" ] || { fail "seed: no row inserted"; echo; echo "Result: $PASS passed, $FAIL failed"; exit 1; }
pass "seeded scheduled row #$ID"
launch || fail "the app did not come up"
if card_posted; then
    pass "the shade holds a card tagged '$TAG' (ids: $(card_ids))"
else
    fail "no card tagged '$TAG' in the shade"
    echo "--- live shade:"; head -6 "$LIVE"
fi

info "2. The card is ongoing and silent, and names the queue"
awk -v t="tag=$TAG" 'index($0, t) {f=1} f' "$LIVE" >"$CARD"
if grep -q "flags=0x" "$CARD"; then
    FLAGS=$(grep -oE "flags=0x[0-9a-f]+" "$CARD" | head -1 | cut -d= -f2)
    if [ $((FLAGS & 8)) -ne 0 ]; then
        pass "the card is ongoing (ONGOING_EVENT set, flags=$FLAGS)"
    else
        fail "the card is not ongoing (flags=$FLAGS)"
    fi
else
    fail "could not read the card's flags"
fi
if grep -q "channel=messages_scheduled" "$CARD"; then
    pass "it uses its own silent channel"
else
    fail "the card is not on the scheduled channel"
fi
if grep -q "android.title=String (Scheduled message)" "$CARD"; then
    pass "the title names what it is"
else
    fail "the title does not read 'Scheduled message'"
fi
if grep -q "android.text=String ($BODY)" "$CARD"; then
    pass "the body is the queued text"
else
    fail "the body is not the queued text"
fi
if grep -q "actions=2" "$CARD"; then
    pass "the card carries two actions"
else
    fail "the card does not carry two actions"
fi

info "3. Cancel (the card's action) drops both the row and the card"
send_action com.anindra.messages.SCHEDULED_CANCEL "$ID"
sleep 3
if row_exists "$ID"; then
    fail "Cancel left the scheduled row behind"
else
    pass "Cancel removed the scheduled row"
fi
if card_gone; then
    pass "Cancel dropped the card from the shade"
else
    fail "the card survived Cancel ($(card_ids))"
fi

info "4. Send now (the card's action) sends and retires the row"
CID=$(seed_conversation "$NUM")
[ -n "$CID" ] || fail "could not seed the conversation"
ID=$(seed_row "$NUM" "$BODY")
launch || fail "the app did not come up"
if card_posted; then pass "a fresh row posted a fresh card"; else fail "the fresh row posted no card"; fi
send_action com.anindra.messages.SCHEDULED_SEND_NOW "$ID"
sleep 4
if row_exists "$ID"; then
    fail "Send now left the scheduled row behind"
else
    pass "Send now retired the row"
fi
SENT=$(sql "SELECT count(*) FROM messages WHERE is_me=1 AND body='$BODY';")
if [ "${SENT:-0}" -ge 1 ]; then
    pass "the queued text was handed to the send path"
else
    fail "no outgoing message with the queued text"
fi
if card_gone; then
    pass "Send now dropped the card"
else
    fail "the card survived Send now ($(card_ids))"
fi

info "5. App start reconciles one card per pending row"
A=$(seed_row "$NUM" "$BODY")
B=$(seed_row "$NUM2" "$BODY2")
[ -n "$A" ] && [ -n "$B" ] || fail "could not seed two rows"
launch || fail "the app did not come up"
card_posted || fail "no cards for the two pending rows"
IDS=$(card_ids)
if [ "$(count_ids "$IDS")" -eq 2 ]; then
    pass "two pending rows posted two cards (ids: $IDS)"
else
    fail "expected two cards, saw $(count_ids "$IDS") ($IDS)"
fi
if delete_row "$A"; then
    launch || fail "the app did not come up after the delete"
    IDS=$(card_ids)
    case " $IDS " in
        *" $A "*) fail "the card for a deleted row survived app start ($IDS)" ;;
        *" $B "*) pass "app start dropped the stale card and kept the live one" ;;
        *)        fail "the live row's card was dropped too ($IDS)" ;;
    esac
else
    fail "could not delete row #$A"
fi
if delete_row "$B"; then
    launch || fail "the app did not come up after the second delete"
    if card_gone; then
        pass "app start dropped the last card once its row was gone"
    else
        fail "a card survived with no rows left ($(card_ids))"
    fi
else
    fail "could not delete row #$B"
fi

echo
echo "Result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
