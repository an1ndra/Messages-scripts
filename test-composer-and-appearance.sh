#!/usr/bin/env bash
# Regression for the appearance feedback on #347:
#   - the send button is absent while there is nothing to send (a faded circle
#     read as a broken control rather than "empty composer");
#   - Settings offers "Theme colours for avatars" and the switch persists.
#
# Both are asserted from uiautomator dumps / the settings store, so no screenshot
# is involved and the check is cheap enough to run on every change.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

MARK="composer$(date +%s)$$"
NUM="+1555994${MARK: -4}"
PREFS="/data/data/$PKG/shared_prefs/messages_settings.xml"

adb_ root >/dev/null 2>&1; adb_ wait-for-device; sleep 1
sql() { adb_ shell "sqlite3 /data/data/$PKG/databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r'; }
pref() { adb_ shell "run-as $PKG cat $PREFS" 2>/dev/null | grep -oE "name=\"$1\" value=\"[^\"]*\"" | sed 's/.*value="//;s/"//'; }

cleanup() {
    sql "DELETE FROM messages WHERE body LIKE '%$MARK%';" >/dev/null 2>&1
    sql "DELETE FROM conversations WHERE address='$NUM';" >/dev/null 2>&1
    adb_ shell "run-as $PKG sed -i '/avatar_theme_colors/d' $PREFS" >/dev/null 2>&1
}
trap cleanup EXIT

for p in READ_SMS RECEIVE_SMS READ_CONTACTS POST_NOTIFICATIONS; do
    adb_ shell pm grant "$PKG" "android.permission.$p" >/dev/null 2>&1
done

info "Seed a conversation to type into"
TS=$(date +%s000)
sql "INSERT INTO conversations(address,name,snippet,timestamp,unread_count) VALUES('$NUM','$MARK','$MARK',$TS,0);" >/dev/null 2>&1
CID=$(sql "SELECT id FROM conversations WHERE address='$NUM';")
[ -z "$CID" ] && { bad "could not seed a conversation"; exit 1; }
sql "INSERT INTO messages(conversation_id,body,timestamp,status) VALUES($CID,'$MARK seed',$TS,'received');" >/dev/null 2>&1

open_chat() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
    adb_ shell am start -n "$ACT" --es open_conversation_address "$NUM" >/dev/null 2>&1
    sleep 5
    dump_ui
}

info "An empty composer has no send button"
open_chat
if grep -q 'content-desc="Send"' "$TMP/ui.xml"; then
    bad "send button is rendered with an empty composer"
else
    ok "no send button while the composer is empty"
fi

info "Typing reveals it"
# Tap the message field (the only EditText on screen), then type.
FIELD=$(python3 - "$TMP/ui.xml" <<'PY'
import re, sys
xml = open(sys.argv[1], encoding='utf-8', errors='replace').read()
m = re.search(r'class="android.widget.EditText"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', xml)
if m:
    x1, y1, x2, y2 = map(int, m.groups())
    print((x1 + x2) // 2, (y1 + y2) // 2)
PY
)
if [ -n "$FIELD" ]; then
    set -- $FIELD
    adb_ shell input tap "$1" "$2" >/dev/null 2>&1; sleep 1
    adb_ shell input text "$MARK" >/dev/null 2>&1; sleep 2
    dump_ui
    if grep -q 'content-desc="Send"' "$TMP/ui.xml"; then
        ok "typing shows the send button"
    else
        bad "send button still missing after typing"
    fi
else
    bad "no message field found"
fi

info "Clearing the text hides it again"
adb_ shell input keyevent 123 >/dev/null 2>&1
for _ in $(seq 1 40); do adb_ shell input keyevent 67 >/dev/null 2>&1; done
sleep 2
dump_ui
if grep -q 'content-desc="Send"' "$TMP/ui.xml"; then
    bad "send button stayed after the text was cleared"
else
    ok "send button disappears again when the field is empty"
fi

info "Settings offers theme colours for avatars"
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null 2>&1; sleep 5
dump_ui
if grep -qE 'text="Theme colours for avatars"' "$TMP/ui.xml"; then
    ok "the appearance toggle is listed"
else
    # The row may be below the fold.
    found=0
    for _ in $(seq 1 4); do
        adb_ shell input swipe 540 1800 540 900 300 >/dev/null 2>&1; sleep 1
        dump_ui
        if grep -qE 'text="Theme colours for avatars"' "$TMP/ui.xml"; then found=1; break; fi
    done
    [ "$found" = "1" ] && ok "the appearance toggle is listed (after scrolling)" \
        || bad "the appearance toggle is missing from Settings"
fi

TOGGLE=$(python3 - "$TMP/ui.xml" <<'PY'
import re, sys
xml, needle = open(sys.argv[1], encoding='utf-8', errors='replace').read(), "Theme colours for avatars"
i = xml.find(f'text="{needle}"')
if i < 0:
    raise SystemExit(0)
hits = re.findall(r'clickable="true"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', xml[:i])
if not hits:
    raise SystemExit(0)
x1, y1, x2, y2 = map(int, hits[-1])
print((x1 + x2) // 2, (y1 + y2) // 2)
PY
)
if [ -n "$TOGGLE" ]; then
    before=$(pref avatar_theme_colors)
    set -- $TOGGLE
    adb_ shell input tap "$1" "$2" >/dev/null 2>&1
    sleep 2
    after=$(pref avatar_theme_colors)
    if [ "$after" != "$before" ] && [ -n "$after" ]; then
        ok "toggling it persists (avatar_theme_colors=$after)"
    else
        bad "toggling it did not persist (before='${before:-unset}' after='${after:-unset}')"
    fi
else
    bad "the appearance row is not tappable"
fi

info "No crashes"
if adb_ shell "logcat -d -b crash" 2>/dev/null | grep -q "$PKG"; then
    bad "app crashed during the run"
else
    ok "no crashes"
fi

echo ""
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
