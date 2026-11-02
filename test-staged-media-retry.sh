#!/usr/bin/env bash
# Regression for #364 M8: a staged picture and its caption must survive a Send
# that stored nothing. The composer used to clear the tray and the draft before
# the asynchronous send reported, so a conversation the MMS path refused
# swallowed both with no message and no toast.
#
# The AVD has no system photo picker, so the picture is staged through the
# debug-only `mms_stage` probe. The refusal is made real by renaming the open
# conversation to an address the send path rejects; nothing is mocked in the app.
source "$(dirname "$0")/env.sh"
set -euo pipefail

PASS=0
FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
[[ "$ANDROID_SERIAL" == emulator-* ]] || { printf 'Requires a disposable emulator.\n'; exit 1; }

MARKER="stage$(date +%s)$$"
ADDRESS="+1557$(date +%s | tail -c 7)"
CAPTION="KeepCaption$RANDOM"
MEDIA_URI="content://$PKG.fileprovider/camera/$MARKER.png"
CID=""
local_query() {
    adb_ shell "run-as '$PKG' sqlite3 databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r'
}

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    if [ -n "$CID" ]; then
        local_query "DELETE FROM messages WHERE conversation_id=$CID; DELETE FROM conversation_recipients WHERE conversation_id=$CID; DELETE FROM conversations WHERE id=$CID;" >/dev/null 2>&1 || true
    fi
    local_query "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$ADDRESS'); DELETE FROM conversations WHERE address='$ADDRESS';" >/dev/null 2>&1 || true
    adb_ shell "run-as '$PKG' rm -f cache/camera/$MARKER.png" >/dev/null 2>&1 || true
    adb_ shell rm -f "/data/local/tmp/$MARKER.png" >/dev/null 2>&1 || true
    rm -f "/tmp/$MARKER.png"
}
trap cleanup EXIT

python3 - "$MARKER" <<'PY'
import struct, sys, zlib
marker = sys.argv[1]
w = h = 2
raw = b''.join(b'\x00' + b'\xff\x00\x00' * w for _ in range(h))
def chunk(tag, data):
    body = tag + data
    return struct.pack('>I', len(data)) + body + struct.pack('>I', zlib.crc32(body) & 0xffffffff)
png = (b'\x89PNG\r\n\x1a\n'
       + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
       + chunk(b'IDAT', zlib.compress(raw))
       + chunk(b'IEND', b''))
open('/tmp/%s.png' % marker, 'wb').write(png)
PY
adb_ shell "run-as '$PKG' mkdir -p cache/camera"
adb_ push "/tmp/$MARKER.png" "/data/local/tmp/$MARKER.png" >/dev/null
adb_ shell "run-as '$PKG' sh -c 'cat /data/local/tmp/$MARKER.png > cache/camera/$MARKER.png'"

adb_ shell am force-stop "$PKG" >/dev/null 2>&1
adb_ shell am start -n "$ACT" >/dev/null
sleep 4
adb_ shell am start -n "$ACT" --es mms_stage "$MEDIA_URI" --es mms_probe_to "$ADDRESS" >/dev/null

STAGED=0
for _ in $(seq 1 10); do
    sleep 1
    dump_ui >/dev/null 2>&1 || continue
    if grep -qF 'content-desc="Photo"' "$TMP/ui.xml"; then STAGED=1; break; fi
done
[[ "$STAGED" == 1 ]] && pass "the probe staged one picture" \
    || { fail "the probe did not stage a picture"; exit 1; }

tap_edittext >/dev/null 2>&1 || true
sleep 0.5
type_text "$CAPTION"
sleep 1
rm -f "$TMP/ui.xml"
dump_ui >/dev/null 2>&1 || true
grep -qF "text=\"$CAPTION\"" "$TMP/ui.xml" && pass "the caption is in the composer" \
    || fail "the caption never reached the composer"

# Make the conversation unusable for sending without touching the screen. The
# app's conversation flow only re-reads after its own notifyChanged(), so an
# external write leaves the open composer holding the old, valid address: the
# Send tap reaches sendMediaMessage, which re-reads the row and refuses. That is
# the silent early return this fix is about.
CID=$(local_query "SELECT id FROM conversations WHERE address='$ADDRESS' ORDER BY id DESC LIMIT 1;")
[[ -n "$CID" ]] && pass "the probe opened a conversation for the staged picture" \
    || { fail "no conversation for the staged picture"; exit 1; }
local_query "UPDATE conversations SET address='not-a-number' WHERE id=$CID;" >/dev/null
[[ "$(local_query "SELECT address FROM conversations WHERE id=$CID;")" == "not-a-number" ]] \
    && pass "the conversation now has an address the send path refuses" \
    || { fail "could not make the address unusable"; exit 1; }
BEFORE=$(local_query "SELECT COUNT(*) FROM messages WHERE conversation_id=$CID;")

rm -f "$TMP/ui.xml"
dump_ui >/dev/null 2>&1 || true
C=$(grep -qF 'content-desc="Send"' "$TMP/ui.xml" && center_of "Send" 2>/dev/null) || C=""
if [[ -n "$C" ]]; then
    pass "the composer still offers Send"
    adb_ shell input tap $C >/dev/null 2>&1 || true
else
    fail "the composer still offers Send"
fi
sleep 2

AFTER=$(local_query "SELECT COUNT(*) FROM messages WHERE conversation_id=$CID;")
[[ "${AFTER:-x}" == "${BEFORE:-y}" ]] && pass "the refused send stored no message" \
    || fail "the refused send still stored a message"

rm -f "$TMP/ui.xml"
dump_ui >/dev/null 2>&1 || true
grep -qF 'content-desc="Photo"' "$TMP/ui.xml" && pass "the staged picture survived the refused send" \
    || fail "the refused send threw the staged picture away"
grep -qF "text=\"$CAPTION\"" "$TMP/ui.xml" && pass "the caption survived the refused send" \
    || fail "the refused send threw the caption away"

printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
