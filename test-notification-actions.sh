#!/usr/bin/env bash
# Regression: the notification's Reply / Mark as read / Delete actions are each
# opt-in from Advanced settings (Notifications). Turning one off must drop only
# that action from the posted notification.
#
# The settings are flipped at their source of truth (the prefs file) and the
# posted action set is read back from the notification record, so the test does
# not depend on which settings UI is active. The toggles themselves sit inline
# in the legacy Advanced screen and on the Notification settings screen in the
# new UI; that both render them is pinned by NotificationActionSettingsTest.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

PREFS="/data/data/$PKG/shared_prefs/messages_settings.xml"
MARK="notifacts$(date +%s)"
NUM="+1555$(( (RANDOM % 9000) + 1000 ))"

adb_ root >/dev/null 2>&1
adb_ wait-for-device; sleep 1

# Add-or-update a boolean pref while the app is stopped. The key may be absent
# (defaults to true), so a plain sed update is not enough.
pref_bool() {
    adb_ shell "if grep -q 'name=\"$1\"' $PREFS; then sed -i 's#name=\"$1\" value=\"[^\"]*\"#name=\"$1\" value=\"$2\"#' $PREFS; else sed -i 's#</map>#    <boolean name=\"$1\" value=\"$2\" /></map>#' $PREFS; fi"
}

sql() { adb_ shell "sqlite3 /data/data/$PKG/databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r'; }

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    pref_bool notif_action_reply true
    pref_bool notif_action_mark_read true
    pref_bool notif_action_delete true
    sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM');" >/dev/null 2>&1
    sql "DELETE FROM conversations WHERE address='$NUM';" >/dev/null 2>&1
    adb_ shell am start -n "$ACT" >/dev/null 2>&1
}
trap cleanup EXIT

# The NotificationRecord whose MessagingStyle carries MARK. Actions appear in
# the same record, so this scopes the action list to our own notification.
actions_of_mark() {
    adb_ shell "dumpsys notification --noredact" 2>/dev/null | tr -d '\r' | awk -v m="$MARK" '
        /NotificationRecord\(/ { if (buf ~ m) print buf; buf = "" }
        { buf = buf $0 "\n" }
        END { if (buf ~ m) print buf }
    '
}
has_action() { actions_of_mark | grep -q "\"$1\" ->"; }

# Restart with the wanted action settings, send the message, wait for it to land.
post_with() {
    adb_ shell am force-stop "$PKG"; sleep 1
    pref_bool notif_action_reply "$1"
    pref_bool notif_action_mark_read "$2"
    pref_bool notif_action_delete "$3"
    adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 3
    adb_ emu sms send "$NUM" "$MARK hello" >/dev/null 2>&1
    for _ in $(seq 1 15); do
        [ "$(sql "SELECT COUNT(*) FROM messages WHERE body LIKE '%$MARK%';")" != "0" ] && break
        sleep 1
    done
    sleep 1
}

adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1
adb_ shell pm grant "$PKG" android.permission.POST_NOTIFICATIONS 2>/dev/null
adb_ shell pm grant "$PKG" android.permission.RECEIVE_SMS 2>/dev/null

info "Baseline: all three actions on"
post_with true true true
for a in Reply "Mark as read" Delete; do
    if has_action "$a"; then ok "baseline shows '$a'"; else bad "baseline missing '$a'"; fi
done

info "Turning Delete off drops only Delete"
post_with true true false
has_action "Delete" && bad "Delete still shown" || ok "Delete removed"
has_action "Mark as read" && ok "Mark as read kept" || bad "Mark as read lost"
has_action "Reply" && ok "Reply kept" || bad "Reply lost"

info "Turning Mark as read off too drops it as well"
post_with true false false
has_action "Mark as read" && bad "Mark as read still shown" || ok "Mark as read removed"
has_action "Reply" && ok "Reply still kept" || bad "Reply lost"

info "Turning Reply off leaves no actions"
post_with false false false
for a in Reply "Mark as read" Delete; do
    has_action "$a" && bad "'$a' still shown with all three off" || ok "'$a' removed"
done

info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
