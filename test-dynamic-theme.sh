#!/usr/bin/env bash
# Regression for #347: the wallpaper-derived ("Material You") theme.
#
# Two halves. The picker half drives the real UI: Settings -> Choose theme must
# list "Dynamic" on Android 12+. The rendering half reads the Diagnostics sheet,
# which reports the colour the stored mode actually resolves to. A mode that
# stores "dynamic" but falls through to the seeded light scheme is the failure
# this catches - it looks identical in review and only shows as a page that
# ignores the wallpaper.
#
# Android 11 and older have no wallpaper colours at all, so there the mode must
# fall back to the seeded palettes; the script checks that too.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

PREFS="/data/data/$PKG/shared_prefs/messages_settings.xml"
SDK=$(adb_ shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')
ORIG=$(adb_ shell "run-as $PKG cat $PREFS" 2>/dev/null \
    | grep -oE 'name="theme_mode">[^<]*' | cut -d'>' -f2 | tr -d '\r')
[ -z "$ORIG" ] && ORIG=system

set_theme() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
    adb_ shell am start -n "$ACT" --es set_theme "$1" >/dev/null 2>&1; sleep 7
}

stored_theme() {
    adb_ shell "run-as $PKG cat $PREFS" 2>/dev/null \
        | grep -oE 'name="theme_mode">[^<]*' | cut -d'>' -f2 | tr -d '\r'
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

# "<mode>|<resolved page colour>", read off the Diagnostics sheet.
read_report() {
    adb_ shell input tap 976 226 >/dev/null 2>&1; sleep 3
    scroll_to_and_tap "Advanced settings" || { back_out 2; echo "|"; return; }
    sleep 4
    scroll_to_and_tap "Diagnostics" || { back_out 3; echo "|"; return; }
    sleep 6
    local mode colour fab
    for _ in $(seq 1 12); do
        dump_ui
        mode=$(grep -oE 'Theme mode: [a-z]+' "$TMP/ui.xml" | head -1 | sed 's/.*: //')
        colour=$(grep -oE 'Resolved page colour: #[0-9A-F]{6}' "$TMP/ui.xml" | head -1 | sed 's/.*#//')
        fab=$(grep -oE 'Resolved Start chat colours: #[0-9A-F]{6} on #[0-9A-F]{6}' "$TMP/ui.xml" | head -1 | sed 's/.*colours: //')
        if [ -n "$mode" ] && [ -n "$colour" ] && [ -n "$fab" ]; then
            back_out 3
            echo "$mode|$colour|$fab"
            return 0
        fi
        adb_ shell input swipe 540 1800 540 800 300 >/dev/null 2>&1; sleep 1
    done
    back_out 3
    echo "|"
}

info "device SDK $SDK, starting theme '$ORIG'"

info "Dynamic is accepted by the set_theme hook and persists"
set_theme dynamic
if [ "$(stored_theme)" = "dynamic" ]; then
    ok "set_theme dynamic persisted to the settings store"
else
    bad "set_theme dynamic did not persist (got '$(stored_theme)')"
fi

OUT=$(read_report)
MODE=$(echo "$OUT" | cut -d'|' -f1)
COLOUR=$(echo "$OUT" | cut -d'|' -f2)
FAB=$(echo "$OUT" | cut -d'|' -f3)
if [ -z "$COLOUR" ]; then
    bad "could not read the Diagnostics sheet"
else
    [ "$MODE" = "dynamic" ] \
        && ok "Diagnostics reports theme mode 'dynamic'" \
        || bad "Diagnostics reports '${MODE:-none}', expected 'dynamic'"
    if [ "$SDK" -ge 31 ]; then
        # The seeded light scheme is #F8F9FC; wallpaper colours are derived from
        # the device's wallpaper and cannot be assumed, so the assertion is that
        # the page is *not* one of the fixed seeds.
        case "$COLOUR" in
            F8F9FC|131314|000000)
                bad "dynamic resolved to a seeded colour (#$COLOUR), so the wallpaper scheme is not in use" ;;
            *)
                ok "dynamic resolves to a wallpaper colour (#$COLOUR)" ;;
        esac
    else
        case "$COLOUR" in
            F8F9FC|131314)
                ok "below Android 12 dynamic falls back to a seeded colour (#$COLOUR)" ;;
            *)
                bad "below Android 12 dynamic should fall back to a seed, got #$COLOUR" ;;
        esac
    fi
fi

info "The Start chat pill stays legible on this palette"
# A wallpaper palette can hand back a dark container and a dark primary; the
# pill then paints dark-on-dark and reads as a black blob. Diagnostics reports
# the pair the FAB actually paints with, so the contrast is checkable without a
# screenshot.
if [ -z "$FAB" ]; then
    bad "Diagnostics did not report the Start chat colours"
else
    echo "  reported pair: $FAB"
    RATIO=$(python3 - "$FAB" <<'PY'
import sys
pair = sys.argv[1]
content, container = [h.strip().lstrip('#') for h in pair.split(' on ')]
def lum(h):
    c = [int(h[i:i+2], 16) / 255 for i in (0, 2, 4)]
    c = [v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4 for v in c]
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
a, b = lum(content), lum(container)
hi, lo = max(a, b), min(a, b)
print(round((hi + 0.05) / (lo + 0.05), 2))
PY
)
    awk -v r="$RATIO" 'BEGIN { exit (r >= 3.0) ? 0 : 1 }' \
        && ok "Start chat content/container contrast is ${RATIO}:1 (>= 3)" \
        || bad "Start chat content/container contrast is ${RATIO}:1 (< 3, the pill reads as a black blob)"
fi

info "The theme picker offers Dynamic"
set_theme dynamic
adb_ shell input tap 976 226 >/dev/null 2>&1; sleep 3
if scroll_to_and_tap "Choose theme"; then
    sleep 3
    dump_ui
    if [ "$SDK" -ge 31 ]; then
        if grep -qiE 'text="Dynamic"' "$TMP/ui.xml"; then
            ok "Dynamic listed in the theme picker"
        else
            bad "Dynamic missing from the theme picker"
        fi
    else
        if grep -qiE 'text="Dynamic"' "$TMP/ui.xml"; then
            bad "Dynamic is listed below Android 12, where it cannot work"
        else
            ok "Dynamic is not offered below Android 12"
        fi
    fi
    back_out 2
else
    bad "could not open the theme picker"
fi

info "Restore original theme (${ORIG})"
set_theme "$ORIG"

echo ""
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
