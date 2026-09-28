#!/usr/bin/env bash
# Regression for the Advanced > "Emoji button" setting, exercised on a dual-SIM
# setup (debug `--ez fake_dual_sim true`). Default is OFF, so the chat input
# shows the SIM switcher but no emoji button; turning it ON adds the emoji
# button beside the SIM glyph; turning it back OFF removes it. Restores the
# default at the end.
source "$(dirname "$0")/env.sh"

SEED="+15551231177"
DUAL="true"
PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

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

launch_home() {
    adb_ shell am force-stop "$PKG"; sleep 1
    if [ "$DUAL" = "true" ]; then
        adb_ shell am start -n "$ACT" --ez fake_dual_sim true >/dev/null 2>&1
    else
        adb_ shell am start -n "$ACT" >/dev/null 2>&1
    fi
    sleep 4
}
launch_settings() {
    adb_ shell am force-stop "$PKG"; sleep 1
    adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null 2>&1; sleep 3
}
open_advanced() {
    adb_ shell input swipe 500 1900 500 700 400; sleep 0.5
    adb_ shell input swipe 500 1900 500 700 400; sleep 1
    tap_text "Advanced" || tap_contains "Advanced"
    sleep 1.5
}

# Flip the "Emoji button" switch in Advanced to wanted true|false.
set_emoji() {
    local want="$1" i cur
    launch_settings; open_advanced
    for i in $(seq 1 12); do
        dump_ui
        grep -q 'text="Emoji button"' "$TMP/ui.xml" && break
        adb_ shell input swipe 540 1700 540 900 250; sleep 0.5
    done
    dump_ui
    if ! grep -q 'text="Emoji button"' "$TMP/ui.xml"; then
        bad "Advanced row 'Emoji button' not found"
        return 1
    fi
    cur=$(pref_get); [ -z "$cur" ] && cur=false
    if [ "$cur" != "$want" ]; then
        tap_switch_near "Emoji button"; sleep 0.8
    fi
    cur=$(pref_get); [ -z "$cur" ] && cur=false
    [ "$cur" = "$want" ] && ok "toggle set to $want" || bad "toggle stayed '$cur' (want $want)"
}

open_seed_chat() {
    launch_home
    adb_ emu sms send "$SEED" "emoji-toggle-seed" >/dev/null 2>&1; sleep 4
    local c i
    for i in 1 2 3; do
        c=$(center_of_contains "1177") || c=$(center_of_contains "emoji-toggle-seed") || { sleep 1; continue; }
        adb_ shell input tap $c; sleep 2
        dump_ui
        grep -q "Message\|text=\"Message\"" "$TMP/ui.xml" && return 0
        sleep 1
    done
    return 1
}

info "Dual-SIM, setting OFF: SIM switcher shown, emoji hidden"
set_emoji false
open_seed_chat || bad "could not open seeded chat"
dump_ui
grep -q 'content-desc="Switch SIM"' "$TMP/ui.xml" \
    && ok "SIM switcher present on dual-SIM" \
    || bad "SIM switcher missing on dual-SIM"
grep -q 'content-desc="Emoji"' "$TMP/ui.xml" \
    && bad "emoji button visible while the setting is off" \
    || ok "emoji button hidden while the setting is off"

info "Dual-SIM, setting ON: SIM switcher and emoji both shown"
set_emoji true
open_seed_chat || bad "could not open seeded chat (on)"
dump_ui
grep -q 'content-desc="Switch SIM"' "$TMP/ui.xml" \
    && ok "SIM switcher still present with emoji enabled" \
    || bad "SIM switcher missing with emoji enabled"
grep -q 'content-desc="Emoji"' "$TMP/ui.xml" \
    && ok "emoji button appears when enabled" \
    || bad "emoji button missing when enabled"

info "Restore default OFF"
set_emoji false
open_seed_chat || bad "could not open seeded chat (restore)"
dump_ui
grep -q 'content-desc="Switch SIM"' "$TMP/ui.xml" \
    && ok "SIM switcher present after restore" \
    || bad "SIM switcher missing after restore"
grep -q 'content-desc="Emoji"' "$TMP/ui.xml" \
    && bad "emoji button still visible after restoring off" \
    || ok "emoji button hidden again"

echo ""
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
