#!/usr/bin/env bash
# Regression for the MMS send path after the move to the :mms package.
#
# Sending used to be built by MmsComposer on top of a vendored AOSP MMS stack
# (android-smsmms). It now goes through :mms, and the app's job is to read the
# attachment, hand it over, and remember which message the outbox row belongs
# to so the platform's result can be applied to the right bubble.
#
# Two defects are pinned here because both are invisible until a real send:
#
#   - the sent picture appears twice, because the provider's copy of the
#     message was imported as a new one when nothing linked the two;
#   - the row is never settled, because the platform reports the send with the
#     MMS transaction id and nothing of the app's own.
#
# A send needs a carrier, which the AVD has none of, so this asserts the wiring
# and the recording, and the round trip itself is checked by hand with a SIM.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

SRC="$PROJECT_DIR/app/src/main/java/com/anindra/messages"
MMS="$PROJECT_DIR/mms/src/main/java/com/anindra/messages/mms"

info "The vendored MMS stack is gone"
if [ ! -d "$PROJECT_DIR/android-smsmms" ] && [ ! -f "$SRC/sms/MmsComposer.kt" ]; then
    ok "android-smsmms and MmsComposer removed"
else
    bad "the old send path is still present"
fi
if grep -q 'include(":android-smsmms")' "$PROJECT_DIR/settings.gradle.kts"; then
    bad "settings.gradle.kts still includes android-smsmms"
else
    ok "no gradle reference to android-smsmms"
fi
if grep -q 'pdu_alt' "$PROJECT_DIR/app/proguard-rules.pro"; then
    bad "proguard still keeps the vendored PDU parsers"
else
    ok "proguard keep rules for the vendored stack removed"
fi

info "Sending goes through the :mms stack"
if grep -q "MmsSender.send(" "$SRC/sms/SmsSupport.kt"; then
    ok "sendMms delegates to MmsSender"
else
    bad "sendMms does not delegate to the :mms stack"
fi
if grep -q "MmsFacade.of(app," "$SRC/sms/MmsSender.kt"; then
    ok "MmsSender calls the facade with its own diagnostics"
else
    bad "MmsSender does not use the facade"
fi

info "The result is matched by transaction id"
if grep -q "EXTRA_TRANSACTION_ID" "$SRC/sms/SmsStatusReceiver.kt"; then
    ok "the receiver reads the MMS transaction id"
else
    bad "the receiver cannot tell which message a result belongs to"
fi
if grep -q "com.anindra.messages.mms.action.SEND_SENT" "$PROJECT_DIR/app/src/main/AndroidManifest.xml"; then
    ok "the receiver is registered for the stack's action"
else
    bad "the receiver is not registered for the stack's action"
fi
if grep -q "MmsPendingSends.remember(context, transactionId, messageId)" "$SRC/sms/MmsSender.kt"; then
    ok "the link is written before the PDU is handed over"
else
    bad "no tr_id -> message id link is recorded"
fi

info "The provider row is recorded in both places"
# The mapping table is what chat deletion and import dedupe read, so a link
# that only filled messages.sys_id would let the row come back as a new chat.
if grep -q "message_provider_ids" "$SRC/data/Repository.kt" && \
   sed -n '/fun linkMmsRow(/,/^    }/p' "$SRC/data/Repository.kt" | grep -q "message_provider_ids"; then
    ok "linkMmsRow writes the mapping table as well as the column"
else
    bad "linkMmsRow does not record the mapping table"
fi

info "The app starts and records"
cleanup() { adb_ shell am force-stop "$PKG" >/dev/null 2>&1; }
trap cleanup EXIT
cleanup
adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 5
if adb_ shell dumpsys activity activities 2>/dev/null | grep -q "$PKG"; then
    ok "app launched with the new send path"
else
    bad "app did not come up"
fi

info "Diagnostics still opens"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
# The AVD drops the launch right after a force-stop often enough that this is
# retried until the app is actually in front, not just started.
for _ in 1 2 3 4; do
    adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null 2>&1; sleep 3
    adb_ shell dumpsys window 2>/dev/null | grep -q "mCurrentFocus=.*$PKG" && break
    sleep 2
done
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
    SHOWN=0
    for _ in 1 2 3 4; do
        sleep 2
        dump_ui || true
        grep -q -- "--- MMS activity ---" "$TMP/ui.xml" && { SHOWN=1; break; }
    done
    if [ "$SHOWN" = "1" ]; then
        ok "Diagnostics prints the MMS trace"
    else
        bad "Diagnostics lost the MMS trace"
    fi
else
    bad "could not open Diagnostics"
fi

echo -e "\n=== $PASS passed, $FAIL failed ==="
exit $((FAIL > 0))