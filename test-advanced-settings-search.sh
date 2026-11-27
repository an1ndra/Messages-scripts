#!/usr/bin/env bash
# Task 1: the redesigned Advanced settings page has a search like the legacy
# tree, but its results cover every redesigned settings screen. Picking a result
# leaves search, opens that screen and flashes the row; the jump is reported as
# text in logcat so no screenshot is needed.
source "$(dirname "$0")/env.sh"
set -uo pipefail

PASS=0; FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
info() { printf '\n=== %s ===\n' "$1"; }
[[ "$ANDROID_SERIAL" == emulator-* ]] || { printf 'Requires a disposable emulator.\n'; exit 1; }

ADV=$(res_string settings_advanced_title)
LINKS=$(res_string settings_link_behaviour_title)
INBOX=$(res_string settings_inbox_title)
SEARCH=$(res_string icon_search)
CALENDAR=$(res_string settings_calendar_title)
NOTIF=$(res_string settings_notif_title)
GENERAL=$(res_string settings_general_title)
NONE=$(res_string settings_search_none)
for label in "$ADV" "$LINKS" "$INBOX" "$SEARCH" "$CALENDAR" "$NOTIF" "$GENERAL" "$NONE"; do
    [ -n "$label" ] || { printf 'env.sh: a required string is missing\n'; exit 1; }
done

adb_ root >/dev/null 2>&1; adb_ wait-for-device; sleep 1
cleanup() { adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true; }
trap cleanup EXIT

open_advanced() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    sleep 1
    adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null 2>&1
    sleep 5
    dump_ui >/dev/null 2>&1 || true
    if grep -q 'text="Not now"' "$TMP/ui.xml" 2>/dev/null; then tap_text "Not now"; sleep 2; fi
    for i in 1 2 3 4 5 6 7 8 9 10; do
        dump_ui >/dev/null 2>&1 || continue
        if tap_text "$ADV" >/dev/null 2>&1; then
            sleep 2
            wait_for_text "$LINKS" 8 && return 0
        fi
        adb_ shell input swipe 540 1700 540 800 400 >/dev/null 2>&1
        sleep 1
    done
    return 1
}
search_for() {
    tap_text "$SEARCH" >/dev/null || return 1
    sleep 1
    type_text "$1"
    sleep 2
    dump_ui >/dev/null 2>&1 || return 1
}
start_search() {
    open_advanced || return 1
    tap_text "$SEARCH" >/dev/null || return 1
    sleep 1
}
jump_log() { adb_ shell logcat -d -s SettingsSearch 2>/dev/null | tr -d '\r'; }

info "A result from another screen jumps there and flashes its row"
open_advanced || { fail 'Advanced settings did not open'; exit 1; }
adb_ logcat -c >/dev/null 2>&1 || true
search_for "Calendar" || { fail 'the search field is missing'; exit 1; }
if grep -qF "text=\"$CALENDAR\"" "$TMP/ui.xml" &&
   grep -qF "text=\"$INBOX\"" "$TMP/ui.xml"; then
    pass 'the result names the option and its screen'
else
    fail 'the Calendar result does not say where it goes'
fi
tap_text "$CALENDAR" >/dev/null || { fail 'the result is not tappable'; exit 1; }
sleep 3
printf '%s\n' "$(jump_log)" | sed 's/^/    | /'
if printf '%s' "$(jump_log)" | grep -q 'jumped row='; then
    pass 'the destination reported the jumped row'
else
    fail 'no jump was reported'
fi
dump_ui >/dev/null 2>&1 || true
if wait_for_text "$INBOX" 6 && grep -qF "text=\"$CALENDAR\"" "$TMP/ui.xml"; then
    pass 'the Calendar row is visible on Inbox settings'
else
    fail 'the search did not land on the Calendar row'
fi

info "A repeated label stays two separate results with screen names"
start_search || { fail 'Advanced search did not reopen'; exit 1; }
type_text "Notifications"
sleep 2
dump_ui >/dev/null 2>&1 || true
if grep -qF "text=\"$GENERAL\"" "$TMP/ui.xml" &&
   grep -qF "text=\"$ADV\"" "$TMP/ui.xml"; then
    pass 'General and Advanced each keep their own labelled result'
else
    fail 'a repeated label lost one of its screen labels'
fi

info "No match has a plain empty state"
start_search || { fail 'Advanced search did not reopen'; exit 1; }
type_text "zzzznotasetting"
sleep 2
dump_ui >/dev/null 2>&1 || true
grep -qF "text=\"$NONE\"" "$TMP/ui.xml" \
    && pass 'the empty state is shown' \
    || fail 'no empty state was shown'

printf '\n=== RESULTS: %s passed, %s failed ===\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
