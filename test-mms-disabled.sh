#!/usr/bin/env bash
# With MMS switched off the app sends text only: the composer loses its attach
# button (and the tray behind it) and the emoji button takes that slot. Turning
# MMS back on brings the plus back.
#
# The setting is driven through the debug probe, which writes the same
# preference the switch writes — walking Settings → Advanced → MMS would make
# this a test of the settings tree, not of the composer.
#
# Run: scripts/test-mms-disabled.sh
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

ATTACH=$(res_string icon_attach)
EMOJI=$(res_string icon_emoji)
if [ -z "$ATTACH" ] || [ -z "$EMOJI" ]; then
    echo "  [FAIL] this build has no attach/emoji label"
    echo; echo "  PASS=0 FAIL=1"; echo "=== FAILED ==="; exit 1
fi

adb_su "cmd role add-role-holder android.app.role.SMS $PKG" >/dev/null 2>&1
cleanup() {
    # Leave the device with MMS on, whatever happened here. The probe is read in
    # onCreate, so the app has to be restarted for it to take effect.
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    adb_ shell am start -W -n "$ACT" --es mms_probe on >/dev/null 2>&1 || true
}
trap cleanup EXIT

# A failed dump must not leave the previous screen behind for ui_has to read.
fresh_dump() {
    rm -f "$TMP/ui.xml" "$TMP/ui.decoded.xml"
    for _ in 1 2 3; do
        dump_ui >/dev/null 2>&1 && [ -s "$TMP/ui.xml" ] && return 0
        sleep 0.5
    done
    return 1
}

open_first_chat() {
    fresh_dump || return 1
    row=$(python3 - "$TMP/ui.xml" <<'PY'
import re, sys
xml = open(sys.argv[1]).read()
best = None
for m in re.finditer(r'<node[^>]*content-desc="([^"]+)"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', xml):
    y1 = int(m.group(3))
    if y1 > 300 and (best is None or y1 < best[0]):
        best = (y1, (int(m.group(2)) + int(m.group(4))) // 2, (int(m.group(3)) + int(m.group(5))) // 2)
print(f"{best[1]} {best[2]}" if best else "")
PY
)
    [ -n "$row" ] || return 1
    adb_ shell input tap ${row% *} ${row#* }
    sleep 2
}

center_x_of() {
    python3 - "$TMP/ui.xml" "$1" <<'PY'
import re, sys
xml = open(sys.argv[1]).read()
want = sys.argv[2]
for m in re.finditer(r'<node[^>]*content-desc="' + re.escape(want) + r'"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', xml):
    x1, y1, x2, y2 = map(int, m.groups())
    print((x1 + x2) // 2)
    sys.exit(0)
sys.exit(1)
PY
}

info "MMS off: the plus is gone and the emoji button took its place"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1
adb_ shell am start -W -n "$ACT" --es mms_probe off >/dev/null 2>&1
sleep 3
if open_first_chat; then
    ok "the conversation opened"
else
    bad "no conversation to open"
fi
fresh_dump || true
if ui_has "$ATTACH"; then
    bad "the attach button is still there with MMS off"
else
    ok "no '$ATTACH' button with MMS off"
fi
if ui_has "$EMOJI"; then
    ok "the '$EMOJI' button is in the composer"
else
    bad "the composer has no '$EMOJI' button to take the plus's place"
fi
width=$(adb_ shell wm size | tr -d '\r' | sed -E 's/.*: ([0-9]+)x([0-9]+)/\1/')
ex=$(center_x_of "$EMOJI" || true)
if [ -n "$ex" ] && [ -n "$width" ] && [ "$ex" -lt $(( width / 2 )) ]; then
    ok "it sits where the plus was, at the start of the bar (${ex}px)"
else
    bad "the emoji button is not in the plus's slot (${ex:-?}px)"
fi

info "MMS on: the plus comes back"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1
adb_ shell am start -W -n "$ACT" --es mms_probe on >/dev/null 2>&1
sleep 3
open_first_chat || true
fresh_dump || true
if ui_has "$ATTACH"; then
    ok "the '$ATTACH' button is back"
else
    bad "no '$ATTACH' button with MMS on"
fi

echo
echo "  PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && echo "=== OK ===" || echo "=== FAILED ==="
exit $((FAIL > 0))
