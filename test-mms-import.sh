#!/usr/bin/env bash
source "$(dirname "$0")/env.sh"
set -euo pipefail

PASS=0
FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
[[ "$ANDROID_SERIAL" == emulator-* ]] || { printf 'Requires a disposable emulator.\n'; exit 1; }
[[ "$(adb_ shell id -u | tr -d '\r')" == 0 ]] || { printf 'Run adb root on the test emulator first.\n'; exit 1; }
PROVDB="${PROVDB:-/data/data/com.android.providers.telephony/databases/mmssms.db}"
MARKER="mms210_$(date +%s)_$$"
ADDRESS="+1555$(date +%s | tail -c 8)"
STAMP=$(date +%s)
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
provider "BEGIN; INSERT INTO canonical_addresses(address) VALUES('$ADDRESS'); INSERT INTO threads(recipient_ids,date) VALUES(CAST(last_insert_rowid() AS TEXT),${STAMP}000); INSERT INTO pdu(thread_id,date,msg_box,m_type,read,sub_id,tr_id) VALUES(last_insert_rowid(),$STAMP,1,132,1,-1,'$MARKER'); INSERT INTO addr(msg_id,address,type,charset) SELECT _id,'$ADDRESS',137,106 FROM pdu WHERE tr_id='$MARKER'; INSERT INTO part(mid,ct,text,chset) SELECT _id,'text/plain','$MARKER',106 FROM pdu WHERE tr_id='$MARKER'; COMMIT;" >/dev/null
FIXTURE=$(provider "SELECT COUNT(*) FROM pdu JOIN addr ON addr.msg_id=pdu._id JOIN part ON part.mid=pdu._id JOIN threads ON threads._id=pdu.thread_id WHERE pdu.tr_id='$MARKER' AND pdu.msg_box=1 AND pdu.m_type=132 AND addr.address='$ADDRESS' AND addr.type=137 AND part.ct='text/plain' AND part.text='$MARKER';")
[[ "$FIXTURE" == 1 ]] || { fail 'complete MMS fixture exists in active provider database'; exit 1; }
pass 'complete MMS fixture exists in active provider database'
restart() {
    adb_ shell am force-stop "$PKG" >/dev/null
    adb_ shell am start -n "$ACT" >/dev/null
    sleep 5
    if dump_ui && grep -Fq 'Set as default SMS app?' "$TMP/ui.xml"; then
        tap_text 'Not now'
        sleep 2
    fi
}
restart
for _ in 1 2 3 4 5; do
    [[ "$(local_query "SELECT COUNT(*) FROM messages WHERE body='$MARKER';")" == 1 ]] && break
    sleep 2
done
if [[ "$(local_query "SELECT COUNT(*) FROM messages WHERE body='$MARKER';")" == 1 ]]; then
    pass 'existing provider MMS imported'
else
    fail 'existing provider MMS imported'
    exit 1
fi
if [[ "$(local_query "SELECT transport || '|' || timestamp || '|' || sub_id FROM messages WHERE body='$MARKER';")" == "mms|${STAMP}000|-1" ]]; then
    pass 'transport, timestamp and subscription preserved'
else
    fail 'transport, timestamp and subscription preserved'
fi
restart
[[ "$(local_query "SELECT COUNT(*) FROM messages WHERE body='$MARKER';")" == 1 ]] && pass 'reimport is idempotent' || fail 'reimport duplicated message'
adb_ shell am start -n "$ACT" --es open_conversation_address "$ADDRESS" >/dev/null
sleep 3
FOUND=0
for _ in 1 2 3; do
    if dump_ui && grep -Fq "$MARKER" "$TMP/ui.xml"; then FOUND=1; break; fi
    sleep 2
done
[[ "$FOUND" == 1 ]] && pass 'MMS text rendered in conversation' || fail 'MMS text missing in conversation'
printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
