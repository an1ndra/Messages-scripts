#!/usr/bin/env bash
# Regression for #364 B2/M5: several staged pictures leave as one MMS.
#
# The composer used to call the send path once per picture, so three pictures
# became three MMS transactions, three provider rows and three bubbles. They now
# leave in one PDU and one SMIL slideshow, which is what makes them one message.
#
# The AVD has no carrier, so the hand-off itself fails; that is fine, because
# everything asserted here happens before or independently of delivery:
#
#   - the app stored exactly three media rows and one caption;
#   - all three rows carry the SAME provider id, which can only happen when one
#     MMS was built for them;
#   - each row was pointed at a different part of that provider row, so the PDU
#     really held three pictures rather than one picture three times;
#   - the chat draws one "3 photos" bubble.
#
# Broken code (one send per picture) fails every one of those: three different
# provider ids, and three separate single-picture bubbles.
source "$(dirname "$0")/env.sh"
set -euo pipefail

PASS=0
FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
[[ "$ANDROID_SERIAL" == emulator-* ]] || { printf 'Requires a disposable emulator.\n'; exit 1; }

MARKER="album$(date +%s)$$"
ADDRESS="+1557$(date +%s | tail -c 7)"
CAPTION="AlbumCap$RANDOM"
BASE="content://$PKG.fileprovider/camera"
COLORS=(ff0000 00ff00 0000ff)
URIS=()
for color in "${COLORS[@]}"; do
    URIS+=("$BASE/$MARKER$color.png")
done
STAGED_ARG=$(IFS=,; echo "${URIS[*]}")
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
    for color in "${COLORS[@]}"; do
        adb_ shell "run-as '$PKG' rm -f cache/camera/$MARKER$color.png" >/dev/null 2>&1 || true
        adb_ shell rm -f "/data/local/tmp/$MARKER$color.png" >/dev/null 2>&1 || true
        rm -f "/tmp/$MARKER$color.png"
    done
}
trap cleanup EXIT

seed_png() {
    python3 - "$1" "$2" <<'PY'
import struct, sys, zlib
marker, hexcol = sys.argv[1], sys.argv[2]
w = h = 2
px = bytes.fromhex(hexcol)
raw = b''.join(b'\x00' + px * w for _ in range(h))

def chunk(tag, data):
    body = tag + data
    return struct.pack('>I', len(data)) + body + struct.pack('>I', zlib.crc32(body) & 0xffffffff)

png = (b'\x89PNG\r\n\x1a\n'
       + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
       + chunk(b'IDAT', zlib.compress(raw))
       + chunk(b'IEND', b''))
open('/tmp/%s.png' % marker, 'wb').write(png)
PY
}

adb_ shell "run-as '$PKG' mkdir -p cache/camera"
for color in "${COLORS[@]}"; do
    seed_png "$MARKER$color" "$color"
    adb_ push "/tmp/$MARKER$color.png" "/data/local/tmp/$MARKER$color.png" >/dev/null
    adb_ shell "run-as '$PKG' sh -c 'cat /data/local/tmp/$MARKER$color.png > cache/camera/$MARKER$color.png'"
done

adb_ shell am force-stop "$PKG" >/dev/null 2>&1
adb_ shell am start -n "$ACT" >/dev/null
sleep 4
adb_ shell am start -n "$ACT" --es mms_stage "$STAGED_ARG" --es mms_probe_to "$ADDRESS" >/dev/null

STAGED=0
for _ in $(seq 1 10); do
    sleep 1
    dump_ui >/dev/null 2>&1 || continue
    COUNT=$(grep -o 'content-desc="Photo"' "$TMP/ui.xml" 2>/dev/null | wc -l | tr -d ' ' || true)
    if [ "${COUNT:-0}" -ge 3 ]; then STAGED=1; break; fi
done
if [ "$STAGED" = 1 ]; then
    pass "the probe staged all three pictures"
else
    fail "the probe did not stage three pictures (saw ${COUNT:-0})"
    exit 1
fi

tap_edittext >/dev/null 2>&1 || true
sleep 0.5
type_text "$CAPTION"
sleep 1
rm -f "$TMP/ui.xml"
dump_ui >/dev/null 2>&1 || true
grep -qF "text=\"$CAPTION" "$TMP/ui.xml" && pass "the caption is in the composer" \
    || fail "the caption never reached the composer"

CID=$(local_query "SELECT id FROM conversations WHERE address='$ADDRESS' ORDER BY id DESC LIMIT 1;")
[[ -n "$CID" ]] && pass "the probe opened a conversation" \
    || { fail "no conversation for the staged pictures"; exit 1; }

rm -f "$TMP/ui.xml"
dump_ui >/dev/null 2>&1 || true
SEND=$(grep -qF 'content-desc="Send"' "$TMP/ui.xml" && center_of "Send" 2>/dev/null) || SEND=""
if [[ -n "$SEND" ]]; then
    pass "the composer offers Send"
    adb_ shell input tap $SEND >/dev/null 2>&1 || true
else
    fail "the composer offers Send"
    exit 1
fi

# The rows are written before the hand-off; the provider id arrives with it.
ROWS=""
for _ in $(seq 1 15); do
    sleep 1
    ROWS=$(local_query "SELECT id||'|'||sys_id||'|'||media_type||'|'||body||'|'||media_uri FROM messages WHERE conversation_id=$CID ORDER BY id;")
    COUNT=$(printf '%s\n' "$ROWS" | grep -c '|image|' || true)
    SYSIDS=$(printf '%s\n' "$ROWS" | grep '|image|' | cut -d'|' -f2 | sort -u)
    if [ "${COUNT:-0}" -eq 3 ] && [ "$(printf '%s\n' "$SYSIDS" | sed '/^$/d' | wc -l)" -eq 1 ] \
        && ! printf '%s\n' "$SYSIDS" | grep -qx '0'; then
        break
    fi
done

COUNT=$(printf '%s\n' "$ROWS" | grep -c '|image|' || true)
[[ "${COUNT:-0}" -eq 3 ]] && pass "three pictures were stored" \
    || fail "expected three stored pictures, found ${COUNT:-0}"

SYSID=$(printf '%s\n' "$ROWS" | grep '|image|' | cut -d'|' -f2 | sort -u | sed '/^$/d')
[[ "$(printf '%s\n' "$SYSID" | wc -l)" -eq 1 ]] && [[ "$SYSID" != "0" ]] \
    && pass "all three pictures share one provider MMS (sys_id=$SYSID)" \
    || fail "the pictures did not share one provider MMS: '$(printf '%s' "$SYSID" | tr '\n' ' ')'"

PARTS=$(printf '%s\n' "$ROWS" | grep '|image|' | cut -d'|' -f5 | sort -u | grep -c '^content://mms/part/' || true)
[[ "${PARTS:-0}" -eq 3 ]] && pass "each picture points at its own part of that PDU" \
    || fail "expected three distinct provider parts, found ${PARTS:-0}"

CAPTIONS=$(printf '%s\n' "$ROWS" | grep -cF "|$CAPTION|" || true)
[[ "${CAPTIONS:-0}" -eq 1 ]] && pass "the caption rides once, on the message not on a picture" \
    || fail "expected the caption on exactly one row, found ${CAPTIONS:-0}"

rm -f "$TMP/ui.xml"
dump_ui >/dev/null 2>&1 || true
ALBUMS=$(grep -o 'content-desc="3 photos"' "$TMP/ui.xml" 2>/dev/null | wc -l | tr -d ' ' || true)
[[ "${ALBUMS:-0}" -eq 1 ]] && pass "the chat draws one three-picture bubble" \
    || fail "expected one three-picture bubble, found ${ALBUMS:-0}"
TRAY=$(grep -o 'content-desc="Photo"' "$TMP/ui.xml" 2>/dev/null | wc -l | tr -d ' ' || true)
[[ "${TRAY:-0}" -eq 0 ]] && pass "the composer released the pictures after storing them" \
    || fail "the composer still holds ${TRAY:-0} staged picture(s)"

printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
