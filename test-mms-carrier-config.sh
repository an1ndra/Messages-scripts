#!/usr/bin/env bash
# MMS must obey the carrier config instead of hardcoded limits.
#
# Before the fix the send path read nothing from CarrierConfigManager: it sent
# reports as VALUE_NO regardless of the carrier, never checked maxMessageSize,
# and re-encoded every attachment as-is, so a carrier capping images at 640x480
# rejected the PDU with a failure the user could not act on.
#
# This drives real carrier-config overrides through `cmd phone cc set-value` and
# asserts the app reads and applies them: image downscaling, the message-size
# cap, and the delivery/read report headers.
source "$(dirname "$0")/env.sh"
set -euo pipefail

PASS=0
FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
[[ "$ANDROID_SERIAL" == emulator-* ]] || { printf 'Requires a disposable emulator.\n'; exit 1; }
[[ "$(adb_ shell id -u | tr -d '\r')" == 0 ]] || { printf 'Run adb root on the test emulator first.\n'; exit 1; }

PROVDB="${PROVDB:-/data/data/com.android.providers.telephony/databases/mmssms.db}"
SLOT="${SLOT:-0}"
MARKER="mmscfg$(date +%s)$$"
ADDRESS="+1666$(date +%s | tail -c 7)"
MEDIA_URI="content://$PKG.fileprovider/camera/$MARKER.png"
IDFILE="$TMP/mms-cfg-pdu"
provider() { adb_ shell "sqlite3 '$PROVDB' \"$1\"" | tr -d '\r'; }
# Written as a quoted word so `cc set-value` parses it as a boolean; a bare
# false is rejected with "Unable to parse ... as a BOOLEAN". Every write is read
# back, because a rejected write silently leaves the previous value in place.
cc_set() {
    adb_ shell cmd phone cc set-value -s "$SLOT" "$1" "$2" >/dev/null 2>&1 || true
    # get-value lags the write, so a read-back race is reported once and the
    # value re-read rather than treating the first stale read as a failure.
    local got i
    for i in 1 2 3; do
        got="$(cc_get "$1" | sed -E 's/.*[[:space:]]+([A-Za-z0-9_-]+)[[:space:]]*$/\1/')"
        [ "$got" = "$2" ] && return 0
        sleep 1
    done
    printf '[WARN] %s=%s did not stick (read back %s)\n' "$1" "$2" "${got:-<none>}"
    return 0
}
cc_get() { adb_ shell cmd phone cc get-value -s "$SLOT" "$1" 2>/dev/null | tr -d '\r' | tail -1; }

# `cmd phone cc` has no "unset", so every value this test changes is captured up
# front and restored exactly on the way out.
# Anything this test overrides has to be captured first; `cc clear-values` would
# work but also drops overrides belonging to other tests.
declare -a SAVED=()
for key in maxImageWidth maxImageHeight maxMessageSize enableMMSDeliveryReports enableMMSReadReports; do
    SAVED+=("$key=$(cc_get "$key")")
done
restore_cc() {
    local entry key value saved
    for entry in "${SAVED[@]}"; do
        key="${entry%%=*}"
        value="$(sed -E 's/.*[[:space:]]+([A-Za-z0-9_-]+)[[:space:]]*$/\1/' <<< "${entry#*=}")"
        [ -n "$value" ] || continue
        cc_set "$key" "$value"
    done
    printf 'carrier config restored\n'
}

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    if [ -s "$IDFILE" ]; then
        local id; id=$(cat "$IDFILE")
        provider "DELETE FROM part WHERE mid=$id; DELETE FROM addr WHERE msg_id=$id; DELETE FROM pdu WHERE _id=$id;" >/dev/null || true
    fi
    adb_ shell "run-as '$PKG' sqlite3 databases/messages.db \"DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$ADDRESS'); DELETE FROM conversations WHERE address='$ADDRESS'; DELETE FROM participants WHERE normalized_destination='$ADDRESS';\"" >/dev/null 2>&1 || true
    adb_ shell "run-as '$PKG' rm -f cache/camera/$MARKER.png" >/dev/null 2>&1 || true
    rm -f "/tmp/$MARKER.png" "$IDFILE"
    restore_cc
}
trap cleanup EXIT

adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1 || true

# A 900x600 solid PNG: larger than the caps installed below, so a correct send has
# to downscale it. 2x2 would pass through untouched and assert nothing.
info "Seed a 900x600 PNG (bigger than the caps set below)"
python3 - "$MARKER" <<'PY'
import struct, sys, zlib
marker = sys.argv[1]
w, h = 900, 600
raw = b''.join(b'\x00' + b'\x33\x66\x99' * w for _ in range(h))
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

send_probe() {
    provider "DELETE FROM part WHERE mid IN (SELECT _id FROM pdu WHERE m_type=128); DELETE FROM addr WHERE msg_id IN (SELECT _id FROM pdu WHERE m_type=128); DELETE FROM pdu WHERE m_type=128;" >/dev/null || true
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    adb_ logcat -c >/dev/null 2>&1 || true
    adb_ shell am start -n "$ACT" >/dev/null
    sleep 4
    adb_ shell am start -n "$ACT" --es mms_probe "$MEDIA_URI" --es mms_probe_to "$ADDRESS" >/dev/null
    sleep 10
}

# ---------------------------------------------------------------- image caps
info "Carrier caps images at 100x100: the attachment must be downscaled"
cc_set maxImageWidth 100
cc_set maxImageHeight 100
send_probe

PDU=$(provider "SELECT _id FROM pdu WHERE m_type=128 ORDER BY _id DESC LIMIT 1;")
if [ -n "$PDU" ]; then
    printf '%s' "$PDU" > "$IDFILE"
    pass "MMS still composed under tight image caps (pdu=$PDU)"

    # The provider stores the image part row without its data blob, so the
    # composed PDU is the only place the encoded bytes exist. The composer logs
    # the source -> encoded dimension transition, which is what actually proves
    # the resize ran; a part count would pass either way.
    DIMLOG=$(adb_ logcat -d 2>/dev/null | grep -oE 'attachment [0-9]+x[0-9]+ -> [0-9]+x[0-9]+ \(carrier cap [0-9]+x[0-9]+\)' | tail -1)
    if [ -n "${DIMLOG:-}" ]; then
        pass "composer reported the resize: $DIMLOG"
    else
        fail 'no attachment resize logged despite a 100x100 carrier cap'
    fi

    SRC=$(sed -nE 's/.*attachment ([0-9]+)x([0-9]+) ->.*/\1/p' <<< "${DIMLOG:-}")
    DST_W=$(sed -nE 's/.*-> ([0-9]+)x.*/\1/p' <<< "${DIMLOG:-}")
    DST_H=$(sed -nE 's/.*-> [0-9]+x([0-9]+).*/\1/p' <<< "${DIMLOG:-}")
    if [ "${SRC:-0}" = "900" ] && [ "${DST_W:-0}" -le 100 ] && [ "${DST_H:-0}" -le 100 ]; then
        pass "attachment downscaled to the carrier cap (${SRC} -> ${DST_W}x${DST_H})"
    else
        fail "attachment not downscaled to the cap (${SRC:-?} -> ${DST_W:-0}x${DST_H:-0}, expected <=100x100)"
    fi
else
    fail "no MMS PDU produced under tight image caps"
fi

# ------------------------------------------------------------- size cap
info "Carrier caps messages at 2KB: the send must be refused, not transmitted"
# Back to a large image cap so the only thing that can reject the send is the
# message-size limit, not the dimensions.
cc_set maxImageWidth 2592
cc_set maxImageHeight 1944
cc_set maxMessageSize 2048
send_probe

PDU2=$(provider "SELECT _id FROM pdu WHERE m_type=128 ORDER BY _id DESC LIMIT 1;")
if [ -z "$PDU2" ]; then
    pass "oversized MMS refused before reaching the provider outbox (maxMessageSize=2048)"
else
    printf '%s' "$PDU2" > "$IDFILE"
    fail "oversized MMS was still persisted (pdu=$PDU2) despite maxMessageSize=2048"
fi

if adb_ logcat -d 2>/dev/null | grep -q 'MMS not sent: TOO_LARGE'; then
    pass 'composer rejected the attachment as TOO_LARGE'
else
    fail 'no TOO_LARGE rejection logged for the oversized attachment'
fi

# --------------------------------------------------------------- reports
info "Carrier enables MMS delivery and read reports: the PDU headers must follow"
cc_set maxMessageSize 1048576
cc_set enableMMSDeliveryReports true
cc_set enableMMSReadReports true
send_probe

PDU3=$(provider "SELECT _id FROM pdu WHERE m_type=128 ORDER BY _id DESC LIMIT 1;")
if [ -z "$PDU3" ]; then
    fail "no MMS PDU produced with reports enabled"
else
    printf '%s' "$PDU3" > "$IDFILE"
    # Provider columns are Telephony.Mms: d_rpt (delivery), rr (read).
    # 128 == 0x80 == PduHeaders.VALUE_YES, 129 == VALUE_NO.
    DREP=$(provider "SELECT d_rpt FROM pdu WHERE _id=$PDU3;" 2>/dev/null | tr -d '\r' || true)
    RREP=$(provider "SELECT rr FROM pdu WHERE _id=$PDU3;" 2>/dev/null | tr -d '\r' || true)
    if [ "${DREP:-0}" = "128" ]; then
        pass 'delivery report requested (d_rpt=0x80) per carrier config'
    else
        fail "delivery report not requested (d_rpt=${DREP:-<none>}, expected 128)"
    fi
    if [ "${RREP:-0}" = "128" ]; then
        pass 'read report requested (rr=0x80) per carrier config'
    else
        fail "read report not requested (rr=${RREP:-<none>}, expected 128)"
    fi
fi

if adb_ logcat -d -b crash 2>/dev/null | grep -q "$PKG"; then
    fail 'app crashed while applying carrier config'
else
    pass 'no crash while applying carrier config'
fi

printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
