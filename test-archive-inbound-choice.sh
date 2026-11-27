#!/usr/bin/env bash
# Issue #532: the first archive asks once whether new messages should bring an
# archived chat back to Inbox or leave it archived. The answer is locked until
# app data is cleared, and either answer applies to every conversation.
#
#   bash scripts/test-archive-inbound-choice.sh
set -uo pipefail
cd "$(dirname "$0")"
source ./env.sh

PASS=0
FAIL=0
MARK="archive-choice-532"
A="+1555772031"
B="+1555772032"
C="+1555772033"
PREF_BAK="$TMP/archive-inbound-choice-prefs-$$.xml"

ok()   { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad()  { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

if ! "$ADB" devices | grep -q "^$ANDROID_SERIAL[[:space:]]*device"; then
    echo "ABORT: no device $ANDROID_SERIAL"; exit 2
fi
if ! adb_ emu sms send +1555772030 probe >/dev/null 2>&1; then
    echo "ABORT: $ANDROID_SERIAL has no modem to inject an SMS; run this on an emulator." >&2
    exit 2
fi

dbq() { printf '%s' "$1" | adb_ shell "run-as $PKG sqlite3 databases/messages.db" 2>/dev/null | tr -d '\r'; }
prefs() { adb_ shell run-as "$PKG" cat shared_prefs/messages_settings.xml 2>/dev/null | tr -d '\r'; }
pref_value() {
    prefs | grep -o "name=\"$1\" value=\"[^\"]*\"" | head -1 |
        grep -o 'value="[^"]*"' | cut -d'"' -f2
}

backup_prefs() {
    adb_ exec-out run-as "$PKG" cat shared_prefs/messages_settings.xml > "$PREF_BAK" 2>/dev/null || true
}

reset_choice() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    adb_ shell run-as "$PKG" rm -f shared_prefs/messages_settings.xml >/dev/null 2>&1 || true
}

restore_prefs() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    if [ -s "$PREF_BAK" ]; then
        adb_ shell "run-as $PKG sh -c 'cat > shared_prefs/messages_settings.xml'" < "$PREF_BAK" >/dev/null 2>&1 || true
    else
        adb_ shell run-as "$PKG" rm -f shared_prefs/messages_settings.xml >/dev/null 2>&1 || true
    fi
}

launch() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    adb_ shell am start -n "$ACT" >/dev/null 2>&1
    sleep 5
    if ui_has "Set as default SMS app?"; then
        tap_text "Not now" >/dev/null 2>&1 || true
        sleep 1
    fi
}

seed() {
    local addr="$1" name="$2" body="$MARK-$3" seed_body="$MARK-$3-seed"
    dbq "DELETE FROM messages WHERE body LIKE '$MARK-$3%';"
    dbq "DELETE FROM conversations WHERE address='$addr';"
    dbq "INSERT INTO conversations(address,name,snippet,timestamp,unread_count,last_is_me,archived) VALUES('$addr','$name','$seed_body',$(date +%s)000,0,1,0);"
    dbq "INSERT INTO messages(conversation_id,body,timestamp,is_me,status) SELECT id, '$seed_body', $(date +%s)000, 0, 'received' FROM conversations WHERE address='$addr';"
}

archive_row() {
    local label="$1" c x y
    c=$(center_of_contains "$label") || return 1
    x=${c% *}
    y=${c#* }
    adb_ shell input swipe "$x" "$y" "$x" "$y" 900
    sleep 1
    tap_text "Archive" >/dev/null 2>&1 || return 1
    sleep 2
}

send_and_wait() {
    local addr="$1" body="$MARK-$2" rows=""
    adb_ shell su 0 cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1 || true
    adb_ emu sms send "$addr" "$body" >/dev/null 2>&1
    for _ in $(seq 1 20); do
        rows=$(dbq "SELECT COUNT(*) FROM messages WHERE body='$body';")
        [ "$rows" != "0" ] && [ -n "$rows" ] && return 0
        sleep 1
    done
    return 1
}

info "First archive shows the one-time choice"
backup_prefs
reset_choice
seed "$A" "Archive choice A" "a"
launch
if archive_row "1555772031" && [ "$(dbq "SELECT archived FROM conversations WHERE address='$A';")" = "1" ]; then
    ok "archived the first conversation"
else
    bad "could not archive the first conversation"
fi
if ui_has "New messages in archived chats"; then ok "the one-time modal appeared"; else bad "no one-time modal after the first archive"; fi
if ui_has "Bring to Inbox" && ui_has "Keep archived"; then ok "both answers are offered"; else bad "the modal is missing an answer"; fi

info "Keeping archived is remembered and applies to inbound messages"
if tap_text "Keep archived"; then ok "tapped Keep archived"; else bad "could not tap Keep archived"; fi
sleep 1
[ "$(pref_value archive_inbound_choice_asked)" = "true" ] && ok "the prompt is marked as asked" || bad "the prompt was not marked as asked"
[ "$(pref_value keep_archived_on_inbound)" = "true" ] && ok "the archive choice is stored" || bad "the archive choice was not stored"
[ "$(dbq "SELECT archived FROM conversations WHERE address='$A';")" = "1" ] && ok "the first chat stayed archived" || bad "the first chat did not stay archived"

seed "$B" "Archive choice B" "b"
launch
if archive_row "1555772032" && [ "$(dbq "SELECT archived FROM conversations WHERE address='$B';")" = "1" ]; then
    ok "archived a second conversation"
else
    bad "could not archive the second conversation"
fi
if ui_has "New messages in archived chats"; then bad "the modal appeared a second time"; else ok "the modal stayed one-time"; fi

if send_and_wait "$A" "a"; then ok "a text reached the archived chat"; else bad "the text never arrived"; fi
[ "$(dbq "SELECT archived FROM conversations WHERE address='$A';")" = "1" ] && ok "the chat stayed archived after the text" || bad "the chat left the archive after the text"

info "A fresh choice can bring it back to Inbox"
reset_choice
seed "$C" "Archive choice C" "c"
launch
if archive_row "1555772033" && [ "$(dbq "SELECT archived FROM conversations WHERE address='$C';")" = "1" ]; then
    ok "archived a conversation after the choice was cleared"
else
    bad "could not archive after the choice was cleared"
fi
if ui_has "New messages in archived chats"; then ok "the modal appeared again only after clearing the choice"; else bad "no modal after clearing the choice"; fi
if tap_text "Bring to Inbox"; then ok "tapped Bring to Inbox"; else bad "could not tap Bring to Inbox"; fi
sleep 1
[ "$(pref_value archive_inbound_choice_asked)" = "true" ] && ok "the second prompt is marked as asked" || bad "the second prompt was not marked as asked"
[ "$(pref_value keep_archived_on_inbound)" = "false" ] && ok "the Inbox choice is stored" || bad "the Inbox choice was not stored"
if send_and_wait "$C" "c"; then ok "a text reached the second chat"; else bad "the second text never arrived"; fi
[ "$(dbq "SELECT archived FROM conversations WHERE address='$C';")" = "0" ] && ok "the chat returned to Inbox after the text" || bad "the chat stayed archived after the text"

info "Clean up"
for addr in "$A" "$B" "$C"; do
    dbq "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$addr');"
    dbq "DELETE FROM conversations WHERE address='$addr';"
done
restore_prefs
adb_ shell su 0 cmd role add-role-holder android.app.role.SMS com.google.android.apps.messaging >/dev/null 2>&1 || true
adb_ shell am force-stop "$PKG" >/dev/null 2>&1

info "Result"
echo "  PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && echo "=== OK ===" || echo "=== FAILED ==="
exit $((FAIL > 0))
