#!/usr/bin/env bash
# Regression for the "Blocked keywords" option (Settings -> Advanced ->
# Blocked keywords). A message whose body contains a blocked keyword is moved
# to Trash: kept in the database with its conversation trashed (recoverable via
# Trash -> Restore), no notification (so no sound). A normal message still
# arrives in the inbox. The keyword is added/removed through the UI.
source "$(dirname "$0")/env.sh"

KW="ZZBLOCK$RANDOM"
NORMAL_BODY="normal hello $RANDOM$RANDOM"
SENDER="+1555000$(( RANDOM % 9000 + 1000 ))"
NORMAL_SENDER="+1555000$(( RANDOM % 9000 + 1000 ))"

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

pref_get() {
    adb_ shell "run-as $PKG cat shared_prefs/messages_settings.xml" 2>/dev/null > "$TMP/prefs.xml"
    python3 - "$1" "$TMP/prefs.xml" <<'PY'
import re, sys
key, path = sys.argv[1], sys.argv[2]
try:
    s = open(path).read()
except OSError:
    s = ""
m = re.search(r'<set name="%s">(.*?)</set>' % re.escape(key), s, re.S)
if m:
    print(" ".join(re.findall(r'<string>([^<]*)</string>', m.group(1))))
else:
    m = re.search(r'name="%s">([^<]*)</string>' % re.escape(key), s)
    print(m.group(1) if m else "")
PY
}

db_count() {
    adb_ shell "run-as $PKG sh -c 'sqlite3 databases/messages.db \"SELECT COUNT(*) FROM messages WHERE body LIKE \\\"%$1%\\\";\"'" 2>/dev/null | tr -d '\r'
}

# deleted_at of the conversation carrying the message whose body contains $1
conv_deleted_at() {
    adb_ shell "run-as $PKG sh -c 'sqlite3 databases/messages.db \"SELECT c.deleted_at FROM conversations c JOIN messages m ON m.conversation_id=c.id WHERE m.body LIKE \\\"%$1%\\\" ORDER BY m.id DESC LIMIT 1;\"'" 2>/dev/null | tr -d '\r'
}

# deleted_reason of the conversation carrying the message whose body contains $1
conv_deleted_reason() {
    adb_ shell "run-as $PKG sh -c 'sqlite3 databases/messages.db \"SELECT c.deleted_reason FROM conversations c JOIN messages m ON m.conversation_id=c.id WHERE m.body LIKE \\\"%$1%\\\" ORDER BY m.id DESC LIMIT 1;\"'" 2>/dev/null | tr -d '\r'
}

tap_edittext_here() {
    local b x y x2 y2
    dump_ui || return 1
    b=$(grep -oE 'class="android.widget.EditText"[^>]*bounds="\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]"' "$TMP/ui.xml" \
        | grep -oE '\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]' | head -1)
    [ -z "$b" ] && return 1
    x=$(echo "$b" | sed -E 's/\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]/\1/')
    y=$(echo "$b" | sed -E 's/\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]/\2/')
    x2=$(echo "$b" | sed -E 's/\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]/\3/')
    y2=$(echo "$b" | sed -E 's/\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]/\4/')
    adb_ shell input tap $(( (x + x2) / 2 )) $(( (y + y2) / 2 ))
}

scroll_until() {
    local target="$1" i
    for i in $(seq 1 8); do
        dump_ui || true
        grep -q "text=\"$target\"" "$TMP/ui.xml" && return 0
        adb_ shell input swipe 540 1700 540 900 250 >/dev/null 2>&1; sleep 0.5
    done
    return 1
}

open_keywords() {
    adb_ shell am force-stop "$PKG"; sleep 1
    adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null 2>&1; sleep 3
    scroll_until "Advanced" >/dev/null 2>&1
    tap_text "Advanced" >/dev/null 2>&1; sleep 1.5
    scroll_until "Blocked keywords" >/dev/null 2>&1
    tap_text "Blocked keywords" >/dev/null 2>&1; sleep 1.5
}

cleanup() {
    adb_ shell "run-as $PKG sh -c 'sqlite3 databases/messages.db \
        \"DELETE FROM conversations WHERE id IN (SELECT conversation_id FROM messages WHERE body LIKE \\\"%$KW%\\\");\"'" >/dev/null 2>&1
    adb_ shell "run-as $PKG sh -c 'sqlite3 databases/messages.db \
        \"DELETE FROM messages WHERE body LIKE \\\"%$KW%\\\";\"'" >/dev/null 2>&1
    # clear the blocklist so the test leaves no residue
    open_keywords >/dev/null 2>&1
    for i in 1 2 3 4 5; do
        dump_ui || break
        grep -q 'content-desc="Remove keyword"' "$TMP/ui.xml" || break
        tap_text "Remove keyword" >/dev/null 2>&1; sleep 0.6
    done
    adb_ shell input keyevent 4 >/dev/null 2>&1
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
}
trap cleanup EXIT

adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1
adb_ shell pm grant "$PKG" android.permission.RECEIVE_SMS 2>/dev/null
adb_ shell pm grant "$PKG" android.permission.POST_NOTIFICATIONS 2>/dev/null

info "Open Settings -> Advanced -> Blocked keywords"
open_keywords
dump_ui
if grep -q 'text="Blocked keywords"' "$TMP/ui.xml"; then
    ok "Blocked keywords dialog opened"
else
    bad "Blocked keywords dialog did not open"
fi

info "Add keyword via the UI"
tap_edittext_here >/dev/null 2>&1
sleep 0.5
type_text "$KW"
sleep 0.5
tap_text "Add" >/dev/null 2>&1
sleep 1
if pref_get blocked_keywords | grep -q "$KW"; then
    ok "keyword persisted in prefs"
else
    bad "keyword not persisted"
fi
dump_ui
grep -q "text=\"$KW\"" "$TMP/ui.xml" && ok "keyword listed in the dialog" || bad "keyword not listed"
tap_text "Close" >/dev/null 2>&1; sleep 1
adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1

info "Blocked message is moved to Trash (kept, no notification)"
adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 3
adb_ emu sms send "$SENDER" "$KW promo offer" >/dev/null 2>&1; sleep 4
adb_ emu sms send "$NORMAL_SENDER" "$NORMAL_BODY" >/dev/null 2>&1; sleep 4
BLOCKED=$(db_count "$KW")
NORMAL=$(db_count "$NORMAL_BODY")
[ "$BLOCKED" = "1" ] && ok "blocked message kept in the database" || bad "blocked message missing ($BLOCKED)"
BLOCKED_TRASH=$(conv_deleted_at "$KW")
if [ -n "$BLOCKED_TRASH" ] && [ "$BLOCKED_TRASH" -gt 0 ] 2>/dev/null; then
    ok "blocked conversation moved to Trash (deleted_at=$BLOCKED_TRASH)"
else
    bad "blocked conversation not in Trash (deleted_at='$BLOCKED_TRASH')"
fi
[ "$NORMAL" = "1" ] && ok "normal message stored" || bad "normal message missing ($NORMAL)"
NORMAL_TRASH=$(conv_deleted_at "$NORMAL_BODY")
[ "$NORMAL_TRASH" = "0" ] && ok "normal conversation stays in the inbox" || bad "normal conversation trashed (deleted_at='$NORMAL_TRASH')"
REASON=$(conv_deleted_reason "$KW")
[ "$REASON" = "blocked_keyword" ] && ok "trash reason recorded as blocked_keyword" || bad "wrong trash reason ('$REASON')"
NOTIF=$(adb_ shell dumpsys notification --noredact 2>/dev/null | grep -c "$KW")
[ "$NOTIF" = "0" ] && ok "no notification for the blocked message" || bad "notification posted for blocked message ($NOTIF)"

info "Trash screen shows the blocked-keyword reason"
adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null 2>&1; sleep 3
scroll_until "Trash" >/dev/null 2>&1
tap_text "Trash" >/dev/null 2>&1; sleep 1.5
dump_ui
grep -q 'text="Keyword"' "$TMP/ui.xml" \
    && ok "Trash row shows the 'Keyword' tag" \
    || bad "Trash row reason tag missing"
adb_ shell input keyevent 4 >/dev/null 2>&1; sleep 1

info "Removing the keyword restores delivery"
open_keywords
for i in 1 2 3 4 5; do
    dump_ui || break
    grep -q 'content-desc="Remove keyword"' "$TMP/ui.xml" || break
    tap_text "Remove keyword" >/dev/null 2>&1; sleep 0.6
done
if [ -z "$(pref_get blocked_keywords)" ]; then
    ok "blocklist cleared"
else
    bad "blocklist not cleared: $(pref_get blocked_keywords)"
fi

echo ""
info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
