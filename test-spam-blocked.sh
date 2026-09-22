#!/usr/bin/env bash
# Regression for GM-like "Spam & blocked": blocking a number moves its
# conversation out of the inbox into the Spam & blocked folder, later messages
# from that number are kept there (no notification), and Unblock restores it.
source "$(dirname "$0")/env.sh"

TAIL=$(printf '%04d' $((RANDOM % 10000)))
SENDER="+1555123$TAIL"
PROBE="spam-probe-$TAIL"
SECOND="spam-second-$TAIL"

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

db() { adb_ shell "run-as $PKG sh -c 'sqlite3 databases/messages.db \"$1\"'" 2>/dev/null | tr -d '\r'; }
conv_blocked() {
    adb_ shell "run-as $PKG sh -c 'sqlite3 databases/messages.db \"SELECT address,blocked FROM conversations;\"'" 2>/dev/null \
        | tr -d '\r' | awk -F'|' -v t="$TAIL" 'index($1,t) {print $2; exit}'
}
msg_count() {
    adb_ shell "run-as $PKG sh -c 'sqlite3 databases/messages.db \"SELECT COUNT(*) FROM messages WHERE body LIKE \\\"%$1%\\\";\"'" 2>/dev/null | tr -d '\r'
}
blocked_count() {
    adb_ shell "run-as $PKG sh -c 'sqlite3 databases/messages.db \"SELECT COUNT(*) FROM blocked_numbers WHERE number LIKE \\\"%$TAIL%\\\";\"'" 2>/dev/null | tr -d '\r'
}

cleanup() {
    adb_ shell "run-as $PKG sh -c 'sqlite3 databases/messages.db \"DELETE FROM blocked_numbers WHERE number LIKE \\\"%$TAIL%\\\";\"'" >/dev/null 2>&1
    local ids
    ids=$(adb_ shell "run-as $PKG sh -c 'sqlite3 databases/messages.db \"SELECT id,address FROM conversations;\"'" 2>/dev/null \
        | tr -d '\r' | awk -F'|' -v t="$TAIL" 'index($2,t) {print $1}' | paste -sd, -)
    [ -n "$ids" ] && adb_ shell "run-as $PKG sh -c 'sqlite3 databases/messages.db \"DELETE FROM conversations WHERE id IN ($ids);\"'" >/dev/null 2>&1
    adb_ shell "run-as $PKG sh -c 'sqlite3 databases/messages.db \"DELETE FROM messages WHERE body LIKE \\\"%$PROBE%\\\" OR body LIKE \\\"%$SECOND%\\\";\"'" >/dev/null 2>&1
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
}
trap cleanup EXIT

adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1
adb_ shell pm grant "$PKG" android.permission.RECEIVE_SMS 2>/dev/null
adb_ shell pm grant "$PKG" android.permission.POST_NOTIFICATIONS 2>/dev/null

info "Seed a conversation from $SENDER"
adb_ emu sms send "$SENDER" "$PROBE" >/dev/null 2>&1; sleep 4
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 6

info "Block via the long-press sheet"
c=$(center_of_contains "$TAIL") || { bad "seed row not on list"; echo "Results: $PASS passed, $FAIL failed"; exit 1; }
xy=($c)
adb_ shell input swipe "${xy[0]}" "${xy[1]}" "${xy[0]}" "${xy[1]}" 900; sleep 1.2
tap_text "Block" >/dev/null 2>&1; sleep 1.5
[ "$(blocked_count)" = "1" ] && ok "number stored in the blocklist" || bad "number not in the blocklist"
[ "$(conv_blocked)" = "1" ] && ok "conversation flagged blocked" || bad "conversation not flagged blocked"

info "Blocked conversation leaves the main list"
dump_ui
grep -q "$TAIL" "$TMP/ui.xml" \
    && bad "blocked conversation still in the main list" \
    || ok "blocked conversation hidden from the main list"

info "A later message from the blocked number is kept (no notification)"
adb_ emu sms send "$SENDER" "$SECOND" >/dev/null 2>&1; sleep 4
[ "$(msg_count "$SECOND")" = "1" ] && ok "blocked SMS kept in the database" || bad "blocked SMS missing"
NOTIF=$(adb_ shell dumpsys notification --noredact 2>/dev/null | grep -c "$SECOND")
[ "$NOTIF" = "0" ] && ok "no notification for the blocked SMS" || bad "notification posted ($NOTIF)"

info "Settings > Spam & blocked lists it with a Blocked badge"
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null 2>&1; sleep 3
for i in $(seq 1 8); do
    dump_ui
    grep -q 'Spam &amp; blocked' "$TMP/ui.xml" && break
    adb_ shell input swipe 540 1700 540 900 300 >/dev/null 2>&1; sleep 0.7
done
c=$(center_of_contains "Spam &amp; blocked") && adb_ shell input tap $c
sleep 1.5
dump_ui
grep -q "$TAIL" "$TMP/ui.xml" \
    && ok "blocked conversation listed in Spam & blocked" \
    || bad "blocked conversation not in Spam & blocked"
grep -q 'text="Blocked"' "$TMP/ui.xml" \
    && ok "blocked badge shown" \
    || bad "blocked badge missing"

info "Unblock restores it to the inbox"
tap_text "Unblock" >/dev/null 2>&1; sleep 1.5
[ "$(conv_blocked)" = "0" ] && ok "conversation unblocked" || bad "conversation still blocked"
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 6
dump_ui
grep -q "$TAIL" "$TMP/ui.xml" \
    && ok "conversation back in the inbox" \
    || bad "conversation not restored to the inbox"

echo ""
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
