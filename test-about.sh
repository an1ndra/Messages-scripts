#!/usr/bin/env bash
# Regression: the About screen and the row that opens it.
#
# Asserted here, because none of it is visible in a diff:
#   - About is the LAST row in Settings (rounded bottom) and Advanced is MIDDLE
#   - the old "Messages 1.0 - offline SMS" footer is gone from both surfaces
#   - the screen shows the build version, the developer and its four actions
#   - the launcher icon is a hero, not a thumbnail
#   - Report an issue asks before attaching diagnostics
#   - Share Messages reaches the system share sheet
#   - Star on GitHub opens the project page
#
# The URL building and the 4096-character prefill cap are unit-tested in
# AboutLinksTest; this script covers what only a device can answer.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

PREFS="shared_prefs/messages_settings.xml"

# Which settings surface the app renders: true = redesigned, false = legacy.
# Set explicitly at both ends: a run that dies half way must not change what the
# next script sees, and a previous run must not decide what this one tests.
set_new_ui() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    adb_ shell "run-as $PKG sh -c 'if grep -q name=\"use_new_ui\" $PREFS; then sed -i \"s#name=\\\"use_new_ui\\\" value=\\\"[^\\\"]*\\\"#name=\\\"use_new_ui\\\" value=\\\"$1\\\"#\" $PREFS; else sed -i \"s#</map>#    <boolean name=\\\"use_new_ui\\\" value=\\\"$1\\\" />\\n</map>#\" $PREFS; fi'" >/dev/null 2>&1
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    sleep 1
}

cleanup() {
    set_new_ui true
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
}
trap cleanup EXIT

# A first launch can sit behind the SMS-role or phone-permission dialog.
dismiss_dialogs() {
    local i
    for i in 1 2 3 4; do
        dump_ui >/dev/null 2>&1 || return 0
        if grep -q 'text="ALLOW"' "$TMP/ui.xml"; then
            tap_text "ALLOW" >/dev/null 2>&1
        elif grep -q 'text="Not now"' "$TMP/ui.xml"; then
            tap_text "Not now" >/dev/null 2>&1
        else
            return 0
        fi
        sleep 1.5
    done
}

# Taps the clickable row carrying a label. The label's own centre lands between
# rows at the bottom of a settings list, under the navigation inset, so the
# enclosing clickable node is what gets tapped.
tap_row() {
    local label="$1" c
    dump_ui >/dev/null 2>&1 || return 1
    c=$(python3 - "$TMP/ui.decoded.xml" "$label" <<'PY'
import re, sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
label = sys.argv[2]

def center(node):
    m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", node.get("bounds", ""))
    if not m:
        return None
    return ((int(m.group(1)) + int(m.group(3))) // 2,
            (int(m.group(2)) + int(m.group(4))) // 2)

def walk(node):
    for child in node:
        text = (child.get("text") or child.get("content-desc") or "")
        if text == label or text.startswith(label):
            holder = child
            if holder.get("clickable") != "true":
                holder = node if node.get("clickable") == "true" else None
            point = center(holder) if holder is not None else None
            if point:
                return point
        found = walk(child)
        if found:
            return found
    return None

point = walk(root)
if not point:
    sys.exit(1)
print(point[0], point[1])
PY
    ) || return 1
    adb_ shell input tap $c >/dev/null 2>&1
    return 0
}

open_settings() {
    adb_ shell am force-stop "$PKG"; sleep 1
    adb_ shell logcat -c >/dev/null 2>&1
    adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null 2>&1; sleep 4
    dismiss_dialogs
    # A dump can be lost to uiautomator's segfault; retry rather than assert on
    # a stale file, which is how a wrong-screen dump once looked like a pass.
    local i
    for i in 1 2 3; do
        dump_ui >/dev/null 2>&1 && return 0
        sleep 1
    done
    bad "settings did not open"
    return 1
}

# Scrolls down until a row is on screen. A fixed number of swipes was not
# enough for the bottom of this list, which is exactly where About lives.
scroll_to_row() {
    local label="$1" tries="${2:-14}" i
    for ((i = 1; i <= tries; i++)); do
        if dump_ui >/dev/null 2>&1 && python3 - "$TMP/ui.decoded.xml" "$label" <<'PY'
import re, sys
import xml.etree.ElementTree as ET

label = sys.argv[2]
root = ET.parse(sys.argv[1]).getroot()
found = any(
    (node.get("text") or "").startswith(label) for node in root.iter("node")
)
sys.exit(0 if found else 1)
PY
        then
            return 0
        fi
        adb_ shell input swipe 540 1700 540 800 300 >/dev/null 2>&1
        sleep 0.7
    done
    return 1
}

open_settings_row() {
    local label="$1"
    open_settings || return 1
    scroll_to_row "$label" || { bad "the $label row was never on screen"; return 1; }
    tap_row "$label"
}

# Top edge of a label, for comparing where the list was before and after.
label_y() {
    local label="$1"
    python3 - "$TMP/ui.decoded.xml" "$label" <<'PTY'
import re, sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
label = sys.argv[2]
for node in root.iter("node"):
    if (node.get("text") or "") == label:
        m = re.match(r"\[(\d+),(\d+)\]", node.get("bounds", ""))
        if m:
            print(m.group(2))
            break
PTY
}

info "Settings ends with a rounded About row, not a version footer"
set_new_ui true
open_settings || exit 1
scroll_to_row "About" || true

grep -q 'text="About"' "$TMP/ui.xml" \
    && ok "the About row is in Settings" \
    || bad "no About row in Settings"

if grep -qF "Messages 1.0 - offline SMS" "$TMP/ui.xml"; then
    bad "the old version footer is still on the screen"
else
    ok "the version footer is gone"
fi

# Row shapes come from the SettingsRowShape marker, the same way the settings
# sheet colour is asserted.
SHAPES=$(adb_ shell logcat -d -s SettingsRowShape 2>/dev/null | tr -d '\r')
echo "$SHAPES" | grep -q "title=About position=LAST" \
    && ok "About carries the rounded bottom edge" \
    || bad "About is not LAST (no rounded bottom)"
echo "$SHAPES" | grep -q "title=Advanced settings position=MIDDLE" \
    && ok "Advanced gave up the rounded edge" \
    || bad "Advanced still claims a rounded edge"

# About must sit below Advanced: compare the two label centres.
BELOW=$(python3 - "$TMP/ui.decoded.xml" <<'PY'
import re, sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
ys = {}
for node in root.iter("node"):
    text = node.get("text") or ""
    if text in ("About", "Advanced settings") and text not in ys:
        m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", node.get("bounds", ""))
        if m:
            ys[text] = (int(m.group(2)) + int(m.group(4))) // 2
if "About" in ys and "Advanced settings" in ys and ys["About"] > ys["Advanced settings"]:
    print("yes")
PY
)
[ "$BELOW" = "yes" ] && ok "About is rendered after Advanced" \
    || bad "About is not below Advanced (or not both on screen)"

info "The About screen shows what it promises"
if open_settings_row "About" && sleep 1 && dump_ui >/dev/null 2>&1 \
    && grep -q 'text="Star on GitHub"' "$TMP/ui.xml"; then
    ok "the About row opens the About screen"

    grep -q 'text="Version 1\.0\.' "$TMP/ui.xml" \
        && ok "the build version is shown" \
        || bad "no version line on the About screen"
    for label in "Star on GitHub" "Report an issue" "Share Messages" "Open-source licences"; do
        grep -qF -- "text=\"$label\"" "$TMP/ui.xml" \
            && ok "row: $label" \
            || bad "missing row: $label"
    done
    grep -q "Developed by an1ndra" "$TMP/ui.xml" \
        && ok "the developer is credited" \
        || bad "no developer credit"

    # The icon's size has no text equivalent, so the screen publishes it.
    ICON=$(adb_ shell logcat -d -s AboutIcon 2>/dev/null | tr -d '\r' \
        | grep -o 'plate=[0-9.]*dp glyph=[0-9.]*dp' | tail -1)
    [ -n "$ICON" ] && ok "the launcher icon reports its size ($ICON)" \
        || bad "the About screen never reported the icon size"
    case "$ICON" in
        plate=136*dp*) ok "the icon is hero-sized (136dp plate)" ;;
        *) bad "the icon is a thumbnail again ($ICON)" ;;
    esac
else
    bad "the About row did not open the About screen"
fi

info "Coming back from About leaves the list where it was"
open_settings || true
scroll_to_row "About" || true
before_y=$(label_y "About")
if tap_row "About"; then
    sleep 2
    adb_ shell input keyevent 4 >/dev/null 2>&1; sleep 4
    dump_ui >/dev/null 2>&1 || true
    after_y=$(label_y "About")
    if [ -z "$before_y" ] || [ -z "$after_y" ]; then
        bad "could not measure the list position (before=$before_y after=$after_y)"
    else
        delta=$((before_y - after_y))
        [ "$delta" -lt 0 ] && delta=$((-delta))
        if [ "$delta" -le 8 ]; then
            ok "the list stayed put ($before_y -> $after_y)"
        else
            bad "the list moved when coming back ($before_y -> $after_y)"
        fi
    fi
else
    bad "could not reopen About for the scroll check"
fi

info "Report an issue asks before attaching anything"
# The scroll round trip above ends on the settings list, so come back first.
open_settings_row "About" || true
if tap_row "Report an issue"; then
    sleep 1.5
    dump_ui >/dev/null 2>&1 || true
    grep -q 'text="Open with diagnostics"' "$TMP/ui.xml" \
        && ok "the dialog offers diagnostics" \
        || bad "the issue dialog did not open"
    grep -q 'text="Open without"' "$TMP/ui.xml" \
        && ok "and offers to go without them" \
        || bad "no 'Open without' option"
    adb_ shell input keyevent 4 >/dev/null 2>&1; sleep 1
else
    bad "could not tap Report an issue"
fi

info "Share Messages reaches the share sheet"
if tap_row "Share Messages"; then
    sleep 2
    dump_ui >/dev/null 2>&1 || true
    if grep -qi "share with\|Share via" "$TMP/ui.xml" \
        || adb_ shell dumpsys activity activities 2>/dev/null | tr -d '\r' | grep -qi "ChooserActivity"; then
        ok "the system share sheet opened"
    else
        bad "no share sheet after tapping Share Messages"
    fi
    SHARE=$(adb_ shell logcat -d -s AboutAction 2>/dev/null | tr -d '\r' | grep -o 'share .*' | tail -1)
    case "$SHARE" in
        *release=true*fdroid=true*) ok "the share text carries both the release and F-Droid links" ;;
        *) bad "the share text is missing a download link ($SHARE)" ;;
    esac
    adb_ shell input keyevent 4 >/dev/null 2>&1; sleep 1
else
    bad "could not tap Share Messages"
fi

info "Star on GitHub opens the project page"
if tap_row "Star on GitHub"; then
    sleep 4
    if adb_ shell logcat -d -s AboutAction 2>/dev/null | tr -d '\r' \
        | grep -q "open https://github.com/an1ndra/Messages$"; then
        ok "the star row opened the repository"
    else
        bad "the star row did not open the repository"
    fi
    # Brave (or any browser) is in front now; going back keeps the walk honest.
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
else
    bad "could not tap Star on GitHub"
fi

info "The legacy surface carries the same row"
set_new_ui false
open_settings || true
if scroll_to_row "About"; then
    ok "the legacy sheet lists About too"
    ICON=$(adb_ shell logcat -d -s AboutIcon 2>/dev/null | tr -d '\r' \
        | grep -o 'plate=[0-9]*dp' | tail -1)
    if tap_row "About"; then
        sleep 2
        dump_ui >/dev/null 2>&1 || true
        grep -q 'text="Star on GitHub"' "$TMP/ui.xml" \
            && ok "the legacy row opens the same About screen" \
            || bad "the legacy row opened nothing"
    fi
else
    bad "the legacy sheet has no About row"
fi
grep -qF "Messages 1.0 - offline SMS" "$TMP/ui.xml" \
    && bad "the legacy sheet still prints the version footer" \
    || ok "the legacy footer is gone as well"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
exit $((FAIL > 0))
