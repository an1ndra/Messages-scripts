#!/usr/bin/env bash
# Regression: Delivery reports and Swipe actions are reached from Inbox settings.
#
# Delivery reports used to sit on General settings, and the two swipe directions
# used to be inline rows there with a picker popping up on the spot. A move is
# easy to "prove" by reading source alone, so this script walks the real UI:
# General must no longer offer the row, Inbox must offer both, and the Swipe
# actions page must still write the same stored values.
#
# Run: scripts/test-inbox-settings-move.sh
set -uo pipefail
cd "$(dirname "$0")"
source ./env.sh

PASS=0
FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
[[ "$ANDROID_SERIAL" == emulator-* ]] || { printf 'Requires a disposable emulator.\n'; exit 1; }

DELIVERY=$(res_string settings_delivery_reports_title)
INBOX=$(res_string settings_inbox_title)
SWIPE=$(res_string settings_swipe_actions_title)
LEFT=$(res_string swipe_left_title)
RIGHT=$(res_string swipe_right_title)
ARCHIVE=$(res_string access_archive)
for label in "$DELIVERY" "$INBOX" "$SWIPE" "$LEFT" "$RIGHT" "$ARCHIVE"; do
    [ -n "$label" ] || { echo "env.sh: a required string is missing"; exit 1; }
done

PREFS="/data/data/$PKG/shared_prefs/messages_settings.xml"
BACKUP="$TMP/inbox-settings-move.bak.xml"
adb_ shell "run-as $PKG cat $PREFS" > "$BACKUP" 2>/dev/null || true
restore() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    if [ -s "$BACKUP" ]; then
        adb_ shell "run-as $PKG sh -c 'cat > $PREFS'" < "$BACKUP" >/dev/null 2>&1 || true
    fi
}
trap restore EXIT

stored() {
    adb_ shell "run-as $PKG cat $PREFS 2>/dev/null" \
        | grep -oE "name=\"$1\" value=\"[0-9]+\"" | grep -oE '[0-9]+' | tail -1
}

stored_bool() {
    adb_ shell "run-as $PKG cat $PREFS 2>/dev/null" \
        | grep -oE "name=\"$1\" value=\"(true|false)\"" \
        | grep -oE '(true|false)' | tail -1
}

info "Enable the redesigned interface"
adb_ shell am force-stop "$PKG"
cat > "$TMP/inbox-settings-move.prefs.xml" <<XML
<?xml version="1.0" encoding="utf-8" standalone="yes" ?>
<map>
    <boolean name="first_import_done" value="true" />
    <boolean name="use_new_ui" value="true" />
</map>
XML
adb_ shell "run-as $PKG sh -c 'cat > $PREFS'" < "$TMP/inbox-settings-move.prefs.xml"

open_general() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
    adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null 2>&1
    sleep 3
}

open_inbox() {
    open_general
    scroll_to_layout "$INBOX" >/dev/null 2>&1 || return 1
    tap_layout "$INBOX" >/dev/null 2>&1 || return 1
    sleep 2
}

info "1. General settings no longer offers Delivery reports"
open_general
if wait_layout_has "$DELIVERY" 3; then
    fail "'$DELIVERY' is still on General settings"
else
    pass "General settings no longer shows '$DELIVERY'"
fi

info "2. Inbox settings offers Delivery reports and Swipe actions"
open_inbox || { fail "could not open Inbox settings"; exit 1; }
if scroll_to_layout "$DELIVERY" >/dev/null 2>&1; then
    pass "Inbox settings shows '$DELIVERY'"
else
    fail "Inbox settings has no '$DELIVERY' row"
fi
open_inbox || { fail "could not open Inbox settings again"; exit 1; }
if scroll_to_layout "$SWIPE" >/dev/null 2>&1; then
    pass "Inbox settings shows '$SWIPE'"
else
    fail "Inbox settings has no '$SWIPE' row"
fi

info "3. The Delivery reports row still writes the setting"
open_inbox || { fail "could not open Inbox settings"; exit 1; }
scroll_to_layout "$DELIVERY" >/dev/null 2>&1 || { fail "no '$DELIVERY' row to tap"; exit 1; }
before=$(stored_bool delivery_reports_enabled); [ -n "$before" ] || before=false
tap_layout "$DELIVERY" >/dev/null 2>&1
sleep 2
after=$(stored_bool delivery_reports_enabled)
if [ -n "$after" ] && [ "$after" != "$before" ]; then
    pass "the row wrote delivery_reports_enabled=$after"
else
    fail "the row did not change delivery_reports_enabled (was '$before', now '${after:-unset}')"
fi

info "4. Swipe actions opens a page with both directions"
open_inbox || { fail "could not open Inbox settings"; exit 1; }
scroll_to_layout "$SWIPE" >/dev/null 2>&1 || { fail "no '$SWIPE' row to tap"; exit 1; }
tap_layout "$SWIPE" >/dev/null 2>&1
sleep 2
if wait_layout_has "$LEFT" 4 && wait_layout_has "$RIGHT" 4; then
    pass "the page offers '$LEFT' and '$RIGHT'"
else
    fail "the page is missing a direction row"
fi

info "5. A choice on that page still reaches the store"
tap_layout "$LEFT" >/dev/null 2>&1
sleep 2
tap_layout "$ARCHIVE" >/dev/null 2>&1
sleep 2
if [ "$(stored swipe_left_action)" = "1" ]; then
    pass "swipe_left_action=1 after picking '$ARCHIVE'"
else
    fail "swipe_left_action is '$(stored swipe_left_action)', expected 1"
fi

printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
exit $(( FAIL > 0 ))
