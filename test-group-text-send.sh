#!/usr/bin/env bash
# Issue #448: a group text leaves as ONE group MMS.
#
# Sent per person, the recipients never see a group and their replies come back
# private — the broadcast SMS that AOSP Messaging refuses outright. This asserts
# the replacement: one stored message, one outbox PDU carrying every member as a
# To (type 151), with the text as a text/plain part beside the SMIL.
#
# Delivery is not asserted: the emulator has no MMSC, so the platform reports a
# failure. What matters is what the app put on the wire.
source "$(dirname "$0")/env.sh"

PASS=0
FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
[[ "$ANDROID_SERIAL" == emulator-* ]] || { printf 'Requires a disposable emulator.\n'; exit 1; }
[[ "$(adb_ shell id -u | tr -d '\r')" == 0 ]] || { printf 'Run adb root on the test emulator first.\n'; exit 1; }

PROVDB=/data/data/com.android.providers.telephony/databases/mmssms.db
STAMP=$(date +%s)
A="+1555$(printf '%07d' $((STAMP % 10000000)))4"
B="+1555$(printf '%07d' $((STAMP % 10000000)))5"
C="+1555$(printf '%07d' $((STAMP % 10000000)))6"
BODY="GroupSend448_$STAMP"

provider() { adb_ shell "sqlite3 '$PROVDB' \"$1\"" | tr -d '\r'; }
local_q() { adb_ shell "run-as '$PKG' sqlite3 databases/messages.db \"$1\"" | tr -d '\r'; }

CID=""
cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    [ -n "$CID" ] || return 0
    local_q "DELETE FROM messages WHERE conversation_id=$CID;" >/dev/null 2>&1 || true
    local_q "DELETE FROM conversation_recipients WHERE conversation_id=$CID;" >/dev/null 2>&1 || true
    local_q "DELETE FROM conversations WHERE id=$CID;" >/dev/null 2>&1 || true
}
trap cleanup EXIT

adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1
for p in READ_SMS SEND_SMS RECEIVE_SMS READ_CONTACTS; do
    adb_ shell pm grant "$PKG" "android.permission.$p" >/dev/null 2>&1
done

printf 'Preparing a three-member group conversation\n'
CID=$(local_q "INSERT INTO conversations(address,name,snippet,timestamp) VALUES('$A','Group448','',0); SELECT last_insert_rowid();")
for addr in "$A" "$B" "$C"; do
    local_q "INSERT OR IGNORE INTO conversation_recipients(conversation_id,address) VALUES($CID,'$addr');" >/dev/null
done
[[ "$(local_q "SELECT COUNT(*) FROM conversation_recipients WHERE conversation_id=$CID;")" == 3 ]] \
    && pass 'group conversation has three members' \
    || { fail 'could not prepare the group conversation'; exit 1; }

adb_ shell am force-stop "$PKG" >/dev/null
adb_ shell am start -n "$ACT" --es open_conversation_address "$A" >/dev/null
sleep 4

# The composer is a Compose EditText; locate it through the layout dump because
# uiautomator's Compose tree is unreliable on this AVD.
composer=$(layout_json >/dev/null 2>&1 && python3 - "$TMP/layout.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); found = [None]
def walk(x):
    if found[0] is not None: return
    if isinstance(x, list):
        for y in x: walk(y)
    elif isinstance(x, dict):
        cls = str(x.get("class") or x.get("className") or "")
        if "EditText" in cls and x.get("center"):
            found[0] = x["center"]; return
        for k in ("content", "children"): walk(x.get(k) or [])
walk(d)
print(found[0].strip("[]").replace(",", " ")) if found[0] else sys.exit(1)
PY
) || true
if [ -z "${composer:-}" ]; then fail 'composer not found'; printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"; exit 1; fi
adb_ shell input tap $composer < /dev/null
sleep 1
adb_ shell input text "$BODY" < /dev/null
sleep 2

# The send label is localized, so resolve it the way the device would.
SEND=$(res_string icon_send)
if tap_layout_exact "$SEND" >/dev/null 2>&1; then
    pass "send button tapped ($SEND)"
else
    fail "could not tap '$SEND'"
    printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
    exit 1
fi
sleep 6

STORED=$(local_q "SELECT COUNT(*) FROM messages WHERE body='$BODY';")
[[ "$STORED" == 1 ]] && pass 'one stored message for the group send' \
    || fail "$STORED stored message(s) for one group send"

TRANSPORT=$(local_q "SELECT transport FROM messages WHERE body='$BODY';")
[[ "$TRANSPORT" == mms ]] && pass 'the group text was stored as an MMS' \
    || fail "the group text was stored as '$TRANSPORT'"

OUTBOX=$(provider "SELECT _id FROM pdu WHERE msg_box IN (2,5) AND tr_id IS NOT NULL ORDER BY _id DESC LIMIT 1;")
ROWS=$(provider "SELECT COUNT(*) FROM addr WHERE msg_id=${OUTBOX:-0} AND type=151;")
[[ "$ROWS" == 3 ]] && pass 'one outbox PDU addressed to all three members' \
    || fail "outbox PDU has $ROWS To address(es), expected 3"

TEXT=$(provider "SELECT COUNT(*) FROM part WHERE mid=${OUTBOX:-0} AND ct='text/plain' AND text='$BODY';")
[[ "$TEXT" == 1 ]] && pass 'the body rides in the PDU as a text/plain part' \
    || fail 'the body is missing from the outbox PDU'

SMIL=$(provider "SELECT COUNT(*) FROM part WHERE mid=${OUTBOX:-0} AND ct='application/smil';")
[[ "$SMIL" == 1 ]] && pass 'the text-only message still carries a SMIL presentation' \
    || fail 'no SMIL part in the outbox PDU'

printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
