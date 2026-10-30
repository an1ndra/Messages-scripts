#!/usr/bin/env bash
# Defaults for someone installing for the first time: the redesigned UI and DM
# Sans, with no trip through Settings. An installation that has been updated
# keeps what it started with — an update must not restyle the app under a user
# who never touched the setting.
#
# First launch after a fresh install seeds font_family=dm_sans (once, from
# firstInstallTime == lastUpdateTime). Reinstalling over the package moves
# lastUpdateTime, so the second half of this script starts from the state an
# updating user is in: no stored font, and an age that says "not new".
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

PASS=0; FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }
info() { printf '\n=== %s ===\n' "$1"; }

APK=app/build/outputs/apk/debug/app-debug.apk

back_out() { for _ in $(seq 1 "${1:-1}"); do adb_ shell input keyevent 4 >/dev/null 2>&1; sleep 1; done; }
PREFS="shared_prefs/messages_settings.xml"

[ -f "$APK" ] || ./gradlew assembleDebug --quiet || { echo "no APK"; exit 1; }

font_pref() {
    adb_ shell "run-as $PKG cat $PREFS" 2>/dev/null \
        | grep -oE 'name="font_family">[^<]*' | cut -d'>' -f2 | tr -d '\r'
}

# The font a Diagnostics dump reports, i.e. the value the theme actually reads.
diagnostics_font() {
    local font=""
    adb_ shell input tap 970 143 >/dev/null 2>&1; sleep 3
    if ! scroll_to_layout "Advanced settings"; then back_out 2; echo ""; return; fi
    tap_layout "Advanced settings" >/dev/null 2>&1; sleep 3
    if ! scroll_to_layout "Diagnostics"; then back_out 3; echo ""; return; fi
    tap_layout "Diagnostics" >/dev/null 2>&1; sleep 5
    for _ in 1 2 3 4 5 6; do
        layout_json || { sleep 1; continue; }
        # The whole report is one text node with \n escapes, so there is no
        # quote after the value: match the label and stop at the newline escape.
        font=$(grep -oE 'Font: [a-z_]+' "$TMP/layout.json" | head -1 | sed 's/Font: //')
        [ -n "$font" ] && break
        adb_ shell input swipe 540 1800 540 800 300 >/dev/null 2>&1; sleep 1
    done
    back_out 4
    echo "$font"
}

launch() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    adb_ shell am start -n "$ACT" >/dev/null 2>&1
    sleep 6
    # A brand-new install asks to become the default SMS app; the role is
    # granted above, but the prompt still shows on the first launch.
    if layout_has "Set default"; then
        tap_layout "Not now" >/dev/null 2>&1 || adb_ shell input keyevent 4 >/dev/null 2>&1
        sleep 2
    fi
}

grant() {
    for p in READ_SMS SEND_SMS RECEIVE_SMS READ_CONTACTS READ_PHONE_STATE; do
        adb_ shell pm grant "$PKG" "android.permission.$p" >/dev/null 2>&1
    done
    adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1
}

settings_text() {
    local try
    for try in 1 2 3; do
        adb_ shell input tap 970 143 >/dev/null 2>&1; sleep 3
        if layout_has "Inbox settings"; then
            python3 - "$TMP/layout.json" <<'PYEOF'
import json, sys
def walk(node, out):
    if isinstance(node, list):
        for c in node: walk(c, out)
    elif isinstance(node, dict):
        if isinstance(node.get("text"), str) and node["text"].strip():
            out.append(node["text"])
        for key in ("content", "children"):
            for c in (node.get(key) or []): walk(c, out)
out = []
walk(json.load(open(sys.argv[1])), out)
print("\n".join(out))
PYEOF
            back_out 1
            return 0
        fi
        sleep 1
    done
    back_out 1
    echo ""
}

info "A fresh install starts on the redesigned UI and DM Sans"
adb_ uninstall "$PKG" >/dev/null 2>&1
adb_ install "$APK" >/dev/null 2>&1
grant
launch

stored=$(font_pref)
[ "$stored" = "dm_sans" ] \
    && pass "fresh install seeded font_family=dm_sans" \
    || fail "fresh install stored font_family='${stored}', want dm_sans"

text=$(settings_text)
echo "$text" | grep -qx "Inbox settings" \
    && pass "Settings opens the redesigned screen (Inbox settings present)" \
    || fail "Settings is not the redesigned screen"

font=$(diagnostics_font)
[ "$font" = "dm_sans" ] \
    && pass "the theme resolves the new user to DM Sans" \
    || fail "Diagnostics reports font '${font}', want dm_sans"

info "An installation that has been updated keeps System default"
adb_ install -r "$APK" >/dev/null 2>&1
adb_ shell pm clear "$PKG" >/dev/null 2>&1
grant
launch

stored=$(font_pref)
[ -z "$stored" ] \
    && pass "an update does not write a font choice of its own" \
    || fail "an update seeded font_family='${stored}', it must not"

font=$(diagnostics_font)
[ "$font" = "system" ] \
    && pass "an updating user stays on System default" \
    || fail "an updating user resolves to '${font}', want system"

info "Restore a fresh-install state"
adb_ uninstall "$PKG" >/dev/null 2>&1
adb_ install "$APK" >/dev/null 2>&1
grant
launch

echo ""
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
exit $((FAIL > 0))
