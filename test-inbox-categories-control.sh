#!/usr/bin/env bash
# Task 2: Categories & rules opens with the same animated navigation as every
# other settings sub-screen, and the category chips on the main screen have a
# real on/off switch instead of only a pull gesture.
#
# Assertions come from NavTransition logcat, preferences and uiautomator dumps;
# no screenshots.
source "$(dirname "$0")/env.sh"
set -uo pipefail

PASS=0; FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
info() { printf '\n=== %s ===\n' "$1"; }
[[ "$ANDROID_SERIAL" == emulator-* ]] || { printf 'Requires a disposable emulator.\n'; exit 1; }

RULES=$(res_string settings_inbox_rules_title)
INBOX=$(res_string settings_inbox_title)
SHOW=$(res_string settings_inbox_categories_title)
PERSONAL=$(res_string inbox_category_personal)
for label in "$RULES" "$INBOX" "$SHOW" "$PERSONAL"; do
    [ -n "$label" ] || { printf 'env.sh: a required string is missing\n'; exit 1; }
done

PREFS="shared_prefs/messages_settings.xml"
BACKUP="$TMP/inbox-categories-control.prefs.xml"
adb_ shell "run-as $PKG cat $PREFS" > "$BACKUP" 2>/dev/null || true
set_categories() {
    adb_ shell "run-as $PKG sh -c 'sed -i \"/inbox_categories_enabled/d; s#</map>#<boolean name=\\\"inbox_categories_enabled\\\" value=\\\"$1\\\" /></map>#\" $PREFS'" \
        >/dev/null 2>&1 || true
}
stored_categories() {
    adb_ shell "run-as $PKG cat $PREFS" 2>/dev/null | tr -d '\r' \
        | sed -n 's/.*name="inbox_categories_enabled" value="\([^"]*\)".*/\1/p' | tail -1
}
cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    if [ -s "$BACKUP" ]; then
        adb_ shell "run-as $PKG sh -c 'cat > $PREFS'" < "$BACKUP" >/dev/null 2>&1 || true
    else
        set_categories true
    fi
}
trap cleanup EXIT

adb_ root >/dev/null 2>&1; adb_ wait-for-device; sleep 1
for p in READ_SMS RECEIVE_SMS READ_CONTACTS POST_NOTIFICATIONS; do
    adb_ shell pm grant "$PKG" "android.permission.$p" >/dev/null 2>&1
done

open_settings() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    sleep 1
    adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null 2>&1
    sleep 5
    dump_ui >/dev/null 2>&1 || true
    if grep -q 'text="Not now"' "$TMP/ui.xml" 2>/dev/null; then tap_text "Not now"; sleep 2; fi
    wait_for_text "$INBOX" 8
}
open_inbox() {
    open_settings || return 1
    tap_text "$INBOX" >/dev/null || return 1
    sleep 2
    wait_for_text "$RULES" 8
}
back_to_list() {
    adb_ shell input keyevent 4 >/dev/null 2>&1; sleep 1.5
    adb_ shell input keyevent 4 >/dev/null 2>&1; sleep 1.5
    dump_ui >/dev/null 2>&1 || true
}
pull_down() {
    adb_ shell input swipe 540 700 540 1500 300 >/dev/null 2>&1
    sleep 1.5
    dump_ui >/dev/null 2>&1 || true
}
nav_log() { adb_ shell logcat -d -s NavTransition 2>/dev/null | tr -d '\r'; }

set_categories true
info "Categories & rules uses the navigation animation"
adb_ logcat -c >/dev/null 2>&1 || true
open_inbox || { fail 'Inbox settings did not open'; exit 1; }
tap_text "$RULES" >/dev/null || { fail 'the Categories & rules row is not tappable'; exit 1; }
sleep 2
printf '%s\n' "$(nav_log)" | sed 's/^/    | /'
printf '%s' "$(nav_log)" | grep -q 'NavTransition: inbox to inbox-rules' \
    && pass 'opening slides in like a sub-screen' \
    || fail 'opening did not animate through navRoute'
adb_ shell input keyevent 4 >/dev/null 2>&1; sleep 2
printf '%s' "$(nav_log)" | grep -q 'NavTransition: inbox-rules to inbox' \
    && pass 'back slides out to Inbox settings' \
    || fail 'back did not animate through navRoute'

info "Switch off: pulling the list cannot reveal the chips"
tap_text "$SHOW" >/dev/null || { fail 'the Show categories switch is missing'; exit 1; }
sleep 1
[ "$(stored_categories)" = false ] \
    && pass 'the switch is stored' \
    || fail 'the switch was not stored'
back_to_list
pull_down
if grep -qF "text=\"$PERSONAL\"" "$TMP/ui.xml"; then
    fail 'the chips appeared with the switch off'
else
    pass 'the chips stay hidden'
fi

info "Switch on: the pull reveals the chips again"
open_inbox || { fail 'Inbox settings did not reopen'; exit 1; }
tap_text "$SHOW" >/dev/null || { fail 'the switch is gone'; exit 1; }
sleep 1
[ "$(stored_categories)" = true ] \
    && pass 'the switch is stored back on' \
    || fail 'the switch did not turn back on'
back_to_list
pull_down
if grep -qF "text=\"$PERSONAL\"" "$TMP/ui.xml"; then
    pass 'the chips can be revealed again'
else
    fail 'the pull no longer reveals the chips'
fi

printf '\n=== RESULTS: %s passed, %s failed ===\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
