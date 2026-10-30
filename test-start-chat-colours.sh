#!/usr/bin/env bash
# The "Start chat" pill must keep the accent pair (#347 feedback round): the
# theme's primary fills the pill and onPrimary reads on it, in every seeded
# theme and under the wallpaper scheme alike, matching Google Messages.
# The old secondary-container surface read as a grey mismatch next to the
# wallpaper's accent.
#
# Diagnostics reports the pair the FAB actually paints with, so this is checked
# without a screenshot: light/dark/amoled each have a fixed seeded pair.
#
# Run: scripts/test-start-chat-colours.sh
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

PREFS="/data/data/$PKG/shared_prefs/messages_settings.xml"
ORIG=$(adb_ shell "run-as $PKG cat $PREFS" 2>/dev/null \
    | grep -oE 'name="theme_mode">[^<]*' | cut -d'>' -f2 | tr -d '\r')
[ -z "$ORIG" ] && ORIG=system

set_theme() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
    adb_ shell am start -n "$ACT" --es set_theme "$1" >/dev/null 2>&1; sleep 7
}

back_out() {
    local n="${1:-1}" _
    for _ in $(seq "$n"); do adb_ shell input keyevent 4 >/dev/null 2>&1; sleep 1; done
}

row_centre() {
    python3 - "$TMP/ui.xml" "$1" <<'PY'
import re, sys
xml, needle = open(sys.argv[1], encoding='utf-8', errors='replace').read(), sys.argv[2]
i = xml.find(f'text="{needle}"')
if i < 0:
    raise SystemExit(0)
hits = re.findall(r'clickable="true"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', xml[:i])
if not hits:
    raise SystemExit(0)
x1, y1, x2, y2 = map(int, hits[-1])
print((x1 + x2) // 2, (y1 + y2) // 2)
PY
}

scroll_to_and_tap() {
    local label="$1" c
    for _ in 1 2 3 4 5 6 7 8; do
        dump_ui
        c=$(row_centre "$label")
        if [ -n "$c" ]; then
            set -- $c
            adb_ shell input tap "$1" "$2" >/dev/null 2>&1
            return 0
        fi
        adb_ shell input swipe 540 1800 540 700 300 >/dev/null 2>&1; sleep 1
    done
    return 1
}

# The pill pair as Diagnostics reports it: "#RRGGBB on #RRGGBB".
read_pill_pair() {
    adb_ shell input tap 970 143 >/dev/null 2>&1; sleep 3
    scroll_to_and_tap "Advanced settings" || { back_out 2; echo ""; return; }
    sleep 4
    scroll_to_and_tap "Diagnostics" || { back_out 3; echo ""; return; }
    sleep 6
    local pair
    for _ in $(seq 1 12); do
        dump_ui
        pair=$(grep -oE 'Resolved Start chat colours: #[0-9A-F]{6} on #[0-9A-F]{6}' "$TMP/ui.xml" \
            | head -1 | sed 's/.*colours: //')
        if [ -n "$pair" ]; then
            back_out 3
            echo "$pair"
            return 0
        fi
        adb_ shell input swipe 540 1800 540 800 300 >/dev/null 2>&1; sleep 1
    done
    back_out 3
    echo ""
}

trap 'set_theme "$ORIG" >/dev/null 2>&1 || true' EXIT

check() {
    local mode="$1" want="$2" got
    info "$mode"
    set_theme "$mode"
    got=$(read_pill_pair)
    if [ -z "$got" ]; then
        bad "Diagnostics did not report the Start chat colours in $mode"
    elif [ "$got" = "$want" ]; then
        ok "$mode paints GM's pill pair: $got"
    else
        bad "$mode paints '$got', want '$want' (GM pill pair)"
    fi
}

# Seeded role values; these must change only together with the palette.
check light   "#0B57D0 on #D3E3FD"
check dark    "#D3E3FD on #0842A0"
check amoled  "#D3E3FD on #0A3D8F"

echo
echo "PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0))
