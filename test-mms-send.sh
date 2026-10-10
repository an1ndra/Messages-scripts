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
    if [ -n "${SIMID_BEFORE:-}" ]; then
        adb_ shell "run-as '$PKG' sed -i 's#<int name=\"sim_subscription_id\" value=\"-*[0-9]*\"#<int name=\"sim_subscription_id\" value=\"$SIMID_BEFORE\"#' $SETTINGS_PREFS" >/dev/null 2>&1 || true
    fi
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

# The app stores "whichever SIM holds the default SMS role" as a negative id and
# hands it to the platform MMS call. The MMS service validates that id, so a
# negative one has to be resolved to the default SIM manager before it gets
# there. The AVD stores an explicit SIM id, so the default is forced for the
# send and restored on exit.
SETTINGS_PREFS="shared_prefs/messages_settings.xml"
SIMID_BEFORE=$(adb_ shell "run-as '$PKG' cat $SETTINGS_PREFS" 2>/dev/null | tr -d '\r' \
    | sed -n 's/.*name="sim_subscription_id"[^>]*value="\(-*[0-9]*\)".*/\1/p' | head -1)
adb_ shell "run-as '$PKG' sed -i 's#<int name=\"sim_subscription_id\" value=\"-*[0-9]*\"#<int name=\"sim_subscription_id\" value=\"-1\"#' $SETTINGS_PREFS" >/dev/null 2>&1 || true

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

# The platform opens the composed PDU through the app's FileProvider from its own
# process, so the PDU has to be written into the cache root file_paths.xml exposes
# and the URI has to carry the mms/ segment. Neither the URI nor the file is left
# behind after a send (the receiver deletes the file), so what is asserted here is
# the trace: that the stack composed a PDU, linked its outbox row to the app's
# message, and handed it over. On this AVD the platform answers every send with
# code 12 regardless, so the outcome cannot distinguish the paths - the trace can.
TRACELOG=$(adb_ shell "logcat -d -s MmsSender MmsTrace MmsSend" 2>/dev/null | tr -d '\r' || true)
if [[ "$TRACELOG" == *"fit ok"* || "$TRACELOG" == *"fit fitted"* || "$TRACELOG" == *"[fit]"* ]]; then
    pass 'the attachment was fitted and the encode decision was recorded'
else
    fail 'no fit decision recorded: the attachment never reached the encoder'
    printf '%s\n' "$TRACELOG" | sed 's/^/    | /'
fi

if [[ "$TRACELOG" == *"linked to message"* ]]; then
    pass 'the outbox row was linked to the app message (no duplicate on re-entry)'
else
    fail 'outbox row not linked to the app message: the picture would appear twice'
    printf '%s\n' "$TRACELOG" | sed 's/^/    | /'
fi

# The default-SIM send forced above must have reached the transport on that id.
# This is smoke coverage, not the regression gate: on this AVD
# getSmsManagerForSubscriptionId(-1) does not throw, so a build without
# usesDefaultSmsManager sends identically here and the two cannot be told apart
# from adb. The gate is JUnit (DefaultSmsManagerTest for the rule,
# DefaultSimSendWiringTest for the constant it has to agree with); this only
# proves the default-SIM path still sends end to end.
SIMID=$(adb_ shell "run-as '$PKG' cat $SETTINGS_PREFS" 2>/dev/null | tr -d '\r' \
    | sed -n 's/.*name="sim_subscription_id"[^>]*value="\(-*[0-9]*\)".*/\1/p' | head -1)
info "stored default-SIM subscription id: ${SIMID:-<unset>}"
if [[ -z "$SIMID" || "$SIMID" -le 0 ]]; then
    pass 'sending on the default SMS SIM (a non-positive subscription id)'
else
    fail "expected the default SIM (a non-positive id) but found $SIMID"
fi

if [[ "$TRACELOG" == *"sub=$SIMID"* || "$TRACELOG" == *"sub=-1"* ]]; then
    pass "the send ran on subscription $SIMID"
else
    fail "the send did not run on the stored subscription $SIMID"
    printf '%s\n' "$TRACELOG" | grep -i 'sendmms start' | sed 's/^/    | /'
fi

if printf '%s' "$TRACELOG" | grep -qiE 'invalid sub|InvalidSubscriptionId'; then
    fail 'the platform MMS service rejected the subscription id on a default-SIM send'
    printf '%s\n' "$TRACELOG" | grep -iE 'invalid sub' | sed 's/^/    | /'
else
    pass 'no invalid-subscription error on a default-SIM send'
fi

# A send that fails is only diagnosable if the line says how: the result code
# alone cannot separate "the MMSC refused" from "no route", and downloads already
# carry the HTTP status. Matched on the send line itself — the download sweep
# logs its own httpStatus= on every start and would satisfy a looser check.
SENDFINISHED=$(printf '%s\n' "$TRACELOG" | grep 'MMS send finished:' | tail -1)
if [[ -n "$SENDFINISHED" ]]; then
    pass 'the send reported a result'
else
    fail 'no send result line: the send never called back'
fi
if [[ "$SENDFINISHED" == *"httpStatus="* ]]; then
    pass 'the send result line carries the HTTP status'
else
    fail 'the send result line has no httpStatus, so a failing send cannot be diagnosed'
    printf '    | %s\n' "$SENDFINISHED"
fi

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
