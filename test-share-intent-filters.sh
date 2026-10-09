#!/usr/bin/env bash
# Regression for issue #304: app must appear in SMS/text share sheets from
# other apps and must accept the shared body into the composer.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

MARKER1="ShareBodyTest$$"
MARKER2="PlainTextShare$$"

query_has_main() {
    adb_ shell cmd package query-activities "$@" 2>/dev/null | grep -qF "name=$PKG.MainActivity"
}

unlock_device() {
    adb_ shell input keyevent 26 >/dev/null 2>&1 || true
    sleep 0.5
    adb_ shell input keyevent 26 >/dev/null 2>&1 || true
    sleep 1
    adb_ shell input swipe 540 1800 540 700 400 >/dev/null 2>&1 || true
    adb_ shell locksettings set-disabled true >/dev/null 2>&1 || true
    sleep 0.5
}

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
}
trap cleanup EXIT

unlock_device
cleanup

info "Manifest declares the filters the platform resolves for share intents"
if query_has_main -a android.intent.action.SENDTO -d "smsto:+15551230000"; then
    ok "SENDTO smsto resolves to MainActivity"
else
    bad "SENDTO smsto does not resolve to MainActivity"
fi

if query_has_main -a android.intent.action.SENDTO -d "sms:+15551230000"; then
    ok "SENDTO sms resolves to MainActivity"
else
    bad "SENDTO sms does not resolve to MainActivity"
fi

if query_has_main -a android.intent.action.SEND -t "text/plain"; then
    ok "ACTION_SEND text/plain resolves to MainActivity"
else
    bad "ACTION_SEND text/plain does not resolve to MainActivity"
fi

info "SENDTO with recipient + body opens the target chat with body pre-filled"
adb_ shell am start -a android.intent.action.SENDTO \
    -d "smsto:+15551230000?body=$MARKER1" \
    "$PKG" >/dev/null 2>&1
sleep 3
dump_ui >/dev/null 2>&1 || true
if grep -qF "$MARKER1" "$TMP/ui.decoded.xml" 2>/dev/null; then
    ok "shared body from SENDTO uri appears in the chat composer"
else
    bad "shared body from SENDTO uri not found in UI"
fi
cleanup; sleep 1

info "ACTION_SEND text/plain without recipient opens the new-chat picker"
adb_ shell am start -a android.intent.action.SEND -t "text/plain" \
    --es android.intent.extra.TEXT "$MARKER2" \
    "$PKG" >/dev/null 2>&1
sleep 3
dump_ui >/dev/null 2>&1 || true
if grep -qF "Enter name or phone number" "$TMP/ui.decoded.xml" 2>/dev/null || \
   grep -qF "New conversation" "$TMP/ui.decoded.xml" 2>/dev/null; then
    ok "ACTION_SEND opens the contact picker"
else
    bad "ACTION_SEND did not open the contact picker"
fi

echo ""
info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
