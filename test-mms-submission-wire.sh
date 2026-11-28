#!/usr/bin/env bash
# Issue #530: Telstra rejected every MMS with HTTP 500 while Quik and Fossify
# worked on the same SIM. The difference is on the wire: our submission wrote
# a real From, omitted part content-locations, declared X-Mms-Message-Size and
# used a different header order. Assert the submission line the platform gets.
# The AVD has no MMSC, so the send outcome is irrelevant; the composed PDU is
# read from logcat before the hand-off.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()   { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
[[ "$ANDROID_SERIAL" == emulator-* ]] || { printf 'Requires a disposable emulator.\n'; exit 1; }

MARKER="mmspdu$(date +%s)$$"
ADDRESS="+1557$(date +%s | tail -c 7)"
MEDIA_URI="content://$PKG.fileprovider/camera/$MARKER.png"
SETTINGS_PREFS="shared_prefs/messages_settings.xml"
local_query() { adb_ shell "run-as '$PKG' sqlite3 databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r'; }
local_pref() { adb_ shell "run-as '$PKG' cat $SETTINGS_PREFS" 2>/dev/null | tr -d '\r' | grep -o "name=\"$1\"[^>]*value=\"[^\"]*\"" | grep -o 'value="[^"]*"' | cut -d'"' -f2 | head -1; }

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    if [ -n "${SIMID_BEFORE:-}" ]; then
        adb_ shell "run-as '$PKG' sed -i 's#<int name=\"sim_subscription_id\" value=\"-*[0-9]*\"#<int name=\"sim_subscription_id\" value=\"$SIMID_BEFORE\"#' $SETTINGS_PREFS" >/dev/null 2>&1 || true
    fi
    if [ -n "${MMS_BEFORE:-}" ]; then
        adb_ shell "run-as '$PKG' sed -i 's#<boolean name=\"mms_enabled\" value=\"[^\"]*\"#<boolean name=\"mms_enabled\" value=\"$MMS_BEFORE\"#' $SETTINGS_PREFS" >/dev/null 2>&1 || true
    fi
    local_query "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$ADDRESS'); DELETE FROM conversations WHERE address='$ADDRESS'; DELETE FROM participants WHERE normalized_destination='$ADDRESS';" >/dev/null 2>&1 || true
    adb_ shell "run-as '$PKG' rm -f cache/camera/$MARKER.png" >/dev/null 2>&1 || true
    adb_ shell "rm -f /data/local/tmp/$MARKER.png" >/dev/null 2>&1 || true
    rm -f "/tmp/$MARKER.png"
}
trap cleanup EXIT

adb_su "cmd role add-role-holder android.app.role.SMS $PKG" >/dev/null 2>&1 || true

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
open('/tmp/' + marker + '.png', 'wb').write(png)
PY
adb_ shell "run-as '$PKG' mkdir -p cache/camera"
adb_ push "/tmp/$MARKER.png" "/data/local/tmp/$MARKER.png" >/dev/null
adb_ shell "run-as '$PKG' sh -c 'cat /data/local/tmp/$MARKER.png > cache/camera/$MARKER.png'"

SIMID_BEFORE=$(local_pref sim_subscription_id)
MMS_BEFORE=$(local_pref mms_enabled)
adb_ shell "run-as '$PKG' sed -i 's#<int name=\"sim_subscription_id\" value=\"-*[0-9]*\"#<int name=\"sim_subscription_id\" value=\"-1\"#' $SETTINGS_PREFS" >/dev/null 2>&1 || true

info "Send one MMS through the debug probe and read the submission"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1
adb_ logcat -c >/dev/null 2>&1 || true
adb_ shell am start -n "$ACT" --es mms_probe on >/dev/null
sleep 2
adb_ shell am start -n "$ACT" --es mms_probe "$MEDIA_URI" --es mms_probe_to "$ADDRESS" >/dev/null
sleep 10
TRACE=$(adb_ shell logcat -d -s MmsTrace MmsSender MmsSend 2>/dev/null | tr -d '\r' || true)
LINE=$(printf '%s\n' "$TRACE" | grep -E 'send pdu ' | tail -1 || true)
[ -n "$LINE" ] && ok "the trace reports the submission that was handed over" \
    || { bad "no submission line in the trace"; printf '%s\n' "$TRACE" | sed 's/^/    | /' | tail -20; exit 1; }

case "$LINE" in
    *'from=insert-address-token'*) ok "From is the insert-address token the platform fills" ;;
    *) bad "From is written explicitly instead of the insert-address token" ;;
esac
case "$LINE" in
    *'msgSize=-'*) ok "no X-Mms-Message-Size header is declared" ;;
    *) bad "the submission declares X-Mms-Message-Size" ;;
esac
case "$LINE" in
    *'parts=smil.xml/application/smil/cid=smil.xml/cl=smil.xml/'*) ok "the SMIL part has a content-location" ;;
    *) bad "the SMIL part has no content-location" ;;
esac
case "$LINE" in
    *'/image/jpeg/cid=image/cl=image/'*) ok "the image part has a content-location" ;;
    *) bad "the image part has no content-location" ;;
esac
case "$LINE" in
    *'headers=8c.98.8d.85.89.97.8a.88.8f.86.90.84'*) ok "header order matches the platform composer" ;;
    *) bad "header order does not match the platform composer" ;;
esac

printf '\n'
info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
