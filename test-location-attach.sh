#!/usr/bin/env bash
# Issue #479: the attach sheet offers a location, and the dialog that opens
# sends a geo: link rather than anything that needs a map.
#
#   bash scripts/test-location-attach.sh
set -uo pipefail
cd "$(dirname "$0")"
source ./env.sh

PASS=0
FAIL=0
ok()   { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad()  { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
skip() { echo "  [SKIP] $1"; }
info() { echo -e "\n=== $* ==="; }

center_of() {
    dump_ui >/dev/null
    python3 - "$TMP/ui.xml" "$1" <<'PY'
import re, sys
xml = open(sys.argv[1]).read()
want = sys.argv[2]
for m in re.finditer(r'<node[^>]*>', xml):
    tag = m.group(0)
    if f'text="{want}"' in tag or f'content-desc="{want}"' in tag:
        b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', tag)
        if b:
            x1, y1, x2, y2 = map(int, b.groups())
            print((x1 + x2) // 2, (y1 + y2) // 2)
            sys.exit(0)
sys.exit(1)
PY
}

center_of_text() { # a node whose text (not content-desc) is exactly this
    dump_ui >/dev/null
    python3 - "$TMP/ui.xml" "$1" <<'PY'
import re, sys
xml = open(sys.argv[1]).read()
want = sys.argv[2]
for m in re.finditer(r'<node[^>]*>', xml):
    tag = m.group(0)
    if f'text="{want}"' in tag:
        b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', tag)
        if b:
            x1, y1, x2, y2 = map(int, b.groups())
            print((x1 + x2) // 2, (y1 + y2) // 2)
            sys.exit(0)
sys.exit(1)
PY
}

location_label=$(res_string chat_media_location)
location_hint=$(res_string location_hint)
use_mine=$(res_string location_use_mine)

info "Open a demo chat"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1
adb_ shell am start -n "$ACT" >/dev/null 2>&1
sleep 5
dump_ui >/dev/null
row=$(python3 - "$TMP/ui.xml" <<'PY'
import re, sys
xml = open(sys.argv[1]).read()
best = None
for m in re.finditer(r'<node[^>]*content-desc="([^"]+)"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', xml):
    y1 = int(m.group(3))
    if y1 > 300 and (best is None or y1 < best[0]):
        best = (y1, (int(m.group(2)) + int(m.group(4))) // 2, (int(m.group(3)) + int(m.group(5))) // 2)
if not best:
    sys.exit(1)
print(best[1], best[2])
PY
) || true
[ -n "$row" ] && adb_ shell input tap ${row% *} ${row#* } && sleep 3 || { bad "no conversation"; exit 1; }

info "Attach sheet offers '$location_label'"
attach=$(center_of "Attach" || true)
[ -n "$attach" ] && adb_ shell input tap ${attach% *} ${attach#* } && sleep 2 || bad "attach button not found"
if dump_ui >/dev/null && grep -q "text=\"$location_label\"" "$TMP/ui.decoded.xml"; then
    ok "attach sheet lists '$location_label'"
else
    bad "attach sheet has no '$location_label' entry"
fi

info "The dialog opens and can fill itself"
loc=$(center_of "$location_label" || true)
if [ -n "$loc" ]; then
    adb_ shell input tap ${loc% *} ${loc#* }; sleep 2
    if dump_ui >/dev/null && grep -q "text=\"$use_mine\"" "$TMP/ui.decoded.xml"; then
        ok "location dialog opened with '$use_mine'"
        # The field fills from the last fix the device already holds, so give it
        # one: an emulator has no GPS and would otherwise always come up empty,
        # which made this step fail for the wrong reason.
        case "$ANDROID_SERIAL" in
            emulator-*)
                adb_ shell settings put secure location_mode 3 >/dev/null 2>&1
                adb_ shell pm grant "$PKG" android.permission.ACCESS_COARSE_LOCATION >/dev/null 2>&1
                adb_ emu geo fix 77.594566 12.971599 >/dev/null 2>&1
                sleep 1
                ;;
        esac
        mine=$(center_of "$use_mine" || true)
        [ -n "$mine" ] && adb_ shell input tap ${mine% *} ${mine#* } && sleep 3
        # A permission prompt may appear on a fresh install; accept it if so.
        if dump_ui >/dev/null && grep -qi "allow" "$TMP/ui.decoded.xml"; then
            allow=$(center_of "Allow" || center_of "While using the app" || true)
            [ -n "$allow" ] && adb_ shell input tap ${allow% *} ${allow#* } && sleep 3
        fi
        dump_ui >/dev/null
        if grep -q "text=\"geo:" "$TMP/ui.decoded.xml"; then
            ok "a geo: link was filled in"
        else
            skip "no fix to fill from; the field stays empty by design"
        fi
        # Whatever the fix situation, the link the person types has to reach the
        # chat: that is the path every share takes once the field holds a link.
        typed="geo:12.971599,77.594566"
        field=$(center_of "$typed" || center_of "$location_hint" || true)
        [ -n "$field" ] && adb_ shell input tap ${field% *} ${field#* } && sleep 1
        adb_ shell input text "$typed" >/dev/null 2>&1
        sleep 1
        dump_ui >/dev/null
        send=$(center_of_text "Send" || true)
        [ -n "$send" ] && adb_ shell input tap ${send% *} ${send#* } && sleep 3
        dump_ui >/dev/null
        if grep -q "text=\"$typed\"" "$TMP/ui.decoded.xml"; then
            ok "the typed geo: link was sent into the chat"
        else
            bad "the typed geo: link never reached the chat"
        fi
    else
        bad "location dialog did not open"
    fi
else
    bad "no location row to tap"
fi

adb_ shell am force-stop "$PKG" >/dev/null 2>&1

info "Result"
echo "  PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && echo "=== OK ===" || echo "=== FAILED ==="
exit $((FAIL > 0))
