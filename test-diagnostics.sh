#!/usr/bin/env bash
# Regression for the diagnostics report (issues #208 SIM label, #192 display
# scale). Settings -> Advanced -> Diagnostics must show a report containing the
# SIM and display sections, and Save must write it to
# Downloads/Messages/messages-diagnostics.txt so the user can attach it to a
# GitHub issue.
#
# Before this feature: no Diagnostics row, no report -> fails.
source "$(dirname "$0")/env.sh"

DIAG_FILE="/sdcard/Download/Messages/messages-diagnostics.txt"
PULLED="$TMP/diagnostics.txt"

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    adb_ shell rm -f "$DIAG_FILE" >/dev/null 2>&1
}
trap cleanup EXIT

info "Setup: permissions + default-SMS role"
for p in SEND_SMS RECEIVE_SMS READ_SMS READ_CONTACTS READ_PHONE_STATE POST_NOTIFICATIONS; do
    adb_ shell pm grant "$PKG" android.permission.$p 2>/dev/null
done
adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" 2>/dev/null
cleanup

info "Open Settings -> Advanced"
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null 2>&1; sleep 3
adb_ shell input swipe 500 1900 500 700 400 >/dev/null 2>&1; sleep 0.5
adb_ shell input swipe 500 1900 500 700 400 >/dev/null 2>&1; sleep 1
tap_text "Advanced" >/dev/null 2>&1 || center_of_contains "Advanced" >/dev/null 2>&1
sleep 1.5

info "Open Diagnostics"
adb_ shell input swipe 500 1900 500 700 400 >/dev/null 2>&1; sleep 0.8
if tap_text "Diagnostics" >/dev/null 2>&1; then
    ok "Diagnostics row present in Advanced settings"
else
    bad "Diagnostics row not found"
fi
sleep 2

info "Report dialog shows app + SIM + display sections"
SHOWN=0
for i in 1 2 3; do
    dump_ui || { sleep 1; continue; }
    if grep -q "Messages diagnostics report" "$TMP/ui.xml" && \
       grep -q -- "--- App ---" "$TMP/ui.xml" && \
       grep -q -- "--- SIM ---" "$TMP/ui.xml" && \
       grep -q -- "--- Display ---" "$TMP/ui.xml"; then
        SHOWN=1; break
    fi
    sleep 1
done
if [ "$SHOWN" = "1" ]; then
    ok "diagnostics dialog shows app, SIM and display sections"
else
    bad "diagnostics dialog missing sections"
fi

if grep -q "Default SMS handler" "$TMP/ui.xml" && \
   grep -q "Selected subscriptionId" "$TMP/ui.xml"; then
    ok "report includes app state and the selected subscription id"
else
    bad "report missing app state or selected subscription id"
fi

if grep -q 'text="Close"' "$TMP/ui.xml"; then
    ok "dialog has a Close button"
else
    bad "dialog has no Close button"
fi
if grep -q 'text="Share"' "$TMP/ui.xml"; then
    bad "dialog still shows the unwanted Share button"
else
    ok "dialog has no Share button"
fi

button_x() {
    grep -oE "text=\"$1\"[^>]*bounds=\"\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]\"" "$TMP/ui.xml" \
        | grep -oE '\[[0-9]+' | head -1 | tr -d '['
}
CLOSE_X=$(button_x Close); SAVE_X=$(button_x Save); COPY_X=$(button_x Copy)
if [ -n "$CLOSE_X" ] && [ -n "$SAVE_X" ] && [ -n "$COPY_X" ] && \
   [ "$CLOSE_X" -lt "$SAVE_X" ] && [ "$SAVE_X" -lt "$COPY_X" ]; then
    ok "buttons ordered left-to-right: Close, Save, Copy"
else
    bad "button order wrong (Close=$CLOSE_X Save=$SAVE_X Copy=$COPY_X)"
fi

info "Save writes the report to Downloads/Messages"
tap_text "Save" >/dev/null 2>&1
sleep 3
if adb_ shell ls "$DIAG_FILE" >/dev/null 2>&1; then
    ok "diagnostics file saved to Downloads/Messages"
else
    bad "diagnostics file not saved"
fi

if adb_ shell ls "$DIAG_FILE" >/dev/null 2>&1; then
    adb_ exec-out cat "$DIAG_FILE" > "$PULLED" 2>/dev/null
    if grep -q -- "--- Display ---" "$PULLED" && grep -q "Supported modes:" "$PULLED"; then
        ok "saved report contains the display mode list"
    else
        bad "saved report missing the display mode list"
    fi
fi

echo ""
info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
