#!/usr/bin/env bash
# Regression for issue #323: a SIM renamed in Android settings must show that
# name in the chat instead of the bare "SIM n" slot label.
#
# The emulator is single-SIM, so the debug fake dual-SIM hook supplies a second
# subscription whose display name ("Vodafone UK") differs from its carrier
# ("Vodafone") — the shape Android reports for a user-renamed SIM.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

NUM="+1555$(date +%s | tail -c 8)"

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    adb_ shell "run-as $PKG sqlite3 databases/messages.db \"DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM'); DELETE FROM conversations WHERE address='$NUM';\"" >/dev/null 2>&1 || true
}
trap cleanup EXIT

adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1 || true
adb_ shell pm grant "$PKG" android.permission.READ_PHONE_STATE 2>/dev/null

info "1. Settings picker shows the user's SIM name"
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" --ez open_settings true --ez fake_dual_sim true >/dev/null 2>&1
sleep 3
scroll_to_layout "SIM card" >/dev/null 2>&1 || true
tap_layout "SIM card" >/dev/null 2>&1; sleep 1.5
if layout_has "Vodafone UK (SIM 2)"; then
    ok "renamed SIM shows 'Vodafone UK (SIM 2)'"
else
    bad "renamed SIM name missing from the settings picker"
fi
if layout_has "Vodafone (SIM 2)"; then
    bad "picker still shows the carrier instead of the user's name"
else
    ok "carrier echo replaced by the user's name"
fi
adb_ shell input keyevent 4 >/dev/null 2>&1

info "2. Message meta line shows the SIM name"
adb_ shell am force-stop "$PKG"; sleep 1
adb_ emu sms send "$NUM" "simname seed" >/dev/null 2>&1
sleep 4
adb_ shell am force-stop "$PKG"; sleep 1
# An outgoing row filed under fake subId 7, the way a message sent on the
# renamed SIM is stored, so the bubble's meta line can be asserted directly.
adb_ shell "run-as $PKG sqlite3 databases/messages.db \"INSERT INTO messages(conversation_id, body, timestamp, is_me, status, sub_id) SELECT id, 'simname probe', CAST(strftime('%s','now') AS INTEGER) * 1000 + 1, 1, 'sent', 7 FROM conversations WHERE address='$NUM';\"" >/dev/null 2>&1
adb_ shell am start -n "$ACT" --ez fake_dual_sim true --es open_conversation_address "$NUM" >/dev/null 2>&1
sleep 4
if layout_has "• Vodafone UK"; then
    ok "sent bubble is labelled with the SIM name"
else
    bad "sent bubble does not show the SIM name"
fi
if layout_has "• SIM 2"; then
    bad "sent bubble still shows the slot label"
else
    ok "slot label replaced by the SIM name"
fi

echo ""
info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
