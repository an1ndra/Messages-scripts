#!/usr/bin/env bash
# Regression for the debug-only fake dual-SIM hook (issue #208 tooling).
#
# The stock emulator is single-SIM, so `--ez fake_dual_sim true` makes the app
# see two fake subscriptions (T-Mobile/SIM 1, Vodafone/SIM 2 with subId 7). This
# lets the dual-SIM UI + the label logic (subId 7 -> "SIM 2", never "SIM 7") be
# exercised on emulator-5554. Debug builds only; real launches are unaffected.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

pref_get() {
    adb_ shell "run-as $PKG cat shared_prefs/messages_settings.xml" 2>/dev/null > "$TMP/prefs.xml"
    python3 - "$1" "$TMP/prefs.xml" <<'PY'
import re, sys
key, path = sys.argv[1], sys.argv[2]
try:
    s = open(path).read()
except OSError:
    s = ""
m = re.search(r'name="%s" value="([^"]*)"' % re.escape(key), s)
print(m.group(1) if m else "")
PY
}

launch() {  # $1 = true/false for fake_dual_sim
    adb_ shell am force-stop "$PKG"; sleep 1
    adb_ shell am start -n "$ACT" --ez open_settings true --ez fake_dual_sim "$1" >/dev/null 2>&1
    sleep 3
}

open_sim_dialog() {
    dump_ui || return 1
    grep -q 'text="SIM card"' "$TMP/ui.xml" || adb_ shell input swipe 540 1700 540 900 250 >/dev/null 2>&1
    tap_text "SIM card" >/dev/null 2>&1
    sleep 1.5
}

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
}
trap cleanup EXIT

adb_ shell pm grant "$PKG" android.permission.READ_PHONE_STATE 2>/dev/null

info "Fake dual-SIM launch shows two subscriptions"
launch true
open_sim_dialog
dump_ui
grep -q 'text="T-Mobile (SIM 1)"' "$TMP/ui.xml" && ok "shows T-Mobile (SIM 1)" || bad "missing T-Mobile (SIM 1)"
grep -q 'text="Vodafone (SIM 2)"' "$TMP/ui.xml" && ok "shows Vodafone (SIM 2)" || bad "missing Vodafone (SIM 2)"
grep -q 'text="SIM 7"' "$TMP/ui.xml" && bad "raw subId leaked as 'SIM 7'" || ok "no raw 'SIM 7' label"

info "Selecting the second SIM updates the row + pref"
tap_text "Vodafone (SIM 2)" >/dev/null 2>&1; sleep 0.6
tap_text "OK" >/dev/null 2>&1; sleep 1.5
[ "$(pref_get sim_subscription_id)" = "7" ] && ok "pref sim_subscription_id=7" || bad "pref is $(pref_get sim_subscription_id)"
dump_ui
grep -q 'text="Vodafone (SIM 2)"' "$TMP/ui.xml" && ok "SIM row shows Vodafone (SIM 2)" || bad "SIM row not updated"

info "Restore Default"
open_sim_dialog
tap_text "Default (System)" >/dev/null 2>&1; sleep 0.6
tap_text "OK" >/dev/null 2>&1; sleep 1.5
[ "$(pref_get sim_subscription_id)" = "-1" ] && ok "restored to Default" || bad "not restored"

info "Normal launch (no flag) shows the real single SIM"
launch false
open_sim_dialog
dump_ui
grep -q 'text="Vodafone (SIM 2)"' "$TMP/ui.xml" && bad "fake SIM leaked into a normal launch" || ok "no fake SIM without the flag"

echo ""
info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
