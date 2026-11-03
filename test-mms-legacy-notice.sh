#!/usr/bin/env bash
# A multi-picture MMS imported before #398 kept one picture row plus the
# "[MMS: N additional/unsupported attachment(s) not displayed]" notice. Later
# imports backfilled a row per picture, but the per-part skip (#364) treats an
# MMS whose parts are all stored as done, so it never re-read the row and the
# notice stayed on screen under the album. A row that still says something was
# not displayed has to be re-read, because only the provider can say whether
# that is true.
source "$(dirname "$0")/env.sh"
set -euo pipefail

PASS=0
FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
[[ "$ANDROID_SERIAL" == emulator-* ]] || { printf 'Requires a disposable emulator.\n'; exit 1; }
[[ "$(adb_ shell id -u | tr -d '\r')" == 0 ]] || { printf 'Run adb root on the test emulator first.\n'; exit 1; }

PROVDB="${PROVDB:-/data/data/com.android.providers.telephony/databases/mmssms.db}"
MARKER="mmsnotice_$(date +%s)_$$"
ADDRESS="+1555$(date +%s | tail -c 8)"
STAMP=$(date +%s)
NOTICE='[MMS: 2 additional/unsupported attachment(s) not displayed]'
provider() { adb_ shell "sqlite3 '$PROVDB' \"$1\"" | tr -d '\r'; }
local_query() { adb_ shell "run-as '$PKG' sqlite3 databases/messages.db \"$1\"" | tr -d '\r'; }

[[ "$(provider "SELECT COUNT(*) FROM canonical_addresses WHERE address='$ADDRESS';")" == 0 ]] || exit 1
[[ "$(local_query "SELECT COUNT(*) FROM conversations WHERE address='$ADDRESS';")" == 0 ]] || exit 1

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    provider "DELETE FROM pdu WHERE tr_id='$MARKER'; DELETE FROM threads WHERE recipient_ids IN (SELECT CAST(_id AS TEXT) FROM canonical_addresses WHERE address='$ADDRESS'); DELETE FROM canonical_addresses WHERE address='$ADDRESS';" >/dev/null || true
    local_query "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$ADDRESS'); DELETE FROM conversations WHERE address='$ADDRESS'; DELETE FROM participants WHERE normalized_destination='$ADDRESS';" >/dev/null || true
}
trap cleanup EXIT

# A build installed over a database from another branch has not opened it yet,
# and the legacy rows below go through an index that only exists after the
# schema upgrade. One launch settles it; the fixture is seeded afterwards.
adb_ shell am start -n "$ACT" >/dev/null 2>&1
sleep 6
adb_ shell am force-stop "$PKG" >/dev/null

# Three pictures plus the SMIL slide: exactly what the reporter's album is.
provider "BEGIN; INSERT INTO canonical_addresses(address) VALUES('$ADDRESS'); INSERT INTO threads(recipient_ids,date) VALUES(CAST(last_insert_rowid() AS TEXT),${STAMP}000); INSERT INTO pdu(thread_id,date,msg_box,m_type,read,sub_id,tr_id) VALUES(last_insert_rowid(),$STAMP,1,132,1,-1,'$MARKER'); INSERT INTO addr(msg_id,address,type,charset) SELECT _id,'$ADDRESS',137,106 FROM pdu WHERE tr_id='$MARKER'; INSERT INTO part(mid,ct) SELECT _id,'application/smil' FROM pdu WHERE tr_id='$MARKER'; INSERT INTO part(mid,ct) SELECT _id,'image/png' FROM pdu WHERE tr_id='$MARKER'; INSERT INTO part(mid,ct) SELECT _id,'image/png' FROM pdu WHERE tr_id='$MARKER'; INSERT INTO part(mid,ct) SELECT _id,'image/png' FROM pdu WHERE tr_id='$MARKER'; COMMIT;" >/dev/null

MID=$(provider "SELECT _id FROM pdu WHERE tr_id='$MARKER';")
PARTS=($(provider "SELECT _id FROM part WHERE mid=$MID AND ct LIKE 'image/%' ORDER BY _id;"))
[[ "$MID" =~ ^[0-9]+$ && ${#PARTS[@]} -eq 3 ]] || { fail 'provider fixture carries three picture parts'; exit 1; }
pass 'provider fixture carries three picture parts'

# The state left by the pre-#398 import: a row for every part (so the MMS is
# complete) and the notice still on the first picture's body.
adb_ shell am force-stop "$PKG" >/dev/null
local_query "INSERT INTO conversations(address,name,timestamp) VALUES('$ADDRESS','$ADDRESS',${STAMP}000);"
CID=$(local_query "SELECT id FROM conversations WHERE address='$ADDRESS';")
local_query "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,media_type,media_uri,sys_id,transport,sub_id) VALUES($CID,'$NOTICE',${STAMP}000,0,'received','image','content://mms/part/${PARTS[0]}',$MID,'mms',-1);"
for part in "${PARTS[@]:1}"; do
    local_query "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,media_type,media_uri,sys_id,transport,sub_id) VALUES($CID,'',${STAMP}000,0,'received','image','content://mms/part/$part',$MID,'mms',-1);"
done
[[ "$(local_query "SELECT COUNT(*) FROM messages WHERE transport='mms' AND sys_id=$MID;")" == 3 ]] || { fail 'complete local album seeded'; exit 1; }
pass 'complete local album seeded'

adb_ shell am start -n "$ACT" >/dev/null
sleep 5
if dump_ui && grep -Fq 'Set as default SMS app?' "$TMP/ui.xml"; then
    tap_text 'Not now'
    sleep 2
fi
BODY="$NOTICE"
for _ in $(seq 1 15); do
    sleep 2
    BODY=$(local_query "SELECT body FROM messages WHERE transport='mms' AND sys_id=$MID AND media_uri='content://mms/part/${PARTS[0]}';")
    [[ "$BODY" != *"additional/unsupported"* ]] && break
done

if [[ "$BODY" != *"additional/unsupported"* ]]; then
    pass 'stale notice cleared on a complete provider MMS'
else
    fail 'stale notice cleared on a complete provider MMS'
fi
[[ "$(local_query "SELECT COUNT(*) FROM messages WHERE transport='mms' AND sys_id=$MID;")" == 3 ]] \
    && pass 'the re-read does not duplicate the album' \
    || fail 'the re-read does not duplicate the album'

printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
