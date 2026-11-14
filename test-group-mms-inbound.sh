#!/usr/bin/env bash
# Issue #448: a group MMS is a provider thread, not a message from a sender.
#
# The provider groups a group MMS on its participants, and the platform's own
# SMS app lists one conversation for it. This app used to route an imported MMS
# by its From, so a 3-member group appeared as two separate one-to-one chats and
# there was no way to reply to the group.
#
# Seeds one provider thread with three members and two messages from two
# different senders, then asserts the import files both into ONE conversation
# with three recipients, stamped with that provider thread.
source "$(dirname "$0")/env.sh"

PASS=0
FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
[[ "$ANDROID_SERIAL" == emulator-* ]] || { printf 'Requires a disposable emulator.\n'; exit 1; }
[[ "$(adb_ shell id -u | tr -d '\r')" == 0 ]] || { printf 'Run adb root on the test emulator first.\n'; exit 1; }

PROVDB=/data/data/com.android.providers.telephony/databases/mmssms.db
STAMP=$(date +%s)
A="+1555$(printf '%07d' $((STAMP % 10000000)))1"
B="+1555$(printf '%07d' $((STAMP % 10000000)))2"
C="+1555$(printf '%07d' $((STAMP % 10000000)))3"
MARK1="GroupInboundA$STAMP"
MARK2="GroupInboundB$STAMP"

provider() { adb_ shell "sqlite3 '$PROVDB' \"$1\"" | tr -d '\r'; }
local_q() { adb_ shell "run-as '$PKG' sqlite3 databases/messages.db \"$1\"" | tr -d '\r'; }

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    provider "DELETE FROM part WHERE mid IN (SELECT _id FROM pdu WHERE tr_id LIKE 'G448T$STAMP%');" >/dev/null 2>&1 || true
    provider "DELETE FROM addr WHERE msg_id IN (SELECT _id FROM pdu WHERE tr_id LIKE 'G448T$STAMP%');" >/dev/null 2>&1 || true
    provider "DELETE FROM pdu WHERE tr_id LIKE 'G448T$STAMP%';" >/dev/null 2>&1 || true
    provider "DELETE FROM threads WHERE recipient_ids IN (SELECT CAST(_id AS TEXT) FROM canonical_addresses WHERE address IN ('$A','$B','$C'));" >/dev/null 2>&1 || true
    provider "DELETE FROM canonical_addresses WHERE address IN ('$A','$B','$C');" >/dev/null 2>&1 || true
    for id in $(local_q "SELECT id FROM conversations WHERE address IN ('$A','$B','$C');" | tr '\n' ' '); do
        local_q "DELETE FROM messages WHERE conversation_id=$id; DELETE FROM conversation_recipients WHERE conversation_id=$id; DELETE FROM conversations WHERE id=$id;" >/dev/null 2>&1 || true
    done
}
trap cleanup EXIT

adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1
adb_ shell pm grant "$PKG" android.permission.READ_SMS >/dev/null 2>&1

printf 'Seeding a three-member provider thread\n'
provider "BEGIN;
INSERT INTO canonical_addresses(address) VALUES('$A');
INSERT INTO canonical_addresses(address) VALUES('$B');
INSERT INTO canonical_addresses(address) VALUES('$C');
INSERT INTO threads(recipient_ids,date) VALUES(
  (SELECT CAST(_id AS TEXT) FROM canonical_addresses WHERE address='$A')||' '||
  (SELECT CAST(_id AS TEXT) FROM canonical_addresses WHERE address='$B')||' '||
  (SELECT CAST(_id AS TEXT) FROM canonical_addresses WHERE address='$C'), $STAMP);
INSERT INTO pdu(thread_id,date,msg_box,m_type,read,sub_id,tr_id) VALUES(
  (SELECT MAX(_id) FROM threads),$STAMP,1,132,1,-1,'G448T${STAMP}A');
INSERT INTO addr(msg_id,address,type,charset) SELECT _id,'$A',137,106 FROM pdu WHERE tr_id='G448T${STAMP}A';
INSERT INTO addr(msg_id,address,type,charset) SELECT _id,'$A',151,106 FROM pdu WHERE tr_id='G448T${STAMP}A';
INSERT INTO addr(msg_id,address,type,charset) SELECT _id,'$B',151,106 FROM pdu WHERE tr_id='G448T${STAMP}A';
INSERT INTO addr(msg_id,address,type,charset) SELECT _id,'$C',151,106 FROM pdu WHERE tr_id='G448T${STAMP}A';
INSERT INTO part(mid,ct,text,chset,seq) SELECT _id,'text/plain','$MARK1',106,0 FROM pdu WHERE tr_id='G448T${STAMP}A';
INSERT INTO pdu(thread_id,date,msg_box,m_type,read,sub_id,tr_id) VALUES(
  (SELECT MAX(_id) FROM threads),$((STAMP+60)),1,132,1,-1,'G448T${STAMP}B');
INSERT INTO addr(msg_id,address,type,charset) SELECT _id,'$B',137,106 FROM pdu WHERE tr_id='G448T${STAMP}B';
INSERT INTO addr(msg_id,address,type,charset) SELECT _id,'$A',151,106 FROM pdu WHERE tr_id='G448T${STAMP}B';
INSERT INTO addr(msg_id,address,type,charset) SELECT _id,'$B',151,106 FROM pdu WHERE tr_id='G448T${STAMP}B';
INSERT INTO addr(msg_id,address,type,charset) SELECT _id,'$C',151,106 FROM pdu WHERE tr_id='G448T${STAMP}B';
INSERT INTO part(mid,ct,text,chset,seq) SELECT _id,'text/plain','$MARK2',106,0 FROM pdu WHERE tr_id='G448T${STAMP}B';
COMMIT;" >/dev/null

THREAD=$(provider "SELECT MAX(_id) FROM threads;")
[[ "$(provider "SELECT COUNT(*) FROM pdu WHERE tr_id LIKE 'G448T$STAMP%';")" == 2 ]] \
    && pass 'two inbound group MMS exist in one provider thread' \
    || { fail 'group MMS fixture missing'; exit 1; }

adb_ shell am force-stop "$PKG" >/dev/null
adb_ shell am start -n "$ACT" >/dev/null
for _ in $(seq 1 20); do
    got=$(local_q "SELECT COUNT(*) FROM messages WHERE body IN ('$MARK1','$MARK2');")
    [[ "$got" == 2 ]] && break
    sleep 2
done
[[ "$(local_q "SELECT COUNT(*) FROM messages WHERE body IN ('$MARK1','$MARK2');")" == 2 ]] \
    && pass 'both group messages imported' \
    || { fail 'group messages not imported'; printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"; exit 1; }

CID=$(local_q "SELECT conversation_id FROM messages WHERE body='$MARK1';")
[[ -n "$CID" ]] && [[ "$CID" == "$(local_q "SELECT conversation_id FROM messages WHERE body='$MARK2';")" ]] \
    && pass 'both senders in one conversation' \
    || fail 'group messages split across conversations'

MEMBERS=$(local_q "SELECT COUNT(*) FROM conversation_recipients WHERE conversation_id=${CID:-0};")
[[ "$MEMBERS" == 3 ]] && pass 'conversation has all three members' \
    || fail "conversation has $MEMBERS member(s), expected 3"

STAMPED=$(local_q "SELECT provider_thread_id FROM conversations WHERE id=${CID:-0};")
[[ "$STAMPED" == "$THREAD" ]] && pass "conversation is stamped with provider thread $THREAD" \
    || fail "provider_thread_id is '$STAMPED', expected '$THREAD'"

# The bug's visible shape: a sender's private chat holding the group message.
PRIVATE=$(local_q "SELECT COUNT(*) FROM messages m JOIN conversations c ON c.id=m.conversation_id
    WHERE m.body IN ('$MARK1','$MARK2')
      AND (SELECT COUNT(*) FROM conversation_recipients r WHERE r.conversation_id=c.id)<=1;")
[[ "$PRIVATE" == 0 ]] && pass 'no group message sits in a one-to-one chat' \
    || fail "$PRIVATE group message(s) filed in a one-to-one chat"

printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
