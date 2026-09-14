#!/usr/bin/env bash
# Regression for issue #203:
#   "Unable to send the message from a new conversation and a new number."
#
# Reporter flow: Contacts -> a contact -> the "Text" (message) button next to a
# number. That button fires ACTION_SENDTO with an `smsto:<number>` URI. Messages
# launched but landed on the conversation LIST instead of a chat for that
# recipient, because MainActivity only read the internal
# `open_conversation_address` extra and never parsed intent.data. The user then
# had no recipient, and the blank-address send was rejected with the misleading
# "You can't send messages to alphanumeric senders like """ dialog.
#
# This script fires the same external intents (cold + warm, sms:/smsto:,
# ?body= query, multi-recipient) and asserts the chat for the contact opens.
# Before the fix it lands on the list -> fails; after the fix it passes.
source "$(dirname "$0")/env.sh"

NUM="+15551239977"
NAME="Issue203Tester"
SID="issue203-test"
CONTACTS_DB=/data/user/0/com.android.providers.contacts/databases/contacts2.db

PASS=0; FAIL=0
ok()   { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad()  { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

grant_perms() {
    for p in SEND_SMS RECEIVE_SMS READ_SMS READ_CONTACTS POST_NOTIFICATIONS; do
        adb_ shell pm grant "$PKG" android.permission.$p 2>/dev/null
    done
    adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" 2>/dev/null
}

raw_id() {
    adb_ shell "su 0 sqlite3 $CONTACTS_DB \"select _id from raw_contacts where sourceid='$SID' limit 1;\" 2>/dev/null" | tr -d '\r' | head -1
}

seed_contact() {
    # Always recreate from scratch: reusing a surviving raw contact while
    # re-inserting name/phone would leave duplicate rows and stale phone_lookup
    # entries, which makes PhoneLookup fail and the header fall back to a number.
    adb_ shell "content delete --uri content://com.android.contacts/raw_contacts \
        --where \"sourceid='$SID'\"" >/dev/null 2>&1
    adb_ shell "content insert --uri content://com.android.contacts/raw_contacts \
        --bind account_name:s:issue203 --bind account_type:s:com.local --bind sourceid:s:$SID" >/dev/null
    local rid
    rid=$(raw_id)
    [ -z "$rid" ] && return 1
    adb_ shell "content insert --uri content://com.android.contacts/data \
        --bind raw_contact_id:l:$rid --bind mimetype:s:vnd.android.cursor.item/name \
        --bind data1:s:$NAME --bind data2:s:$NAME" >/dev/null
    adb_ shell "content insert --uri content://com.android.contacts/data \
        --bind raw_contact_id:l:$rid --bind mimetype:s:vnd.android.cursor.item/phone_v2 \
        --bind data1:s:$NUM --bind data2:l:2" >/dev/null
}

cleanup() {
    adb_ shell "content delete --uri content://com.android.contacts/raw_contacts \
        --where \"sourceid='$SID'\"" >/dev/null 2>&1
    adb_ shell "run-as $PKG sh -c 'sqlite3 databases/messages.db \
        \"DELETE FROM messages WHERE conversation_id IN \
          (SELECT id FROM conversations WHERE address LIKE \\\"%1239977%\\\"); \
          DELETE FROM conversations WHERE address LIKE \\\"%1239977%\\\";\"'" >/dev/null 2>&1
}
trap cleanup EXIT

# Send an external SMS intent; wait for the chat to settle and dump. The URI is
# single-quoted for the DEVICE shell so `;`/`,` recipient separators and `?` are
# not re-parsed as shell syntax.
fire_intent() {
    adb_ shell "am start -a android.intent.action.SENDTO -d '$1'" >/dev/null 2>&1
    sleep 3
}

# Assert the contact's chat is foreground: input placeholder present, the home
# list's "Start chat" FAB absent, and the header resolves to the contact name.
assert_chat_open() {
    local label="$1" i
    for i in 1 2 3; do
        dump_ui || { sleep 1; continue; }
        grep -q 'text="Text message"' "$TMP/ui.xml" && break
        sleep 1
    done
    if grep -q 'text="Text message"' "$TMP/ui.xml"; then
        ok "$label: chat screen opened"
    else
        bad "$label: chat screen NOT opened (still on list)"
    fi
    if grep -q 'content-desc="Start chat"' "$TMP/ui.xml"; then
        bad "$label: home list still visible (Start chat FAB)"
    else
        ok "$label: home list not shown"
    fi
    if grep -q "$NAME" "$TMP/ui.xml"; then
        ok "$label: header shows the contact name"
    else
        bad "$label: header missing the contact name"
    fi
}

info "Setup: permissions + contact"
grant_perms
seed_contact || { bad "could not seed contact"; exit 1; }

info "Cold launch via smsto: (the Contacts 'Text' button intent)"
adb_ shell am force-stop "$PKG"; sleep 1
fire_intent "smsto:$NUM"
assert_chat_open "cold smsto"

info "Back from the deep-link chat lands on the home list (Main screen)"
adb_ shell input keyevent 4; sleep 1.5
dump_ui
if grep -q 'content-desc="Start chat"' "$TMP/ui.xml"; then
    ok "back from chat -> home list"
else
    bad "back from chat did not reach the home list"
fi

info "Warm launch via sms: after returning to the list"
fire_intent "sms:$NUM"
assert_chat_open "warm sms"

info "Query string is stripped (sms:<num>?body=...)"
adb_ shell input keyevent 4; sleep 1.5
fire_intent "sms:$NUM?body=hello"
assert_chat_open "sms with ?body"

info "Multi-recipient picks the first number"
adb_ shell input keyevent 4; sleep 1.5
fire_intent "smsto:$NUM;+15550000000"
assert_chat_open "multi-recipient"

info "Trashed thread is restored (no blank header / failed send)"
adb_ shell input keyevent 4; sleep 1.5
adb_ shell "run-as $PKG sh -c 'sqlite3 databases/messages.db \
    \"UPDATE conversations SET deleted_at=9999999999999 \
      WHERE address LIKE \\\"%1239977%\\\";\"'" >/dev/null 2>&1
fire_intent "smsto:$NUM"
assert_chat_open "trashed thread"
ACTIVE=$(adb_ shell "run-as $PKG sh -c 'sqlite3 databases/messages.db \
    \"SELECT COUNT(*) FROM conversations \
      WHERE address LIKE \\\"%1239977%\\\" AND deleted_at=0;\"'" | tr -d '\r')
if [ "$ACTIVE" = "1" ]; then
    ok "trashed thread un-trashed in DB"
else
    bad "trashed thread still trashed (active=$ACTIVE)"
fi

info "No misleading alphanumeric dialog for the valid address"
if grep -q "Can't send message" "$TMP/ui.xml"; then
    bad "alphanumeric dialog shown for a valid phone number"
else
    ok "no alphanumeric dialog"
fi

echo ""
info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
