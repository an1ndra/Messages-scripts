#!/usr/bin/env bash
# Regression for issue #207: alphanumeric sender IDs were reduced to bare
# digits ("A1 SRB" -> "1"), so the thread displayed as "1" and was replyable.
#
# Note: `adb emu sms send` parses its sender argument as a phone number and
# strips letters for digit-containing IDs ("A1-SRB" arrives as "1"), so a
# digit-containing sender is seeded straight into the provider with
# `content insert` instead. The notification check uses a digit-less sender ID
# (preserved by the console) because only a real delivery posts a notification.
#
# Asserts:
#   1. alphanumeric notifications carry no Reply action, numeric ones still do;
#   2. a provider SMS from "A1-SRB" yields a conversation labelled "A1-SRB";
#   3. that chat is read-only (no composer, "can't receive replies" notice);
#   4. a legacy row corrupted to "1" is repaired from the provider on next sync.
#
# Fails before the fix, passes after. Run: scripts/test-alphanumeric-sender.sh
set -u
source "$(dirname "$0")/env.sh"

SENDER="A1-SRB"          # digit-containing ID: the issue #207 case
STRIPPED="1"             # what the old canonical() produced
ALPHA="AXKOTAKB"         # digit-less ID: deliverable by `emu sms send`
CTRL="+15551230077"
STAMP="$(date +%s)"
DB="databases/messages.db"

PASS=0; FAIL=0
ok()   { echo "[PASS] $1"; PASS=$((PASS+1)); }
bad()  { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }
note() { echo "[NOTE] $1"; }

cancel_our_notifs() {
    for id in $(adb_ shell cmd notification list 2>/dev/null \
            | grep "$PKG" | sed -E 's/^\S+ \|'"$PKG"' \|([0-9]+).*/\1/'); do
        adb_ shell cmd notification cancel "$PKG" "$id" >/dev/null 2>&1 || true
    done
}

# Our posted notifications with >1 action carry the quick-reply action.
some_reply_action() {
    adb_ shell dumpsys notification --noredact 2>/dev/null \
        | grep "pkg=$PKG" | grep -qE "actions=[2-9]"
}

# Insert a provider SMS directly, bypassing the emulator console's number parser.
seed_provider() {
    local now=$(( $(date +%s) * 1000 ))
    adb_ shell "content insert --uri content://sms \
        --bind address:s:$1 --bind body:s:$2 --bind date:l:$now \
        --bind read:i:1 --bind type:i:1 --bind seen:i:1" >/dev/null 2>&1
}

pref_set() {
    adb_ shell "run-as $PKG sed -i 's#<boolean name=\"$1\" value=\"[a-z]*\"#<boolean name=\"$1\" value=\"$2\"#' shared_prefs/messages_settings.xml" >/dev/null 2>&1 || true
}

db_query() {
    adb_ shell "run-as $PKG sqlite3 $DB \"$1\"" 2>/dev/null | tr -d '\r'
}

reset_app() {
    adb_ shell pm clear "$PKG" >/dev/null 2>&1
    adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1 || true
    bash "$(dirname "$0")/grant-permissions.sh" >/dev/null 2>&1 || true
}

info "Set as default SMS app + grant permissions"
adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1 || true
bash "$(dirname "$0")/grant-permissions.sh" >/dev/null 2>&1 || true
cancel_our_notifs

info "1. Alphanumeric sender notification must NOT offer Reply"
adb_ shell am force-stop "$PKG"; sleep 1
adb_ emu sms send "$ALPHA" "alnum probe $STAMP" >/dev/null 2>&1; sleep 3
if adb_ shell cmd notification list 2>/dev/null | grep -q "$PKG"; then
    ok "alphanumeric notification posted"
else
    bad "alphanumeric notification missing"
fi
if some_reply_action; then
    bad "alphanumeric notification wrongly offers a Reply action"
else
    ok "no Reply action on alphanumeric notification"
fi

info "2. Control: numeric sender notification still offers Reply"
cancel_our_notifs
adb_ emu sms send "$CTRL" "numeric probe $STAMP" >/dev/null 2>&1; sleep 3
if some_reply_action; then
    ok "numeric notification still offers a Reply action"
else
    bad "numeric notification lost its Reply action"
fi
cancel_our_notifs

info "3. Provider SMS from '$SENDER' must keep the full sender ID"
BODY="a1srbprobe$STAMP"
seed_provider "$SENDER" "$BODY"
reset_app
adb_ shell am start -n "$ACT" >/dev/null 2>&1
CID=""
for _ in $(seq 1 90); do
    CID=$(db_query "SELECT conversation_id FROM messages WHERE body LIKE '%$BODY%' LIMIT 1;")
    [ -n "$CID" ] && break
    sleep 1
done
if [ -n "$CID" ]; then
    ok "message imported into a conversation (id=$CID)"
else
    bad "seeded message never imported"
fi
ADDR=$( [ -n "$CID" ] && db_query "SELECT address FROM conversations WHERE id=$CID;" )
if [ "$ADDR" = "$SENDER" ]; then
    ok "conversation stored with address '$SENDER'"
else
    bad "conversation address is '$ADDR', expected '$SENDER' (digit-stripped?)"
fi
adb_ shell am start -n "$ACT" --es open_conversation_address "$SENDER" >/dev/null 2>&1
sleep 2
if dump_ui && grep -q "text=\"$SENDER\"" "$TMP/ui.xml"; then
    ok "chat header shows '$SENDER'"
else
    bad "chat header lost the sender ID"
fi
if dump_ui && ! grep -q 'class="android.widget.EditText"' "$TMP/ui.xml" \
        && grep -q "receive replies" "$TMP/ui.xml"; then
    ok "no composer; 'can't receive replies' notice shown"
else
    bad "composer still present for alphanumeric sender"
fi
adb_ shell input keyevent 4; sleep 1

info "4. Legacy digit-corrupted row is repaired from the provider"
adb_ shell am force-stop "$PKG"; sleep 1
if [ -z "$CID" ]; then
    bad "cannot corrupt: no conversation id captured"
else
    adb_ shell "run-as $PKG sqlite3 $DB \"UPDATE conversations SET address='$STRIPPED', name='$STRIPPED' WHERE id=$CID;\"" >/dev/null 2>&1
    pref_set alphanumeric_repair_done false
    note "corrupted conversation id=$CID to '$STRIPPED'"
    adb_ shell am start -n "$ACT" >/dev/null 2>&1
    AFTER=""
    for _ in $(seq 1 30); do
        AFTER=$(db_query "SELECT address FROM conversations WHERE id=$CID;")
        [ "$AFTER" = "$SENDER" ] && break
        sleep 1
    done
    if [ "$AFTER" = "$SENDER" ]; then
        ok "corrupted row repaired to '$SENDER'"
    else
        bad "repair failed (id=$CID address='$AFTER')"
    fi
fi

echo
[ "$FAIL" = "0" ] && echo "== ALL PASSED ($PASS) ==" || echo "== $FAIL CHECK(S) FAILED ($PASS passed) =="
exit $((FAIL > 0))
