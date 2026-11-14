#!/usr/bin/env bash
# Regression for #461: an MMS carrying a video must arrive as a clip.
#
# Before this, the import kept only picture parts: a clip-only MMS was stored as
# one message row whose body said "[MMS: 1 additional/unsupported attachment(s)
# not displayed]", so nothing could be played and the file could not be saved.
#
# Two sections:
#   1. A provider fixture (rooted emulator) proves the import keeps a video part
#      as its own row with media_type='video' and no apology in the body.
#   2. A clip written into the app's files directory proves the bubble, the
#      player and Save — a provider part carries no bytes here, so the concrete
#      play/save path needs a real file. The clip is generated with ffmpeg.
source "$(dirname "$0")/env.sh"
set -euo pipefail

PASS=0
FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
info() { printf '\n=== %s ===\n' "$*"; }

[[ "$ANDROID_SERIAL" == emulator-* ]] || { printf 'Requires a disposable emulator.\n'; exit 1; }
[[ "$(adb_ shell id -u | tr -d '\r')" == 0 ]] || { printf 'Run adb root on the test emulator first.\n'; exit 1; }
command -v ffmpeg >/dev/null 2>&1 || { printf 'ffmpeg is needed to generate the clip fixture.\n'; exit 1; }

PROVDB="${PROVDB:-/data/data/com.android.providers.telephony/databases/mmssms.db}"
MARKER="mms461_$(date +%s)_$$"
ADDRESS="+1555$(date +%s | tail -c 8)"
# The clip fixture gets its own thread: the provider fixture already owns ADDRESS.
CLIP_ADDR="+1556$(date +%s | tail -c 8)"
STAMP=$(date +%s)
STAMP_MS="${STAMP}000"
provider() { adb_ shell "sqlite3 '$PROVDB' \"$1\"" | tr -d '\r'; }
local_query() { adb_ shell "run-as '$PKG' sqlite3 databases/messages.db \"$1\" 2>/dev/null" | tr -d '\r'; }

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    provider "DELETE FROM pdu WHERE tr_id='$MARKER'; DELETE FROM threads WHERE recipient_ids IN (SELECT CAST(_id AS TEXT) FROM canonical_addresses WHERE address='$ADDRESS'); DELETE FROM canonical_addresses WHERE address='$ADDRESS';" >/dev/null || true
    local_query "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$ADDRESS' OR address='$CLIP_ADDR'); DELETE FROM conversations WHERE address='$ADDRESS' OR address='$CLIP_ADDR';" >/dev/null || true
    adb_ shell "run-as '$PKG' rm -f files/clip-probe.mp4" >/dev/null 2>&1 || true
    adb_ shell "rm -f /sdcard/Movies/Messages/*$STAMP_MS* 2>/dev/null" >/dev/null 2>&1 || true
}
trap cleanup EXIT

info "Preflight"
adb_ shell pm path "$PKG" >/dev/null 2>&1 && pass "the app is installed" || { fail "the app is not installed"; exit 1; }
adb_ shell am start -n "$ACT" >/dev/null 2>&1
sleep 5
adb_ shell am force-stop "$PKG" >/dev/null 2>&1

info "The provider fixture: one MMS carrying one clip"
provider "BEGIN; INSERT INTO canonical_addresses(address) VALUES('$ADDRESS'); INSERT INTO threads(recipient_ids,date) VALUES(CAST(last_insert_rowid() AS TEXT),${STAMP}000); INSERT INTO pdu(thread_id,date,msg_box,m_type,read,sub_id,tr_id) VALUES(last_insert_rowid(),$STAMP,1,132,1,-1,'$MARKER'); INSERT INTO addr(msg_id,address,type,charset) SELECT _id,'$ADDRESS',137,106 FROM pdu WHERE tr_id='$MARKER'; INSERT INTO part(mid,ct,seq,chset) SELECT _id,'video/mp4',1,106 FROM pdu WHERE tr_id='$MARKER'; COMMIT;" >/dev/null
PDU=$(provider "SELECT _id FROM pdu WHERE tr_id='$MARKER';")
local_query "DELETE FROM messages WHERE sys_id=$PDU;" >/dev/null 2>&1 || true
[[ "$(provider "SELECT COUNT(*) FROM part WHERE mid=$PDU AND ct LIKE 'video/%';")" == 1 ]] \
    && pass "the fixture carries a video part" || { fail "the fixture carries a video part"; exit 1; }

restart() {
    adb_ shell am force-stop "$PKG" >/dev/null
    adb_ shell am start -n "$ACT" >/dev/null
    sleep 5
    if dump_ui && grep -Fq 'Set as default SMS app?' "$TMP/ui.xml"; then
        tap_text 'Not now' || true
        sleep 2
    fi
}

info "The clip is imported as a row, not as a notice"
restart
for _ in 1 2 3 4 5 6; do
    [[ "$(local_query "SELECT COUNT(*) FROM messages WHERE sys_id=$PDU AND media_type='video';")" == 1 ]] && break
    sleep 2
done
[[ "$(local_query "SELECT COUNT(*) FROM messages WHERE sys_id=$PDU AND media_type='video';")" == 1 ]] \
    && pass "the clip was imported with media_type='video'" \
    || { fail "no video row was imported for the provider MMS"; exit 1; }
BODY=$(local_query "SELECT body FROM messages WHERE sys_id=$PDU AND media_type='video';")
[[ "$BODY" != *unsupported* ]] \
    && pass "the row does not carry the unsupported-attachment notice" \
    || fail "the row still says the attachment is unsupported: $BODY"

info "A clip in a conversation draws a play bubble"
ffmpeg -loglevel error -y -f lavfi -i testsrc=size=160x120:rate=10:duration=1 \
    -pix_fmt yuv420p "$TMP/clip.mp4" >/dev/null 2>&1
[[ -s "$TMP/clip.mp4" ]] && pass "a clip fixture was generated" || { fail "ffmpeg produced no clip"; exit 1; }
adb_ shell "run-as '$PKG' sh -c 'cat > files/clip-probe.mp4'" < "$TMP/clip.mp4"
CLIP_STAMP="$STAMP_MS"
CLIP_CID=$(local_query "INSERT INTO conversations(address,name,snippet,timestamp,unread_count) VALUES('$CLIP_ADDR','Clip probe','',$CLIP_STAMP,0); SELECT last_insert_rowid();")
local_query "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,media_type,media_uri) VALUES($CLIP_CID,'',$CLIP_STAMP,0,'received','video','file:///data/data/$PKG/files/clip-probe.mp4');" >/dev/null
[[ "$(local_query "SELECT COUNT(*) FROM messages WHERE conversation_id=$CLIP_CID AND media_type='video';")" == 1 ]] \
    && pass "the clip message is stored" || { fail "the clip message was not stored"; exit 1; }

video_desc=$(res_string access_video)
save_label=$(res_string chat_save_video)
close_label=$(res_string chat_close)

open_chat() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    adb_ shell am start -n "$ACT" --es open_conversation_address "$CLIP_ADDR" >/dev/null 2>&1
    local i
    for i in $(seq 1 15); do
        sleep 1
        wait_layout_has "$video_desc" 1 && return 0
    done
    return 1
}

open_chat && pass "the conversation opened with the clip" || { fail "the clip bubble never appeared"; exit 1; }
tap_layout "$video_desc" >/dev/null 2>&1 || true
sleep 2

info "Tapping the clip plays it, with Save beside Close"
if layout_has "$save_label"; then pass "the player offers Save video"; else fail "the player has no Save control"; fi
if layout_has "$close_label"; then pass "the player offers Close"; else fail "the player lost its Close control"; fi

info "Save writes the clip to Movies/Messages"
adb_ shell ls /sdcard/Movies/Messages 2>/dev/null | tr -d '\r' > "$TMP/movies-before.txt" || true
tap_layout "$save_label" >/dev/null 2>&1 || true
sleep 3
adb_ shell ls /sdcard/Movies/Messages 2>/dev/null | tr -d '\r' > "$TMP/movies-after.txt" || true
if grep -qF "$CLIP_STAMP" "$TMP/movies-after.txt"; then
    pass "Save wrote $(grep -F "$CLIP_STAMP" "$TMP/movies-after.txt" | head -1)"
else
    fail "Save wrote no clip for timestamp $CLIP_STAMP; got: $(tr '\n' ' ' < "$TMP/movies-after.txt")"
fi
if grep -qF "$CLIP_STAMP" "$TMP/movies-before.txt"; then
    fail "a clip with this timestamp was already in Movies/Messages"
else
    pass "the file was not there before Save"
fi

printf '\n[%s] %d passed, %d failed\n' "$([ "$FAIL" -eq 0 ] && echo PASS || echo FAIL)" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
