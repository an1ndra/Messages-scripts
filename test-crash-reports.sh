#!/usr/bin/env bash
# Regression for the in-app crash reporter.
#
# A JVM crash must be captured by the global uncaught-exception handler
# installed in MessagesApplication, and written BOTH to internal storage
# (files/crash_reports/crash-<stamp>.txt) and to Downloads/Messages so the log
# is reachable even when the app crash-loops and never reaches its UI.
# On the next launch the app offers a "Crash report" dialog: Save ZIP (writes
# messages-crash-report.zip to Downloads/Messages — no share chooser, which on
# many devices only lists Bluetooth), Copy, Delete.
#
# Before this feature: `am crash` wrote no report and no dialog appeared ->
# fails. After: report captured (internal + Downloads), dialog shown, valid zip
# saved to Downloads, Delete clears the internal reports.
source "$(dirname "$0")/env.sh"

CRASH_DIR="files/crash_reports"
DOWNLOADS_DIR="/sdcard/Download/Messages"
REPORT_FILE="messages-crash-report.txt"
ZIP_FILE="messages-crash-report.zip"
ZIP_OUT="$TMP/crash-report.zip"

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

crash_files() {
    adb_ shell run-as "$PKG" ls "$CRASH_DIR" 2>/dev/null | tr -d '\r'
}

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    adb_ shell run-as "$PKG" rm -rf "$CRASH_DIR" >/dev/null 2>&1
    adb_ shell rm -f "$DOWNLOADS_DIR/$REPORT_FILE" "$DOWNLOADS_DIR/$ZIP_FILE" >/dev/null 2>&1
}
trap cleanup EXIT

info "Setup: permissions + default-SMS role (keeps the role dialog out of the way)"
for p in SEND_SMS RECEIVE_SMS READ_SMS READ_CONTACTS POST_NOTIFICATIONS; do
    adb_ shell pm grant "$PKG" android.permission.$p 2>/dev/null
done
adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" 2>/dev/null
cleanup

info "Cold launch"
adb_ shell am start -n "$ACT" >/dev/null 2>&1
sleep 4
if [ -n "$(adb_ shell pidof "$PKG" | tr -d '\r')" ]; then
    ok "app launched"
else
    bad "app did not stay running"
fi

info "Force a JVM crash (am crash routes through the app's uncaught handler)"
adb_ shell am crash "$PKG" >/dev/null 2>&1
sleep 3
REPORTS=$(crash_files)
if echo "$REPORTS" | grep -q 'crash-.*\.txt'; then
    ok "crash report written to internal storage"
else
    bad "no crash report captured (got: '$REPORTS')"
fi

DL=$(adb_ shell ls "$DOWNLOADS_DIR" 2>/dev/null | tr -d '\r')
if echo "$DL" | grep -q "$REPORT_FILE"; then
    ok "crash log published to Downloads/Messages (reachable if the app can't open)"
else
    bad "no crash log in Downloads/Messages (got: '$DL')"
fi

info "Relaunch: the crash dialog is offered"
adb_ shell am start -n "$ACT" >/dev/null 2>&1
SHOWN=0
for i in 1 2 3; do
    sleep 2
    dump_ui || continue
    if grep -q 'text="Crash report"' "$TMP/ui.xml" && \
       grep -q 'text="Save ZIP"' "$TMP/ui.xml"; then
        SHOWN=1; break
    fi
done
if [ "$SHOWN" = "1" ]; then
    ok "crash dialog shown with a save action"
else
    bad "crash dialog not shown on relaunch"
fi

info "Save ZIP writes an attachable archive to Downloads/Messages"
tap_text "Save ZIP" >/dev/null 2>&1
sleep 3
DL=$(adb_ shell ls "$DOWNLOADS_DIR" 2>/dev/null | tr -d '\r')
if echo "$DL" | grep -q "$ZIP_FILE"; then
    ok "zip saved to Downloads/Messages ($ZIP_FILE)"
else
    bad "no zip saved to Downloads/Messages (got: '$DL')"
fi

if echo "$DL" | grep -q "$ZIP_FILE"; then
    adb_ exec-out cat "$DOWNLOADS_DIR/$ZIP_FILE" > "$ZIP_OUT" 2>/dev/null
    if python3 -c "
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
assert any(n.endswith('.txt') for n in z.namelist()), z.namelist()
assert b'Messages crash report' in z.read(z.namelist()[0])
" "$ZIP_OUT" 2>/dev/null; then
        ok "zip is a valid archive containing the crash report"
    else
        bad "saved zip is not a valid crash-report archive"
    fi
fi

info "Delete clears the internal reports"
tap_text "Delete" >/dev/null 2>&1
sleep 2
LEFT=$(crash_files)
if [ -z "$LEFT" ]; then
    ok "Delete cleared the crash reports"
else
    bad "reports remain after Delete: '$LEFT'"
fi

echo ""
info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
