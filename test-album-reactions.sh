#!/usr/bin/env bash
# Regression for #364 M6: a multi-picture bubble can carry a reaction.
#
# A multi-picture MMS is stored as one row per picture and drawn as one album
# bubble; its long-press selects every row. The reaction bar was gated on the
# bubble being exactly one row (`rowIds.size == 1`), so an album could never
# show it — long-pressing offered Copy/Forward/Trash and nothing else.
#
# The fixture is one incoming MMS with three image parts (same shape as
# test-mms-multi-image.sh). Before the fix the long-press shows no emoji bar;
# after it, tapping one stores the reaction on the album's first row and the
# chip appears under the bubble.
source "$(dirname "$0")/env.sh"
set -euo pipefail

PASS=0
FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
[[ "$ANDROID_SERIAL" == emulator-* ]] || { printf 'Requires a disposable emulator.\n'; exit 1; }
[[ "$(adb_ shell id -u | tr -d '\r')" == 0 ]] || { printf 'Run adb root on the test emulator first.\n'; exit 1; }

PROVDB="${PROVDB:-/data/data/com.android.providers.telephony/databases/mmssms.db}"
MARKER="react364_$(date +%s)_$$"
ADDRESS="+1555$(date +%s | tail -c 8)"
STAMP=$(date +%s)
EMOJI="👍"
provider() { adb_ shell "sqlite3 '$PROVDB' \"$1\"" | tr -d '\r'; }
local_query() { adb_ shell "run-as '$PKG' sqlite3 databases/messages.db \"$1\" 2>/dev/null" | tr -d '\r'; }

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    provider "DELETE FROM pdu WHERE tr_id='$MARKER'; DELETE FROM threads WHERE recipient_ids IN (SELECT CAST(_id AS TEXT) FROM canonical_addresses WHERE address='$ADDRESS'); DELETE FROM canonical_addresses WHERE address='$ADDRESS';" >/dev/null 2>&1 || true
    local_query "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$ADDRESS'); DELETE FROM conversations WHERE address='$ADDRESS'; DELETE FROM participants WHERE normalized_destination='$ADDRESS';" >/dev/null 2>&1 || true
}
trap cleanup EXIT

provider "BEGIN; INSERT INTO canonical_addresses(address) VALUES('$ADDRESS'); INSERT INTO threads(recipient_ids,date) VALUES(CAST(last_insert_rowid() AS TEXT),${STAMP}000); INSERT INTO pdu(thread_id,date,msg_box,m_type,read,sub_id,tr_id) VALUES(last_insert_rowid(),$STAMP,1,132,1,-1,'$MARKER'); INSERT INTO addr(msg_id,address,type,charset) SELECT _id,'$ADDRESS',137,106 FROM pdu WHERE tr_id='$MARKER'; INSERT INTO part(mid,ct,seq,chset) SELECT _id,'image/jpeg',1,106 FROM pdu WHERE tr_id='$MARKER'; INSERT INTO part(mid,ct,seq,chset) SELECT _id,'image/png',2,106 FROM pdu WHERE tr_id='$MARKER'; INSERT INTO part(mid,ct,seq,chset) SELECT _id,'image/webp',3,106 FROM pdu WHERE tr_id='$MARKER'; COMMIT;" >/dev/null
PDU=$(provider "SELECT _id FROM pdu WHERE tr_id='$MARKER';")
[[ -n "$PDU" ]] || { fail "the provider fixture was written"; printf 'PASS=0 FAIL=1\n'; exit 1; }
local_query "DELETE FROM messages WHERE sys_id=$PDU;" >/dev/null 2>&1 || true

info "Open the conversation and wait for the album"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
adb_ shell am start -n "$ACT" --es open_conversation_address "$ADDRESS" >/dev/null
SHOWN=0
for _ in 1 2 3 4 5 6; do
    sleep 2
    dump_ui >/dev/null 2>&1 || continue
    if grep -Fq 'content-desc="3 photos"' "$TMP/ui.xml"; then SHOWN=1; break; fi
done
if [[ "$SHOWN" != 1 ]]; then
    fail "the conversation draws the three-picture album"
    printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
    exit 1
fi
pass "the conversation draws the three-picture album"

info "Long-press the album"
ALBUM=$(center_of "3 photos" 2>/dev/null || true)
[[ -n "$ALBUM" ]] || { fail "the album bubble can be located for a long-press"; printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"; exit 1; }
LX=${ALBUM% *}; LY=${ALBUM#* }
adb_ shell input swipe "$LX" "$LY" "$LX" "$LY" 900 >/dev/null 2>&1 || true
SEL=0
for _ in 1 2 3 4 5 6; do
    sleep 0.5
    dump_ui >/dev/null 2>&1 || continue
    if grep -qF 'content-desc="Cancel selection"' "$TMP/ui.xml"; then SEL=1; break; fi
done
[[ "$SEL" == 1 ]] && pass "the long-press opens the selection toolbar" \
    || fail "the long-press opens the selection toolbar"

# The bar renders one Text per emoji in MessageReactions.EMOJI; before the fix
# the gate was rowIds.size == 1, so none of them ever appeared for an album.
BAR=""
for _ in 1 2 3 4 5 6; do
    sleep 0.4
    dump_ui >/dev/null 2>&1 || continue
    BAR=$(center_of "$EMOJI" 2>/dev/null || true)
    [[ -n "$BAR" ]] && break
done
if [[ -n "$BAR" ]]; then
    pass "the album offers the reaction bar"
else
    fail "the album offers the reaction bar (no emoji bar over a multi-picture bubble)"
fi

info "React to the album"
if [[ -n "$BAR" ]]; then
    adb_ shell input tap $BAR >/dev/null 2>&1 || true
fi

REACTED=""
for _ in $(seq 1 10); do
    sleep 0.5
    REACTED=$(local_query "SELECT reactions FROM messages WHERE sys_id=$PDU ORDER BY id ASC LIMIT 1;")
    [[ "$REACTED" == *"$EMOJI"* ]] && break
done
if [[ "$REACTED" == *"$EMOJI"* ]]; then
    pass "the reaction is stored on the album's first row (reactions=${REACTED:-<none>})"
else
    fail "the reaction is stored on the album's first row (reactions=${REACTED:-<none>})"
fi

REACTED_ROWS=$(local_query "SELECT COUNT(*) FROM messages WHERE sys_id=$PDU AND reactions LIKE '%$EMOJI%';" || true)
[[ "${REACTED_ROWS:-0}" == 1 ]] && pass "the reaction lands on the message, not on a picture row" \
    || fail "the reaction lands on the message, not on a picture row (reacted rows=${REACTED_ROWS:-0})"

# With the selection cleared by the reaction, the remaining emoji node is the
# chip under the bubble.
CHIP=0
for _ in 1 2 3 4 5 6; do
    sleep 0.5
    dump_ui >/dev/null 2>&1 || continue
    if CHIPC=$(center_of "$EMOJI" 2>/dev/null) && [[ -n "$CHIPC" ]]; then CHIP=1; break; fi
done
[[ "$CHIP" == 1 ]] && pass "the album shows the reaction chip" \
    || fail "the album shows the reaction chip"

printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
