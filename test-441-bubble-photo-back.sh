#!/usr/bin/env bash
# Regression for #441: a bubble kept a contact's previous photo, and its Back
# gesture reached nothing.
#
# Photo (fails on the build before the fix):
#   * the shortcut publishes a fingerprint of the picture it draws,
#   * adding a photo to the contact republishes that shortcut with a |PHOTO|
#     fingerprint and a new one, and the avatar is rebuilt from the contact
#     instead of the cached monogram,
#   * the notification survives the refresh.
# Back:
#   * the installed APK declares enableOnBackInvokedCallback=true, so a bubble
#     window on Android 16 has an OnBackInvokedCallback to receive Back at all,
#   * with "Close bubble with Back" off, Back stays on the conversation,
#   * with it on, Back finishes the bubble and cancels its notification.
#
# The photo assertions fail on the pre-fix build (the shortcut was never
# refreshed); the manifest assertion fails there too. The two gesture checks
# pass on both, since the emulator's legacy path delivered Back already — they
# guard the behaviour rather than reproduce the Android 16 report.
#
# Run: scripts/test-441-bubble-photo-back.sh
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

RUN=$(date +%s)
MARK="probe441$RUN"
TEXT="photo probe $MARK"
NUM="+1555444$(( (RUN % 9000) + 1000 ))"
SID="probe-441-$RUN"
CNAME="Bubble Probe 441"
BUBBLE_ACT="$PKG/.BubbleChatActivity"

adb_ root >/dev/null 2>&1
adb_ wait-for-device; sleep 1

DB=/data/user/0/com.android.providers.contacts/databases/contacts2.db
CONTACTS_DB() { adb_su "sqlite3 $DB \"$1\"" 2>/dev/null | tr -d '\r'; }
sql() { adb_ shell "sqlite3 /data/data/$PKG/databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r'; }

PREFS="/data/data/$PKG/shared_prefs/messages_settings.xml"
pref_bool() {
    adb_ shell "if grep -q 'name=\"$1\"' $PREFS; then sed -i 's#name=\"$1\" value=\"[^\"]*\"#name=\"$1\" value=\"$2\"#' $PREFS; else sed -i 's#</map>#    <boolean name=\"$1\" value=\"$2\" /></map>#' $PREFS; fi"
}

convo_id() {
    sql "SELECT conversation_id FROM messages WHERE body LIKE '%$MARK%' LIMIT 1;"
}

shortcut_extras() {
    adb_ shell dumpsys shortcut 2>/dev/null | tr -d '\r' \
        | grep -A20 "id=conversation_$1," | grep -o "conversation_icon=[^]]*" | head -1 | cut -d= -f2-
}

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    sql "DELETE FROM messages WHERE body LIKE '%$MARK%';" >/dev/null 2>&1
    sql "DELETE FROM conversations WHERE address='$NUM';" >/dev/null 2>&1
    adb_ shell "content delete --uri content://com.android.contacts/raw_contacts --where \"sourceid='$SID'\"" >/dev/null 2>&1
    adb_ shell cmd notification set_bubbles "$PKG" 0 >/dev/null 2>&1
    pref_bool bubble_back_closes false
}
trap cleanup EXIT

post_message() {
    adb_ emu sms send "$NUM" "$TEXT" >/dev/null 2>&1
    for _ in $(seq 1 20); do
        [ -n "$(convo_id)" ] && break
        sleep 1
    done
    sleep 2
}

# --- contact seeding -------------------------------------------------------
# Same provider technique as insert-demo-contacts.sh: raw contact + name +
# phone through `content insert`, photo blob through sqlite3 (content cannot
# bind a blob), then a provider-mediated update so the URI notifier runs.
seed_contact() {
    adb_ shell "content insert --uri content://com.android.contacts/raw_contacts --bind account_name:s:probe --bind account_type:s:com.local --bind sourceid:s:$SID" >/dev/null
    local rid; rid=$(CONTACTS_DB "SELECT _id FROM raw_contacts WHERE sourceid='$SID';")
    [ -n "$rid" ] || { echo "contact seeding failed (no raw contact)"; return 1; }
    adb_ shell "content insert --uri content://com.android.contacts/data --bind raw_contact_id:i:$rid --bind mimetype:s:vnd.android.cursor.item/name --bind data1:s:\"$CNAME\" --bind data2:s:\"Bubble\" --bind data3:s:\"Probe\" --bind data10:i:0" >/dev/null
    adb_ shell "content insert --uri content://com.android.contacts/data --bind raw_contact_id:i:$rid --bind mimetype:s:vnd.android.cursor.item/phone_v2 --bind data1:s:\"$NUM\" --bind data2:i:2 --bind is_primary:i:1" >/dev/null
    adb_ shell "content insert --uri content://com.android.contacts/data --bind raw_contact_id:i:$rid --bind mimetype:s:vnd.android.cursor.item/photo" >/dev/null
    echo "$rid"
}

add_photo() { # rid, png
    local rid="$1" png="$2"
    local hex cid rowid
    hex=$(python3 -c 'import sys;print(open(sys.argv[1],"rb").read().hex())' "$png")
    rowid=$(CONTACTS_DB "SELECT _id FROM data WHERE raw_contact_id=$rid AND mimetype_id=(SELECT _id FROM mimetypes WHERE mimetype='vnd.android.cursor.item/photo') LIMIT 1;")
    cid=$(CONTACTS_DB "SELECT contact_id FROM raw_contacts WHERE _id=$rid;")
    [ -n "$rowid" ] && [ -n "$cid" ] || { echo "photo row missing"; return 1; }
    adb_su "sqlite3 $DB \"UPDATE data SET data15=X'$hex', data14=NULL, data_version=data_version+1 WHERE _id=$rowid;
        UPDATE contacts SET photo_id=$rowid, photo_file_id=NULL WHERE _id=$cid;
        UPDATE raw_contacts SET version=version+1, metadata_dirty=1, aggregation_needed=1 WHERE _id=$rid;\"" >/dev/null
    local ver; ver=$(CONTACTS_DB "SELECT version FROM raw_contacts WHERE _id=$rid;")
    adb_ shell "content update --uri content://com.android.contacts/raw_contacts/$rid --bind version:i:$ver" >/dev/null 2>&1 || true
}

make_png() { # path
    python3 - "$1" <<'PY'
import struct, sys, zlib
w = h = 64
raw = b"".join(b"\x00" + b"".join(bytes([(x * 4) % 256, (y * 4) % 256, 200]) for x in range(w)) for y in range(h))
def chunk(t, d):
    return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
png = (b"\x89PNG\r\n\x1a\n"
       + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
open(sys.argv[1], "wb").write(png)
PY
}

# --- preconditions ---------------------------------------------------------
info "Preconditions"
adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1
adb_ shell pm grant "$PKG" android.permission.READ_CONTACTS 2>/dev/null
adb_ shell pm grant "$PKG" android.permission.POST_NOTIFICATIONS 2>/dev/null
adb_ shell cmd notification set_bubbles "$PKG" 1 >/dev/null 2>&1
pref_bool bubble_back_closes false
# The platform allows 10 shortcut updates per day; the assertions below need
# every republish to land.
adb_ shell cmd shortcut reset-throttling >/dev/null 2>&1
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 3
ok "app started with the SMS role and bubbles enabled"

# --- Back goes through the dispatcher -------------------------------------
info "The installed app receives Back through OnBackInvokedDispatcher"
APK_PATH=$(adb_ shell pm path "$PKG" | tr -d '\r' | sed 's/^package://' | head -1)
APK_LOCAL="$TMP/installed-441.apk"
if [ -n "$APK_PATH" ] && adb_ pull "$APK_PATH" "$APK_LOCAL" >/dev/null 2>&1; then
    AAPT=$(ls "$HOME"/android/build-tools/*/aapt2 2>/dev/null | sort -V | tail -1)
    FLAG=$("$AAPT" dump xmltree --file AndroidManifest.xml "$APK_LOCAL" 2>/dev/null \
        | grep -o 'enableOnBackInvokedCallback(0x[0-9a-f]*)=[a-z]*' | head -1 | cut -d= -f2)
    if [ "$FLAG" = "true" ]; then
        ok "the manifest opts into the back dispatcher"
    else
        bad "enableOnBackInvokedCallback is '${FLAG:-absent}', so a bubble on Android 16 gets no Back"
    fi
else
    bad "could not read the installed APK's manifest"
fi

# --- contact photo reaches the bubble -------------------------------------
info "A conversation without a contact photo publishes a monogram"
RID=$(seed_contact)
[ -n "$RID" ] && ok "seeded contact '$CNAME' ($NUM, no photo)" \
              || bad "could not seed the probe contact"
post_message
CONVO=$(convo_id)
if [ -n "$CONVO" ]; then
    ok "message landed in conversation $CONVO"
else
    bad "message never reached the database"
    echo; echo "PASS=$PASS FAIL=$FAIL"; [ "$FAIL" -eq 0 ]; exit 1
fi

adb_ logcat -c >/dev/null 2>&1
BEFORE=""
for _ in $(seq 1 20); do
    BEFORE=$(shortcut_extras "$CONVO")
    [ -n "$BEFORE" ] && break
    sleep 1
done
if [ -n "$BEFORE" ]; then
    ok "the shortcut stores the picture it draws"
else
    bad "the shortcut carries no picture fingerprint, so a contact edit cannot be detected"
fi
case "$BEFORE" in
    *"|AVATAR|"*) ok "before the edit the shortcut is a monogram ($BEFORE)" ;;
    *) bad "expected a monogram fingerprint before the edit, got '${BEFORE:-none}'" ;;
esac

info "Changing the contact's photo refreshes the bubble"
make_png "$TMP/441-photo.png"
add_photo "$RID" "$TMP/441-photo.png"
sleep 2

AFTER=""
for _ in $(seq 1 30); do
    AFTER=$(shortcut_extras "$CONVO")
    case "$AFTER" in *"|PHOTO|"*) break ;; esac
    sleep 1
done
case "$AFTER" in
    *"|PHOTO|"*) ok "the shortcut was republished with the contact photo ($AFTER)" ;;
    *) bad "the shortcut still draws the old picture after the photo changed (${AFTER:-none})" ;;
esac
if [ -n "$BEFORE" ] && [ "$BEFORE" != "$AFTER" ]; then
    ok "the fingerprint changed with the picture"
else
    bad "the fingerprint did not change, so the bubble cannot follow the edit"
fi
if adb_ logcat -d -s 'BubbleIcon:*' 2>/dev/null | grep -q "address=$NUM source=PHOTO"; then
    ok "the avatar was rebuilt from the contact, not the cached monogram"
else
    bad "the avatar cache still served the monogram"
fi
if adb_ shell cmd notification list 2>/dev/null | tr -d '\r' | grep -q "|$PKG|"; then
    ok "the notification survived the refresh"
else
    bad "refreshing the picture dropped the notification"
fi

# --- Back ------------------------------------------------------------------
info "Back stays on the bubble's conversation by default"
# No force-stop here: the app is still running with the notification from the
# photo section, and stopping it would cancel that notification before Back can
# be judged on it.
adb_ shell am start -a android.intent.action.VIEW -d "messages://conversation/$CONVO" \
    -n "$BUBBLE_ACT" -f 0x10000000 \
    --es open_conversation_address "$NUM" --ez open_in_bubble true >/dev/null 2>&1
sleep 4
adb_ shell input keyevent KEYCODE_BACK >/dev/null 2>&1
sleep 3
if adb_ shell cmd notification list 2>/dev/null | tr -d '\r' | grep -q "|$PKG|"; then
    ok "Back kept the bubble's notification"
else
    bad "Back dismissed the bubble even though the setting is off"
fi
if adb_ shell dumpsys activity activities 2>/dev/null | tr -d '\r' | grep "ResumedActivity" | grep -q "BubbleChatActivity"; then
    ok "Back left the bubble on its conversation"
else
    bad "Back took the bubble off its conversation"
fi

info "With 'Close bubble with Back' on, Back closes the bubble"
pref_bool bubble_back_closes true
adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
# A fresh notification to judge: force-stop cancelled the previous one.
post_message
adb_ shell am start -a android.intent.action.VIEW -d "messages://conversation/$CONVO" \
    -n "$BUBBLE_ACT" -f 0x10000000 \
    --es open_conversation_address "$NUM" --ez open_in_bubble true >/dev/null 2>&1
sleep 4
adb_ shell input keyevent KEYCODE_BACK >/dev/null 2>&1
sleep 3
if adb_ shell dumpsys activity activities 2>/dev/null | tr -d '\r' | grep "ResumedActivity" | grep -q "BubbleChatActivity"; then
    bad "Back did not close the bubble with the setting on"
else
    ok "Back closed the bubble"
fi
if adb_ shell cmd notification list 2>/dev/null | tr -d '\r' | grep -q "|$PKG|"; then
    bad "the closed bubble left its notification behind"
else
    ok "closing the bubble released its notification"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
