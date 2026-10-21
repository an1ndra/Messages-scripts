#!/usr/bin/env bash
# Regression for #326: picking pictures from '+' -> Gallery sent them the moment
# the picker closed, so they could never be captioned or dropped. They must wait
# in the composer until Send.
#
# The gallery is multi-select (like Google Messages): several photos are chosen
# in one pass and confirmed with "Add (N)", and all of them stage together.
# Pictures are seeded into MediaStore so the system Photo Picker has tiles.
#
# The assertion is the outgoing-image rows in the DB: 0 while staged, 2 after
# Send — which is exactly the bug the report described.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

PRIMARY="+1555771030"
DB="/data/data/$PKG/databases/messages.db"
STAMP=$(date +%s)
IMG1="pending-media-a-$STAMP.png"
IMG2="pending-media-b-$STAMP.png"

sq() { adb_ shell "run-as $PKG sqlite3 $DB \"$1\"" 2>/dev/null | tr -d '\r'; }
outgoing_images() {
    sq "select count(*) from messages where is_me=1 and media_type='image'
        and conversation_id=(select id from conversations where address='$PRIMARY' limit 1);"
}

# Count distinct nodes whose text/content-desc equals $1 in the current layout.
layout_count() {
    layout_json || { echo 0; return; }
    python3 - "$TMP/layout.json" "$1" <<'PY'
import json, sys
data = json.load(open(sys.argv[1])); q = sys.argv[2]; centers = set()
def walk(x):
    if isinstance(x, list):
        for c in x: walk(c)
    elif isinstance(x, dict):
        for k in ("text", "content-desc", "contentDesc"):
            if x.get(k) == q:
                centers.add(x.get("center") or "")
        for k in ("content", "children"): walk(x.get(k) or [])
walk(data)
centers.discard("")
print(len(centers))
PY
}

# Distinct on-screen nodes whose content-desc starts with $1.
layout_count_prefix() {
    layout_json || { echo 0; return; }
    python3 - "$TMP/layout.json" "$1" <<'PY'
import json, sys
data = json.load(open(sys.argv[1])); q = sys.argv[2]; centers = set()
def walk(x):
    if isinstance(x, list):
        for c in x: walk(c)
    elif isinstance(x, dict):
        cd = x.get("content-desc") or x.get("contentDesc") or ""
        if cd.startswith(q): centers.add(x.get("center") or "")
        for k in ("content", "children"): walk(x.get(k) or [])
walk(data); centers.discard(""); print(len(centers))
PY
}

# Tap the first $1 photo tiles in the picker (grid order), de-duplicated.
tap_first_tiles() {
    local n="$1" coords
    coords=$(layout_json && python3 - "$TMP/layout.json" "$n" <<'PY'
import json, sys
data = json.load(open(sys.argv[1])); n = int(sys.argv[2]); tiles = []
def walk(x):
    if isinstance(x, list):
        for c in x: walk(c)
    elif isinstance(x, dict):
        cd = x.get("content-desc") or x.get("contentDesc") or ""
        if cd.startswith("Photo taken") and x.get("center"):
            tiles.append(x["center"])
        for k in ("content", "children"): walk(x.get(k) or [])
walk(data)
seen, uniq = set(), []
for c in tiles:
    if c not in seen:
        seen.add(c)
        uniq.append(c)
for c in uniq[:n]:
    print(c.strip("[]").replace(",", " "))
PY
)
    [ -z "$coords" ] && return 1
    while read -r x y; do
        [ -n "$x" ] || continue
        adb_ shell input tap "$x" "$y" < /dev/null && sleep 1.5
    done <<< "$coords"
    return 0
}

cleanup() {
    sq "delete from messages where conversation_id in
        (select id from conversations where address='$PRIMARY');" >/dev/null
    adb_ shell rm -f "/sdcard/Pictures/$IMG1" "/sdcard/Pictures/$IMG2" >/dev/null 2>&1
    close_picker
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
}

# The photo picker is a separate app; force-stopping the app under test leaves it
# on top of the next run.
close_picker() {
    adb_ shell am force-stop com.android.providers.media.module >/dev/null 2>&1
    adb_ shell am force-stop com.google.android.providers.media.module >/dev/null 2>&1
}
trap cleanup EXIT

for p in READ_SMS SEND_SMS POST_NOTIFICATIONS; do
    adb_ shell pm grant "$PKG" android.permission.$p 2>/dev/null
done

make_png() {  # path, r, g, b
    python3 - "$1" "$2" "$3" "$4" <<'PY'
import struct, sys, zlib
w = h = 240
col = bytes([int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])])
raw = (bytes([0]) + col * w) * h
def chunk(t, d):
    return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
png = b"\x89PNG\r\n\x1a\n"
png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(raw, 9))
png += chunk(b"IEND", b"")
open(sys.argv[1], "wb").write(png)
PY
}
make_png "$TMP/$IMG1" 220 40 40
make_png "$TMP/$IMG2" 40 40 220
adb_ shell mkdir -p /sdcard/Pictures >/dev/null 2>&1
adb_ push "$TMP/$IMG1" "/sdcard/Pictures/$IMG1" >/dev/null 2>&1
adb_ push "$TMP/$IMG2" "/sdcard/Pictures/$IMG2" >/dev/null 2>&1
for f in "$IMG1" "$IMG2"; do
    adb_ shell am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE \
        -d "file:///sdcard/Pictures/$f" >/dev/null 2>&1
done
sleep 2

info "Open a clean 1:1"
close_picker
adb_ shell am force-stop "$PKG"; sleep 1
sq "delete from messages where conversation_id in
    (select id from conversations where address='$PRIMARY');" >/dev/null
OPENED=0
for i in 1 2 3; do
    adb_ shell am start -n "$ACT" --es open_conversation_address "$PRIMARY" >/dev/null
    if wait_layout_has "More options" 6; then OPENED=1; break; fi
    adb_ shell am force-stop "$PKG"; sleep 2
done
if [ "$OPENED" = "1" ]; then
    ok "chat opened"
else
    bad "chat did not open"
    echo; echo "Results: $PASS passed, $FAIL failed"; exit 1
fi
if [ "$(outgoing_images)" = "0" ]; then
    ok "no outgoing image to start from"
else
    bad "conversation already had an outgoing image"
fi

info "Pick two pictures through '+' -> Gallery (multi-select)"
ATTACH=0
for i in 1 2 3; do tap_layout "Attach" >/dev/null && { ATTACH=1; break; }; sleep 2; done
[ "$ATTACH" = "1" ] && ok "opened the attach sheet" || bad "attach control not found"
sleep 1.5
GAL=0
for i in 1 2 3; do tap_layout "Gallery" >/dev/null && { GAL=1; break; }; sleep 1.5; done
[ "$GAL" = "1" ] && ok "chose Gallery" || bad "Gallery row not found"
sleep 3

PICKER=0
for i in 1 2 3 4 5 6; do
    [ "$(layout_count_prefix 'Photo taken')" -ge 2 ] && { PICKER=1; break; }
    sleep 2
done
if [ "$PICKER" = "1" ]; then
    ok "the photo picker opened with tiles"
else
    bad "could not reach the photo picker"
fi
if tap_first_tiles 2; then
    ok "selected two photos in one pass"
else
    bad "could not select photos in the picker"
fi
sleep 1
if layout_has "Add (2)"; then
    ok "the picker counted two selected photos"
else
    bad "the picker did not register two selected photos"
fi
if tap_layout "Add (" >/dev/null; then
    ok "confirmed with the multi-select Add button"
else
    bad "no multi-select Add button — the picker is not multi-select"
fi
if wait_layout_has "More options" 10; then
    ok "returned to the chat"
else
    bad "did not return to the chat after picking"
fi

info "Both pictures must wait in the composer, not be sent"
if [ "$(outgoing_images)" = "0" ]; then
    ok "picking the pictures did not send them"
else
    bad "pictures were sent the moment they were picked (#326 regressed)"
fi
STAGED=$(layout_count "Close")
if [ "$STAGED" = "2" ]; then
    ok "both pictures are staged as removable thumbnails"
else
    bad "expected 2 staged attachments, found ${STAGED:-0}"
fi

info "Send publishes the waiting pictures"
tap_layout "Send" >/dev/null || { bad "send button not found"; }
sleep 6
if [ "$(outgoing_images)" = "2" ]; then
    ok "both pictures were sent on Send"
else
    bad "expected 2 sent pictures, found $(outgoing_images)"
fi

echo
info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
