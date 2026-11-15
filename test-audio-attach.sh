#!/usr/bin/env bash
# Issue #481: the attach sheet offers an audio file, and the entry opens the
# document picker — the photo picker cannot return audio, so it has to be
# DocumentsUI that comes up.
#
#   bash scripts/test-audio-attach.sh
set -uo pipefail
cd "$(dirname "$0")"
source ./env.sh

PASS=0
FAIL=0
ok()   { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad()  { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

center_of() { # text or content-desc
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

audio_label=$(res_string chat_media_audio)

info "Open a chat and the attach sheet"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1
adb_ shell am start -n "$ACT" >/dev/null 2>&1
sleep 5
# First conversation row: the app imports the provider on first launch, so one
# exists even on a fresh install.
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
if [ -z "$row" ]; then bad "no conversation to open"; echo "  PASS=$PASS FAIL=$FAIL"; exit 1; fi
adb_ shell input tap ${row% *} ${row#* }; sleep 3

attach=$(center_of "Attach" || center_of "Add attachment" || true)
if [ -z "$attach" ]; then
    # fall back to the leftmost of the composer's trailing controls
    attach=$(python3 - "$TMP/ui.xml" <<'PY'
import re, sys
xml = open(sys.argv[1]).read()
xs = []
for m in re.finditer(r'<node[^>]*clickable="true"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', xml):
    x1, y1, x2, y2 = map(int, m.groups())
    if y1 > 2000:
        xs.append(((x1 + x2) // 2, (y1 + y2) // 2))
print(*min(xs) if xs else "", sep=" ")
PY
)
fi
[ -n "$attach" ] && adb_ shell input tap ${attach% *} ${attach#* } && sleep 2 || bad "attach button not found"

info "The sheet offers Audio"
if dump_ui >/dev/null && grep -q "text=\"$audio_label\"" "$TMP/ui.decoded.xml"; then
    ok "attach sheet lists '$audio_label'"
else
    bad "attach sheet has no '$audio_label' entry"
fi

info "Tapping it opens the document picker"
audio=$(center_of "$audio_label" || true)
if [ -n "$audio" ]; then
    adb_ shell input tap ${audio% *} ${audio#* }; sleep 3
    focus=$(adb_ shell dumpsys window | grep -m1 mCurrentFocus)
    case "$focus" in
        *documentsui*|*DocumentsUI*) ok "DocumentsUI came up, not the photo picker" ;;
        *) bad "unexpected foreground: $focus" ;;
    esac
    adb_ shell input keyevent KEYCODE_BACK >/dev/null 2>&1
else
    bad "no audio row to tap"
fi

adb_ shell am force-stop "$PKG" >/dev/null 2>&1

info "Result"
echo "  PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && echo "=== OK ===" || echo "=== FAILED ==="
exit $((FAIL > 0))
