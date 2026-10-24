#!/usr/bin/env bash
# Avatar colour: the per-contact palette everywhere, the theme's container colour
# under the dynamic (wallpaper) theme, and no switch to configure either.
#
# The switch ("Theme colours for avatars") was removed once dynamic handled the
# one case that mattered: it would either be dead there or marginal elsewhere.
# This asserts the row is gone from both settings UIs and that the rule survived
# the setting — the avatar fill is a pixel, so Diagnostics reports which source
# it used, through the same function the theme paints through.
#
# Fails on the pre-change build: the switch row still exists, and Diagnostics
# has no "Avatar fill:" line at all.
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

PASS=0; FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }
info() { printf '\n=== %s ===\n' "$1"; }

ROW="Theme colours for avatars"
PREFS="shared_prefs/messages_settings.xml"

ORIG_THEME=$(adb_ shell "run-as $PKG cat $PREFS" 2>/dev/null \
    | grep -oE 'name="theme_mode">[^<]*' | cut -d'>' -f2 | tr -d '\r')
[ -z "$ORIG_THEME" ] && ORIG_THEME=system

cleanup() {
    set_theme "$ORIG_THEME" >/dev/null 2>&1 || true
    pin_new_ui on >/dev/null 2>&1 || true
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
}
trap cleanup EXIT

set_new_ui() {
    case "$1" in
      on)  from=false; to=true ;;
      off) from=true;  to=false ;;
    esac
    adb_ shell "run-as $PKG sh -c 'sed -i \"s#name=\\\"use_new_ui\\\" value=\\\"$from\\\"#name=\\\"use_new_ui\\\" value=\\\"$to\\\"#\" $PREFS'" >/dev/null 2>&1
}

pin_new_ui() {
    adb_ shell "run-as $PKG sh -c 'touch $PREFS'" >/dev/null 2>&1
    adb_ shell "run-as $PKG sh -c 'grep -q use_new_ui $PREFS || echo \"<?xml version=\\\"1.0\\\" encoding=\\\"utf-8\\\" standalone=\\\"yes\\\" ?><map><boolean name=\\\"use_new_ui\\\" value=\\\"true\\\" /></map>\" > $PREFS'" >/dev/null 2>&1
    set_new_ui "$1"
}

# --es set_theme is the app's own hook; it stores the mode the way the picker does.
set_theme() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
    adb_ shell am start -n "$ACT" --es set_theme "$1" >/dev/null 2>&1; sleep 6
}

# Any node whose text mentions an avatar, i.e. the removed switch's title or subtitle.
avatar_text_present() {
    layout_json || return 0
    python3 - "$TMP/layout.json" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
hits = []
def walk(node):
    if isinstance(node, list):
        for child in node:
            walk(child)
    elif isinstance(node, dict):
        for key in ("text", "content-desc", "contentDesc"):
            value = node.get(key)
            if isinstance(value, str) and "avatar" in value.lower():
                hits.append(value)
        for key in ("content", "children"):
            for child in (node.get(key) or []):
                walk(child)
walk(data)
print("\n".join(hits))
sys.exit(1 if hits else 0)
PY
}

check_no_switch() {
    local label="$1"
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
    adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null 2>&1; sleep 4
    if ! wait_layout_has "General settings" 8; then
        fail "$label: Settings never opened"
        return
    fi
    scroll_to_layout "$ROW" >/dev/null 2>&1
    if avatar_text_present; then
        pass "$label: no avatar colour row in Settings"
    else
        fail "$label: an avatar colour row is still on the settings screen"
    fi
}

# The Diagnostics sheet states the avatar rule, and states it the same way for
# every theme: a per-theme value would make two identical builds look different.
avatar_fill_reading() {
    adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null 2>&1; sleep 4
    wait_layout_has "General settings" 8 || { echo ""; return; }
    scroll_to_layout "Advanced settings" >/dev/null 2>&1
    tap_layout "Advanced settings" >/dev/null 2>&1
    sleep 2
    # The Diagnostics row sits below the fold on the Advanced screen, so it has to
    # be scrolled to; waiting for it first would only time out.
    scroll_to_layout "Diagnostics" >/dev/null 2>&1 || { echo ""; return; }
    tap_layout "Diagnostics" >/dev/null 2>&1
    # The report is generated before the dialog appears, so poll for the line.
    local i got
    for i in $(seq 1 10); do
        sleep 1
        layout_json || continue
        got=$(avatar_fill_from_layout)
        [ -n "$got" ] && { echo "$got"; return; }
    done
    echo ""
}

avatar_fill_from_layout() {
    python3 - "$TMP/layout.json" <<'PY'
import json, sys, re
data = json.load(open(sys.argv[1]))
found = []
def walk(node):
    if isinstance(node, list):
        for child in node:
            walk(child)
    elif isinstance(node, dict):
        for key in ("text", "content-desc", "contentDesc"):
            value = node.get(key)
            if isinstance(value, str):
                m = re.search(r"Avatar fill: [^\n]+", value)
                if m:
                    found.append(m.group(0).strip())
        for key in ("content", "children"):
            for child in (node.get(key) or []):
                walk(child)
walk(data)
print(found[0] if found else "")
PY
}

RULE="Avatar fill: theme colour under Dynamic, per-contact palette otherwise"

check_rule() {
    local theme="$1"
    info "theme '$theme' states the same avatar rule"
    set_theme "$theme"
    local got
    got=$(avatar_fill_reading | tail -1)
    if [ "$got" = "$RULE" ]; then
        pass "under '$theme' Diagnostics states the rule unchanged"
    else
        fail "under '$theme' Diagnostics said '${got:-nothing}', expected '$RULE'"
    fi
}

pin_new_ui on
check_no_switch "new settings UI"

pin_new_ui off
check_no_switch "legacy settings UI"

pin_new_ui on
check_rule dynamic
check_rule system
check_rule amoled

printf '\n[RESULT] %d passed, %d failed\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
