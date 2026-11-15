#!/usr/bin/env bash
# Issue #477: a picture message that has to be fetched shows a "Downloading
# message" notice while the carrier has it, and that notice goes away when the
# transfer reports back.
#
# The transfer itself is the platform's, so the fixture is a pending inbound
# MMS row pointed at an address that never answers: the download is accepted and
# stays "running" for as long as the script needs to look at the shade.
#
#   bash scripts/test-mms-download-notice.sh
set -uo pipefail
cd "$(dirname "$0")"
source ./env.sh

PASS=0
FAIL=0
ok()   { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad()  { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

# The notice lives in the notification shade; uiautomator cannot open the shade
# reliably on this image, so the assertion reads NotificationManager's own dump.
notice_count() {
    # The channel is listed for as long as the app exists, so count live records
    # (pkg + channel on one NotificationRecord line), not the word.
    adb_ shell dumpsys notification --noredact 2>/dev/null \
        | grep -c 'NotificationRecord(.*pkg=com.anindra.messages.*channel=mms_download' || true
}

if ! adb_su id 2>/dev/null | grep -q 'uid=0'; then
    echo "ABORT: this script seeds the telephony provider and needs root (adb_su)" >&2
    exit 2
fi

PROVDB="${PROVDB:-/data/data/com.android.providers.telephony/databases/mmssms.db}"
MARKER="mmsnotice_$(date +%s)_$$"
LOCATION="http://10.255.255.1/$MARKER"
ADDRESS="+1557$(date +%s | tail -c 8)"
STAMP=$(date +%s)

provider() { adb_su "sqlite3 '$PROVDB' \"$1\"" | tr -d '\r'; }
local_query() { adb_ shell "run-as '$PKG' sqlite3 databases/messages.db \"$1\"" | tr -d '\r'; }

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    provider "DELETE FROM pdu WHERE tr_id='$MARKER'; DELETE FROM threads WHERE recipient_ids IN (SELECT CAST(_id AS TEXT) FROM canonical_addresses WHERE address='$ADDRESS'); DELETE FROM canonical_addresses WHERE address='$ADDRESS';" >/dev/null 2>&1 || true
    local_query "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$ADDRESS'); DELETE FROM conversations WHERE address='$ADDRESS'; DELETE FROM participants WHERE normalized_destination='$ADDRESS';" >/dev/null 2>&1 || true
}
trap cleanup EXIT

adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1 || true

info "Seed an inbound picture message that still has to be fetched"
provider "BEGIN; INSERT INTO canonical_addresses(address) VALUES('$ADDRESS'); INSERT INTO threads(recipient_ids,date) VALUES(CAST(last_insert_rowid() AS TEXT),${STAMP}000); INSERT INTO pdu(thread_id,date,msg_box,m_type,read,sub_id,ct_l,tr_id) VALUES(last_insert_rowid(),$STAMP,1,130,0,-1,'$LOCATION','$MARKER'); INSERT INTO addr(msg_id,address,type,charset) SELECT _id,'$ADDRESS',137,106 FROM pdu WHERE tr_id='$MARKER'; COMMIT;" >/dev/null
PDU_ID=$(provider "SELECT _id FROM pdu WHERE tr_id='$MARKER';")
[ -n "$PDU_ID" ] && ok "pending MMS seeded (pdu id=$PDU_ID)" || { bad "could not seed a pending MMS"; exit 1; }

info "Opening the app starts the download and posts the notice"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1
adb_ shell am start -n "$ACT" >/dev/null 2>&1

seen=0
for _ in $(seq 1 40); do
    [ "$(notice_count)" -gt 0 ] && { seen=1; break; }
    sleep 0.25
done
[ "$seen" = "1" ] && ok "the 'Downloading message' notice is on screen" \
                   || bad "no download notice appeared while the transfer ran"

info "The notice is gone once the transfer reports back"
# The receiver is not exported, and the shell uid cannot reach it: the platform
# delivers this as the PendingIntent's owner, so the stand-in has to be root.
adb_su "am broadcast -n $PKG/com.anindra.messages.sms.MmsDownloadReceiver \
    -a com.anindra.messages.MMS_DOWNLOAD_COMPLETE \
    --es mms_uri content://mms/$PDU_ID" >/dev/null 2>&1

gone=0
for _ in $(seq 1 40); do
    [ "$(notice_count)" = "0" ] && { gone=1; break; }
    sleep 0.25
done
[ "$gone" = "1" ] && ok "the notice was cancelled when the download finished" \
                  || bad "the notice stayed after the transfer reported back"

info "Result"
echo "  PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && echo "=== OK ===" || echo "=== FAILED ==="
exit $((FAIL > 0))
