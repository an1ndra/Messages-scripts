#!/usr/bin/env bash
# "Bubbles" in General settings opens Android's own per-app Bubbles page.
#
# It used to open an in-app page with the same All / Selected / Nothing choice,
# which duplicated a decision the platform already owns — two places that can
# disagree. Android's page is now the only one, and this asserts both halves:
# the row lands in com.android.settings, and the platform switch really controls
# whether a conversation bubbles.
#
# Fails on the pre-change build: the row opened an in-app screen, so the focused
# window stayed com.anindra.messages.
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
adb_ root >/dev/null 2>&1

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { printf '\n=== %s ===\n' "$1"; }

MARK="settingsbubble$(date +%s)"
TEXT="settings bubble $MARK"
NUM="+1555$(( (RANDOM % 9000) + 1000 ))"
FLAG_BUBBLE=0x1000

sql() { adb_ shell "sqlite3 /data/data/$PKG/databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r'; }
notif_dump() { adb_ shell "dumpsys notification --noredact" 2>/dev/null | tr -d '\r'; }
record() {
    notif_dump | awk -v m="$MARK" '
        /NotificationRecord\(/ { if (buf ~ m) print buf; buf = "" }
        { buf = buf $0 "\n" }
        END { if (buf ~ m) print buf }
    '
}
convo_id() { sql "SELECT id FROM conversations WHERE address='$NUM' LIMIT 1;"; }

record_is_bubble() {
    local hex
    hex=$(record | grep -o "flags=0x[0-9a-fA-F]*" | head -1 | cut -d= -f2)
    if [ -n "$hex" ]; then
        [ $(( hex & FLAG_BUBBLE )) -ne 0 ]
    else
        record | grep -q "flags=[^ ]*BUBBLE"
    fi
}

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    sql "DELETE FROM messages WHERE body LIKE '%$MARK%';" >/dev/null 2>&1
    sql "DELETE FROM conversations WHERE address='$NUM';" >/dev/null 2>&1
    adb_ shell cmd notification set_bubbles "$PKG" 1 >/dev/null 2>&1
    adb_ shell am start -n "$ACT" >/dev/null 2>&1
}
trap cleanup EXIT

post_message() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    adb_ emu sms send "$NUM" "$TEXT" >/dev/null 2>&1
    for _ in $(seq 1 20); do
        [ -n "$(convo_id)" ] && break
        sleep 1
    done
    sleep 2
}

info "Preconditions"
adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1
adb_ shell cmd notification set_bubbles "$PKG" 1 >/dev/null 2>&1
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 5
ok "app started with the SMS role and platform bubbles ON"

info "General settings has a Bubbles row"
adb_ shell input tap 970 143 >/dev/null 2>&1; sleep 3
if wait_layout_has "Bubbles" 6; then
    ok "General settings has a Bubbles row"
else
    bad "General settings has no Bubbles row"
fi
# GM's row is the bare label; this one now leads straight to the system page.
if layout_has "All conversations can bubble"; then
    bad "the row still shows a choice on the list"
else
    ok "the row is the label alone, like Google Messages"
fi

info "Tapping it opens Android's own Bubbles page"
tap_layout "Bubbles" >/dev/null 2>&1; sleep 4
focus=$(adb_ shell "dumpsys window" 2>/dev/null | tr -d '\r' | grep -m1 "mCurrentFocus")
case "$focus" in
    *com.android.settings*Bubble*) ok "the system Bubbles page opened ($focus)" ;;
    *com.anindra.messages*) bad "the row opened an in-app screen instead: $focus" ;;
    *) bad "unexpected window after tapping Bubbles: $focus" ;;
esac
adb_ shell input keyevent 4 >/dev/null 2>&1; sleep 2

info "The platform switch is what actually gates the bubble"
post_message
if record_is_bubble; then
    ok "with bubbles allowed the notification carries the BUBBLE flag"
else
    bad "no bubble even though bubbles are allowed"
fi

adb_ shell cmd notification set_bubbles "$PKG" 0 >/dev/null 2>&1
post_message
if record_is_bubble; then
    bad "the notification still bubbles with the platform switch off"
else
    ok "turning the system switch off stops the bubble"
fi

echo ""
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
exit $((FAIL > 0))
