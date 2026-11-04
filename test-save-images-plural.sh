#!/usr/bin/env bash
# Regression for #398: with several pictures selected the toolbar offered
# "Save image", even though Save writes every selected picture. It must read
# "Save images" once more than one is selected, and stay singular for one.
source "$(dirname "$0")/env.sh"
set -uo pipefail

PASS=0
FAIL=0
ok()  { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
info() { printf '\n=== %s ===\n' "$*"; }

NUM="+15559873981"
TK="S398$(date +%s)"
NOW=$(date +%s)
DB="databases/messages.db"
IMG_A="file:///data/user/0/$PKG/files/save-images-a.png"
IMG_B="file:///data/user/0/$PKG/files/save-images-b.png"

local_query() { adb_ shell "run-as '$PKG' sqlite3 $DB \"$1\"" 2>/dev/null | tr -d '\r'; }

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    local_query "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM');" >/dev/null 2>&1
    local_query "DELETE FROM conversations WHERE address='$NUM';" >/dev/null 2>&1
    adb_ shell "run-as '$PKG' rm -f files/save-images-a.png files/save-images-b.png" >/dev/null 2>&1
}
trap cleanup EXIT

make_png() {
    python3 - "$1" <<'PY'
import struct, sys, zlib
w = h = 96
row = b'\x00' + b'\x33\x66\x99' * w
raw = row * h
def chunk(kind, data):
    return (struct.pack('>I', len(data)) + kind + data +
            struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff))
png = (b'\x89PNG\r\n\x1a\n' +
       chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) +
       chunk(b'IDAT', zlib.compress(raw)) +
       chunk(b'IEND', b''))
open(sys.argv[1], 'wb').write(png)
PY
}

seed() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    local_query "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM');" >/dev/null
    local_query "DELETE FROM conversations WHERE address='$NUM';" >/dev/null
    local_query "INSERT INTO conversations(address,name,snippet,timestamp) VALUES('$NUM','$TK','$TK',${NOW}000);" >/dev/null
    local cid
    cid=$(local_query "SELECT id FROM conversations WHERE address='$NUM' ORDER BY id DESC LIMIT 1;")
    [ -z "$cid" ] && return 1
    local_query "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,media_type,media_uri) VALUES($cid,'$TK a',${NOW}000,0,'received','image','$IMG_A');" >/dev/null
    local_query "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,media_type,media_uri) VALUES($cid,'$TK b',$((NOW + 1))000,0,'received','image','$IMG_B');" >/dev/null
    local n
    n=$(local_query "SELECT COUNT(*) FROM messages WHERE conversation_id=$cid AND media_uri<>'';")
    [ "${n:-0}" = "2" ]
}

# The two picture bubbles, top to bottom, as "x y" centres.
photo_centres() {
    dump_ui >/dev/null 2>&1 || return 1
    python3 - "$TMP/ui.decoded.xml" <<'PY'
import re, sys
data = open(sys.argv[1], encoding='utf-8', errors='replace').read()
pts = []
for m in re.finditer(r'content-desc="Photo"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', data):
    x1, y1, x2, y2 = map(int, m.groups())
    pts.append((x1 + (x2 - x1) // 2, y1 + (y2 - y1) // 2))
for x, y in sorted(pts, key=lambda p: p[1]):
    print(x, y)
PY
}

open_overflow() {
    local i
    for i in 1 2 3; do
        tap_text "More options" >/dev/null 2>&1 || true
        sleep 1
        dump_ui >/dev/null 2>&1 || continue
        grep -qF 'text="Select all"' "$TMP/ui.xml" && return 0
    done
    return 1
}

has_text() {
    dump_ui >/dev/null 2>&1 || return 1
    grep -qF "text=\"$1\"" "$TMP/ui.xml"
}

info "Hold the default SMS role"
adb_su "cmd role add-role-holder android.app.role.SMS $PKG" >/dev/null 2>&1

LOC=$(adb_ shell getprop persist.sys.locale | tr -d '\r')
case "$LOC" in
    en*) : ;;
    *) printf 'device locale is %s; this script matches English labels — set persist.sys.locale to en-US first\n' "$LOC"
       exit 1 ;;
esac

info "Seed two picture messages"
make_png "$TMP/s398-a.png"
make_png "$TMP/s398-b.png"
adb_ push "$TMP/s398-a.png" /data/local/tmp/s398-a.png >/dev/null 2>&1
adb_ push "$TMP/s398-b.png" /data/local/tmp/s398-b.png >/dev/null 2>&1
adb_ shell "run-as '$PKG' sh -c 'mkdir -p files; cat /data/local/tmp/s398-a.png > files/save-images-a.png; cat /data/local/tmp/s398-b.png > files/save-images-b.png'" >/dev/null 2>&1
if seed; then
    ok "seeded two picture messages"
else
    bad "could not seed two picture messages"
    printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
    exit $((FAIL > 0))
fi

adb_ shell am force-stop "$PKG" >/dev/null
sleep 1
adb_ shell am start -n "$ACT" --es open_conversation_address "$NUM" >/dev/null 2>&1
sleep 5

PTS=()
for _ in 1 2 3 4 5 6; do
    mapfile -t PTS < <(photo_centres 2>/dev/null || true)
    [ "${#PTS[@]}" -ge 2 ] && break
    sleep 2
done
if [ "${#PTS[@]}" -ge 2 ]; then
    ok "the chat draws both picture bubbles"
else
    bad "the chat draws both picture bubbles (found ${#PTS[@]})"
    printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
    exit $((FAIL > 0))
fi
X1=${PTS[0]% *}; Y1=${PTS[0]#* }
X2=${PTS[1]% *}; Y2=${PTS[1]#* }

info "One selected picture keeps the singular label"
adb_ shell input swipe "$X1" "$Y1" "$X1" "$Y1" 900 >/dev/null 2>&1
sleep 1.5
has_text "1" && ok "long-press selects the first picture" || bad "long-press did not select the first picture"
if open_overflow; then
    has_text "Save image" && ok "one picture offers 'Save image'" || bad "one picture does not offer 'Save image'"
    has_text "Save images" && bad "one picture offers the plural label" || ok "one picture does not offer the plural label"
else
    bad "the selection overflow did not open"
    bad "one picture does not offer 'Save image'"
    bad "one picture does not offer the plural label"
fi

info "Two selected pictures offer the plural label"
adb_ shell input keyevent 4 >/dev/null 2>&1
sleep 1
adb_ shell input tap "$X2" "$Y2" >/dev/null 2>&1
sleep 1.5
has_text "2" && ok "tapping the second picture selects it" || bad "tapping the second picture did not select it"
if open_overflow; then
    has_text "Save images" && ok "two pictures offer 'Save images'" || bad "two pictures do not offer 'Save images'"
    has_text "Save image" && bad "two pictures still offer the singular label" || ok "two pictures do not offer the singular label"
else
    bad "the selection overflow did not open again"
    bad "two pictures do not offer 'Save images'"
    bad "two pictures do not offer the singular label"
fi

printf '\nPASS=%s FAIL=%s\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
