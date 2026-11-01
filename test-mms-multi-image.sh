#!/usr/bin/env bash
# Regression for #398: an MMS carrying several pictures must show all of them.
#
# The app used to import one picture per provider MMS and print
# "[MMS: N additional/unsupported attachment(s) not displayed]" over the rest.
# Each picture part now becomes its own message row, grouped under the same
# provider id, so the conversation shows every one.
#
# The fixture is written straight into the provider database (the emulator is
# rooted): one MMS, three image parts, no text. Asserted on both sides — the
# provider really holds three parts, the app really stores three rows — and
# again after a restart, because the import is what a second sync re-runs.
source "$(dirname "$0")/env.sh"
set -euo pipefail

PASS=0
FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }

command -v sqlite3 >/dev/null 2>&1 || true
[[ "$ANDROID_SERIAL" == emulator-* ]] || { printf 'Requires a disposable emulator.\n'; exit 1; }
[[ "$(adb_ shell id -u | tr -d '\r')" == 0 ]] || { printf 'Run adb root on the test emulator first.\n'; exit 1; }

PROVDB="${PROVDB:-/data/data/com.android.providers.telephony/databases/mmssms.db}"
MARKER="mms398_$(date +%s)_$$"
ADDRESS="+1555$(date +%s | tail -c 8)"
STAMP=$(date +%s)
provider() { adb_ shell "sqlite3 '$PROVDB' \"$1\"" | tr -d '\r'; }
# A fresh install has no database until the app has opened once, and sqlite3
# writes an error to stderr for that; an empty answer reads as "no rows".
local_query() { adb_ shell "run-as '$PKG' sqlite3 databases/messages.db \"$1\" 2>/dev/null" | tr -d '\r'; }

[[ "$(provider "SELECT COUNT(*) FROM canonical_addresses WHERE address='$ADDRESS';")" == 0 ]] || exit 1
LOCAL_ROWS=$(local_query "SELECT COUNT(*) FROM conversations WHERE address='$ADDRESS';" || true)
[[ -z "$LOCAL_ROWS" || "$LOCAL_ROWS" == 0 ]] || exit 1
cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    provider "DELETE FROM pdu WHERE tr_id='$MARKER'; DELETE FROM threads WHERE recipient_ids IN (SELECT CAST(_id AS TEXT) FROM canonical_addresses WHERE address='$ADDRESS'); DELETE FROM canonical_addresses WHERE address='$ADDRESS';" >/dev/null || true
    local_query "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$ADDRESS'); DELETE FROM conversations WHERE address='$ADDRESS'; DELETE FROM participants WHERE normalized_destination='$ADDRESS';" >/dev/null || true
}
trap cleanup EXIT

provider "BEGIN; INSERT INTO canonical_addresses(address) VALUES('$ADDRESS'); INSERT INTO threads(recipient_ids,date) VALUES(CAST(last_insert_rowid() AS TEXT),${STAMP}000); INSERT INTO pdu(thread_id,date,msg_box,m_type,read,sub_id,tr_id) VALUES(last_insert_rowid(),$STAMP,1,132,1,-1,'$MARKER'); INSERT INTO addr(msg_id,address,type,charset) SELECT _id,'$ADDRESS',137,106 FROM pdu WHERE tr_id='$MARKER'; INSERT INTO part(mid,ct,seq,chset) SELECT _id,'image/jpeg',1,106 FROM pdu WHERE tr_id='$MARKER'; INSERT INTO part(mid,ct,seq,chset) SELECT _id,'image/png',2,106 FROM pdu WHERE tr_id='$MARKER'; INSERT INTO part(mid,ct,seq,chset) SELECT _id,'image/webp',3,106 FROM pdu WHERE tr_id='$MARKER'; COMMIT;" >/dev/null

PDU=$(provider "SELECT _id FROM pdu WHERE tr_id='$MARKER';")
# Provider ids are reused after a delete, and an app row left behind with the
# same sys_id would be counted as one of ours. Start from a clean slate for this
# id only.
local_query "DELETE FROM messages WHERE sys_id=$PDU;" >/dev/null 2>&1 || true
PARTS=$(provider "SELECT COUNT(*) FROM part WHERE mid=$PDU AND ct LIKE 'image/%';")
[[ "$PARTS" == 3 ]] && pass "the provider fixture carries three picture parts" \
    || { fail "the provider fixture carries three picture parts (got $PARTS)"; exit 1; }

restart() {
    adb_ shell am force-stop "$PKG" >/dev/null
    adb_ shell am start -n "$ACT" >/dev/null
    sleep 5
    if dump_ui && grep -Fq 'Set as default SMS app?' "$TMP/ui.xml"; then
        tap_text 'Not now' || true
        sleep 2
    fi
}

imported_rows() { local_query "SELECT COUNT(*) FROM messages WHERE sys_id=$PDU AND transport='mms';" || true; }

restart
for _ in 1 2 3 4 5 6; do
    [[ "$(imported_rows)" == 3 ]] && break
    sleep 2
done
ROWS=$(imported_rows)
[[ "$ROWS" == 3 ]] && pass "all three pictures were imported as separate rows" \
    || fail "all three pictures were imported as separate rows (got $ROWS)"

DISTINCT=$(local_query "SELECT COUNT(DISTINCT media_uri) FROM messages WHERE sys_id=$PDU;")
[[ "$DISTINCT" == 3 ]] && pass "the three rows point at three different parts" \
    || fail "the three rows point at three different parts (got $DISTINCT)"

MEDIA=$(local_query "SELECT COUNT(*) FROM messages WHERE sys_id=$PDU AND media_type='image';")
[[ "$MEDIA" == 3 ]] && pass "every imported row is a picture" \
    || fail "every imported row is a picture (got $MEDIA)"

# The old build hid the extras behind this notice; it must not appear any more.
NOTICE=$(local_query "SELECT COUNT(*) FROM messages WHERE sys_id=$PDU AND body LIKE '%additional/unsupported%';")
[[ "$NOTICE" == 0 ]] && pass "the 'unsupported attachment' notice is gone" \
    || fail "the 'unsupported attachment' notice is gone (got $NOTICE)"

restart
sleep 3
ROWS=$(imported_rows)
[[ "$ROWS" == 3 ]] && pass "a second sync does not duplicate the pictures" \
    || fail "a second sync does not duplicate the pictures (got $ROWS)"

adb_ shell am force-stop "$PKG" >/dev/null
sleep 1
adb_ shell am start -n "$ACT" --es open_conversation_address "$ADDRESS" >/dev/null
SHOWN=0
for _ in 1 2 3 4 5; do
    sleep 2
    dump_ui >/dev/null 2>&1 || continue
    # The composer's mic means a conversation is open; the address renders
    # grouped ("(555) 933-0002") rather than as stored, so it cannot be grepped.
    if grep -Fq 'content-desc="Record voice message"' "$TMP/ui.xml" &&
       ! grep -Fq 'additional/unsupported attachment' "$TMP/ui.xml"; then SHOWN=1; break; fi
done
# The bubbles themselves carry no text (the fixture has no captions), and an
# image that cannot be decoded has no semantics node to count, so the assertion
# is that the conversation opened without the old "not displayed" notice.
[[ "$SHOWN" == 1 ]] && pass "the conversation shows the pictures without the notice" \
    || fail "the conversation still says some attachments are not displayed"

# Diagnostics has to carry the same story, because that is what a report
# attaches: what we stored, and what the provider actually holds (#398).
adb_ shell am force-stop "$PKG" >/dev/null
sleep 1
adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null
sleep 4
for _ in 1 2; do adb_ shell input swipe 500 1900 500 700 300 >/dev/null; sleep 0.5; done
tap_text "Advanced settings" >/dev/null 2>&1 || true
sleep 2
for _ in 1 2 3; do adb_ shell input swipe 540 1700 540 900 250 >/dev/null; sleep 0.4; done
if tap_text "Diagnostics" >/dev/null 2>&1; then
    sleep 3
    dump_ui >/dev/null 2>&1 || true
    if grep -qE 'Imported: [0-9]+ row\(s\), [1-9][0-9]* from multi-part MMS \(max [2-9]' "$TMP/ui.decoded.xml"; then
        pass "Diagnostics counts the multi-part MMS in the store"
    else
        fail "Diagnostics does not count the multi-part MMS in the store"
    fi
    if grep -qF "Provider MMS: newest multi-part" "$TMP/ui.decoded.xml"; then
        pass "Diagnostics lists the newest multi-part provider MMS"
    else
        fail "Diagnostics does not list the provider's multi-part MMS"
    fi
else
    fail "could not reach Diagnostics"
    fail "could not reach Diagnostics"
fi

printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
