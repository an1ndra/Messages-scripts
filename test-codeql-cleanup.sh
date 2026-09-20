#!/usr/bin/env bash
# Regression for the CodeQL security-and-quality cleanup (alerts #8, #9, #12,
# #13, #15, #22, #23, #24, #25, #27, #28, #29, #30, #31, #32, #33):
#  - MainActivity: display-mode probe no longer null-checks a @NonNull display
#    and dropped the unused isList/isChat locals
#  - Repository: ImportResult is a sealed interface (no generated `$stable`
#    field can mask the superclass) and the unused group `name` binding is gone
#  - SimLabels: Default/Unknown are plain objects (no generated equals locals)
#  - SmsSupport: no compile-time SmsManager.getSmsManagerForSubscriptionId call
#  - DiagnosticsReport: no deprecated TelephonyManager.phoneCount
#  - MessageLockCrypto: no deprecated setUserAuthenticationValidityDurationSeconds
#  - SmsReceiver/ChatScreen/Components: unused locals removed
#
# The source checks are deterministic; the on-device checks confirm the touched
# runtime paths (launch display probe, SMS receive, diagnostics collect) still
# work without a crash on emulator-5554.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

SRC="$PROJECT_DIR/app/src/main/java/com/anindra/messages"

cleanup() { adb_ shell am force-stop "$PKG" >/dev/null 2>&1; }
trap cleanup EXIT

info "Source: flagged patterns removed"
if grep -qE 'display\?\.' "$SRC/MainActivity.kt"; then
    bad "MainActivity still null-checks display"
else
    ok "MainActivity display probe has no useless null check"
fi
if grep -qE 'val (isList|isChat) ' "$SRC/MainActivity.kt"; then
    bad "MainActivity still declares unused isList/isChat"
else
    ok "MainActivity unused isList/isChat removed"
fi
if grep -qE 'for \(\(id, addr, name\) in group\)' "$SRC/data/Repository.kt"; then
    bad "Repository still binds the unused group name"
else
    ok "Repository group name binding removed"
fi
if grep -qE 'for \(\(addr, cid, m\) in batch\)' "$SRC/data/Repository.kt"; then
    bad "Repository still binds the unused provider addr"
else
    ok "Repository batch addr binding removed"
fi
if grep -q 'sealed interface ImportResult' "$SRC/data/Repository.kt"; then
    ok "Repository.ImportResult is a sealed interface"
else
    bad "Repository.ImportResult is not a sealed interface"
fi
if grep -qE 'object (Default|Unknown) : SimLabel' "$SRC/data/SimLabels.kt"; then
    ok "SimLabel.Default/Unknown are plain objects"
else
    bad "SimLabel stateless labels are still data objects"
fi
if grep -q 'SmsManager\.getSmsManagerForSubscriptionId' "$SRC/sms/SmsSupport.kt"; then
    bad "SmsSupport still calls deprecated getSmsManagerForSubscriptionId"
else
    ok "SmsSupport no longer calls deprecated getSmsManagerForSubscriptionId"
fi
if grep -q 'legacyManagerForSubscription' "$SRC/sms/SmsSupport.kt"; then
    ok "SmsSupport keeps the pre-S per-SIM path"
else
    bad "SmsSupport lost the pre-S per-SIM path"
fi
if grep -qE 'tm\?\.phoneCount' "$SRC/diagnostics/DiagnosticsReport.kt"; then
    bad "DiagnosticsReport still reads deprecated telephony phoneCount"
else
    ok "DiagnosticsReport no longer reads deprecated telephony phoneCount"
fi
if grep -q 'activeSubscriptionInfoCountMax' "$SRC/diagnostics/DiagnosticsReport.kt"; then
    ok "DiagnosticsReport falls back to SubscriptionManager below SDK 30"
else
    bad "DiagnosticsReport missing the SDK<30 phone-count fallback"
fi
if grep -q 'setUserAuthenticationValidityDurationSeconds' "$SRC/data/MessageLockCrypto.kt"; then
    bad "MessageLockCrypto still calls the deprecated auth-validity method"
else
    ok "MessageLockCrypto no longer calls the deprecated auth-validity method"
fi
if grep -q 'val appInForeground' "$SRC/sms/SmsReceiver.kt"; then
    bad "SmsReceiver still declares the unused appInForeground local"
else
    ok "SmsReceiver unused appInForeground removed"
fi
if grep -q 'val showEntrySkeleton' "$SRC/ui/ChatScreen.kt" || \
   grep -q 'val hasEarlierButton' "$SRC/ui/ChatScreen.kt"; then
    bad "ChatScreen still declares unused skeleton/earlier locals"
else
    ok "ChatScreen unused skeleton/earlier locals removed"
fi
if grep -q 'val cs = MaterialTheme.colorScheme' "$SRC/ui/Components.kt"; then
    bad "Components.SkeletonConversationRow still declares unused cs"
else
    ok "Components.SkeletonConversationRow unused cs removed"
fi

info "Setup: permissions + default-SMS role"
for p in READ_SMS SEND_SMS RECEIVE_SMS READ_PHONE_STATE POST_NOTIFICATIONS; do
    adb_ shell pm grant "$PKG" android.permission.$p 2>/dev/null
done
adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" 2>/dev/null

info "Launch (exercises the MainActivity display-mode probe)"
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell logcat -c
adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 5
if adb_ shell "ps -A 2>/dev/null" | grep -q "$PKG"; then
    ok "process running after launch"
else
    bad "process not running after launch"
fi
dump_ui || true
if grep -q 'text="Messages"' "$TMP/ui.xml"; then
    ok "home screen reached"
else
    bad "home screen not reached"
fi

info "Inbound SMS (exercises SmsReceiver)"
adb_ emu sms send 15551339911 "cleanup-regression $(date +%s)" >/dev/null 2>&1; sleep 3
if adb_ shell logcat -d 2>/dev/null | grep -q "FATAL EXCEPTION"; then
    bad "FATAL EXCEPTION in logcat"
else
    ok "no FATAL EXCEPTION"
fi

info "Diagnostics report (exercises DiagnosticsReport.collect)"
adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null 2>&1; sleep 3
adb_ shell input swipe 500 1900 500 700 400 >/dev/null 2>&1; sleep 0.5
adb_ shell input swipe 500 1900 500 700 400 >/dev/null 2>&1; sleep 1
tap_text "Advanced" >/dev/null 2>&1 || center_of_contains "Advanced" >/dev/null 2>&1
sleep 1.5
for i in 1 2 3 4 5; do
    dump_ui || true
    grep -q 'text="Diagnostics"' "$TMP/ui.xml" && break
    adb_ shell input swipe 540 1700 540 900 250 >/dev/null 2>&1; sleep 0.4
done
if tap_text "Diagnostics" >/dev/null 2>&1; then
    ok "Diagnostics row opened"
else
    bad "Diagnostics row not found"
fi
sleep 2
REPORT=0
for i in 1 2 3; do
    dump_ui || { sleep 1; continue; }
    if grep -q "Messages diagnostics report" "$TMP/ui.xml" && \
       grep -q "phoneCount:" "$TMP/ui.xml"; then
        REPORT=1; break
    fi
    sleep 1
done
[ "$REPORT" = "1" ] && ok "report rendered with a phoneCount line" \
    || bad "report missing phoneCount line"

if adb_ shell logcat -d 2>/dev/null | grep -q "FATAL EXCEPTION"; then
    bad "FATAL EXCEPTION after diagnostics"
else
    ok "no FATAL EXCEPTION after diagnostics"
fi

echo ""
info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
