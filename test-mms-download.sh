#!/usr/bin/env bash
# Regression for #236: an incoming MMS is announced to the default SMS app as an
# empty m_type=130 row, and the app itself has to download it (the platform no
# longer does). Seeds such a pending row straight into the provider, resumes the
# app and asserts a download was requested for it — from the row's own
# Content-Location (ct_l), not from a made-up URL. The WAP push half: the
# broadcast carries the PDU in its "data" extra and no data URI, so the receiver
# must sweep the pending rows rather than read intent.data.
source "$(dirname "$0")/env.sh"
set -euo pipefail

PASS=0
FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
[[ "$ANDROID_SERIAL" == emulator-* ]] || { printf 'Requires a disposable emulator.\n'; exit 1; }
[[ "$(adb_ shell id -u | tr -d '\r')" == 0 ]] || { printf 'Run adb root on the test emulator first.\n'; exit 1; }
PROVDB="${PROVDB:-/data/data/com.android.providers.telephony/databases/mmssms.db}"
MARKER="mmsdl_$(date +%s)_$$"
LOCATION="http://mmsc.local/$MARKER"
ADDRESS="+1556$(date +%s | tail -c 8)"
STAMP=$(date +%s)
provider() { adb_ shell "sqlite3 '$PROVDB' \"$1\"" | tr -d '\r'; }
local_query() { adb_ shell "run-as '$PKG' sqlite3 databases/messages.db \"$1\"" | tr -d '\r'; }

[[ "$(provider "SELECT COUNT(*) FROM canonical_addresses WHERE address='$ADDRESS';")" == 0 ]] || exit 1
cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    provider "DELETE FROM pdu WHERE tr_id='$MARKER' OR tr_id='$MARKER-b'; DELETE FROM threads WHERE recipient_ids IN (SELECT CAST(_id AS TEXT) FROM canonical_addresses WHERE address='$ADDRESS'); DELETE FROM canonical_addresses WHERE address='$ADDRESS';" >/dev/null || true
    local_query "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$ADDRESS'); DELETE FROM conversations WHERE address='$ADDRESS'; DELETE FROM participants WHERE normalized_destination='$ADDRESS';" >/dev/null || true
}
trap cleanup EXIT

adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1 || true

info "Seed an announced-but-undownloaded inbound MMS with its Content-Location (msg_box=1, m_type=130, no parts)"
provider "BEGIN; INSERT INTO canonical_addresses(address) VALUES('$ADDRESS'); INSERT INTO threads(recipient_ids,date) VALUES(CAST(last_insert_rowid() AS TEXT),${STAMP}000); INSERT INTO pdu(thread_id,date,msg_box,m_type,read,sub_id,ct_l,tr_id) VALUES(last_insert_rowid(),$STAMP,1,130,0,-1,'$LOCATION','$MARKER'); INSERT INTO addr(msg_id,address,type,charset) SELECT _id,'$ADDRESS',137,106 FROM pdu WHERE tr_id='$MARKER'; COMMIT;" >/dev/null
PDU_ID=$(provider "SELECT _id FROM pdu WHERE tr_id='$MARKER';")
FIXTURE=$(provider "SELECT COUNT(*) FROM pdu JOIN addr ON addr.msg_id=pdu._id WHERE pdu.tr_id='$MARKER' AND pdu.msg_box=1 AND pdu.m_type=130 AND pdu.ct_l='$LOCATION' AND addr.address='$ADDRESS';")
[[ "$FIXTURE" == 1 ]] || { fail 'pending MMS fixture exists in active provider database'; exit 1; }
pass "pending MMS fixture exists (pdu id=$PDU_ID)"
[[ "$(provider "SELECT COUNT(*) FROM part WHERE mid=$PDU_ID;")" == 0 ]] \
    && pass 'pending MMS has no parts yet (nothing downloaded it)' \
    || fail 'pending MMS unexpectedly has parts'

adb_ shell logcat -c >/dev/null 2>&1 || true
info "Resume the app so it sweeps for MMS it still has to fetch"
adb_ shell am start -n "$ACT" >/dev/null
sleep 8
if dump_ui && grep -Fq 'Set as default SMS app?' "$TMP/ui.xml"; then
    tap_text 'Not now' >/dev/null 2>&1 || true
    sleep 2
fi
adb_ shell am start -n "$ACT" >/dev/null
sleep 6

LOGS=$(adb_ shell "logcat -d -s MmsDownload" 2>/dev/null | tr -d '\r' || true)
if [[ "$LOGS" == *"MMS download requested for content://mms/$PDU_ID from $LOCATION"* ]]; then
    pass "app requested the MMS download for content://mms/$PDU_ID from its Content-Location"
else
    fail "no download requested for content://mms/$PDU_ID from $LOCATION (dropped, or fetched from a made-up URL)"
    printf '%s\n' "$LOGS" | sed 's/^/    | /'
fi

info "A WAP push carries the PDU in its 'data' extra and no data URI, so it must trigger the same sweep"
PDU_B=$(provider "INSERT INTO pdu(thread_id,date,msg_box,m_type,read,sub_id,ct_l,tr_id) VALUES(0,$STAMP,1,130,0,1,'$LOCATION-b','$MARKER-b'); SELECT last_insert_rowid();" | tail -1)
[[ -n "$PDU_B" ]] || { fail 'could not seed a second announced MMS'; exit 1; }
adb_ shell logcat -c >/dev/null 2>&1 || true
# Explicit component: a shell-sent implicit WAP_PUSH_DELIVER is never dispatched
# by AMS, so the filter cannot be exercised from adb. The receiver's handling of
# the action+type pair itself is what regressed, and it runs identically here.
adb_ shell am broadcast -a android.provider.Telephony.WAP_PUSH_DELIVER -t application/vnd.wap.mms-message -n "$PKG/.sms.MmsReceiver" >/dev/null
sleep 3
PUSHLOGS=$(adb_ shell "logcat -d -s MmsDownload" 2>/dev/null | tr -d '\r' || true)
if [[ "$PUSHLOGS" == *"MMS download requested for content://mms/$PDU_B from $LOCATION-b"* ]]; then
    pass "WAP push requested the MMS download for content://mms/$PDU_B"
else
    fail "WAP push was dropped: no download requested for content://mms/$PDU_B"
    printf '%s\n' "$PUSHLOGS" | sed 's/^/    | /'
fi

if [[ "$(local_query "SELECT COUNT(*) FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$ADDRESS');")" == 0 ]]; then
    pass 'undownloaded MMS is not imported as an empty message'
else
    fail 'undownloaded MMS was imported without being downloaded'
fi

if adb_ shell "logcat -d -b crash" 2>/dev/null | grep -q "$PKG"; then
    fail 'app crashed while handling the pending MMS'
else
    pass 'no crash while handling the pending MMS'
fi

printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
