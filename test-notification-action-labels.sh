#!/usr/bin/env bash
# Regression for #452: the notification's Reply and Mark as read buttons were
# built from hardcoded English literals, so they stayed English while Delete
# (already a resource) followed the app's language. Reported from a device set
# to Persian.
#
# Android has no per-app locale before API 33, so the only way to make the app
# render Persian on the AOSP-12 target is the system locale: set
# persist.sys.locale, restart zygote, post a message, then read the action
# titles back out of the notification record. The expected labels come from
# values-fa/ itself, so the script cannot drift from the translation, and the
# original locale is restored on exit — leaving the comparison AVD in Persian
# breaks every other script on it.
#
# Fails before the fix: the record then carries "Reply" / "Mark as read".
# Run: scripts/test-notification-action-labels.sh
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

STRINGS="$PROJECT_DIR/app/src/main/res/values-fa/strings_main.xml"
PREFS="/data/data/$PKG/shared_prefs/messages_settings.xml"
MARK="notiflabels$(date +%s)"
NUM="+1555$(( (RANDOM % 9000) + 1000 ))"

adb_ root >/dev/null 2>&1
adb_ wait-for-device; sleep 1

sql() { adb_ shell "sqlite3 /data/data/$PKG/databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r'; }

pref_bool() {
    adb_ shell "if grep -q 'name=\"$1\"' $PREFS; then sed -i 's#name=\"$1\" value=\"[^\"]*\"#name=\"$1\" value=\"$2\"#' $PREFS; else sed -i 's#</map>#    <boolean name=\"$1\" value=\"$2\" /></map>#' $PREFS; fi"
}

# Resource lookup straight out of the shipped Persian file: the assertion and
# the translation are the same string, not two copies of it.
fa_string() {
    sed -n "s#.*<string name=\"$1\">\(.*\)</string>.*#\1#p" "$STRINGS" | head -1
}

ORIG_LOCALE=$(adb_ shell getprop persist.sys.locale 2>/dev/null | tr -d '\r')
[ -z "$ORIG_LOCALE" ] && ORIG_LOCALE="en-US"

set_locale() {
    adb_ shell "su -c 'setprop persist.sys.locale $1'" >/dev/null 2>&1
    adb_ shell "su -c 'setprop ctl.restart zygote'" >/dev/null 2>&1
    local i
    for i in $(seq 1 60); do
        sleep 2
        if adb_ shell am get-config 2>/dev/null | grep -q "$2"; then
            sleep 2
            return 0
        fi
    done
    return 1
}

restore() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM');" >/dev/null 2>&1
    sql "DELETE FROM conversations WHERE address='$NUM';" >/dev/null 2>&1
    if [ "$ORIG_LOCALE" != "fa-IR" ]; then
        set_locale "$ORIG_LOCALE" "${ORIG_LOCALE%%-*}"
    fi
}
trap restore EXIT

# The notification record whose MessagingStyle carries MARK; its actions sit in
# the same record, so the label list is scoped to our own notification.
record_of_mark() {
    adb_ shell "dumpsys notification --noredact" 2>/dev/null | tr -d '\r' | awk -v m="$MARK" '
        /NotificationRecord\(/ { if (buf ~ m) print buf; buf = "" }
        { buf = buf $0 "\n" }
        END { if (buf ~ m) print buf }
    '
}

REPLY=$(fa_string notif_action_reply)
MARK_READ=$(fa_string notif_action_mark_read)
DELETE=$(fa_string notif_action_delete)
if [ -z "$REPLY" ] || [ -z "$MARK_READ" ] || [ -z "$DELETE" ]; then
    bad "values-fa/strings_main.xml does not define the three notification action labels"
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

info "Device: switch to Persian"
if ! adb_ shell "su -c id" 2>/dev/null | grep -q "uid=0"; then
    bad "no root on $ANDROID_SERIAL - the locale switch needs Magisk su"
elif set_locale "fa-IR" "fa-rIR"; then
    ok "device configuration is now fa-rIR"
else
    bad "device did not come back with a fa-rIR configuration"
fi

info "Post a notification with all three actions on"
for p in READ_SMS RECEIVE_SMS READ_CONTACTS; do
    adb_ shell pm grant "$PKG" "android.permission.$p" >/dev/null 2>&1
done
adb_ shell "su -c 'cmd role add-role-holder android.app.role.SMS $PKG'" >/dev/null 2>&1
adb_ shell am force-stop "$PKG" >/dev/null 2>&1
pref_bool notif_action_reply true
pref_bool notif_action_mark_read true
pref_bool notif_action_delete true
adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 3
adb_ emu sms send "$NUM" "$MARK hello" >/dev/null 2>&1
for _ in $(seq 1 15); do
    [ "$(sql "SELECT COUNT(*) FROM messages WHERE body LIKE '%$MARK%';")" != "0" ] && break
    sleep 1
done
sleep 2

RECORD=$(record_of_mark)
if [ -z "$RECORD" ]; then
    bad "no notification record carries the '$MARK' message - cannot read the action labels"
else
    ok "notification posted under the Persian configuration"
    for label in "$REPLY" "$MARK_READ" "$DELETE"; do
        if printf '%s' "$RECORD" | grep -qF "\"$label\" ->"; then
            ok "action label '$label' is rendered from the Persian resources"
        else
            bad "action label '$label' is missing from the notification"
        fi
    done
    # The bug itself: the two hardcoded literals leaking into a Persian shade.
    for literal in Reply "Mark as read"; do
        if printf '%s' "$RECORD" | grep -qF "\"$literal\" ->"; then
            bad "action label is the hardcoded English literal '$literal'"
        else
            ok "no English literal '$literal' to the left of an action"
        fi
    done
fi

info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
