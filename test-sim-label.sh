#!/usr/bin/env bash
# Regression for issue #208: the Settings "SIM card" row must show the carrier
# name for the selected SIM (e.g. "T-Mobile (SIM 1)"), never the raw
# subscription id — which surfaced as a random "SIM 7" / "SIM 3".
#
# Root cause was SettingsScreen resolving the label only from an async SIM list
# that was still empty, then falling back to `settings_sim_label` with the
# subscription id. Fix loads the list on entry and resolves via SimLabels.
#
# Before the fix the row fell back to "SIM <subscriptionId>"; after, it shows
# the carrier + slot. Restores the default SIM at the end.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0; SKIP=0
ok()   { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad()  { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
skip() { echo "[SKIP] $1"; SKIP=$((SKIP + 1)); }
info() { echo -e "\n=== $* ==="; }

adb_ shell pm grant "$PKG" android.permission.READ_PHONE_STATE 2>/dev/null

launch_settings() {
    adb_ shell am force-stop "$PKG"; sleep 1
    adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null 2>&1; sleep 3
}

open_sim_dialog() {
    dump_ui
    if ! grep -q 'text="SIM card"' "$TMP/ui.xml"; then
        adb_ shell input swipe 500 1900 500 700 400 >/dev/null 2>&1; sleep 0.8
    fi
    tap_text "SIM card" >/dev/null 2>&1 || center_of_contains "SIM card" >/dev/null 2>&1
    sleep 1.5
}

# First carrier-labelled option in the dialog, e.g. "T-Mobile (SIM 1)".
carrier_option() {
    dump_ui || return 1
    grep -oE 'text="[^"]*\(SIM [0-9]+\)"' "$TMP/ui.xml" | head -1 \
        | sed -E 's/text="([^"]*)"/\1/'
}

select_default() {
    tap_text "Default (System)" >/dev/null 2>&1
    sleep 0.5
    tap_text "OK" >/dev/null 2>&1
    sleep 1
}

cleanup() {
    open_sim_dialog >/dev/null 2>&1
    select_default >/dev/null 2>&1
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
}
trap cleanup EXIT

info "Open Settings -> SIM card dialog"
launch_settings
open_sim_dialog
LABEL=$(carrier_option)

if [ -z "$LABEL" ]; then
    skip "no SIM with a carrier name on this device"
else
    ok "SIM dialog lists a carrier option: $LABEL"

    info "Select the carrier SIM"
    C=$(center_of "$LABEL") || C=$(center_of_contains "$LABEL")
    if [ -n "$C" ]; then
        adb_ shell input tap $C
        sleep 0.5
        tap_text "OK" >/dev/null 2>&1
        sleep 1.5
    fi

    info "Settings row shows the carrier label, not a raw number"
    dump_ui
    if grep -q "text=\"$LABEL\"" "$TMP/ui.xml"; then
        ok "SIM row shows '$LABEL'"
    else
        bad "SIM row does not show '$LABEL'"
    fi
fi

echo ""
info "Results: $PASS passed, $FAIL failed, $SKIP skipped"
exit $((FAIL > 0))
