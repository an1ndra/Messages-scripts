#!/usr/bin/env bash
# Regression for issue #227: the in-field SIM switcher in the chat input bar.
#
# The stock emulator is single-SIM, so the debug `--ez fake_dual_sim true` flag
# makes the app see two SIMs (T-Mobile/SIM 1, Vodafone/SIM 2 with subId 7) and
# the dual path is exercised for real:
#   - dual-SIM  -> "Switch SIM" button beside the send button; tap cycles the
#                  selected SIM (pref changes, toast confirms); stays visible
#                  for the whole draft, including after the keyboard is closed
#   - single-SIM -> button absent
# Before the fix there was no in-field control at all, so the dual assertions
# fail. Restores the SIM preference at the end.
source "$(dirname "$0")/env.sh"

SEED="+15551234599"
PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

pref_get() {
    adb_ shell "run-as $PKG cat shared_prefs/messages_settings.xml" 2>/dev/null > "$TMP/prefs.xml"
    python3 - "$TMP/prefs.xml" <<'PY'
import re
try:
    s = open("/tmp/opencode/messages-tests/prefs.xml").read()
except OSError:
    s = ""
m = re.search(r'name="sim_subscription_id" value="([^"]*)"', s)
print(m.group(1) if m else "")
PY
}

pref_set() {
    adb_ shell "run-as $PKG sed -i 's/name=\"sim_subscription_id\" value=\"[^\"]*\"/name=\"sim_subscription_id\" value=\"$1\"/' shared_prefs/messages_settings.xml" >/dev/null 2>&1
}

pref_set_default() { pref_set -1; }

launch() {  # $1 = fake_dual_sim true/false
    adb_ shell am force-stop "$PKG"; sleep 1
    adb_ shell am start -n "$ACT" --ez fake_dual_sim "$1" >/dev/null 2>&1; sleep 4
}

open_seed_chat() {
    adb_ emu sms send "$SEED" "sim-inputbar-seed" >/dev/null 2>&1
    sleep 4
    local c i
    for i in 1 2 3; do
        c=$(center_of_contains "(555) 123-4599") || c=$(center_of_contains "555-123-4599") || { sleep 1; continue; }
        adb_ shell input tap $c; sleep 2
        dump_ui || true
        grep -q "Message" "$TMP/ui.xml" && return 0
        sleep 1
    done
    return 1
}

pref_set_default

info "Dual-SIM (fake): switcher visible beside send"
launch true
open_seed_chat || { bad "could not open seeded chat"; }
dump_ui
if grep -q 'content-desc="Switch SIM"' "$TMP/ui.xml"; then
    ok "Switch SIM button present"
else
    bad "Switch SIM button missing on dual-SIM"
fi
grep -q 'text="1"' "$TMP/ui.xml" \
    && ok "SIM slot number overlaid on the icon" \
    || bad "SIM slot number label missing"
grep -q 'content-desc="Message"\|text="Message"' "$TMP/ui.xml" \
    && ok "input pill intact" || bad "input pill missing"

info "Tap cycles the selected SIM"
p0=$(pref_get)
tap_text "Switch SIM" >/dev/null 2>&1; sleep 1.5
p1=$(pref_get)
[ -n "$p1" ] && [ "$p1" != "$p0" ] && ok "pref changes on tap ($p0 -> $p1)" \
    || bad "pref did not change on tap (p0=$p0 p1=$p1)"

info "Second tap wraps back"
tap_text "Switch SIM" >/dev/null 2>&1; sleep 1.5
p2=$(pref_get)
[ "$p2" = "$p0" ] && ok "pref wrapped back to $p0" || bad "pref did not wrap (p2=$p2 expected=$p0)"

info "Stays visible for the whole draft"
tap_edittext >/dev/null 2>&1; sleep 1
type_text "hi" >/dev/null 2>&1; sleep 1
dump_ui
grep -q 'content-desc="Switch SIM"' "$TMP/ui.xml" \
    && ok "Switch SIM still visible while typing" \
    || bad "Switch SIM hidden while typing"

# The reported bug (#219): visibility was gated on the draft being empty, so
# dismissing the keyboard left the control gone. Dismiss without clearing.
adb_ shell input keyevent 4 >/dev/null 2>&1; sleep 1.5
dump_ui
grep -q 'content-desc="Switch SIM"' "$TMP/ui.xml" \
    && ok "Switch SIM visible after dismissing the keyboard" \
    || bad "Switch SIM missing after dismissing the keyboard"

tap_edittext >/dev/null 2>&1; sleep 1
for _ in 1 2 3 4; do adb_ shell input keyevent 67 >/dev/null 2>&1; done
sleep 1
dump_ui
grep -q 'content-desc="Switch SIM"' "$TMP/ui.xml" \
    && ok "Switch SIM visible after clearing the draft" \
    || bad "Switch SIM missing after clearing the draft"
adb_ shell input keyevent 4 >/dev/null 2>&1; sleep 1

info "A stale saved SIM falls back to slot 1, not slot 0"
pref_set 99
launch true
open_seed_chat || bad "could not open seeded chat (stale saved SIM)"
dump_ui
grep -q 'text="1"' "$TMP/ui.xml" \
    && ok "slot numeral falls back to 1" \
    || bad "slot numeral wrong for a stale saved SIM (renders 0)"
grep -q 'content-desc="Switch SIM"' "$TMP/ui.xml" \
    && ok "Switch SIM still shown with a stale saved SIM" \
    || bad "Switch SIM missing with a stale saved SIM"
PS=$(pref_get)
[ "$PS" = "1" ] \
    && ok "stale pref rewritten to the first available SIM ($PS)" \
    || bad "stale pref left as '$PS' instead of being normalised"

info "Single-SIM: switcher absent"
launch false
open_seed_chat || bad "could not open seeded chat (single-SIM)"
dump_ui
grep -q 'content-desc="Switch SIM"' "$TMP/ui.xml" \
    && bad "Switch SIM shown on single-SIM" \
    || ok "Switch SIM hidden on single-SIM"
adb_ shell input keyevent 4 >/dev/null 2>&1

pref_set_default
echo ""
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
