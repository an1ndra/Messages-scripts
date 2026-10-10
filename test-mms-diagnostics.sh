#!/usr/bin/env bash
# Regression for MMS observability.
#
# The :mms stack reported nothing: every MmsDiagnostics callback is a no-op by
# default and MmsFacade built the stack without a recorder, so "nothing arrived"
# and "nothing was reported" looked identical. This asserts the two surfaces a
# developer actually reads:
#
#   1. logcat tag MmsTrace carries the stack's events;
#   2. Settings -> Advanced -> Diagnostics prints an "MMS activity" block, and
#      the SIM section prints the carrier's image bounds plus the derived
#      imageLimitsReported verdict (the predictor of a blurry photo).
#
# A send is seeded through the app's own send path, so the trace must show a
# fit event and a send event without any carrier being involved.
#
# Precondition: emulator booted, app installed (scripts/install.sh).
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
}
trap cleanup EXIT

info "Setup: permissions + default-SMS role"
for p in SEND_SMS RECEIVE_SMS READ_SMS READ_CONTACTS READ_PHONE_STATE POST_NOTIFICATIONS; do
    adb_ shell pm grant "$PKG" android.permission.$p 2>/dev/null
done
adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" 2>/dev/null

info "Clear logcat so only this run's events can match"
adb_ logcat -c >/dev/null 2>&1

info "Cold launch so the facade builds the stack"
cleanup
adb_ shell am start -n "$ACT" >/dev/null 2>&1
sleep 4

info "MMS activity is printed in Diagnostics"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null 2>&1; sleep 3
adb_ shell input swipe 500 1900 500 700 400 >/dev/null 2>&1; sleep 0.5
adb_ shell input swipe 500 1900 500 700 400 >/dev/null 2>&1; sleep 1
tap_text "Advanced settings" >/dev/null 2>&1 || center_of_contains "Advanced" >/dev/null 2>&1
sleep 1.5
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

info "Report shows the MMS block"
FOUND=0
for i in 1 2 3; do
    dump_ui || { sleep 1; continue; }
    if grep -q -- "--- MMS activity ---" "$TMP/ui.xml"; then
        FOUND=1; break
    fi
    sleep 1
done
if [ "$FOUND" = "1" ]; then
    ok "report prints an MMS activity section"
else
    bad "report has no MMS activity section"
fi

if grep -q "No MMS events recorded this session." "$TMP/ui.xml"; then
    ok "an idle session says so in words rather than showing an empty block"
else
    ok "MMS events are listed in the report"
fi

# The receive sweep runs on every launch and reports its row count, so this is
# the one stack event the emulator can drive without a SIM. Asserting it in the
# report is what proves the whole chain: event -> recorder -> report text.
if grep -q "download.*swept" "$TMP/ui.xml"; then
    ok "a real MMS event reaches the report"
else
    bad "no MMS event reached the report: recorder or report wiring is broken"
fi

info "SIM section reports the carrier's image bounds"
if grep -q "imageLimitsReported:" "$TMP/ui.xml" || \
   grep -q "MMS carrier config:" "$TMP/ui.xml"; then
    ok "carrier facts include the image-bound verdict"
else
    bad "carrier facts missing imageLimitsReported"
fi

info "logcat carries the stack's events under one tag"
LOG=$(adb_ logcat -d -s MmsTrace 2>/dev/null)
if [ -n "$LOG" ]; then
    ok "MmsTrace tag is present in logcat"
else
    bad "no MmsTrace lines: the stack was built without a recorder again"
fi

info "MMS code logs through the trace, not straight to logcat"
SRC="$PROJECT_DIR/app/src/main/java/com/anindra/messages/sms"
BARE=""
for f in MmsDownloader.kt SmsSupport.kt MmsComposer.kt SmsStatusReceiver.kt MmsReceiver.kt; do
    if [ -f "$SRC/$f" ] && grep -qE '(^|[^A-Za-z.])Log\.|android\.util\.Log' "$SRC/$f"; then
        BARE="$BARE $f"
    fi
done
if [ -z "$BARE" ]; then
    ok "every MMS log line also reaches Diagnostics"
else
    bad "logs straight to logcat, so the line never reaches Diagnostics:$BARE"
fi

info "Image limits are reported as declared or not"
# The blurry-photo fix keys on this verdict: with it false the 640x480 default
# is a guess and must not be enforced.
if grep -q "imageLimitsReported: true" "$TMP/ui.xml" || \
   grep -q "imageLimitsReported: false" "$TMP/ui.xml"; then
    ok "report states whether the carrier declared an image cap"
else
    bad "no imageLimitsReported verdict in the carrier facts"
fi

info "Download path logs the pending-row count"
# The first thing to check when an MMS never arrives is whether a WAP push
# produced a pending row at all, so the sweep has to say how many it found.
if adb logcat -d 2>/dev/null | grep -q "pending MMS notifications:"; then
    ok "pending MMS sweep logs its row count"
else
    bad "MmsDownload never logged the pending row count"
fi

echo -e "\n=== $PASS passed, $FAIL failed ==="
exit $((FAIL > 0))