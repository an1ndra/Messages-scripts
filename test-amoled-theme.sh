#!/usr/bin/env bash
# Regression: the AMOLED theme must be selectable, must actually resolve to the
# true-black scheme, and must be offered in the old UI picker.
#
# Asserted from uiautomator dumps of the Diagnostics sheet, which reports both
# the stored theme mode and the page colour that mode resolves to. The resolved
# colour is the part that matters: a theme wired up to fall through to the dark
# scheme would still store "amoled" while painting #131314, which is invisible
# in review and only shows as a grey page on an OLED panel. Reading the colour
# from the app's own report avoids a screenshot comparison, which is slow and
# brittle across the emulator's swiftshader.
#
# Also drives the theme through the --es set_theme hook, so the intent allowlist
# in MainActivity is covered. Restores the original theme at the end.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

PREFS="/data/data/$PKG/shared_prefs/messages_settings.xml"

stored_theme() {
    adb_ shell "run-as $PKG cat $PREFS" 2>/dev/null \
        | grep -oE 'name="theme_mode">[^<]*' | cut -d'>' -f2 | tr -d '\r'
}

set_theme() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
    adb_ shell am start -n "$ACT" --es set_theme "$1" >/dev/null 2>&1; sleep 7
}

# Opens the Diagnostics sheet and echoes "<mode>|<resolved colour>".
# Diagnostics lives under Advanced settings, which is a sub-screen of Settings,
# and the sheet is a scrolling dialog, so both levels are searched rather than
# assuming a fixed number of swipes.
# Centre of the clickable row that owns the given text, or empty.
#
# The row has to be found through its *enclosing* clickable node, not through
# the text node: the label itself is not clickable, and the Diagnostics row is
# the last one in the list, so it sits at the very bottom of the viewport where
# tapping the label's own centre lands between rows.
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

# Scrolls the current screen until the row owning $2 is on screen, then taps it.
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

read_report() {
    local mode colour
    adb_ shell input tap 976 226 >/dev/null 2>&1; sleep 3      # settings gear
    scroll_to_and_tap "Advanced settings" || { back_out 2; echo "|"; return; }
    sleep 4
    scroll_to_and_tap "Diagnostics" || { back_out 3; echo "|"; return; }
    sleep 6

    for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
        dump_ui
        mode=$(grep -oE 'Theme mode: [a-z]+' "$TMP/ui.xml" | head -1 | sed 's/.*: //')
        colour=$(grep -oE 'Resolved page colour: #[0-9A-F]{6}' "$TMP/ui.xml" | head -1 | sed 's/.*#//')
        if [ -n "$mode" ] && [ -n "$colour" ]; then
            back_out 3
            echo "$mode|$colour"
            return 0
        fi
        adb_ shell input swipe 540 1800 540 800 300 >/dev/null 2>&1; sleep 1
    done
    back_out 3
    echo "|"
}

back_out() {
    local n="${1:-1}" _
    for _ in $(seq "$n"); do adb_ shell input keyevent 4 >/dev/null 2>&1; sleep 1; done
}

assert_report() {
    local want_mode="$1" want_colour="$2" label="$3" out mode colour
    out=$(read_report)
    mode=$(echo "$out" | cut -d'|' -f1)
    colour=$(echo "$out" | cut -d'|' -f2)
    if [ -z "$colour" ]; then
        bad "$label (could not read the Diagnostics sheet)"
        return
    fi
    if [ "$mode" = "$want_mode" ]; then
        ok "$label reports theme mode '$want_mode'"
    else
        bad "$label reports theme mode '${mode:-none}', expected '$want_mode'"
    fi
    if [ "$colour" = "$want_colour" ]; then
        ok "$label resolves to #$want_colour"
    else
        bad "$label resolves to #${colour}, expected #$want_colour"
    fi
}

ORIG=$(stored_theme)
[ -z "$ORIG" ] && ORIG=system

info "AMOLED is accepted by the set_theme hook and persists"
set_theme amoled
if [ "$(stored_theme)" = "amoled" ]; then
    ok "set_theme amoled persisted to the settings store"
else
    bad "set_theme amoled did not persist (got '$(stored_theme)')"
fi

info "AMOLED resolves to the true-black scheme"
assert_report amoled 000000 "AMOLED"

info "Dark still resolves to the dark grey scheme, so the two differ"
set_theme dark
assert_report dark 131314 "dark"

info "Light is unaffected"
set_theme light
assert_report light F8F9FC "light"

info "System default follows the device's night setting"
# The expected colour is read from the device rather than assumed, because the
# AVD is not guaranteed to be in the same night mode it was left in.
NIGHT=$(adb_ shell "cmd uimode night" 2>/dev/null | tr -d '\r')
case "$NIGHT" in
    *yes*) SYS_COLOUR=131314 ;;
    *)     SYS_COLOUR=F8F9FC ;;
esac
echo "  device night mode: $NIGHT -> system should resolve to #$SYS_COLOUR"
set_theme system
assert_report system "$SYS_COLOUR" "system"

info "AMOLED is offered in the old UI theme picker"
set_theme amoled
adb_ shell input tap 976 226 >/dev/null 2>&1; sleep 3
if scroll_to_and_tap "Choose theme"; then
    sleep 3
    dump_ui
    # Match case-insensitively: the label was retitled to "Amoled", and a
    # case-sensitive grep here reads as "the row vanished" rather than a
    # renamed string.
    if grep -qiE 'text="[Aa]moled[^"]*"' "$TMP/ui.xml"; then
        ok "Amoled listed in the theme picker"
    else
        bad "Amoled missing from the theme picker"
    fi
    back_out 2
else
    bad "could not find the 'Choose theme' row in old UI settings"
fi

info "Restore original theme (${ORIG})"
set_theme "$ORIG"

echo ""
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
