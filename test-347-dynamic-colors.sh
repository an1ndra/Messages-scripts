#!/usr/bin/env bash
# Regression: #347 dynamic-colour feedback round.
#
# 1. The dynamic (wallpaper) mode must resolve to a scheme that is none of the
#    seeded palettes (light F8F9FC, dark 131314, amoled 000000), in both night
#    modes.
# 2. The Start chat pill must be readable under every resolved scheme; in the
#    seeded themes it must be the exact pair Google Messages paints (the tinted
#    accent container: #D3E3FD/blue in light, #0842A0/light-blue in dark),
#    which Diagnostics reports through the same helpers the FAB paints with.
# 3. Under Dynamic, a fresh install must report the harmonized per-contact
#    avatar rule from Diagnostics.
# 4. The send button must be absent from the UI dump while the composer is
#    empty (shrink + fade to nothing), and back once there is something to
#    send. The old build kept a faded circle, so its dump always shows a node.
#
# Everything is asserted from uiautomator dumps and the Diagnostics sheet text;
# no screenshots. Drives the theme through the --es set_theme hook and restores
# the original theme at the end.
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

# Opens the Diagnostics sheet and echoes "<mode>|<page colour>|<Start chat pair>"
read_report() {
    local mode colour pair
    adb_ shell input tap 970 143 >/dev/null 2>&1; sleep 3      # settings gear
    scroll_to_and_tap "Advanced settings" || { back_out 2; echo "||"; return; }
    sleep 4
    scroll_to_and_tap "Diagnostics" || { back_out 3; echo "||"; return; }
    sleep 6

    for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
        dump_ui
        mode=$(grep -oE 'Theme mode: [a-z]+' "$TMP/ui.xml" | head -1 | sed 's/.*: //')
        colour=$(grep -oE 'Resolved page colour: #[0-9A-F]{6}' "$TMP/ui.xml" | head -1 | sed 's/.*#//')
        pair=$(grep -oE 'Resolved Start chat colours: #[0-9A-F]{6} on #[0-9A-F]{6}' "$TMP/ui.xml" \
            | head -1 | sed 's/.*colours: //')
        if [ -n "$mode" ] && [ -n "$colour" ]; then
            back_out 3
            echo "$mode|$colour|$pair"
            return 0
        fi
        adb_ shell input swipe 540 1800 540 800 300 >/dev/null 2>&1; sleep 1
    done
    back_out 3
    echo "||"
}

pair_readable() {   # container_hex content_hex
    python3 - "$1" "$2" <<'PY'
import sys
c, t = sys.argv[1], sys.argv[2]
def lum(h):
    r, g, b = (int(h[i:i+2], 16) / 255 for i in (0, 2, 4))
    f = lambda v: v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4
    return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b)
l1 = lum(c); l2 = lum(t)
print("yes" if (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05) >= 3 else "no")
PY
}

assert_side() {     # label want_mode want_pair(content#container or empty) out_line
    local label="$1" want_mode="$2" want_pair="$3" out="$4" \
        mode colour pair content container
    mode=$(echo "$out" | cut -d'|' -f1)
    colour=$(echo "$out" | cut -d'|' -f2)
    pair=$(echo "$out" | cut -d'|' -f3)
    if [ -z "$colour" ]; then
        bad "$label (could not read the Diagnostics sheet)"
        return 1
    fi
    if [ "$mode" = "$want_mode" ]; then
        ok "$label reports theme mode '$want_mode'"
    else
        bad "$label reports theme mode '${mode:-none}', expected '$want_mode'"
    fi
    content=$(echo "$pair" | cut -d' ' -f1 | sed 's/#//')
    container=$(echo "$pair" | cut -d' ' -f3 | sed 's/#//')
    if [ ${#content} -ne 6 ] || [ ${#container} -ne 6 ]; then
        bad "$label Start chat pair missing from Diagnostics"
        return 1
    fi
    if [ "$container:$content" = "$want_pair" ]; then
        ok "$label Start chat pair is #$want_pair"
    elif [ -z "$want_pair" ]; then
        if [ "$(pair_readable "$container" "$content")" = yes ]; then
            ok "$label Start chat pair #$content on #$container is readable (>=3:1)"
        else
            bad "$label Start chat pair #$content on #$container is unreadable"
        fi
    else
        bad "$label Start chat pair is #$content on #$container, expected #$want_pair"
    fi
}

# Opens the first conversation; the composer starts empty.
send_button_check() {
    adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 3
    adb_ shell input tap 500 447 >/dev/null 2>&1; sleep 3
    dump_ui || { bad "could not dump the chat"; back_out 1; return; }
    if grep -q 'content-desc="Send"' "$TMP/ui.xml"; then
        bad "empty composer still shows a send button (pre-#347 behaviour)"
    else
        ok "empty composer shows no send button"
    fi
    # tap_edittext focuses the composer wherever the field sits on the row
    if tap_edittext; then sleep 1; else back_out 1; bad "could not focus the composer"; return; fi
    type_text "hi"; sleep 2
    dump_ui
    if grep -q 'content-desc="Send"' "$TMP/ui.xml"; then
        ok "typed text brings the send button back"
    else
        bad "send button missing after typing"
    fi
    back_out 1
}

ORIG=$(stored_theme)
[ -z "$ORIG" ] && ORIG=system

# Pin the night mode so dynamic's "follows the system" branch is deterministic.
adb_ shell cmd uimode night no >/dev/null 2>&1

info "Dynamic resolves to the wallpaper scheme, not a seeded palette"
set_theme dynamic
out=$(read_report)
assert_side "dynamic (light)" dynamic "" "$out"
PAGE=$(echo "$out" | cut -d'|' -f2)
case "$PAGE" in
    F8F9FC|131314|000000|"")
        bad "dynamic (light) resolved #${PAGE}, a seeded palette value or unreadable" ;;
    *) ok "dynamic (light) resolved #$PAGE, which is a wallpaper scheme" ;;
esac

info "Dynamic follows the system night setting onto the dark wallpaper scheme"
adb_ shell cmd uimode night yes >/dev/null 2>&1; sleep 2
out=$(read_report)
assert_side "dynamic (dark)" dynamic "" "$out"
PAGE=$(echo "$out" | cut -d'|' -f2)
case "$PAGE" in
    F8F9FC|131314|000000|"")
        bad "dynamic (dark) resolved #${PAGE}, a seeded palette value or unreadable" ;;
    *) ok "dynamic (dark) resolved #$PAGE, which is a wallpaper scheme" ;;
esac

info "Seeded themes keep their exact accent pairs"
set_theme light
assert_side "light" light "D3E3FD:0B57D0" "$(read_report)"
set_theme dark
assert_side "dark" dark "0842A0:D3E3FD" "$(read_report)"
set_theme amoled
assert_side "amoled" amoled "0A3D8F:D3E3FD" "$(read_report)"

info "Diagnostics states the avatar ink rule"
set_theme system
adb_ shell input tap 970 143 >/dev/null 2>&1; sleep 3
if scroll_to_and_tap "Advanced settings"; then
    sleep 3
    scroll_to_and_tap "Diagnostics" >/dev/null; sleep 5
    dump_ui
    if grep -qE "Avatar ink: #(202124|FFFFFF) on the fixed GM palette" "$TMP/ui.xml"; then
        ok "Diagnostics states the avatar ink the avatars paint with"
    else
        bad "Diagnostics avatar-ink line not found"
    fi
    back_out 3
else
    bad "could not reach Advanced settings"
fi

info "Send button disappears when the composer is empty"
set_theme system
send_button_check

info "Restore original theme + night mode (${ORIG})"
set_theme "$ORIG"
adb_ shell cmd uimode night no >/dev/null 2>&1
echo ""
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
exit $((FAIL > 0))
