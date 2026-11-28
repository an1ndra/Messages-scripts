#!/usr/bin/env bash
# With MMS switched off the plus disappears, but the emoji button must still
# obey its own setting: OFF hides it, ON puts it in the slot the plus had.
# Both states are driven through the real Advanced settings switch; the debug
# probe only sets MMS so the test need not walk into the MMS page each time.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

EMOJI=$(res_string icon_emoji)
ATTACH=$(res_string icon_attach)
ROW=$(res_string settings_advanced_emoji_button)
if [ -z "$EMOJI" ] || [ -z "$ATTACH" ] || [ -z "$ROW" ]; then
    echo "  [FAIL] this build has no emoji/attach/setting label"
    echo; echo "  PASS=0 FAIL=1"; echo "=== FAILED ==="; exit 1
fi

adb_su "cmd role add-role-holder android.app.role.SMS $PKG" >/dev/null 2>&1

pref_get() {
    adb_ shell "run-as $PKG cat shared_prefs/messages_settings.xml" 2>/dev/null > "$TMP/prefs.xml"
    python3 - "$TMP/prefs.xml" <<'PY'
import re, sys
try:
    s = open(sys.argv[1]).read()
except OSError:
    s = ""
m = re.search(r'name="emoji_button_enabled" value="([^"]*)"', s)
print(m.group(1) if m else "")
PY
}

fresh_dump() {
    rm -f "$TMP/ui.xml" "$TMP/ui.decoded.xml"
    for _ in 1 2 3; do
        dump_ui >/dev/null 2>&1 && [ -s "$TMP/ui.xml" ] && return 0
        sleep 0.5
    done
    return 1
}

launch_settings_mms_off() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    adb_ shell am start -W -n "$ACT" --es mms_probe off --ez open_settings true >/dev/null 2>&1
    sleep 3
}

launch_chat_mms_off() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    adb_ shell am start -W -n "$ACT" --es mms_probe off >/dev/null 2>&1
    sleep 3
    fresh_dump || return 1
    local row
    row=$(python3 - "$TMP/ui.xml" <<'PY'
import re, sys
xml = open(sys.argv[1]).read()
best = None
for m in re.finditer(r'<node[^>]*content-desc="([^"]+)"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', xml):
    y1 = int(m.group(3))
    if y1 > 300 and (best is None or y1 < best[0]):
        best = (y1, (int(m.group(2)) + int(m.group(4))) // 2, (int(m.group(3)) + int(m.group(5))) // 2)
print(f"{best[1]} {best[2]}" if best else "")
PY
)
    [ -n "$row" ] || return 1
    adb_ shell input tap ${row% *} ${row#* }
    sleep 2
    fresh_dump
}

set_emoji_with_mms_off() {
    local want="$1" i cur
    launch_settings_mms_off
    adb_ shell input swipe 500 1900 500 700 400; sleep 0.5
    adb_ shell input swipe 500 1900 500 700 400; sleep 1
    tap_text "Advanced settings" || tap_contains "Advanced"
    sleep 1.5
    for i in $(seq 1 12); do
        fresh_dump || true
        grep -q "text=\"$ROW\"" "$TMP/ui.xml" && break
        adb_ shell input swipe 540 1700 540 900 250; sleep 0.5
    done
    fresh_dump || true
    if ! grep -q "text=\"$ROW\"" "$TMP/ui.xml"; then
        bad "Advanced row '$ROW' not found"
        return 1
    fi
    cur=$(pref_get); [ -z "$cur" ] && cur=false
    if [ "$cur" != "$want" ]; then
        tap_switch_near "$ROW"; sleep 0.8
    fi
    cur=$(pref_get); [ -z "$cur" ] && cur=false
    [ "$cur" = "$want" ]
}

cleanup() {
    local i
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    adb_ shell am start -W -n "$ACT" --es mms_probe on --ez open_settings true >/dev/null 2>&1 || true
    sleep 3
    adb_ shell input swipe 500 1900 500 700 400 >/dev/null 2>&1 || true
    adb_ shell input swipe 500 1900 500 700 400 >/dev/null 2>&1 || true
    tap_text "Advanced settings" >/dev/null 2>&1 || true
    sleep 1
    for i in $(seq 1 12); do
        fresh_dump >/dev/null 2>&1 || true
        grep -q "text=\"$ROW\"" "$TMP/ui.xml" && break
        adb_ shell input swipe 540 1700 540 900 250 >/dev/null 2>&1 || true
        sleep 0.5
    done
    if grep -q "text=\"$ROW\"" "$TMP/ui.xml" 2>/dev/null && [ "$(pref_get)" != "false" ]; then
        tap_switch_near "$ROW" >/dev/null 2>&1 || true
    fi
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
}
trap cleanup EXIT

info "MMS off, emoji setting OFF: the composer has neither button"
set_emoji_with_mms_off false \
    && ok "the setting is off" \
    || bad "could not turn the setting off"
launch_chat_mms_off || bad "could not open a conversation"
if ui_has "$ATTACH"; then
    bad "the attach button is still there with MMS off"
else
    ok "no '$ATTACH' button with MMS off"
fi
if ui_has "$EMOJI"; then
    bad "the '$EMOJI' button is still there with the setting off"
else
    ok "no '$EMOJI' button with the setting off"
fi

info "MMS off, emoji setting ON: the button returns in the plus's slot"
set_emoji_with_mms_off true \
    && ok "the setting is on" \
    || bad "could not turn the setting on"
launch_chat_mms_off || bad "could not open a conversation with the setting on"
if ui_has "$EMOJI"; then
    ok "the '$EMOJI' button is back with MMS off"
else
    bad "the '$EMOJI' button is missing with the setting on"
fi

echo
echo "  PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && echo "=== OK ===" || echo "=== FAILED ==="
exit $((FAIL > 0))
