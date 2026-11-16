#!/usr/bin/env bash
# Attachment tray: the panel takes the keyboard's place instead of covering the
# chat from the bottom.
#
# What it asserts, in the order a finger does it:
#   * typing shows the keyboard and the draft,
#   * tapping attach hides the keyboard, keeps the draft, and shows the tray,
#   * the conversation stays on screen above the tray (the last message's
#     bottom edge is above the tray's tiles, so nothing is covered),
#   * tapping attach again brings the keyboard back and removes the tray,
#   * Back closes the tray,
#   * choosing a tile closes the tray and runs that action.
#
# On the build before this change the attach button opened a ModalBottomSheet:
# the keyboard stayed up behind it and the sheet began at the screen's bottom
# edge, so "tapping attach puts the keyboard away" and "the message stays above
# the tray" both failed.
#
# Run: scripts/test-attach-tray.sh          (add -v to see every dump)
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

RUN=$(date +%s)
MARK="tray$RUN"
NUM="+1555333$(( (RUN % 9000) + 1000 ))"

ATTACH=$(res_string icon_attach)
CLOSE=$(res_string common_close)
CAMERA=$(res_string chat_media_camera)
GALLERY=$(res_string chat_media_gallery)
AUDIO=$(res_string chat_media_audio)
LOCATION=$(res_string chat_media_location)
CONTACT=$(res_string chat_media_contact)
LOC_TITLE=$(res_string chat_location_title)
CANCEL=$(res_string chat_cancel)

# Every wait polls a condition 20 times a second instead of sleeping a fixed
# few seconds per step: the whole run is dominated by `uiautomator dump`
# (~0.5 s), not by the transitions.
POLLS=20

# The IME's visibility is a service field, not a UI node.
# mInputShown, not mIsInputViewShown: the latter stays true after the IME is
# hidden, which made every "the keyboard went away" check fail on a good build.
kb_shown() { adb_ shell dumpsys input_method 2>/dev/null | tr -d '\r' | grep -qE "mInputShown=true"; }

# Poll until $1 appears on screen (text or content-desc).
wait_present() {
    local i
    for i in $(seq 1 "$POLLS"); do
        ui_has "$1" && return 0
        sleep 0.3
    done
    return 1
}

# Poll until $1 is gone from the screen.
wait_gone() {
    local i
    for i in $(seq 1 "$POLLS"); do
        ui_has "$1" || return 0
        sleep 0.3
    done
    return 1
}

# Poll until the IME is in the state $1 wants ("up" or "down").
wait_kb() {
    local i
    for i in $(seq 1 "$POLLS"); do
        if [ "$1" = "up" ] && kb_shown; then return 0; fi
        if [ "$1" = "down" ] && ! kb_shown; then return 0; fi
        sleep 0.3
    done
    return 1
}

# "x1 y1 x2 y2" of the first node whose text contains $1, or nothing.
bounds_of_text() {
    dump_ui >/dev/null 2>&1 || return 1
    local b
    b=$(grep -oE "text=\"[^\"]*$(re_escape "$1")[^\"]*\"[^>]*bounds=\"\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]\"" \
            "$TMP/ui.decoded.xml" 2>/dev/null | head -1 \
        | grep -oE '\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]' | tail -1)
    [ -z "$b" ] && return 1
    local x1 y1 x2 y2
    x1=$(sed -E 's/^\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]$/\1/' <<< "$b")
    y1=$(sed -E 's/^\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]$/\2/' <<< "$b")
    x2=$(sed -E 's/^\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]$/\3/' <<< "$b")
    y2=$(sed -E 's/^\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]$/\4/' <<< "$b")
    echo "$x1 $y1 $x2 $y2"
}

# ── setup ────────────────────────────────────────────────────────────────────
# Runtime grants first: a permission dialog on top reads as "the app never
# opened", and it costs a whole run to discover.
for p in SEND_SMS RECEIVE_SMS READ_PHONE_STATE READ_CONTACTS \
         ACCESS_COARSE_LOCATION ACCESS_FINE_LOCATION; do
    adb_ shell pm grant "$PKG" android.permission.$p >/dev/null 2>&1
done
# The default-SMS role keeps the app from putting a "set as default" prompt on
# top of the list.
adb_su "cmd role add-role-holder android.app.role.SMS $PKG" >/dev/null 2>&1

# The conversation is seeded straight into the app's database. An injected SMS
# arrives on its own schedule, or not at all, which turned this script into a
# 25 s wait that failed on nothing.
dbq() { adb_ shell "run-as $PKG sqlite3 databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r'; }
NOW_MS=$(( $(date +%s) * 1000 ))
BODY="attach tray probe $MARK"

adb_ shell am force-stop "$PKG" >/dev/null 2>&1
dbq "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM');" >/dev/null 2>&1
dbq "DELETE FROM conversations WHERE address='$NUM';" >/dev/null 2>&1
CONV=$(dbq "INSERT INTO conversations (address,name,snippet,timestamp,archived,deleted_at,pinned) VALUES ('$NUM','Tray Probe','$BODY',$NOW_MS,0,0,0); SELECT last_insert_rowid();" | tail -1)
if [ -z "$CONV" ]; then
    bad "could not seed a conversation"
    exit 1
fi
dbq "INSERT INTO messages (conversation_id,body,timestamp,is_me,status,media_type,media_uri,sub_id,transport,address) VALUES ($CONV,'$BODY',$NOW_MS,0,'received','text','',1,'sms','$NUM');" >/dev/null

adb_ shell am start -n "$ACT" >/dev/null 2>&1

# A leftover prompt or permission sheet sits on top of the list; dismiss
# whatever is in front before looking for it.
for i in 1 2 3; do
    if wait_present "$(res_string access_start_chat)" 4; then break; fi
    adb_ shell input keyevent KEYCODE_BACK >/dev/null 2>&1
done
if ! wait_present "$MARK"; then
    bad "the seeded conversation never reached the list"
    exit 1
fi
ok "a conversation with a message is on the list"

tap_contains "$MARK" >/dev/null
opened=1
for i in $(seq 1 30); do
    dump_ui >/dev/null 2>&1
    # The composer's field, or its Back button, means the chat is on screen.
    if grep -qF 'class="android.widget.EditText"' "$TMP/ui.xml" ||
       grep -qF 'content-desc="Back"' "$TMP/ui.xml"; then opened=0; break; fi
    sleep 1
done
[ "$opened" = 0 ] || { bad "the conversation never opened"; exit 1; }
ok "the chat opened with its composer"

DRAFT="hello tray"
tap_edittext >/dev/null 2>&1
wait_kb up >/dev/null
# `input text` splits on a real space; %s is how it types one.
adb_ shell input text "${DRAFT// /%s}" >/dev/null 2>&1
if wait_kb up; then ok "typing brings the keyboard up"; else bad "no keyboard while typing"; fi
if ui_has "$DRAFT"; then ok "the draft is in the field"; else bad "the draft never landed"; fi

# ── tap attach ───────────────────────────────────────────────────────────────
tap_text "$ATTACH" >/dev/null || { bad "no attach button in the composer"; exit 1; }

if wait_kb down; then
    ok "tapping attach puts the keyboard away"
else
    bad "the keyboard stayed up under the tray"
fi

if wait_present "$CAMERA"; then
    ok "the tray shows the $CAMERA tile"
else
    bad "no $CAMERA tile in the tray"
fi
if ui_has "$GALLERY"; then
    ok "the tray shows the $GALLERY tile"
else
    bad "no $GALLERY tile in the tray"
fi
for tile in "$AUDIO" "$LOCATION" "$CONTACT"; do
    if ui_has "$tile"; then
        ok "the tray shows the $tile tile"
    else
        bad "no $tile tile in the tray"
    fi
done

if ui_has "$DRAFT"; then
    ok "the draft survives the keyboard going away"
else
    bad "the draft was lost when the tray opened"
fi

# The chat has to stay visible: the last message must end above the tray.
MSG=$(bounds_of_text "$MARK")
TILE=$(bounds_of_text "$CAMERA")
if [ -z "$MSG" ]; then
    bad "the conversation disappeared behind the tray"
elif [ -z "$TILE" ]; then
    bad "could not locate the tray's tiles"
else
    msg_bottom=$(awk '{print $4}' <<< "$MSG")
    tile_top=$(awk '{print $2}' <<< "$TILE")
    if [ "$tile_top" -gt "$msg_bottom" ]; then
        ok "the message stays on screen above the tray (${msg_bottom}px < ${tile_top}px)"
    else
        bad "the tray covers the conversation (tile top ${tile_top}px, message bottom ${msg_bottom}px)"
    fi
fi

# ── tap attach again ─────────────────────────────────────────────────────────
tap_text "$CLOSE" >/dev/null
if wait_gone "$CAMERA"; then
    ok "tapping the crossed button closes the tray"
else
    bad "the tray is still up after tapping the crossed attach button"
fi
if wait_kb up; then
    ok "the keyboard comes back with the field"
else
    bad "the keyboard did not come back"
fi

# ── Back closes the tray ─────────────────────────────────────────────────────
tap_text "$ATTACH" >/dev/null
if wait_present "$CAMERA"; then ok "the tray reopened"; else bad "the tray did not reopen"; fi
sleep 1
adb_ shell input keyevent KEYCODE_BACK >/dev/null 2>&1
if wait_gone "$CAMERA"; then
    ok "Back closes the tray"
else
    bad "Back left the tray on screen"
fi
if ui_has "$DRAFT"; then
    ok "Back closed the tray without leaving the chat"
else
    bad "Back left the conversation instead of closing the tray"
fi

# ── Location asks before it sends, and can be backed out of ──────────────────
# Open the tray, retrying once: the attach button is the same control the last
# step just closed, and a tap that lands while it is still settling does nothing.
for attempt in 1 2; do
    tap_text "$ATTACH" >/dev/null
    wait_present "$LOCATION" && break
done
if ui_has "$LOCATION"; then
    ok "the tray reopened for $LOCATION"
else
    bad "the $LOCATION tile never appeared"
fi
sleep 1
tap_text "$LOCATION" >/dev/null
if wait_present "$LOC_TITLE"; then
    ok "the $LOCATION tile asks before sending where you are"
else
    bad "the $LOCATION tile sent without asking"
fi
if wait_gone "$CAMERA"; then
    ok "opening a location closes the tray"
else
    bad "the tray stayed up behind the location prompt"
fi
tap_text "$CANCEL" >/dev/null
if wait_gone "$LOC_TITLE"; then
    ok "the location prompt can be dismissed"
else
    bad "the location prompt would not close"
fi

# ── a tile runs its action and closes the tray ───────────────────────────────
tap_text "$ATTACH" >/dev/null
wait_present "$CAMERA" >/dev/null
sleep 1
tap_text "$GALLERY" >/dev/null
if wait_gone "$CAMERA"; then
    ok "choosing $GALLERY closes the tray and hands over to the picker"
else
    bad "choosing $GALLERY left the tray open"
fi
adb_ shell input keyevent KEYCODE_BACK >/dev/null 2>&1
sleep 1

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
