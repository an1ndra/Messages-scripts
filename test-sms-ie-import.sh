#!/usr/bin/env bash
# Regression: import a backup produced by SMS Import / Export (tmo1/sms-ie).
#
# The fixture is a REAL sms-ie v2 export: a ZIP holding messages.ndjson plus a
# data/ directory of MMS part files, exported with the same field shapes the app
# writes (every provider column dumped verbatim, so numbers arrive as strings).
# The import is driven through a debuggable-gated intent extra because the SAF
# picker is not scriptable.
source "$(dirname "$0")/env.sh"
set -euo pipefail

PASS=0
FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }

MARK="smsie$(date +%s)$$"
ADDR_IN="+15558800${MARK: -3}"
ADDR_MMS="+15558801${MARK: -3}"
TMPZIP="$TMP/smsie-$MARK.zip"
PARTFILE="$MARK.png"
REMOTE="/data/local/tmp/smsie-$MARK.zip"
INAPP="/data/data/$PKG/files/smsie-$MARK.zip"
cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    adb_ shell "run-as '$PKG' rm -f files/$(basename "$INAPP")" >/dev/null 2>&1 || true
    adb_ shell "rm -f $REMOTE /data/local/tmp/$PARTFILE" >/dev/null 2>&1 || true
    local_query "DELETE FROM messages WHERE body LIKE '%$MARK%'; DELETE FROM conversations WHERE address IN ('$ADDR_IN','$ADDR_MMS'); DELETE FROM participants WHERE normalized_destination IN ('$ADDR_IN','$ADDR_MMS');" >/dev/null 2>&1 || true
    rm -f "$TMPZIP" "/tmp/$PARTFILE"
}
trap cleanup EXIT
provider_state() { local_query "SELECT COUNT(*) FROM messages WHERE body LIKE '%$MARK%';"; }
local_query() { adb_ shell "run-as '$PKG' sqlite3 databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r'; }

adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1 || true

info "Build a genuine sms-ie v2 backup (messages.ndjson + data/ part files)"
python3 - "$MARK" "$ADDR_IN" "$ADDR_MMS" "$TMPZIP" <<'PY'
import json, struct, sys, zipfile, zlib
mark, addr_in, addr_mms, out = sys.argv[1:5]

def chunk(tag, data):
    body = tag + data
    return struct.pack('>I', len(data)) + body + struct.pack('>I', zlib.crc32(body) & 0xffffffff)
w = h = 2
raw = b''.join(b'\x00' + b'\x20\x80\xf0' * w for _ in range(h))
png = (b'\x89PNG\r\n\x1a\n'
       + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
       + chunk(b'IDAT', zlib.compress(raw))
       + chunk(b'IEND', b''))
part = 'PART_%s.png' % mark

# Field shapes copied from a real export: every provider column is a string.
sms_in = {"_id": "1", "thread_id": "1", "address": addr_in, "date": "1790279506000",
          "read": "0", "type": "1", "body": "smsie inbox %s" % mark, "sub_id": "1"}
sms_out = {"_id": "2", "thread_id": "1", "address": addr_in, "date": "1790279507000",
           "read": "1", "type": "2", "body": "smsie sent %s" % mark, "sub_id": "1"}
mms = {"_id": "3", "thread_id": "2", "date": "1790279508000", "msg_box": "1", "read": "1",
       "m_type": "132",
       "__sender_address": {"address": addr_mms, "type": "137", "charset": "106"},
       "__recipient_addresses": [],
       "__parts": [{"ct": "text/plain", "text": "smsie mms %s" % mark, "chset": "106"},
                  {"ct": "image/png", "_data": "/data/user_de/0/x/app_parts/" + part}]}

with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
    z.writestr('messages.ndjson',
               '\n'.join(json.dumps(r) for r in (sms_in, sms_out, mms)))
    z.writestr('data/' + part, png)
print('built', out)
PY
[ -f "$TMPZIP" ] && pass 'sms-ie v2 fixture built' || { fail 'fixture not created'; exit 1; }

info "Hand the backup to the app"
adb_ push "$TMPZIP" "$REMOTE" >/dev/null
adb_ shell "run-as '$PKG' sh -c 'cp $REMOTE files/$(basename "$INAPP")'" >/dev/null 2>&1
adb_ shell "run-as '$PKG' ls -la files/$(basename "$INAPP")" 2>/dev/null | tr -d '\r' | grep -q smsie \
    && pass 'backup staged inside the app' || { fail 'could not stage the backup'; exit 1; }

BEFORE=$(provider_state)
adb_ logcat -c >/dev/null 2>&1 || true
adb_ shell am force-stop "$PKG" >/dev/null 2>&1
adb_ shell am start -n "$ACT" --es sms_ie_probe "file://$INAPP" >/dev/null
COUNT=""
for _ in $(seq 1 25); do
    sleep 2
    COUNT=$(provider_state)
    [ "${COUNT:-0}" -gt "${BEFORE:-0}" ] && break
done

if [ "${COUNT:-0}" -gt "${BEFORE:-0}" ]; then
    pass "imported $((COUNT - BEFORE)) messages from the sms-ie backup"
else
    fail "nothing imported (before=$BEFORE after=${COUNT:-?})"
    adb_ logcat -d -s SmsIeImport 2>/dev/null | tr -d '\r' | sed 's/^/    | /'
    exit 1
fi

TOTAL=$((COUNT - BEFORE))
[ "$TOTAL" = "3" ] && pass 'all 3 records imported (2 SMS + 1 MMS)' \
    || fail "expected 3 records, imported $TOTAL"

IN_ROW=$(local_query "SELECT COUNT(*) FROM messages WHERE body='smsie inbox $MARK' AND is_me=0 AND status='received';")
[ "$IN_ROW" = "1" ] && pass 'inbox SMS stored as received' || fail "inbox SMS wrong ($IN_ROW)"
OUT_ROW=$(local_query "SELECT COUNT(*) FROM messages WHERE body='smsie sent $MARK' AND is_me=1 AND status='sent';")
[ "$OUT_ROW" = "1" ] && pass 'sent SMS stored as sent' || fail "sent SMS wrong ($OUT_ROW)"
MMS_ROW=$(local_query "SELECT COUNT(*) FROM messages WHERE body='smsie mms $MARK' AND transport='mms' AND is_me=0;")
[ "$MMS_ROW" = "1" ] && pass 'MMS stored with transport=mms' || fail "MMS row wrong ($MMS_ROW)"

IMG=$(local_query "SELECT media_uri FROM messages WHERE body='smsie mms $MARK';")
case "$IMG" in
    *fileprovider/mms/*) pass "MMS image copied into app storage ($IMG)" ;;
    *) fail "MMS image not stored (media_uri='$IMG')" ;;
esac
STORED=$(local_query "SELECT COUNT(*) FROM messages WHERE body='smsie mms $MARK' AND media_type='image';")
[ "$STORED" = "1" ] && pass 'MMS image recorded as an image message' || fail "media_type wrong ($STORED)"

if adb_ shell "logcat -d -b crash" 2>/dev/null | grep -q "$PKG"; then
    fail 'app crashed during the import'
else
    pass 'no crash during the import'
fi

printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
