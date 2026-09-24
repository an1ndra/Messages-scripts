#!/usr/bin/env bash
# Regression for #236 (send half): outgoing MMS must build a real m_SendReq PDU,
# persist it to the provider outbox and hand the composed PDU to the framework.
# Before the fix the picked media URI was passed straight to
# sendMultimediaMessage, so no PDU was ever created and nothing was transmitted.
# The emulator has no MMSC, so the send is expected to end in Failed; what is
# asserted is the PDU/outbox/callback plumbing.
source "$(dirname "$0")/env.sh"
set -euo pipefail

PASS=0
FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
[[ "$ANDROID_SERIAL" == emulator-* ]] || { printf 'Requires a disposable emulator.\n'; exit 1; }
[[ "$(adb_ shell id -u | tr -d '\r')" == 0 ]] || { printf 'Run adb root on the test emulator first.\n'; exit 1; }
PROVDB="${PROVDB:-/data/data/com.android.providers.telephony/databases/mmssms.db}"
MARKER="mmssend$(date +%s)$$"
ADDRESS="+1557$(date +%s | tail -c 7)"
MEDIA_URI="content://$PKG.fileprovider/camera/$MARKER.png"
IDFILE="$TMP/mms-send-pdu"
provider() { adb_ shell "sqlite3 '$PROVDB' \"$1\"" | tr -d '\r'; }
local_query() { adb_ shell "run-as '$PKG' sqlite3 databases/messages.db \"$1\"" | tr -d '\r'; }

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    if [ -s "$IDFILE" ]; then
        local id; id=$(cat "$IDFILE")
        provider "DELETE FROM part WHERE mid=$id; DELETE FROM addr WHERE msg_id=$id; DELETE FROM pdu WHERE _id=$id;" >/dev/null || true
    fi
    local_query "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$ADDRESS'); DELETE FROM conversations WHERE address='$ADDRESS'; DELETE FROM participants WHERE normalized_destination='$ADDRESS';" >/dev/null || true
    adb_ shell "run-as '$PKG' rm -f cache/camera/$MARKER.png" >/dev/null 2>&1 || true
    rm -f "/tmp/$MARKER.png" "$IDFILE"
}
trap cleanup EXIT

adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1 || true

# Start from a clean outbox so the assertions cannot match a leftover PDU.
provider "DELETE FROM part WHERE mid IN (SELECT _id FROM pdu WHERE m_type=128); DELETE FROM addr WHERE msg_id IN (SELECT _id FROM pdu WHERE m_type=128); DELETE FROM pdu WHERE m_type=128;" >/dev/null || true

info "Seed a small image the app can read through its own FileProvider"
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

info "Send one MMS through the debug probe"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1
adb_ logcat -c >/dev/null 2>&1 || true
adb_ shell am start -n "$ACT" >/dev/null
sleep 4
adb_ shell am start -n "$ACT" --es mms_probe "$MEDIA_URI" --es mms_probe_to "$ADDRESS" >/dev/null
sleep 10

PDU=$(provider "SELECT _id FROM pdu WHERE m_type=128 ORDER BY _id DESC LIMIT 1;")
if [ -n "$PDU" ]; then
    printf '%s' "$PDU" > "$IDFILE"
    pass "outgoing MMS PDU persisted to the provider (m_type=128, id=$PDU)"
else
    fail "no outgoing MMS PDU in the provider outbox"
    exit 1
fi

BOX=$(provider "SELECT msg_box FROM pdu WHERE _id=$PDU;")
case "$BOX" in
    2|4|5) pass "PDU sits in an outbox/sent/failed box (msg_box=$BOX)" ;;
    *) fail "unexpected msg_box=$BOX (expected outbox 2, sent 4 or failed 5)" ;;
esac

SMIL=$(provider "SELECT COUNT(*) FROM part WHERE mid=$PDU AND ct='application/smil';")
[ "$SMIL" = "1" ] && pass 'PDU carries a SMIL part' || fail "SMIL part missing ($SMIL)"

IMG=$(provider "SELECT COUNT(*) FROM part WHERE mid=$PDU AND ct LIKE 'image/%';")
[ "${IMG:-0}" -ge 1 ] && pass 'PDU carries the image attachment' || fail "image part missing ($IMG)"

TO=$(provider "SELECT COUNT(*) FROM addr WHERE msg_id=$PDU AND type=151 AND address='$ADDRESS';")
[ "$TO" = "1" ] && pass 'PDU addresses the recipient' || fail "recipient address missing ($TO)"

STATUS=$(local_query "SELECT status FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$ADDRESS') AND media_type='image' ORDER BY id DESC LIMIT 1;")
case "$STATUS" in
    failed|sending|sent) pass "app row resolved to a real status (=$STATUS) via the sent callback" ;;
    *) fail "app row stuck at '=$STATUS' (sent callback never fired)" ;;
esac

LEFTOVER=$(adb_ shell "run-as '$PKG' sh -c 'ls cache/ | grep -c mms-send'" 2>/dev/null | tr -d '\r' || true)
[ "${LEFTOVER:-0}" = "0" ] && pass 'composed PDU file cleaned up' || fail "stale mms-send PDU files ($LEFTOVER)"

if adb_ shell "logcat -d -b crash" 2>/dev/null | grep -q "$PKG"; then
    fail 'app crashed while sending the MMS'
else
    pass 'no crash while sending the MMS'
fi

printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
