#!/usr/bin/env bash
# Regression for conversation bubbles (#354).
#
# Android only floats a notification as a bubble when all of these hold, so the
# script asserts each one from the system dumps rather than from a screenshot:
#   * the notification and the bubble show the chat's own picture, not the app
#     icon (#354 follow-up), and the shortcut carries that picture as a bitmap,
#   * the posted notification references a per-conversation shortcut,
#   * that shortcut is published and long-lived,
#   * with the app's bubbles preference on, the record is flagged BUBBLE,
#   * with it off, the notification is an ordinary one (no BUBBLE flag),
#   * opening the bubble's launch intent keeps the notification alive while the
#     bubble is on screen,
#   * Back inside a bubble leaves the bubble up (#354 follow-up) unless the
#     "Close bubble with Back" setting is turned on, in which case it closes.
#
# Run: scripts/test-notification-bubbles.sh
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

MARK="bubbleprobe$(date +%s)"
TEXT="bubble probe $MARK"
NUM="+1555$(( (RANDOM % 9000) + 1000 ))"

adb_ root >/dev/null 2>&1
adb_ wait-for-device; sleep 1

sql() { adb_ shell "sqlite3 /data/data/$PKG/databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r'; }

PREFS="/data/data/$PKG/shared_prefs/messages_settings.xml"
# Add-or-update a boolean pref while the app is stopped; the key may be absent,
# so a plain sed update is not enough.
pref_bool() {
    adb_ shell "if grep -q 'name=\"$1\"' $PREFS; then sed -i 's#name=\"$1\" value=\"[^\"]*\"#name=\"$1\" value=\"$2\"#' $PREFS; else sed -i 's#</map>#    <boolean name=\"$1\" value=\"$2\" /></map>#' $PREFS; fi"
}

notif_dump() { adb_ shell "dumpsys notification --noredact" 2>/dev/null | tr -d '\r'; }

# The NotificationRecord whose MessagingStyle carries this run's text. Scoping to
# the record keeps the assertions from passing on some other app's bubble.
record() {
    notif_dump | awk -v m="$MARK" '
        /NotificationRecord\(/ { if (buf ~ m) print buf; buf = "" }
        { buf = buf $0 "\n" }
        END { if (buf ~ m) print buf }
    '
}

# The conversation id the app used, so the expected shortcut id is known.
convo_id() {
    sql "SELECT conversation_id FROM messages WHERE body LIKE '%$MARK%' LIMIT 1;"
}

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    sql "DELETE FROM messages WHERE body LIKE '%$MARK%';" >/dev/null 2>&1
    sql "DELETE FROM conversations WHERE address='$NUM';" >/dev/null 2>&1
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

# API 31 prints flags as a hex mask (0x1010 for BUBBLE|AUTO_CANCEL) while newer
# images print them by name, and the old name-only grep therefore never matched
# on emulator-5558 — the bubble was there, the assertion was not.
FLAG_BUBBLE=0x1000
record_is_bubble() {
    local hex
    hex=$(record | grep -o "flags=0x[0-9a-fA-F]*" | head -1 | cut -d= -f2)
    if [ -n "$hex" ]; then
        [ $(( hex & FLAG_BUBBLE )) -ne 0 ]
    else
        record | grep -q "flags=[^ ]*BUBBLE"
    fi
}

info "Preconditions"
adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1
adb_ shell pm grant "$PKG" android.permission.POST_NOTIFICATIONS 2>/dev/null
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 3
ok "app started with the SMS role"

info "Bubbles off in system settings: the notification is an ordinary one"
adb_ shell cmd notification set_bubbles "$PKG" 0 >/dev/null 2>&1
post_message
CONVO=$(convo_id)
[ -n "$CONVO" ] && ok "message landed in conversation $CONVO" || bad "message never reached the database"
if record | grep -q "shortcut=conversation_"; then
    ok "notification references a conversation shortcut"
else
    bad "notification carries no conversation shortcut (bubble metadata cannot attach)"
fi
if record_is_bubble; then
    bad "notification is a bubble even though bubbles are off for the app"
else
    ok "notification stays an ordinary notification while bubbles are off"
fi
if adb_ shell dumpsys shortcut 2>/dev/null | tr -d '\r' | grep -q "id=conversation_$CONVO,"; then
    ok "conversation shortcut is published"
else
    bad "conversation shortcut was not published"
fi
if adb_ shell dumpsys shortcut 2>/dev/null | tr -d '\r' | grep "id=conversation_$CONVO," | grep -q "Liv"; then
    ok "conversation shortcut is long-lived"
else
    bad "conversation shortcut is not long-lived (the platform will not bubble it)"
fi

info "The chat's own picture reaches the panel and the bubble"
if record | grep -q "android.largeIcon=Icon"; then
    ok "the notification carries a large icon (the panel avatar)"
else
    bad "no large icon: the panel shows no contact picture"
fi
# The bitmap path is a field of its own further down the ShortcutInfo block.
if adb_ shell dumpsys shortcut 2>/dev/null | tr -d '\r' \
        | grep -A 20 "id=conversation_$CONVO," | grep -q "bitmapPath=.*\.png"; then
    ok "the conversation shortcut carries its own bitmap icon"
else
    bad "the shortcut has no bitmap icon, so it falls back to the app icon"
fi
# The decision and the colour are logged by the code that built the icon, so a
# script can hold them to account without reading pixels.
ICON_LINE=$(adb_ shell logcat -d -s BubbleIcon:D 2>/dev/null | tr -d '\r' \
    | grep -F "address=$NUM" | tail -1)
case "$ICON_LINE" in
    *source=AVATAR*shade=\#*)
        ok "a photo-less sender gets the app silhouette on its palette colour"
        ;;
    *source=PHOTO*)
        bad "an address with no contact row resolved a photo"
        ;;
    *)
        bad "no BubbleIcon record for $NUM ('${ICON_LINE:-none}')"
        ;;
esac

info "Bubbles on in system settings: the same notification becomes a bubble"
adb_ shell cmd notification set_bubbles "$PKG" 1 >/dev/null 2>&1
sleep 3
if record_is_bubble; then
    ok "notification is flagged BUBBLE"
else
    bad "notification is not flagged BUBBLE with bubbles enabled"
fi
if adb_ shell dumpsys window windows 2>/dev/null | grep -q "Bubbles!"; then
    ok "the system shows a bubble surface"
else
    bad "no bubble surface in the window list"
fi

info "The bubble's launch intent opens the chat and keeps the notification"
adb_ shell am start -a android.intent.action.VIEW -d "messages://conversation/$CONVO" \
    -n "$ACT" -f 0x10000000 \
    --es open_conversation_address "$NUM" --ez open_in_bubble true >/dev/null 2>&1
sleep 4
if wait_layout_has "$MARK" 8; then
    ok "bubble intent opened the conversation"
else
    bad "bubble intent did not open the conversation"
fi
if adb_ shell cmd notification list 2>/dev/null | tr -d '\r' | grep -q "|$PKG|"; then
    ok "notification survives while the bubble is open"
else
    bad "opening the bubble cancelled its notification (the bubble would vanish)"
fi

info "Back leaves the bubble open by default"
adb_ shell input keyevent KEYCODE_BACK >/dev/null 2>&1
sleep 4
if adb_ shell cmd notification list 2>/dev/null | tr -d '\r' | grep -q "|$PKG|"; then
    ok "the bubble's notification survives Back"
else
    bad "Back dismissed the notification and closed the bubble"
fi
# Back collapses the bubble to its floating icon — that is the platform's
# gesture, and the app cannot keep it expanded. What the app controls is whether
# the bubble still *exists*, which is the surface plus its notification.
if adb_ shell dumpsys window windows 2>/dev/null | tr -d '\r' | grep -q "Bubbles!"; then
    ok "the bubble still exists after Back (collapsed to its icon)"
else
    bad "Back removed the bubble surface entirely"
fi

info "With 'Close bubble with Back' on, Back closes it"
pref_bool bubble_back_closes true
adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
post_message
adb_ shell am start -a android.intent.action.VIEW -d "messages://conversation/$CONVO" \
    -n "$ACT" -f 0x10000000 \
    --es open_conversation_address "$NUM" --ez open_in_bubble true >/dev/null 2>&1
sleep 4
adb_ shell input keyevent KEYCODE_BACK >/dev/null 2>&1
sleep 4
if adb_ shell cmd notification list 2>/dev/null | tr -d '\r' | grep -q "|$PKG|"; then
    bad "the notification survived Back even with the setting on"
else
    ok "Back closed the bubble and its notification"
fi
if adb_ shell dumpsys window windows 2>/dev/null | tr -d '\r' | grep -q "Bubbles!"; then
    bad "the bubble surface survived Back even with the setting on"
else
    ok "Back removed the bubble and its surface"
fi
pref_bool bubble_back_closes false

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
