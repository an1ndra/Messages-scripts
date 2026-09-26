#!/usr/bin/env bash
# Wire-byte regression for the hand-written MMS encoder: the composed
# m-Send.req has to be well formed on the wire, not merely present as a row in
# the provider outbox. Sends one MMS through the debug probe, reassembles the
# bytes the composer emitted (the mms-send-<uuid>.dat cache file is deleted by
# the sent callback within seconds) from the MmsPdu log chunks keyed by
# transaction id, then walks them with a WSP parser and asserts the header
# order, content type and part framing. The emulator has no MMSC, so the send
# is expected to end in failed; what is asserted is the encoding.
source "$(dirname "$0")/env.sh"
set -euo pipefail

PASS=0
FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
[[ "$ANDROID_SERIAL" == emulator-* ]] || { printf 'Requires a disposable emulator.\n'; exit 1; }
[[ "$(adb_ shell id -u | tr -d '\r')" == 0 ]] || { printf 'Run adb root on the test emulator first.\n'; exit 1; }
PROVDB="${PROVDB:-/data/data/com.android.providers.telephony/databases/mmssms.db}"
MARKER="mmspdu$(date +%s)_$$"
ADDRESS="+1556$(date +%s | tail -c 7)"
MEDIA_URI="content://$PKG.fileprovider/camera/$MARKER.png"
RAWLOG="$TMP/mms-pdu-bytes.log"
HEXFILE="$TMP/mms-pdu-bytes.hex"
WALKFILE="$TMP/mms-pdu-bytes.walk"
HEXPY="$TMP/mms-pdu-bytes-hex.py"
WALKPY="$TMP/mms-pdu-bytes-walk.py"
provider() { adb_ shell "sqlite3 '$PROVDB' \"$1\"" | tr -d '\r'; }
local_query() { adb_ shell "run-as '$PKG' sqlite3 databases/messages.db \"$1\"" | tr -d '\r'; }
kv() { sed -n "s/^$1=//p" "$WALKFILE" | head -1; }

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    provider "DELETE FROM pdu WHERE _id IN (SELECT msg_id FROM addr WHERE address='$ADDRESS');" >/dev/null 2>&1 || true
    provider "DELETE FROM addr WHERE address='$ADDRESS';" >/dev/null 2>&1 || true
    local_query "DELETE FROM messages WHERE media_uri LIKE '%$MARKER%'; DELETE FROM conversations WHERE address='$ADDRESS'; DELETE FROM participants WHERE normalized_destination='$ADDRESS';" >/dev/null 2>&1 || true
    adb_ shell "run-as '$PKG' rm -f cache/camera/$MARKER.png" >/dev/null 2>&1 || true
    adb_ shell "rm -f /data/local/tmp/$MARKER.png" >/dev/null 2>&1 || true
    rm -f "/tmp/$MARKER.png" "$RAWLOG" "$HEXFILE" "$WALKFILE" "$TMP/mms-pdu-bytes.err"
}
trap cleanup EXIT

info "Preconditions: debuggable build and the app must hold the SMS role"
if ! adb_ shell "run-as '$PKG' echo debuggable" 2>/dev/null | tr -d '\r' | grep -q debuggable; then
    fail "run-as $PKG is refused, so this is not a debuggable build (run install.sh) - the mms_probe hook is a no-op and no wire bytes can be captured"
    printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
    exit 1
fi
pass 'build is debuggable, so the mms_probe hook is live'
adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1 || true
if [[ "$(adb_ shell "cmd role get-role-holders android.app.role.SMS" | tr -d '\r')" != *"$PKG"* ]]; then
    fail "$PKG does not hold the SMS role, so the send cannot be persisted and every assertion below would be meaningless"
    printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
    exit 1
fi
pass 'app holds the SMS role'

info "Install the chunk reassembler and the WSP walker"
cat > "$HEXPY" <<'PY'
import re
import sys

txid, path = sys.argv[1], sys.argv[2]
chunks = {}
for line in open(path, errors='replace'):
    if 'txid=' not in line:
        continue
    hit = re.search(r'txid=(\S+)', line)
    if not hit or hit.group(1) != txid:
        continue
    size = re.search(r'\bn=(\d+)', line)
    index = re.search(r'\bi=(\d+)', line)
    body = re.search(r'([0-9a-fA-F]{8,})\s*$', line.rstrip())
    if not index or not body:
        continue
    chunks[int(index.group(1))] = body.group(1).lower()
if sorted(chunks) != list(range(len(chunks))):
    sys.exit(1)
blob = ''.join(chunks[i] for i in sorted(chunks))
if not blob or len(blob) % 2 or not re.fullmatch(r'[0-9a-f]+', blob):
    sys.exit(2)
# n= is emitted either as the byte count or as the hex-digit count.
if size and int(size.group(1)) not in (len(blob), len(blob) // 2):
    sys.exit(3)
sys.stdout.write(blob + '\n')
PY

cat > "$WALKPY" <<'PY'
import sys

ONE_OCTET = (0x8c, 0x8d, 0x86, 0x8f, 0x90, 0x91, 0x94, 0x95)
VALUE_LENGTH = (0x81, 0x82, 0x84, 0x87, 0x88, 0x89, 0x96, 0x97)
NO_VALUE_LENGTH_TEXT = (0x83, 0x98)
REQUIRED = (0x8d, 0x89, 0x97, 0x8a, 0x88, 0x8f, 0x86, 0x90, 0x84)
SMIL = b'application/smil'

def out(key, value):
    print('%s=%s' % (key, value))

def uintvar(b, i):
    n = 0
    while True:
        if i >= len(b):
            raise ValueError('truncated uintvar at %d' % i)
        v = b[i]; i += 1
        n = (n << 7) | (v & 0x7f)
        if not v & 0x80:
            return n, i

def valuelen(b, i):
    if i >= len(b):
        raise ValueError('truncated value-length at %d' % i)
    v = b[i]; i += 1
    if v < 31:
        return v, i
    if v == 31:
        return uintvar(b, i)
    raise ValueError('reserved value-length 0x%02x at %d' % (v, i - 1))

def text_string(b, i):
    if i < len(b) and b[i] == 0x7f:
        i += 1
    j = b.find(b'\x00', i)
    if j < 0:
        raise ValueError('unterminated text-string at %d' % i)
    return b[i:j].decode('latin-1'), j + 1

def quoted_string(b, i):
    j = b.find(b'\x00', i + 1)
    if j < 0:
        raise ValueError('unterminated quoted-string at %d' % i)
    return b[i + 1:j].decode('latin-1'), j + 1

def long_integer(b, i):
    return i + 1 + b[i]

def encoded_string(b, i):
    if b[i] & 0x80:
        i += 1
    return text_string(b, i)[0]

b = bytes.fromhex(''.join(open(sys.argv[1]).read().split()))
out('SIZE', len(b))
out('HEAD', b[:2].hex())
out('MSGTYPE', '%02x' % b[1] if len(b) > 1 else 'none')

i, order, from_shape, to_texts, ct, version = 2, [], 'none', [], b'', 'none'
while i < len(b):
    fid = b[i]; i += 1
    order.append('%02x' % fid)
    if fid == 0x8d:
        version = '%02x' % b[i]; i += 1
    elif fid in ONE_OCTET:
        i += 1
    elif fid == 0x8a:
        # Message-class is a one-octet token, or a text-string when unrecognised.
        i += 1 if b[i] & 0x80 else text_string(b, i)[1]
    elif fid == 0x85:
        if b[i] in (0x80, 0x81):
            i += 1
        i = long_integer(b, i)
    elif fid in VALUE_LENGTH:
        n, i = valuelen(b, i)
        val = b[i:i + n]; i += n
        if fid == 0x89:
            from_shape = 'insert-address' if val[:1] == b'\x81' else (
                'address-present' if val[:1] == b'\x80' else 'other')
            if from_shape == 'address-present':
                # Address-present-token, then Value-length Char-set Text-string.
                out('FROM', encoded_string(val, valuelen(val, 1)[1]))
        elif fid == 0x97:
            to_texts.append(encoded_string(val, 0))
        elif fid == 0x84:
            ct = val
    elif fid in NO_VALUE_LENGTH_TEXT:
        i = text_string(b, i)[1]
    else:
        out('PARSE_ERROR', 'unknown top-level field 0x%02x at offset %d' % (fid, i - 1))
        break
    if ct:
        break

out('VERSION', version)
out('FROMSHAPE', from_shape)
out('TOCOUNT', len(to_texts))
for n, text in enumerate(to_texts):
    out('TO%d' % n, text)
out('TOPORDER', ','.join(order))
out('REQORDER', ','.join(f for f in order if int(f, 16) in REQUIRED))
out('DUPES', ','.join('%02x' % f for f in REQUIRED if order.count('%02x' % f) > 1))
out('LASTFIELD', order[-1] if order else 'none')

if not ct:
    out('CTLEN', 0)
    out('FRAMEOK', 0)
    out('PARSE_ERROR', 'no top-level Content-Type (0x84) header')
    sys.exit(0)
out('CTLEN', len(ct))
media, j = ct[0], 1
out('CTMEDIABYTE', '%02x' % media)
out('CTMEDIA', str(media & 0x7f) if media & 0x80 else str(media))
params = {}
while j < len(ct):
    pid = ct[j]; j += 1
    params['%02x' % pid], j = text_string(ct, j)
out('CTSTART', params.get('8a', '-'))
out('CTTYPE', params.get('89', '-'))

count, i = uintvar(b, i)
out('PARTCOUNT', count)
cte, frames = 0, []
for k in range(count):
    header_len, i = uintvar(b, i)
    data_len, i = uintvar(b, i)
    header = b[i:i + header_len]; i += header_len
    data = b[i:i + data_len]; i += data_len
    if i > len(b):
        out('PARSE_ERROR', 'part %d overruns the PDU' % k)
        out('FRAMEOK', 0)
        sys.exit(0)
    frames.append('%d+%d' % (header_len, data_len))
    out('P%d_HDR' % k, header_len)
    out('P%d_DATA' % k, data_len)
    out('P%d_CTHEX' % k, header.hex())
    out('P%d_SMIL' % k, 1 if SMIL in header else 0)
    try:
        n, j = valuelen(header, 0)
        j += n
    except ValueError as e:
        out('PARSE_ERROR', 'part %d content-type unreadable: %s' % (k, e))
        out('FRAMEOK', 0)
        sys.exit(0)
    while j < len(header):
        fid = header[j]; j += 1
        if fid == 0xc0:
            j = quoted_string(header, j)[1]
        elif fid == 0x8e:
            j = text_string(header, j)[1]
        elif fid == 0x8d:
            cte = 1
            j += 1
        else:
            out('PARSE_ERROR', 'part %d unknown field 0x%02x' % (k, fid))
            out('FRAMEOK', 0)
            sys.exit(0)
    out('P%d_HDRFIELDS' % k, 'ok')
out('FRAMESUM', ' '.join(frames))
out('FRAMEEND', i)
out('FRAMEOK', 1 if i == len(b) else 0)
out('CTE', cte)
PY

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

PDU_ID=""
TXID=""
for _ in $(seq 1 30); do
    ROW=$(provider "SELECT pdu._id || '@' || pdu.tr_id FROM pdu JOIN addr ON addr.msg_id=pdu._id WHERE addr.type=151 AND addr.address='$ADDRESS' AND pdu.m_type=128 ORDER BY pdu._id DESC LIMIT 1;")
    if [ -n "$ROW" ]; then
        PDU_ID=${ROW%%@*}
        TXID=${ROW#*@}
        break
    fi
    sleep 1
done

info "Reassemble the composed bytes from the MmsPdu log chunks for txid=$TXID"
MISSING="no provider outbox row addressed to $ADDRESS, so no transaction id to key the log on"
if [ -n "$TXID" ]; then
    MISSING="no complete set of MmsPdu hex chunks for txid=$TXID in logcat -s MmsPdu"
    for _ in $(seq 1 30); do
        adb_ logcat -d -s MmsPdu 2>/dev/null | tr -d '\r' > "$RAWLOG" || true
        HEX=$(python3 "$HEXPY" "$TXID" "$RAWLOG" 2>/dev/null || true)
        if [ -n "$HEX" ]; then
            printf '%s\n' "$HEX" > "$HEXFILE"
            break
        fi
        sleep 1
    done
fi
WALK_OK=0
if [ -s "$HEXFILE" ] && python3 "$WALKPY" "$HEXFILE" > "$WALKFILE" 2>"$TMP/mms-pdu-bytes.err"; then
    WALK_OK=1
fi

if [ "$WALK_OK" = 1 ]; then
    info "Wire bytes ($(wc -c < "$HEXFILE" | tr -d ' ') hex digits, txid=$TXID) $(kv PARSE_ERROR)"
    sed 's/^/    /' "$WALKFILE"

    SIZE=$(kv SIZE)
    if [ -n "$SIZE" ] && [ "$SIZE" -gt 0 ] && [ "$(kv HEAD)" = "8c80" ]; then
        pass "composed PDU is ${SIZE} bytes and starts with 8C 80 (MmsService.isRawPduSendReq)"
    else
        fail "composed PDU is empty or does not start with 8C 80 (head=$(kv HEAD) size=${SIZE:-0}) - the framework treats this as an unknown PDU type"
    fi
    if [ "$(kv VERSION)" = "92" ]; then
        pass 'MMS-Version is 8D 92 (short-integer 0x12 = MMS 1.2)'
    else
        fail "MMS-Version is not 8D 92 (got 8D $(kv VERSION))"
    fi
    case "$(kv FROMSHAPE)" in
        insert-address) pass 'From is 89 01 81 (insert-address-token)' ;;
        address-present) pass "From is address-present-token carrying $(kv FROM)" ;;
        *) fail "From is neither 89 01 81 nor an address-present-token (got $(kv FROMSHAPE))" ;;
    esac
    if [ "$(kv TOCOUNT)" = "1" ] && [ "$(kv TO0)" = "$ADDRESS/TYPE=PLMN" ]; then
        pass "To carries the literal $ADDRESS/TYPE=PLMN"
    else
        fail "To does not carry the literal $ADDRESS/TYPE=PLMN (count=$(kv TOCOUNT) to0=$(kv TO0))"
    fi
    if [ "$(kv CTMEDIABYTE)" = "b3" ] && [ "$(kv CTSTART)" != "-" ] && [ "$(kv CTTYPE)" = "application/smil" ]; then
        pass "top-level Content-Type is B3 multipart/related with start=$(kv CTSTART) type=application/smil"
    else
        fail "top-level Content-Type is not B3 multipart/related carrying start and type=application/smil (media=$(kv CTMEDIABYTE) start=$(kv CTSTART) type=$(kv CTTYPE))"
    fi
    if [ "$(kv FRAMEOK)" = "1" ] && [ "$(kv FRAMEEND)" = "$SIZE" ]; then
        pass "per-part framing is self-consistent: $(kv FRAMESUM) lands exactly on the PDU end (${SIZE} bytes)"
    else
        fail "per-part framing is inconsistent: $(kv FRAMESUM) ends at $(kv FRAMEEND) but the PDU is ${SIZE:-?} bytes ($(sed 's/^/    | /' "$TMP/mms-pdu-bytes.err"))"
    fi
    if [ "$(kv P0_SMIL)" = "1" ]; then
        SMIL_ELSEWHERE=0
        for k in $(seq 1 $(( $(kv PARTCOUNT) - 1 ))); do
            if [ "$(kv "P${k}_SMIL")" = "1" ]; then SMIL_ELSEWHERE=1; fi
        done
        if [ "$SMIL_ELSEWHERE" = 0 ]; then
            pass 'part 0 is the SMIL part and no other part claims application/smil'
        else
            fail "application/smil appears in a part other than part 0, so the multipart start/type parameters are wrong"
        fi
    else
        fail "part 0 is not application/smil (header=$(kv P0_CTHEX)), so the SMIL root document is not at the multipart start"
    fi
    if [ "$(kv CTE)" = "0" ]; then
        pass 'no Content-Transfer-Encoding is emitted (parts stay raw 8-bit)'
    else
        fail 'a part emits Content-Transfer-Encoding, which risks the base64 branch in the platform parser'
    fi
    if [ -z "$(kv DUPES)" ] && [ "$(kv REQORDER)" = "8d,89,97,8a,88,8f,86,90,84" ] && [ "$(kv LASTFIELD)" = "84" ]; then
        pass 'header fields 8D 89 97 8A 88 8F 86 90 each appear once in AOSP emit order with Content-Type last'
    else
        fail "header field order is wrong: order=$(kv TOPORDER) dupes=$(kv DUPES) last=$(kv LASTFIELD)"
    fi
else
    while IFS= read -r desc; do
        fail "$desc -- blocked: $MISSING"
    done <<EOF
composed PDU starts with 8C 80
MMS-Version is 8D 92
From is 89 01 81 or an address-present-token
To carries the literal \$ADDRESS/TYPE=PLMN
top-level Content-Type is B3 multipart/related with start and type=application/smil
per-part framing lands exactly on the PDU end
part 0 is application/smil
no Content-Transfer-Encoding is emitted
header fields 8D 89 97 8A 88 8F 86 90 appear once in AOSP emit order with Content-Type last
EOF
fi

if [ -n "$PDU_ID" ]; then
    N=$(provider "SELECT COUNT(*) FROM pdu WHERE tr_id='$TXID' AND m_type=128;")
    if [ "$N" = "1" ]; then
        pass "exactly one provider outbox row carries this transaction id ($TXID)"
    else
        fail "expected exactly one pdu row with tr_id=$TXID, found $N"
    fi
    BOX=$(provider "SELECT msg_box FROM pdu WHERE _id=$PDU_ID;")
    case "$BOX" in
        2|4|5) pass "PDU sits in an outbox/sent/failed box (msg_box=$BOX)" ;;
        *) fail "unexpected msg_box=$BOX (expected outbox 2, sent 4 or failed 5)" ;;
    esac
    SMIL=$(provider "SELECT COUNT(*) FROM part WHERE mid=$PDU_ID AND ct='application/smil';")
    [ "$SMIL" = "1" ] && pass "PDU carries exactly one SMIL part (id=$PDU_ID)" || fail "expected one SMIL part on pdu $PDU_ID, found $SMIL"
    IMG=$(provider "SELECT COUNT(*) FROM part WHERE mid=$PDU_ID AND ct LIKE 'image/%';")
    [ "${IMG:-0}" -ge 1 ] && pass 'PDU carries the image attachment' || fail "image part missing on pdu $PDU_ID ($IMG)"
    TO=$(provider "SELECT COUNT(*) FROM addr WHERE msg_id=$PDU_ID AND type=151 AND address='$ADDRESS';")
    [ "$TO" = "1" ] && pass 'PDU addresses the recipient exactly once' || fail "recipient address missing or duplicated on pdu $PDU_ID ($TO)"
    POLLUTED=$(provider "SELECT COUNT(*) FROM addr WHERE msg_id=$PDU_ID AND address LIKE '%/TYPE=%';")
    [ "${POLLUTED:-0}" = "0" ] && pass 'no addr row carries a wire /TYPE=PLMN suffix' || fail "$POLLUTED addr row(s) polluted with a /TYPE= suffix, which breaks thread matching"
else
    fail "no outgoing MMS PDU in the provider outbox for $ADDRESS - the composer never persisted a row"
fi

STATUS=$(local_query "SELECT status FROM messages WHERE media_uri LIKE '%$MARKER%' ORDER BY id DESC LIMIT 1;")
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
