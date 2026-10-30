#!/usr/bin/env bash
# Regression: the composer's attach dot follows the theme.
#
# Reported: "in light mode in + icon one dot color not looks good?" The dot was
# pinned to the #76D1FF sampled off Google Messages' dark composer, which on a
# light pill is a pale cyan nearly the colour of the field behind it.
#
# A dot colour has no text equivalent, so the composer names it ("ComposerDot")
# and this script compares it across light and dark instead of taking a picture.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

NUM="+15559441111"
MARK="dotprobe$(date +%s)"

adb_ root >/dev/null 2>&1; sleep 1
sql() { adb_ shell "sqlite3 /data/data/$PKG/databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r'; }

cleanup() {
    sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM');" >/dev/null 2>&1
    sql "DELETE FROM conversations WHERE address='$NUM';" >/dev/null 2>&1
}
trap cleanup EXIT
cleanup

sql "INSERT INTO conversations(address,name,snippet,timestamp,unread_count) VALUES('$NUM','$MARK','dot',$(date +%s000),0);" >/dev/null 2>&1
CID=$(sql "SELECT id FROM conversations WHERE address='$NUM';")
[ -z "$CID" ] && { bad "could not seed a conversation"; exit 1; }
sql "INSERT INTO messages(conversation_id,body,timestamp,status,is_me) VALUES($CID,'dot probe',$(date +%s000),'sent',1);" >/dev/null 2>&1

# A first launch can sit behind the SMS-role / phone-access dialog, which hides
# the composer and makes the dot look missing.
dismiss_dialogs() {
    local i
    for i in 1 2 3 4; do
        dump_ui >/dev/null 2>&1 || return 0
        if grep -q 'text="ALLOW"' "$TMP/ui.xml"; then
            c=$(center_of "ALLOW" 2>/dev/null) && adb_ shell input tap $c >/dev/null 2>&1
        elif grep -q 'text="Not now"' "$TMP/ui.xml"; then
            c=$(center_of "Not now" 2>/dev/null) && adb_ shell input tap $c >/dev/null 2>&1
        else
            return 0
        fi
        sleep 1.5
    done
}

open_chat() {   # open_chat <theme>
    local attempt
    for attempt in 1 2 3; do
        adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
        adb_ shell logcat -c >/dev/null 2>&1
        adb_ shell am start -n "$ACT" --es open_conversation_address "$NUM" --es set_theme "$1" >/dev/null 2>&1
        sleep 5
        dismiss_dialogs
        [ -n "$(dot_of)" ] && return 0
        sleep 3
        [ -n "$(dot_of)" ] && return 0
    done
    return 1
}

dot_of() { adb_ shell logcat -d -s ComposerDot 2>/dev/null | tr -d '\r' | grep -o '#[0-9A-F]\{6\}' | tail -1; }

info "Light theme"
open_chat light
LIGHT=$(dot_of)
[ -n "$LIGHT" ] && ok "composer dot reports $LIGHT" || bad "the composer dot reported no colour"
if [ "$LIGHT" = "#76D1FF" ]; then
    bad "the dot is still the dark-composer cyan in light mode"
else
    ok "the dot is not the dark-composer cyan in light mode"
fi

info "Dark theme"
open_chat dark
DARK=$(dot_of)
[ -n "$DARK" ] && ok "composer dot reports $DARK" || bad "the composer dot reported no colour in dark"
if [ -n "$LIGHT" ] && [ -n "$DARK" ] && [ "$LIGHT" = "$DARK" ]; then
    bad "the dot does not change with the theme ($LIGHT in both)"
else
    ok "the dot follows the theme ($LIGHT light, $DARK dark)"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
exit $((FAIL > 0))
