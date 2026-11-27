#!/usr/bin/env bash
# Issue #523: an MMS attachment send must play the same little sound as a text.
# The play path is asserted from logcat, not from audio: the sound is decided by
# the send-sound switch and the MMS call site, and both are text-visible there.
source "$(dirname "$0")/env.sh"
set -uo pipefail

PASS=0
FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
info() { printf '\n=== %s ===\n' "$1"; }

[[ "$ANDROID_SERIAL" == emulator-* ]] || { printf 'Requires a disposable emulator.\n'; exit 1; }
[[ "$(adb_ shell id -u | tr -d '\r')" == 0 ]] || { printf 'Run adb root on the test emulator first.\n'; exit 1; }

MARKER="mmssound$(date +%s)$$"
ADDRESS="+1557$(date +%s | tail -c 7)"
MEDIA_URI="content://$PKG.fileprovider/camera/$MARKER.png"
PREFS="shared_prefs/messages_settings.xml"
PROVDB="/data/data/com.android.providers.telephony/databases/mmssms.db"
local_query() { adb_ shell "run-as $PKG sqlite3 databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r'; }
pref_value() {
    adb_ shell "run-as $PKG cat $PREFS" 2>/dev/null | tr -d '\r' \
        | sed -n "s/.*name=\"$1\"[^>]*value=\"\([^\"]*\)\".*/\1/p" | head -1
}
set_send_sound() { # true | false | absent
    if [ "$1" = absent ]; then
        adb_ shell "run-as $PKG sed -i '/send_sound_enabled/d' $PREFS" >/dev/null 2>&1 || true
    else
        adb_ shell "run-as $PKG sh -c 'sed -i \"/send_sound_enabled/d; s#</map>#<boolean name=\\\"send_sound_enabled\\\" value=\\\"$1\\\" /></map>#\" $PREFS'" >/dev/null 2>&1 || true
    fi
}

SEND_BEFORE=$(pref_value send_sound_enabled)
SIM_BEFORE=$(pref_value sim_subscription_id)
cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    set_send_sound "${SEND_BEFORE:-absent}"
    [ -n "$SIM_BEFORE" ] && adb_ shell "run-as $PKG sed -i 's#<int name=\"sim_subscription_id\" value=\"-*[0-9]*\"#<int name=\"sim_subscription_id\" value=\"$SIM_BEFORE\"#' $PREFS" >/dev/null 2>&1 || true
    adb_ shell "sqlite3 '$PROVDB' 'DELETE FROM part WHERE mid IN (SELECT _id FROM pdu WHERE m_type=128); DELETE FROM addr WHERE msg_id IN (SELECT _id FROM pdu WHERE m_type=128); DELETE FROM pdu WHERE m_type=128;'" >/dev/null 2>&1 || true
    local_query "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$ADDRESS'); DELETE FROM conversations WHERE address='$ADDRESS'; DELETE FROM participants WHERE normalized_destination='$ADDRESS';" >/dev/null || true
    adb_ shell "run-as $PKG rm -f cache/camera/$MARKER.png" >/dev/null 2>&1 || true
    rm -f "/tmp/$MARKER.png"
}
trap cleanup EXIT

adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1 || true
adb_ shell "run-as $PKG sed -i 's#<int name=\"sim_subscription_id\" value=\"-*[0-9]*\"#<int name=\"sim_subscription_id\" value=\"-1\"#' $PREFS" >/dev/null 2>&1 || true

info "Seed a tiny picture for the MMS probe"
python3 - "$MARKER" <<'PY'
import struct, sys, zlib
marker = sys.argv[1]
raw = b'\x00\xff\x00\x00'
def chunk(tag, data):
    body = tag + data
    return struct.pack('>I', len(data)) + body + struct.pack('>I', zlib.crc32(body) & 0xffffffff)
png = (b'\x89PNG\r\n\x1a\n'
       + chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 2, 0, 0, 0))
       + chunk(b'IDAT', zlib.compress(raw))
       + chunk(b'IEND', b''))
open('/tmp/%s.png' % marker, 'wb').write(png)
PY
adb_ shell "run-as $PKG mkdir -p cache/camera" >/dev/null 2>&1
adb_ push "/tmp/$MARKER.png" "/data/local/tmp/$MARKER.png" >/dev/null
adb_ shell "run-as $PKG sh -c 'cat /data/local/tmp/$MARKER.png > cache/camera/$MARKER.png'" >/dev/null

send_probe() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    adb_ logcat -c >/dev/null 2>&1 || true
    adb_ shell am start -n "$ACT" >/dev/null 2>&1
    sleep 4
    adb_ shell am start -n "$ACT" --es mms_probe "$MEDIA_URI" --es mms_probe_to "$ADDRESS" >/dev/null 2>&1
    sleep 8
    adb_ shell logcat -d -s SentSound 2>/dev/null | tr -d '\r'
}

info "Send sound on: an attachment send plays the tone"
set_send_sound true
log=$(send_probe)
echo "$log" | sed 's/^/    | /'
printf '%s' "$log" | grep -q 'played source=mms' \
    && pass 'the MMS send played the sent tone' \
    || fail 'no sent tone was played for the MMS'

info "Send sound off: the same send stays quiet"
set_send_sound false
log=$(send_probe)
echo "$log" | sed 's/^/    | /'
if printf '%s' "$log" | grep -q 'played source=mms'; then
    fail 'the sent tone played with the send-sound switch off'
else
    pass 'the send-sound switch mutes the MMS tone too'
fi

printf '\n=== RESULTS: %s passed, %s failed ===\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
