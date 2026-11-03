#!/usr/bin/env bash
# Regression for #398: an MMS carrying several pictures must show all of them,
# as one message.
#
# The app used to import one picture per provider MMS and print
# "[MMS: N additional/unsupported attachment(s) not displayed]" over the rest.
# Each picture part now becomes its own message row under the same provider id,
# and the chat folds those rows into one bubble showing every picture as a grid.
#
# The fixture is written straight into the provider database (the emulator is
# rooted): one MMS, three image parts, no text. Asserted on both sides — the
# provider really holds three parts, the app really stores three rows — and
# again after a restart, because the import is what a second sync re-runs. The
# last checks put back the notice an old import wrote and prove the versioned
# re-scan clears it and the chat draws one album instead of three messages. A
# final section adds three more parts and proves the album pages four at a time.
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
    || { fail "all three pictures were imported as separate rows (got $ROWS)"; exit 1; }

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

# A row imported before the multi-picture fix carried the notice in its body and
# covered only the first picture. Put that state back — the notice, and the two
# extra rows deleted — and let the next sync fill them in from the provider. No
# one-shot migration flag is involved any more: the import compares the stored
# part URIs with the provider's own part index on every pass (#364 M2/M3).
adb_ shell am force-stop "$PKG" >/dev/null
sleep 2
local_query "UPDATE messages SET body='[MMS: 2 additional/unsupported attachment(s) not displayed]' WHERE sys_id=$PDU AND media_uri=(SELECT MIN(media_uri) FROM messages WHERE sys_id=$PDU);" >/dev/null
local_query "DELETE FROM messages WHERE sys_id=$PDU AND media_uri<>(SELECT MIN(media_uri) FROM messages WHERE sys_id=$PDU);" >/dev/null
NOTICE_SET=$(local_query "SELECT COUNT(*) FROM messages WHERE sys_id=$PDU AND body LIKE '%additional/unsupported%';")
[[ "$NOTICE_SET" == 1 ]] && pass "the fixture carries the notice an old import wrote" \
    || fail "the fixture carries the notice an old import wrote (got $NOTICE_SET)"
OLD_ROWS=$(imported_rows)
[[ "$OLD_ROWS" == 1 ]] && pass "the fixture covers only the first of the three pictures" \
    || fail "the fixture covers only the first of the three pictures (got $OLD_ROWS)"
adb_ shell am start -n "$ACT" >/dev/null
for _ in $(seq 1 20); do
    NOTICE_LEFT=$(local_query "SELECT COUNT(*) FROM messages WHERE sys_id=$PDU AND body LIKE '%additional/unsupported%';")
    [[ "$NOTICE_LEFT" == 0 && "$(imported_rows)" == 3 ]] && break
    sleep 2
done
NOTICE_LEFT=$(local_query "SELECT COUNT(*) FROM messages WHERE sys_id=$PDU AND body LIKE '%additional/unsupported%';")
[[ "$NOTICE_LEFT" == 0 ]] && pass "the sync clears the notice over pictures it now shows" \
    || fail "the sync clears the notice over pictures it now shows (got $NOTICE_LEFT)"
BACKFILLED=$(imported_rows)
[[ "$BACKFILLED" == 3 ]] && pass "the sync backfills the two pictures an old import missed" \
    || fail "the sync backfills the two pictures an old import missed (got $BACKFILLED)"

# The three pictures share one provider MMS, so they must share one bubble: the
# album names itself "3 photos" for a screen reader, and no picture renders as a
# lone "Photo" bubble of its own.
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
       grep -Fq 'content-desc="3 photos"' "$TMP/ui.xml"; then SHOWN=1; break; fi
done
[[ "$SHOWN" == 1 ]] && pass "the conversation draws the pictures as one album" \
    || fail "the conversation does not draw the pictures as one album"
if [[ "$SHOWN" == 1 ]]; then
    if ! grep -Fq 'additional/unsupported attachment' "$TMP/ui.xml"; then
        pass "the conversation no longer says some attachments are not displayed"
    else
        fail "the conversation still says some attachments are not displayed"
    fi
    PHOTO_NODES=$( (grep -o 'content-desc="Photo"' "$TMP/ui.xml" || true) | wc -l | tr -d ' ' )
    [[ "$PHOTO_NODES" == 0 ]] && pass "no picture is a message of its own" \
        || fail "no picture is a message of its own (found $PHOTO_NODES lone photo bubbles)"
else
    # Without a dump the two checks above would pass on an empty file, which is
    # exactly how a broken build slips through.
    fail "the conversation no longer says some attachments are not displayed"
    fail "no picture is a message of its own"
fi

# Save acts on the whole album, not on the first of its rows (#364 M4). The
# album selects as one message, so three save outcomes must come back for the
# three pictures; one means the menu silently kept only part of the bubble.
info "Saving the album saves every picture"
if [[ "$SHOWN" == 1 ]]; then
    ALBUM=$(center_of "3 photos" 2>/dev/null || true)
    SEL=0
    if [[ -n "$ALBUM" ]]; then
        LX=${ALBUM% *}; LY=${ALBUM#* }
        adb_ shell input swipe "$LX" "$LY" "$LX" "$LY" 900 >/dev/null 2>&1 || true
        for _ in 1 2 3 4 5; do
            sleep 0.4
            dump_ui >/dev/null 2>&1 || continue
            if grep -qF 'content-desc="Cancel selection"' "$TMP/ui.xml"; then SEL=1; break; fi
        done
    fi
    [[ "$SEL" == 1 ]] && pass "long-pressing the album opens the selection toolbar" \
        || fail "long-pressing the album did not open the selection toolbar"
    MENU=0
    if [[ "$SEL" == 1 ]]; then
        for _ in 1 2 3 4 5; do
            MC=$(center_of "More options" 2>/dev/null || true)
            [[ -n "$MC" ]] || break
            adb_ shell input tap $MC >/dev/null 2>&1 || true
            for _ in 1 2 3; do
                sleep 0.4
                dump_ui >/dev/null 2>&1 || continue
                if grep -qF 'text="Select all"' "$TMP/ui.xml"; then MENU=1; break 2; fi
            done
        done
    fi
    [[ "$MENU" == 1 ]] && pass "the selection overflow opened" \
        || fail "the selection overflow did not open"
    if [[ "$MENU" == 1 ]]; then
        adb_ shell logcat -c >/dev/null 2>&1 || true
        tap_text "Save image" >/dev/null 2>&1 || true
        SAVES=0
        for _ in $(seq 1 12); do
            sleep 0.5
            adb_ shell logcat -d > "$TMP/logcat.txt" 2>/dev/null || true
            SAVES=$(grep -c 'AttachmentSave:' "$TMP/logcat.txt" 2>/dev/null || true)
            [[ "$SAVES" -ge 3 ]] && break
        done
        [[ "$SAVES" -ge 3 ]] && pass "Save reports one outcome per picture ($SAVES)" \
            || fail "Save reported $SAVES of 3 pictures"
        # The fixture carries part metadata but no bytes, so the MediaStore
        # insert cannot succeed here; what this proves is that Save acted on
        # all three rows. The write itself is covered by the voice save test,
        # which uses a real file.
        TARGETED=$(grep -c 'AttachmentSave: target=IMAGE' "$TMP/logcat.txt" 2>/dev/null || true)
        [[ "$TARGETED" -ge 3 ]] && pass "Save acted on every picture in the album" \
            || fail "Save acted on only $TARGETED of 3 pictures"
    else
        fail "Save reports one outcome per picture (overflow never opened)"
        fail "Save acted on every picture in the album (overflow never opened)"
    fi
else
    fail "long-pressing the album opens the selection toolbar"
    fail "the selection overflow opened"
    fail "Save reports one outcome per picture"
    fail "Save acted on every picture in the album"
fi

# Diagnostics has to carry the same story, because that is what a report
# attaches: what we stored, and what the provider actually holds (#398).
open_diagnostics() {
    local i
    for i in $(seq 1 15); do
        dump_ui >/dev/null 2>&1 || { sleep 1; continue; }
        if grep -qF 'text="Diagnostics"' "$TMP/ui.xml"; then
            tap_text "Diagnostics" >/dev/null 2>&1 && return 0
        elif grep -qF 'text="Advanced settings"' "$TMP/ui.xml" &&
             grep -qF 'text="General settings"' "$TMP/ui.xml"; then
            # Only the settings root carries both rows. Once Advanced settings
            # is tapped its name stays on screen as the title, and tapping the
            # title again left the loop spinning on the wrong screen while the
            # Diagnostics row sat two swipes below it.
            tap_text "Advanced settings" >/dev/null 2>&1 || true
            sleep 2
        else
            adb_ shell input swipe 540 1800 540 800 300 >/dev/null
        fi
        sleep 1
    done
    return 1
}
adb_ shell am force-stop "$PKG" >/dev/null
sleep 1
adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null
sleep 6
if open_diagnostics; then
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

# A big album is paged four pictures at a time. Add three more parts to the
# same MMS, let the next launch backfill them, and prove the badge moves to the
# next page of four and a badge on that page comes back (#398 follow-up).
info "A large album pages in chunks of four"
adb_ shell am force-stop "$PKG" >/dev/null
provider "INSERT INTO part(mid,ct,seq,chset) SELECT _id,'image/jpeg',4,106 FROM pdu WHERE tr_id='$MARKER'; INSERT INTO part(mid,ct,seq,chset) SELECT _id,'image/png',5,106 FROM pdu WHERE tr_id='$MARKER'; INSERT INTO part(mid,ct,seq,chset) SELECT _id,'image/webp',6,106 FROM pdu WHERE tr_id='$MARKER';" >/dev/null
adb_ shell am start -n "$ACT" --es open_conversation_address "$ADDRESS" >/dev/null
PAGED=0
for _ in $(seq 1 20); do
    sleep 2
    [[ "$(imported_rows)" == 6 ]] || continue
    dump_ui >/dev/null 2>&1 || continue
    if grep -Fq 'content-desc="6 photos"' "$TMP/ui.xml"; then PAGED=1; break; fi
done
[[ "$PAGED" == 1 ]] && pass "six pictures import as one six-photo album" \
    || fail "six pictures do not import as one six-photo album"

# Page one shows four of the six, so its badge stands for the two on page two.
NEXT=$(center_of "2 more photos" 2>/dev/null || true)
[[ -n "$NEXT" ]] && pass "the first page advertises the next two pictures" \
    || fail "the first page does not advertise the next two pictures"
if [[ -n "$NEXT" ]]; then
    adb_ shell input tap $NEXT >/dev/null 2>&1 || true
    SECOND=0
    for _ in 1 2 3 4 5; do
        sleep 0.5
        dump_ui >/dev/null 2>&1 || continue
        if ! grep -Fq 'content-desc="2 more photos"' "$TMP/ui.xml" &&
           grep -Fq 'content-desc="Previous photos"' "$TMP/ui.xml"; then SECOND=1; break; fi
    done
    [[ "$SECOND" == 1 ]] && pass "the badge opens the second page of pictures" \
        || fail "the badge does not open the second page of pictures"
    PREV=$(center_of "Previous photos" 2>/dev/null || true)
    [[ -n "$PREV" ]] || PREV=$NEXT
    adb_ shell input tap $PREV >/dev/null 2>&1 || true
    BACK=0
    for _ in 1 2 3 4 5; do
        sleep 0.5
        dump_ui >/dev/null 2>&1 || continue
        if grep -Fq 'content-desc="2 more photos"' "$TMP/ui.xml"; then BACK=1; break; fi
    done
    [[ "$BACK" == 1 ]] && pass "the previous-page badge returns to the first page" \
        || fail "the previous-page badge does not return to the first page"
else
    fail "the badge does not open the second page of pictures"
    fail "the previous-page badge does not return to the first page"
fi

# Twelve pictures are three pages of four, each badge standing for exactly the
# next page rather than the whole remainder ("4+4+4").
provider "INSERT INTO part(mid,ct,seq,chset) SELECT _id,'image/jpeg',7,106 FROM pdu WHERE tr_id='$MARKER'; INSERT INTO part(mid,ct,seq,chset) SELECT _id,'image/png',8,106 FROM pdu WHERE tr_id='$MARKER'; INSERT INTO part(mid,ct,seq,chset) SELECT _id,'image/webp',9,106 FROM pdu WHERE tr_id='$MARKER'; INSERT INTO part(mid,ct,seq,chset) SELECT _id,'image/jpeg',10,106 FROM pdu WHERE tr_id='$MARKER'; INSERT INTO part(mid,ct,seq,chset) SELECT _id,'image/png',11,106 FROM pdu WHERE tr_id='$MARKER'; INSERT INTO part(mid,ct,seq,chset) SELECT _id,'image/webp',12,106 FROM pdu WHERE tr_id='$MARKER';" >/dev/null
adb_ shell am force-stop "$PKG" >/dev/null
adb_ shell am start -n "$ACT" --es open_conversation_address "$ADDRESS" >/dev/null
TWELVE=0
for _ in $(seq 1 20); do
    sleep 2
    [[ "$(imported_rows)" == 12 ]] || continue
    dump_ui >/dev/null 2>&1 || continue
    if grep -Fq 'content-desc="12 photos"' "$TMP/ui.xml"; then TWELVE=1; break; fi
done
[[ "$TWELVE" == 1 ]] && pass "twelve pictures import as one twelve-photo album" \
    || fail "twelve pictures do not import as one twelve-photo album"

FIRST=$(center_of "4 more photos" 2>/dev/null || true)
[[ -n "$FIRST" ]] && pass "the first page of twelve advertises the next four" \
    || fail "the first page of twelve does not advertise the next four"
if [[ -n "$FIRST" ]]; then
    adb_ shell input tap $FIRST >/dev/null 2>&1 || true
    SECOND=0
    for _ in 1 2 3 4 5; do
        sleep 0.5
        dump_ui >/dev/null 2>&1 || continue
        if grep -Fq 'content-desc="4 more photos"' "$TMP/ui.xml" &&
           grep -Fq 'content-desc="Previous photos"' "$TMP/ui.xml"; then SECOND=1; break; fi
    done
    [[ "$SECOND" == 1 ]] && pass "the second page of twelve still has four more" \
        || fail "the second page of twelve does not still have four more"
    SECOND_CHIP=$(center_of "4 more photos" 2>/dev/null || true)
    [[ -n "$SECOND_CHIP" ]] || SECOND_CHIP=$FIRST
    adb_ shell input tap $SECOND_CHIP >/dev/null 2>&1 || true
    THIRD=0
    for _ in 1 2 3 4 5; do
        sleep 0.5
        dump_ui >/dev/null 2>&1 || continue
        if ! grep -Fq 'content-desc="4 more photos"' "$TMP/ui.xml" &&
           grep -Fq 'content-desc="Previous photos"' "$TMP/ui.xml"; then THIRD=1; break; fi
    done
    [[ "$THIRD" == 1 ]] && pass "the third page of twelve has no further page" \
        || fail "the third page of twelve still advertises another page"
    PREV2=$(center_of "Previous photos" 2>/dev/null || true)
    [[ -n "$PREV2" ]] || PREV2=$SECOND_CHIP
    adb_ shell input tap $PREV2 >/dev/null 2>&1 || true
    BACK2=0
    for _ in 1 2 3 4 5; do
        sleep 0.5
        dump_ui >/dev/null 2>&1 || continue
        if grep -Fq 'content-desc="4 more photos"' "$TMP/ui.xml"; then BACK2=1; break; fi
    done
    [[ "$BACK2" == 1 ]] && pass "the previous-page badge returns to the second page" \
        || fail "the previous-page badge does not return to the second page"
else
    fail "the second page of twelve does not still have four more"
    fail "the third page of twelve still advertises another page"
    fail "the previous-page badge does not return to the second page"
fi

printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
