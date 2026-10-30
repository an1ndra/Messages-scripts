#!/usr/bin/env bash
# Avatars keep GM's palette, but a chip that cannot be told apart from the page
# is a chip in name only: pink on white measures 2.58:1, and a muted wallpaper
# palette leaves brown/indigo/blue-grey matching the page in hue and lightness.
#
# So the fill is chosen by contrast: a contact keeps its own palette colour when
# it clears 3:1 against the surface, otherwise it takes the nearest one that
# does. Diagnostics reports the resolved pair, which is what this asserts —
# a colour against a colour cannot be read from a screenshot reliably.
#
# Fails on the pre-change build: the line reads "Avatar ink: … " and no ratio is
# printed at all.
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
adb_ root >/dev/null 2>&1

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { printf '\n=== %s ===\n' "$1"; }

ORIG=$(adb_ shell "run-as $PKG cat shared_prefs/messages_settings.xml" 2>/dev/null \
    | grep -oE 'name="theme_mode">[^<]*' | cut -d'>' -f2 | tr -d '\r')
[ -z "$ORIG" ] && ORIG=system

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    adb_ shell am start -n "$ACT" --es set_theme "$ORIG" >/dev/null 2>&1
}
trap cleanup EXIT

read_avatar_line() {   # echoes "fill|surface|ratio"
    adb_ shell input tap 970 143 >/dev/null 2>&1; sleep 3
    scroll_to_layout "Advanced settings" >/dev/null 2>&1
    tap_layout "Advanced settings" >/dev/null 2>&1; sleep 3
    scroll_to_layout "Diagnostics" >/dev/null 2>&1
    tap_layout "Diagnostics" >/dev/null 2>&1; sleep 4
    layout_json || { echo "||"; return; }
    python3 - "$TMP/layout.json" <<'PY'
import json, re, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    print("||"); raise SystemExit
text = []
def walk(n):
    if isinstance(n, list):
        for c in n: walk(c)
    elif isinstance(n, dict):
        t = n.get("text")
        if isinstance(t, str): text.append(t)
        for k in ("content", "children"):
            for c in (n.get(k) or []): walk(c)
walk(data)
blob = "\n".join(text)
m = re.search(r"Avatar: #([0-9A-F]{6}) on #([0-9A-F]{6}) \(([0-9.]+):1\)", blob)
print("|".join(m.groups()) if m else "||")
PY
    adb_ shell input keyevent 4 >/dev/null 2>&1
    adb_ shell input keyevent 4 >/dev/null 2>&1
    adb_ shell input keyevent 4 >/dev/null 2>&1
    sleep 1
}

check_theme() {   # mode
    info "theme '$1'"
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    adb_ shell am start -n "$ACT" --es set_theme "$1" >/dev/null 2>&1; sleep 5
    line=$(read_avatar_line)
    fill=$(echo "$line" | cut -d'|' -f1)
    surface=$(echo "$line" | cut -d'|' -f2)
    ratio=$(echo "$line" | cut -d'|' -f3)
    if [ -z "$fill" ] || [ -z "$ratio" ]; then
        bad "no avatar line reported under '$1'"
        return
    fi
    echo "  fill #$fill on #$surface = ${ratio}:1"
    python3 - "$ratio" <<'PY'
import sys
ratio = float(sys.argv[1])
sys.exit(0 if ratio >= 3.0 else 1)
PY
    if [ $? -eq 0 ]; then
        ok "the chip clears 3:1 under '$1' (${ratio}:1)"
    else
        bad "the chip is ${ratio}:1 under '$1', below the floor"
    fi
}

check_theme light
check_theme dark
check_theme amoled

echo ""
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
exit $((FAIL > 0))
