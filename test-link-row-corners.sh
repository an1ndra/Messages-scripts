#!/usr/bin/env bash
# Regression: on the redesigned "Link behaviour" page, "Highlight links" is the
# middle row of its three-row group, so all four of its corners use the inner
# radius (4dp) — matching "Hide links from messages".
#
# It once took a LAST position whenever "Hide links from messages" was off,
# which rounded its bottom corners to the group's outer 12dp while the
# "Link open warning" row still sat below it: the over-rounded row reported.
#
# Corner radii are pixels, so the app publishes them as text (the
# SettingsRowShape logcat marker, mirroring the chat BubbleShape one) and this
# script asserts on logcat rather than a screenshot.
#
# Run: scripts/test-link-row-corners.sh
set -uo pipefail
cd "$(dirname "$0")"
source ./env.sh

PASS=0
FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
[[ "$ANDROID_SERIAL" == emulator-* ]] || { printf 'Requires a disposable emulator.\n'; exit 1; }

PREFS="/data/data/$PKG/shared_prefs/messages_settings.xml"
BACKUP="$TMP/link-corners-settings.bak.xml"

adb_ shell "run-as $PKG cat $PREFS" > "$BACKUP" 2>/dev/null || true
restore() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    if [ -s "$BACKUP" ]; then
        adb_ shell "run-as $PKG sh -c 'cat > $PREFS'" < "$BACKUP" >/dev/null 2>&1 || true
    fi
}
trap restore EXIT

info "Enable the redesigned interface"
adb_ shell am force-stop "$PKG"
cat > "$TMP/link-corners-settings.xml" <<XML
<?xml version="1.0" encoding="utf-8" standalone="yes" ?>
<map>
    <boolean name="first_import_done" value="true" />
    <boolean name="use_new_ui" value="true" />
</map>
XML
adb_ shell "run-as $PKG sh -c 'cat > $PREFS'" < "$TMP/link-corners-settings.xml"

info "Open Advanced settings"
adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null
sleep 3
if scroll_to_layout "Advanced settings" && tap_layout "Advanced settings"; then
    pass "opened Advanced settings"
else
    fail "could not open Advanced settings"
fi
sleep 2

info "Open Link behaviour and capture its row shapes"
adb_ shell logcat -c >/dev/null 2>&1 || true
if scroll_to_layout "Link behaviour" && tap_layout "Link behaviour"; then
    pass "opened Link behaviour"
else
    fail "could not open Link behaviour"
fi
sleep 3

SHAPES=$(adb_ shell logcat -d -s SettingsRowShape:D 2>/dev/null || true)

row_line() { printf '%s\n' "$SHAPES" | grep -F "title=$1 " | tail -1; }

expect_row() { # title, expected position, expected "tS tE bS bE" corner string
    local title="$1" pos="$2" corners="$3" line
    line=$(row_line "$title")
    if [ -z "$line" ]; then
        fail "no SettingsRowShape marker for '$title'"
        return
    fi
    if printf '%s' "$line" | grep -qF "position=$pos " &&
        printf '%s' "$line" | grep -qF "$corners"; then
        pass "'$title' is $pos with the expected corners"
    else
        fail "'$title' has the wrong corners: $line"
    fi
}

expect_row "Hide links from messages" FIRST \
    "topStart=12.0 topEnd=12.0 bottomStart=4.0 bottomEnd=4.0"
expect_row "Highlight links" MIDDLE \
    "topStart=4.0 topEnd=4.0 bottomStart=4.0 bottomEnd=4.0"
expect_row "Link open warning" LAST \
    "topStart=4.0 topEnd=4.0 bottomStart=12.0 bottomEnd=12.0"

printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
exit $(( FAIL > 0 ))
