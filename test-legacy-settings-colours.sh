#!/usr/bin/env bash
# Regression: every legacy settings screen paints the same sheet.
#
# Reported: "in old UI General settings and Advanced setting background colour is
# different". Only General set the Scaffold's containerColor to the settings
# sheet; Advanced (and Accessibility, one tap deeper) fell back to the theme
# background, so opening Advanced changed the page colour under the rows.
#
# A page colour is a pixel, so the screens report it themselves
# (ReportSheetColors -> logcat "SettingsColors") and this script compares the two
# screens instead of taking screenshots. Before the fix no colour was reported at
# all, and the assertion fails.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

PREFS="shared_prefs/messages_settings.xml"

set_new_ui() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    adb_ shell "run-as $PKG sh -c \"if grep -q name=\\\"use_new_ui\\\" $PREFS; then sed -i \\\"s#name=\\\\\\\"use_new_ui\\\\\\\" value=\\\\\\\"[^\\\\\\\"]*\\\\\\\"#name=\\\\\\\"use_new_ui\\\\\\\" value=\\\\\\\"$1\\\\\\\"#\\\" $PREFS; else sed -i \\\"s#</map>#    <boolean name=\\\\\\\"use_new_ui\\\\\\\" value=\\\\\\\"$1\\\\\\\" />\\\\n</map>#\\\" $PREFS; fi\"" >/dev/null 2>&1
    sleep 1
}

# Taps the clickable row carrying a label: the last row in a settings list sits
# under the navigation inset, where the label's own centre is between rows.
tap_row() {
    local label="$1" c
    dump_ui >/dev/null 2>&1 || return 1
    c=$(python3 - "$TMP/ui.decoded.xml" "$label" <<'PY'
import re, sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
label = sys.argv[2]
parents = {}
for parent in root.iter():
    for child in parent:
        parents[child] = parent


def center(node):
    m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", node.get("bounds", ""))
    if not m:
        return None
    return ((int(m.group(1)) + int(m.group(3))) // 2,
            (int(m.group(2)) + int(m.group(4))) // 2)


for node in root.iter("node"):
    text = node.get("text") or node.get("content-desc") or ""
    if text != label and not text.startswith(label):
        continue
    holder = node
    while holder is not None and holder.get("clickable") != "true":
        holder = parents.get(holder)
    point = center(holder if holder is not None else node)
    if point:
        print(point[0], point[1])
        sys.exit(0)
sys.exit(1)
PY
    ) || return 1
    adb_ shell input tap $c >/dev/null 2>&1
}

page_of() {   # page_of <screen> -> #RRGGBB, or empty
    adb_ logcat -d -s SettingsColors 2>/dev/null | tr -d '\r' \
        | grep "screen=$1 " | tail -1 | sed -E 's/.*page=(#[0-9A-F]{6}).*/\1/'
}

cleanup() { set_new_ui true; }
trap cleanup EXIT

adb_ root >/dev/null 2>&1; sleep 1
set_new_ui false

info "General settings report their page colour"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
adb_ shell logcat -c >/dev/null 2>&1
adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null 2>&1; sleep 4
dump_ui >/dev/null 2>&1 || true
GENERAL=$(page_of general)
if [ -n "$GENERAL" ]; then ok "general reports page=$GENERAL"; else bad "no colour reported by general settings"; fi

info "Advanced settings report the same one"
adb_ shell input swipe 540 1700 540 800 400 >/dev/null 2>&1; sleep 0.6
adb_ shell input swipe 540 1700 540 800 400 >/dev/null 2>&1; sleep 1
for i in 1 2 3 4 5 6 7 8; do
    dump_ui >/dev/null 2>&1 || true
    if tap_row "Advanced settings"; then break; fi
    adb_ shell input swipe 540 1700 540 800 400 >/dev/null 2>&1; sleep 0.6
done
sleep 2.5
dump_ui >/dev/null 2>&1 || true
ADVANCED=$(page_of advanced)
if [ -n "$ADVANCED" ]; then ok "advanced reports page=$ADVANCED"; else bad "no colour reported by advanced settings"; fi

info "The two pages match"
if [ -n "$GENERAL" ] && [ "$GENERAL" = "$ADVANCED" ]; then
    ok "general and advanced paint the same sheet ($GENERAL)"
else
    bad "sheet differs: general=$GENERAL advanced=$ADVANCED"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
exit $((FAIL > 0))
