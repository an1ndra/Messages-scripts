#!/usr/bin/env bash
# Regression for the diagnostics report (issues #208 SIM label, #192 display
# scale, #209 crashes). Settings -> Advanced -> Diagnostics must show a detailed
# report (app / device / system / data / SIM / display) with Close + Copy only
# (no Save).
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    adb_ shell rm -f /sdcard/Download/Messages/messages-diagnostics.txt >/dev/null 2>&1
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
for i in 1 2 3 4 5; do
    dump_ui || true
    grep -q 'text="Diagnostics"' "$TMP/ui.xml" && break
    adb_ shell input swipe 540 1700 540 900 250 >/dev/null 2>&1; sleep 0.4
done
if tap_text "Diagnostics" >/dev/null 2>&1; then
    ok "Diagnostics row present in Advanced settings"
else
    bad "Diagnostics row not found"
fi
sleep 2

info "Report dialog shows the detailed sections"
SHOWN=0
for i in 1 2 3; do
    dump_ui || { sleep 1; continue; }
    if grep -q "Messages diagnostics report" "$TMP/ui.xml" && \
       grep -q -- "--- App ---" "$TMP/ui.xml" && \
       grep -q -- "--- Device ---" "$TMP/ui.xml" && \
       grep -q -- "--- System ---" "$TMP/ui.xml" && \
       grep -q -- "--- Data ---" "$TMP/ui.xml" && \
       grep -q -- "--- SIM ---" "$TMP/ui.xml" && \
       grep -q -- "--- Display ---" "$TMP/ui.xml"; then
        SHOWN=1; break
    fi
    sleep 1
done
[ "$SHOWN" = "1" ] && ok "report shows app/device/system/data/SIM/display sections" \
    || bad "report missing sections"

if grep -q "Conversations:" "$TMP/ui.xml" && \
   grep -q "Database size:" "$TMP/ui.xml" && \
   grep -q "Battery:" "$TMP/ui.xml" && \
   grep -q "Default SMS handler" "$TMP/ui.xml"; then
    ok "report includes data + system details"
else
    bad "report missing data/system details"
fi

if grep -q "Security patch:" "$TMP/ui.xml" && \
   grep -q "Build ID:" "$TMP/ui.xml" && \
   grep -q "ABIs:" "$TMP/ui.xml" && \
   grep -q "CPU cores:" "$TMP/ui.xml" && \
   grep -q "Kernel:" "$TMP/ui.xml" && \
   grep -q "Emulator:" "$TMP/ui.xml"; then
    ok "report includes extended device details"
else
    bad "report missing extended device details"
fi

info "Dialog buttons: Close + Copy, no Save"
if grep -q 'text="Close"' "$TMP/ui.xml"; then ok "dialog has a Close button"; else bad "no Close button"; fi
if grep -q 'text="Copy"' "$TMP/ui.xml"; then ok "dialog has a Copy button"; else bad "no Copy button"; fi
if grep -q 'text="Save"' "$TMP/ui.xml"; then bad "dialog still shows the removed Save button"; else ok "dialog has no Save button"; fi

button_x() {
    grep -oE "text=\"$1\"[^>]*bounds=\"\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]\"" "$TMP/ui.xml" \
        | grep -oE '\[[0-9]+' | head -1 | tr -d '['
}
CLOSE_X=$(button_x Close); COPY_X=$(button_x Copy)
if [ -n "$CLOSE_X" ] && [ -n "$COPY_X" ] && [ "$CLOSE_X" -lt "$COPY_X" ]; then
    ok "buttons ordered left-to-right: Close, Copy"
else
    bad "button order wrong (Close=$CLOSE_X Copy=$COPY_X)"
fi

echo ""
info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
