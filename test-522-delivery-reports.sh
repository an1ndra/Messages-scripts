#!/usr/bin/env bash
# Regression for issue #522: delivery reports must be reachable from the
# redesigned Settings screen, and a delivered message must show "Delivered" in
# the chat when the switch is on — while the same row reads the message kind
# when it is off, which is what the report saw.
#
# Before the fix the redesigned screen had no Delivery reports row at all, so
# the switch could not be turned on and no confirmation was ever requested.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

NUM="+1555$(date +%s | tail -c 8)"
LABEL=$(res_string settings_delivery_reports_title)
[ -n "$LABEL" ] || LABEL="Delivery reports"

prefs() {
    adb_ shell "run-as $PKG cat shared_prefs/messages_settings.xml" 2>/dev/null \
        | grep -o 'name="delivery_reports_enabled" value="[a-z]*"' \
        | grep -o '[a-z]*"$' | tr -d '"'
}

# Writes the switch through the Settings UI, never the prefs file: the point of
# the test is that the row exists and toggles what the send path reads.
set_switch() {
    local want="$1" now
    now=$(prefs)
    [ -n "$now" ] || now=false
    [ "$now" = "$want" ] && return 0
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
    adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null 2>&1
    sleep 3
    scroll_to_layout "$LABEL" >/dev/null 2>&1 || return 1
    tap_layout "$LABEL" >/dev/null 2>&1 || return 1
    # Read the file while the app is alive: apply() writes to disk right away,
    # while a force-stop this soon can drop the queued write.
    sleep 2
    [ "$(prefs)" = "$want" ]
}

seed_delivered() {
    adb_ shell "run-as $PKG sqlite3 databases/messages.db \"INSERT INTO messages(conversation_id, body, timestamp, is_me, status, media_type, transport, delivered_at, sub_id, address) SELECT id, 'delivery probe', CAST(strftime('%s','now') AS INTEGER) * 1000 + 1, 1, 'delivered', 'text', 'sms', CAST(strftime('%s','now') AS INTEGER) * 1000, -1, address FROM conversations WHERE address='$NUM';\"" >/dev/null 2>&1
}

open_chat() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
    adb_ shell am start -n "$ACT" --es open_conversation_address "$NUM" >/dev/null 2>&1
    sleep 4
}

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    adb_ shell "run-as $PKG sqlite3 databases/messages.db \"DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM'); DELETE FROM conversations WHERE address='$NUM';\"" >/dev/null 2>&1 || true
}
trap cleanup EXIT

adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1 || true
for p in android.permission.SEND_SMS android.permission.READ_SMS android.permission.RECEIVE_SMS \
         android.permission.READ_PHONE_STATE android.permission.POST_NOTIFICATIONS; do
    adb_ shell pm grant "$PKG" "$p" >/dev/null 2>&1 || true
done

info "1. The redesigned Settings screen offers the Delivery reports switch"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null 2>&1
sleep 3
if scroll_to_layout "$LABEL" >/dev/null 2>&1; then
    ok "the Settings row '$LABEL' is present"
else
    bad "no '$LABEL' row in the redesigned Settings screen"
fi

info "2. The row writes the setting the send path reads"
if set_switch true; then
    ok "switching it on stores delivery_reports_enabled=true"
else
    bad "the row does not store delivery_reports_enabled=true (now '$(prefs)')"
fi
if set_switch false; then
    ok "switching it off stores delivery_reports_enabled=false"
else
    bad "the row does not store delivery_reports_enabled=false (now '$(prefs)')"
fi

info "3. A delivered message says 'Delivered' with the switch on"
set_switch true >/dev/null 2>&1
adb_ emu sms send "$NUM" "delivery seed" >/dev/null 2>&1
sleep 4
seed_delivered
open_chat
if wait_layout_has "• Delivered" 4; then
    ok "the delivered bubble reads '… • Delivered'"
else
    bad "a delivered row does not show 'Delivered' with the switch on"
fi

info "4. The same row reads the message kind with the switch off"
set_switch false >/dev/null 2>&1
open_chat
if wait_layout_has "• SMS" 4; then
    ok "the delivered bubble falls back to '… • SMS'"
else
    bad "the bubble does not fall back to the message kind with the switch off"
fi
if wait_layout_has "• Delivered" 2; then
    bad "the bubble still says Delivered with the switch off"
else
    ok "no 'Delivered' claim while the switch is off"
fi

echo ""
info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
