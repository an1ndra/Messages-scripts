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
#   * with "Close bubble with Back" off, the app stops answering Back so the
#     platform can collapse the expanded bubble (a bubble task intercepts Back
#     at its root and SystemUI collapses it there), and the toolbar arrow opens
#     the conversation list in place because the platform owns the gesture;
#     choosing a chat from that list must not retire the bubble that hosts it
#     (opening full-screen retires it, and inside the bubble that cancelled the
#     notification and made the bubble vanish),
#   * with it on, Back finishes the bubble and cancels its notification.
#
# The photo assertions fail on the pre-fix build (the shortcut was never
# refreshed), the manifest assertion fails there too, and the setting-off Back
# assertion fails there as well because the app swallowed the gesture. The
# in-bubble list assertion fails on that build because the list's open path
# retired the hosting bubble's notification. The setting-on check guards
# behaviour rather than reproducing the Android 16 report.
#
# The Back section launches BubbleChatActivity directly: there is no SystemUI
# bubble task to collapse, so it asserts the app-level precondition (Back is not
# consumed) rather than the collapse itself; the real bubble window is covered
# by the manual run recorded in scripts/TODO.md.
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
    # `content delete` on raw_contacts silently no-ops on these images, so the
    # probe contact would outlive every run.
    adb_su "sqlite3 $DB \"DELETE FROM data WHERE raw_contact_id IN (SELECT _id FROM raw_contacts WHERE sourceid='$SID');
        DELETE FROM raw_contacts WHERE sourceid='$SID';\"" >/dev/null 2>&1
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
SDK=$(adb_ shell getprop ro.build.version.sdk | tr -d '\r')
info "Back is left to the platform so it can collapse the bubble (setting off)"
# No force-stop here: the app is still running with the notification from the
# photo section, and stopping it would cancel that notification before Back can
# be judged on it.
adb_ shell am start -a android.intent.action.VIEW -d "messages://conversation/$CONVO" \
    -n "$BUBBLE_ACT" -f 0x10000000 \
    --es open_conversation_address "$NUM" --ez open_in_bubble true >/dev/null 2>&1
sleep 4
adb_ shell input keyevent KEYCODE_BACK >/dev/null 2>&1
sleep 3
if [ "${SDK:-0}" -ge 31 ]; then
    if adb_ shell dumpsys activity activities 2>/dev/null | tr -d '\r' | grep "ResumedActivity" | grep -q "BubbleChatActivity"; then
        bad "Back was consumed, so SystemUI never sees it and cannot collapse the bubble"
    else
        ok "Back reached the platform instead of being swallowed"
    fi
else
    if adb_ shell cmd notification list 2>/dev/null | tr -d '\r' | grep -q "|$PKG|"; then
        ok "Back kept the bubble's notification on API $SDK"
    else
        bad "Back dismissed the bubble on API $SDK, where the platform cannot collapse it"
    fi
    if adb_ shell dumpsys activity activities 2>/dev/null | tr -d '\r' | grep "ResumedActivity" | grep -q "BubbleChatActivity"; then
        ok "Back left the bubble on its conversation on API $SDK"
    else
        bad "Back took the bubble off its conversation on API $SDK"
    fi
fi

info "The back arrow opens the conversation list (setting off)"
# The arrow is the only route to the list from a bubble whose Back belongs to
# the platform. Relaunch: the Back check above finished this window.
adb_ shell am start -a android.intent.action.VIEW -d "messages://conversation/$CONVO" \
    -n "$BUBBLE_ACT" -f 0x10000000 \
    --es open_conversation_address "$NUM" --ez open_in_bubble true >/dev/null 2>&1
sleep 4
dump_ui >/dev/null 2>&1
ARROW=$(python3 - "$TMP/ui.xml" <<'PY'
import re, sys, xml.etree.ElementTree as ET
for n in ET.parse(sys.argv[1]).getroot().iter("node"):
    if n.get("content-desc") == "Back":
        b = [int(v) for v in re.findall(r"\d+", n.get("bounds", ""))]
        if len(b) == 4:
            print((b[0] + b[2]) // 2, (b[1] + b[3]) // 2)
            break
PY
)
if [ -n "$ARROW" ]; then
    ok "the bubble shows a back arrow"
    adb_ shell input tap $ARROW >/dev/null 2>&1
    sleep 3
    dump_ui >/dev/null 2>&1
    if grep -q 'text="Messages"' "$TMP/ui.xml"; then
        ok "the back arrow opened the conversation list"
    else
        bad "the back arrow did not open the conversation list"
    fi
else
    bad "the bubble shows no back arrow"
fi

info "Choosing a chat in the in-bubble list keeps the bubble (setting off)"
# Opening a conversation full-screen retires its bubble, but the list inside a
# bubble is that bubble's own window: retiring it cancelled the notification
# that hosts it and the bubble vanished under the app (#441 follow-up).
post_message
if ! adb_ shell cmd notification list 2>/dev/null | tr -d '\r' | grep -q "|$PKG|"; then
    bad "no notification to judge before opening the in-bubble list"
fi
adb_ shell am start -a android.intent.action.VIEW -d "messages://conversation/$CONVO" \
    -n "$BUBBLE_ACT" -f 0x10000000 \
    --es open_conversation_address "$NUM" --ez open_in_bubble true >/dev/null 2>&1
sleep 4
dump_ui >/dev/null 2>&1
ARROW=$(python3 - "$TMP/ui.xml" <<'PY'
import re, sys, xml.etree.ElementTree as ET
for n in ET.parse(sys.argv[1]).getroot().iter("node"):
    if n.get("content-desc") == "Back":
        b = [int(v) for v in re.findall(r"\d+", n.get("bounds", ""))]
        if len(b) == 4:
            print((b[0] + b[2]) // 2, (b[1] + b[3]) // 2)
            break
PY
)
[ -n "$ARROW" ] && adb_ shell input tap $ARROW >/dev/null 2>&1
sleep 3
dump_ui >/dev/null 2>&1
ROW=$(python3 - "$TMP/ui.xml" "$MARK" <<'PY'
import re, sys, xml.etree.ElementTree as ET
needle = sys.argv[2]
rows = []
for n in ET.parse(sys.argv[1]).getroot().iter("node"):
    s = (n.get("content-desc") or "") + " " + (n.get("text") or "")
    if needle not in s:
        continue
    b = [int(v) for v in re.findall(r"\d+", n.get("bounds", ""))]
    if len(b) != 4:
        continue
    w, h = b[2] - b[0], b[3] - b[1]
    if h >= 80 and w >= 300:
        rows.append((w * h, b))
if rows:
    rows.sort()
    b = rows[0][1]
    print((b[0] + b[2]) // 2, (b[1] + b[3]) // 2)
PY
)
if [ -n "$ROW" ]; then
    ok "the in-bubble list shows the conversation"
    adb_ shell input tap $ROW >/dev/null 2>&1
    sleep 3
    if adb_ shell cmd notification list 2>/dev/null | tr -d '\r' | grep -q "|$PKG|"; then
        ok "opening a chat from the in-bubble list kept the bubble's notification"
    else
        bad "opening a chat from the in-bubble list cancelled the bubble's notification"
    fi
    if adb_ shell dumpsys activity activities 2>/dev/null | tr -d '\r' | grep "ResumedActivity" | grep -q "BubbleChatActivity"; then
        ok "the bubble stayed open on the chosen chat"
    else
        bad "the bubble's window went away with the notification"
    fi
else
    bad "the in-bubble list showed no row for '$MARK'"
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
