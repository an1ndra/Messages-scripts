#!/usr/bin/env bash
# Regression for #331: the legacy "Swipe actions" master switch must toggle.
#
# It used to be hardcoded on — SettingsStore.swipeActionsEnabled had
# `get() = true` — so the switch read as always checked and its writes were
# ignored: the per-direction actions (the real source of truth) never changed,
# and swiping stayed on. It is now derived from, and written back as, that pair:
# off => both directions OFF, on => archive/delete (honouring legacy reverse).
source "$(dirname "$0")/env.sh"

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

PREFS="/data/data/$PKG/shared_prefs/messages_settings.xml"

prefs() { adb_ shell "run-as $PKG cat $PREFS 2>/dev/null" | tr -d '\r'; }

stored() { prefs | grep -oE "name=\"$1\" value=\"[0-9]+\"" | grep -oE '[0-9]+' | tail -1; }

# The switch only reads correctly in the legacy (redesigned-interface-off)
# settings screen, which is also where #331 was reported.
ensure_legacy_ui() {
    adb_ shell am force-stop "$PKG"; sleep 1
    if prefs | grep -q 'name="use_new_ui" value="true"'; then
        prefs | sed 's|name="use_new_ui" value="true"|name="use_new_ui" value="false"|' > "$TMP/prefs-legacy.xml"
        adb_ shell "run-as $PKG sh -c 'cat > $PREFS'" < "$TMP/prefs-legacy.xml" >/dev/null 2>&1
    fi
}

open_legacy_settings() {
    adb_ shell am force-stop "$PKG"; sleep 1
    adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null; sleep 4
    dump_ui >/dev/null
}

# The "Swipe actions" row is the last one and its switch sits under the gesture
# inset on 1080x2400, so a tap on the label centre lands in the nav bar. Find the
# switch's own bounds and tap just under its top edge, which clears the inset.
# Prints "x y checked", or "NONE".
swipe_switch() {
    python3 - "$TMP/ui.xml" <<'PY'
import re, sys
xml = open(sys.argv[1], encoding="utf-8").read()
text = None
for tag in re.findall(r'<node[^>]*>', xml):
    t = re.search(r'text="([^"]*)"', tag)
    b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', tag)
    if t and t.group(1) == "Swipe actions" and b:
        text = (int(b.group(1)), int(b.group(2)), int(b.group(3)), int(b.group(4)))
switch = None
for tag in re.findall(r'<node[^>]*>', xml):
    ck = re.search(r'checked="([^"]*)"', tag)
    chk = re.search(r'checkable="true"', tag)
    b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', tag)
    if ck and chk and b and text and int(b.group(2)) <= text[3] and int(b.group(4)) >= text[1]:
        switch = (int(b.group(1)), int(b.group(2)), int(b.group(3)), int(b.group(4)), ck.group(1))
if text is None or switch is None:
    print("NONE")
else:
    print(f"{(switch[0] + switch[2]) // 2} {switch[1] + 8} {switch[4]}")
PY
}

relocate() { dump_ui >/dev/null; swipe_switch; }

info "=== Legacy settings: the swipe master switch is present ==="
ensure_legacy_ui
open_legacy_settings

read -r SX SY S1 <<<"$(swipe_switch)"
if [ "$SX" = "NONE" ]; then
    fail "no 'Swipe actions' switch on the legacy settings screen"
    echo
    exit 1
fi
pass "found the 'Swipe actions' switch (checked=$S1)"

# Normalise to on first, so the test does not depend on the entry state.
if [ "$S1" != "true" ]; then
    adb_ shell input tap "$SX" "$SY"; sleep 2
    open_legacy_settings
    read -r SX SY S1 <<<"$(swipe_switch)"
fi
[ "$S1" = "true" ] && pass "switch starts enabled" || fail "switch did not start enabled (checked=$S1)"

info "=== Turn it off: the switch flips and both directions go OFF ==="
adb_ shell input tap "$SX" "$SY"; sleep 2
read -r _ _ S2 <<<"$(relocate)"
LEFT=$(stored swipe_left_action); RIGHT=$(stored swipe_right_action)
[ "$S2" = "false" ] && pass "switch reads unchecked after the tap" \
    || fail "switch still checked after the tap (#331: get() was hardcoded true)"
if [ "$LEFT" = "0" ] && [ "$RIGHT" = "0" ]; then
    pass "both directions set to OFF (stored $LEFT/$RIGHT)"
else
    fail "directions not disabled (stored '${LEFT:-none}'/'${RIGHT:-none}')"
fi

info "=== Turn it back on: archive/delete is restored ==="
read -r SX SY S3 <<<"$(relocate)"
adb_ shell input tap "$SX" "$SY"; sleep 2
read -r _ _ S4 <<<"$(relocate)"
LEFT=$(stored swipe_left_action); RIGHT=$(stored swipe_right_action)
[ "$S4" = "true" ] && pass "switch reads checked again" || fail "switch did not return to checked"
if [ "$LEFT" = "1" ] && [ "$RIGHT" = "2" ]; then
    pass "directions restored to archive/delete (stored $LEFT/$RIGHT)"
else
    fail "directions not restored (stored '${LEFT:-none}'/'${RIGHT:-none}')"
fi

echo
if [ "$FAIL" = 0 ]; then
    echo "ALL SWIPE MASTER TOGGLE TESTS PASSED"
else
    echo "SOME SWIPE MASTER TOGGLE TESTS FAILED"
    exit 1
fi
