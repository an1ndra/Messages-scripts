#!/usr/bin/env bash
# Regression: the MMS support page uses the same SettingsRow cards as Advanced
# settings, and its footer says the check is not a guarantee.
#
# Padding and corner radii are pixels, so the app publishes each row's shape as
# text (the SettingsRowShape logcat marker) and this script asserts on logcat
# instead of a screenshot. The old page used a custom MmsCardRow inside one
# hairline-divided GroupedRowList: it emitted no shape marker at all and its
# footer was a long carrier/APN essay that claimed a declaration as the result.
#
# Run: scripts/test-mms-support-card.sh
set -uo pipefail
cd "$(dirname "$0")"
source ./env.sh

PASS=0
FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
[[ "$ANDROID_SERIAL" == emulator-* ]] || { printf 'Requires a disposable emulator.\n'; exit 1; }

PREFS="/data/data/$PKG/shared_prefs/messages_settings.xml"
BACKUP="$TMP/mms-support-card-settings.bak.xml"

adb_ shell "run-as $PKG cat $PREFS" > "$BACKUP" 2>/dev/null || true
restore() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    if [ -s "$BACKUP" ]; then
        adb_ shell "run-as $PKG sh -c 'cat > $PREFS'" < "$BACKUP" >/dev/null 2>&1 || true
    fi
}
trap restore EXIT

info "Enable the redesigned interface"
adb_ shell am force-stop "$PKG"
cat > "$TMP/mms-support-card-settings.xml" <<XML
<?xml version="1.0" encoding="utf-8" standalone="yes" ?>
<map>
    <boolean name="first_import_done" value="true" />
    <boolean name="use_new_ui" value="true" />
</map>
XML
adb_ shell "run-as $PKG sh -c 'cat > $PREFS'" < "$TMP/mms-support-card-settings.xml"

info "Open Advanced settings"
adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null
sleep 3
if scroll_to_layout "Advanced settings" && tap_layout "Advanced settings"; then
    pass "opened Advanced settings"
else
    fail "could not open Advanced settings"
fi
sleep 2

info "Open MMS support and capture its row shapes"
adb_ shell logcat -c >/dev/null 2>&1 || true
if scroll_to_layout "MMS support" && tap_layout "MMS support"; then
    pass "opened MMS support"
else
    fail "could not open MMS support"
fi
sleep 3
SHAPES=$(adb_ shell logcat -d -s SettingsRowShape:D 2>/dev/null || true)

FOOTER=$(res_string mms_check_footer)
if [[ "$FOOTER" == *"does not confirm"* && "$FOOTER" == *"never guaranteed"* && ${#FOOTER} -lt 250 ]]; then
    pass "footer says the check is not a guarantee"
else
    fail "footer still claims a confirmed result: $FOOTER"
fi
if scroll_to_layout "$FOOTER" && wait_layout_has "$FOOTER" 3; then
    pass "short footer is visible on the page"
else
    fail "the footer text is not on screen"
fi

info "Check the footer lines up with the carrier row text"
verdicts=()
for key in mms_check_verdict_supported mms_check_verdict_disabled \
    mms_check_verdict_no_carrier mms_check_verdict_unknown mms_check_no_sims; do
    value=$(res_string "$key")
    [ -n "$value" ] && verdicts+=("$value")
done
layout_json >/dev/null 2>&1 || true
read -r FOOTER_LEFT ROW_LEFT < <(python3 - "$TMP/layout.json" "$FOOTER" "${verdicts[@]}" <<'PY'
import json, re, sys

data = json.load(open(sys.argv[1]))
footer, refs = sys.argv[2], sys.argv[3:]

def walk(node):
    if isinstance(node, list):
        for child in node:
            yield from walk(child)
    elif isinstance(node, dict):
        yield node
        for key in ("content", "children"):
            for child in (node.get(key) or []):
                yield from walk(child)

def left_x(node):
    match = re.search(r"\[\s*(\d+)", node.get("bounds") or "")
    return int(match.group(1)) if match else -1

footer_left = row_left = -1
for node in walk(data):
    text = node.get("text") or ""
    if footer_left < 0 and footer in text:
        footer_left = left_x(node)
    if row_left < 0 and any(ref in text for ref in refs):
        row_left = left_x(node)
print(footer_left, row_left)
PY
)
if [[ "$FOOTER_LEFT" -ge 0 && "$FOOTER_LEFT" == "$ROW_LEFT" ]]; then
    pass "footer text starts at the same x as the carrier row text"
else
    fail "footer x=$FOOTER_LEFT, carrier row x=$ROW_LEFT"
fi

row_line() { printf '%s\n' "$SHAPES" | grep -F "title=$1 " | tail -1; }
line=$(row_line "MMS")
if [ -n "$line" ] &&
    printf '%s' "$line" | grep -qF "position=FIRST " &&
    printf '%s' "$line" | grep -qF "topStart=12.0 topEnd=12.0 bottomStart=4.0 bottomEnd=4.0"; then
    pass "the MMS switch is a FIRST SettingsRow with Advanced settings corners"
else
    fail "the MMS switch is not a FIRST SettingsRow: ${line:-no shape marker}"
fi

last=$(printf '%s\n' "$SHAPES" | grep -F "position=LAST " |
    grep -F "topStart=4.0 topEnd=4.0 bottomStart=12.0 bottomEnd=12.0" | tail -1)
if [ -n "$last" ] && ! printf '%s' "$last" | grep -qF "title=MMS "; then
    pass "a carrier/no-SIM row closes the group with LAST corners"
else
    fail "no LAST settings row below the switch: ${SHAPES:-no shape markers}"
fi

printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
exit $(( FAIL > 0 ))
