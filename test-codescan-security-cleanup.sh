#!/usr/bin/env bash
# Regression for the security-scan cleanup batch:
#  - CodeQL #489 (high) java/zipslip: SmsIeReader proves a zip part name stays
#    inside the staging directory instead of trusting substringAfterLast('/')
#  - CodeQL #490 (medium) java/android/insecure-local-authentication:
#    AppLockVerification ties BiometricPrompt to a Keystore CryptoObject and
#    proves the returned cipher before reporting Verified
#  - CodeQL #494 java/integer-multiplication-cast-to-long: AttachmentFitter
#    promotes the part count before multiplying
#  - CodeQL #491-493 java/whitespace-contradicts-precedence: Wsp.kt parenthesises
#    the infix `and` before a comparison
#  - CodeQL #80/#81/#496/#498 unused locals dropped
#
# The security behaviour itself is unit-tested (SmsIeReaderStagingTest,
# AppLockVerificationWiringTest, BudgetPolicyTest). This script pins the source
# shape so a later refactor cannot quietly undo a fix, and smoke-launches the app
# so the touched files still run. The on-device biometric prompt is exercised by
# test-app-lock-verification.sh.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

SRC="$PROJECT_DIR/app/src/main/java/com/anindra/messages"
MMS_SRC="$PROJECT_DIR/mms/src/main/java/com/anindra/messages/mms"

cleanup() { adb_ shell am force-stop "$PKG" >/dev/null 2>&1; }
trap cleanup EXIT

info "Source: zip-slip guard (#489)"
if grep -q 'File(entry.name).name' "$SRC/data/SmsIeReader.kt" \
    && grep -q 'name.contains("..")' "$SRC/data/SmsIeReader.kt"; then
    ok "SmsIeReader reduces a part name to its final component and rejects .."
else
    bad "SmsIeReader lost the zip-slip sanitizer shape CodeQL recognises"
fi

info "Source: app-lock prompt is crypto-bound (#490)"
HELPER="$SRC/ui/AppLockVerification.kt"
if grep -q 'BiometricPrompt.CryptoObject(' "$HELPER"; then
    ok "the prompt is given a CryptoObject"
else
    bad "the App lock prompt is back to a bare boolean"
fi
if grep -q 'MessageLockCrypto.proveAuth' "$HELPER"; then
    ok "the authenticated cipher runs a real crypto operation"
else
    bad "the auth result is not proven with a crypto operation"
fi
if grep -q 'MessageLockCrypto.newAuthCipher' "$HELPER"; then
    ok "the CryptoObject comes from the auth-bound Keystore key"
else
    bad "the CryptoObject is not backed by the auth-bound key"
fi

info "Source: overflow + precedence (#494, #491-493)"
if grep -q 'partCount.toLong() \* 512' "$MMS_SRC/spi/AttachmentFitter.kt" \
    && ! grep -qE '\+ partCount \* 512' "$MMS_SRC/spi/AttachmentFitter.kt"; then
    ok "AttachmentFitter promotes the part count before multiplying"
else
    bad "AttachmentFitter multiplies partCount as Int again"
fi
WSP="$MMS_SRC/pdu/Wsp.kt"
if grep -q '(byte and 0x80) == 0' "$WSP" \
    && grep -q '(data\[index\].toInt() and 0xFF) == quote' "$WSP" \
    && grep -q '(bytes\[0\].toInt() and 0xFF) > 0x7F' "$WSP"; then
    ok "Wsp.kt parenthesises infix and before the comparison"
else
    bad "Wsp.kt precedence is implicit again"
fi

info "Source: unused locals removed (#80, #81, #496, #498)"
if grep -q 'oldName' "$SRC/data/Repository.kt"; then
    bad "Repository still binds the unused oldName"
else
    ok "Repository unused oldName dropped"
fi
if grep -q ', supporting)' "$SRC/ui/SettingsScreen.kt" "$SRC/ui/legacy/LegacySettingsScreen.kt"; then
    bad "an ImportRadioGroup still binds the unused supporting text"
else
    ok "ImportRadioGroup unused supporting dropped"
fi
if grep -A1 'val context = LocalContext.current' "$SRC/ui/ScheduledMessagesScreen.kt" \
        | grep -q 'vm.scheduledMessages'; then
    bad "ScheduledMessagesScreen still declares an unused context"
else
    ok "ScheduledMessagesScreen unused context dropped"
fi

info "Setup: permissions + launch smoke"
for p in READ_SMS SEND_SMS RECEIVE_SMS POST_NOTIFICATIONS; do
    adb_ shell pm grant "$PKG" android.permission.$p 2>/dev/null
done
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell logcat -c >/dev/null 2>&1 || true
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
if adb_ shell logcat -d 2>/dev/null | grep -q "FATAL EXCEPTION"; then
    bad "FATAL EXCEPTION in logcat"
else
    ok "no FATAL EXCEPTION"
fi

echo ""
info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
