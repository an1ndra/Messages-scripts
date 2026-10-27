#!/usr/bin/env bash
# Regression for #354 follow-up: opening a conversation full-screen in the app
# must retire that conversation's floating bubble. Before the fix the bubble's
# notification was exempt from the chat's dismissal (a live bubble host owns
# it), so the bubble kept floating over the chat screen it duplicated.
# Run: scripts/test-bubble-fullchat.sh
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

MARK="fullchat$(date +%s)"
TEXT="full chat probe $MARK"
NUM="+1555$(( (RANDOM % 9000) + 1000 ))"

adb_ root >/dev/null 2>&1
adb_ wait-for-device; sleep 1

sql() { adb_ shell "sqlite3 /data/data/$PKG/databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r'; }

notif_dump() { adb_ shell "dumpsys notification --noredact" 2>/dev/null | tr -d '\r'; }

record() {
    notif_dump | awk -v m="$MARK" '
        /NotificationRecord\(/ { if (buf ~ m) print buf; buf = "" }
        { buf = buf $0 "\n" }
        END { if (buf ~ m) print buf }
    '
}

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

bubble_surface() {
    adb_ shell dumpsys window windows 2>/dev/null | tr -d '\r' | grep -q "Bubbles!"
}

convo_id() { sql "SELECT conversation_id FROM messages WHERE body LIKE '%$MARK%' LIMIT 1;"; }

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    sql "DELETE FROM messages WHERE body LIKE '%$MARK%';" >/dev/null 2>&1
    sql "DELETE FROM conversations WHERE address='$NUM';" >/dev/null 2>&1
    adb_ shell cmd notification set_bubbles "$PKG" 0 >/dev/null 2>&1
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

info "Preconditions"
adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1
adb_ shell pm grant "$PKG" android.permission.POST_NOTIFICATIONS 2>/dev/null
adb_ shell cmd notification set_bubbles "$PKG" 1 >/dev/null 2>&1
adb_ shell am force-stop "$PKG"; sleep 1
post_message
CONVO=$(convo_id)
[ -n "$CONVO" ] && ok "message landed in conversation $CONVO" || bad "message never reached the database"

info "An incoming message floats the conversation's bubble"
if record_is_bubble; then
    ok "the notification is flagged BUBBLE"
else
    bad "the notification is not flagged BUBBLE"
fi
if bubble_surface; then
    ok "the system shows a bubble surface"
else
    bad "no bubble surface in the window list"
fi

info "The bubble, once hosted and collapsed with Home, is live again"
# Opening the bubble registers its host, and Home collapses it back to a
# floating icon while the app's task keeps it hosted — the sequence the
# reporter hit.
adb_ shell am start -a android.intent.action.VIEW -d "messages://conversation/$CONVO" \
    -n "$ACT" -f 0x10000000 \
    --es open_conversation_address "$NUM" --ez open_in_bubble true >/dev/null 2>&1
sleep 4
if bubble_surface; then
    ok "the hosted bubble is on screen"
else
    bad "the bubble intent did not host the conversation"
fi
adb_ shell input keyevent KEYCODE_HOME >/dev/null 2>&1; sleep 3
if bubble_surface; then
    ok "Home collapsed the bubble back to its floating icon"
else
    bad "Home dismissed the bubble outright"
fi

info "Opening the same conversation full-screen retires the bubble"
# Deterministic in-app open: the launch intent resolves the address to the
# conversation and opens the chat full-screen, like the reporter's flow.
adb_ shell am start -n "$ACT" -f 0x20000000 \
    --es open_conversation_address "$NUM" >/dev/null 2>&1; sleep 4
if wait_layout_has "$MARK" 6; then
    ok "the chat screen is up"
else
    bad "the chat screen did not open"
fi

if bubble_surface; then
    bad "the bubble still floats over its own chat screen"
else
    ok "the bubble surface is gone after opening the chat full-screen"
fi
if [ -n "$(record)" ]; then
    bad "the bubble's notification survived the full-screen open"
else
    ok "the bubble's notification was cancelled with the bubble"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
