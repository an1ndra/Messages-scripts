#!/usr/bin/env bash
# A thread's tab is decided by the message that opened it, not by whatever
# became the preview later. A bank that opened with "debited Rs 500" and an OTP
# sender that opened with a code must still be filed under Transactions / OTP
# after a later "Thanks" becomes the newest message.
#
# What it asserts:
#   * the code that opened one thread files it under OTP,
#   * the debit that opened the other files it under Transactions,
#   * the newer "Thanks" is what the inbox previews, so the tab came from the
#     older message and not from that preview.
#
# Run: scripts/test-category-opening-message.sh
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

OTP_ADDR="+15559220001"
TXN_ADDR="+15559220002"
OTP_OLD="Your verification code is 482913 CATTEST"
TXN_OLD="Your account was debited Rs 500 CATTEST"
OTP_NEW="OTP chat latest CATTEST"
TXN_NEW="TXN chat latest CATTEST"

dbq() { adb_su "run-as $PKG sqlite3 databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r'; }

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    for a in "$OTP_ADDR" "$TXN_ADDR"; do
        dbq "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$a');" >/dev/null 2>&1 || true
        dbq "DELETE FROM conversations WHERE address='$a';" >/dev/null 2>&1 || true
    done
}
trap cleanup EXIT

for a in "$OTP_ADDR" "$TXN_ADDR"; do
    dbq "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$a');" >/dev/null 2>&1
    dbq "DELETE FROM conversations WHERE address='$a';" >/dev/null 2>&1
done

info "Two threads opened by a code and a debit, both closed by a later text"
NOW=$(date +%s000)
OLD=$((NOW - 600000))
seed() {
    local addr="$1" first="$2" latest="$3" cid
    dbq "INSERT INTO conversations(address,name,snippet,timestamp,category,archived,deleted_at,pinned) VALUES('$addr','$addr','$latest',$NOW,'',0,0,0);" >/dev/null
    cid=$(dbq "SELECT id FROM conversations WHERE address='$addr';")
    [ -n "$cid" ] || { bad "could not seed $addr"; return 1; }
    dbq "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,sub_id,transport,address) VALUES($cid,'$first',$OLD,0,'received',1,'sms','$addr');" >/dev/null
    dbq "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,sub_id,transport,address) VALUES($cid,'$latest',$NOW,0,'received',1,'sms','$addr');" >/dev/null
}
seed "$OTP_ADDR" "$OTP_OLD" "$OTP_NEW"
seed "$TXN_ADDR" "$TXN_OLD" "$TXN_NEW"
ok "seeded both threads with an older code/debit"

adb_ shell am force-stop "$PKG" >/dev/null 2>&1
adb_ shell am start -n "$ACT" >/dev/null 2>&1
if ! wait_for_text "$OTP_NEW" 24; then
    bad "the inbox never showed the seeded threads"
    exit 1
fi
ok "both threads are listed in the inbox"

info "The tab comes from the opening message, not the preview"
otp_category=$(dbq "SELECT category FROM conversations WHERE address='$OTP_ADDR';")
txn_category=$(dbq "SELECT category FROM conversations WHERE address='$TXN_ADDR';")
otp_preview=$(dbq "SELECT snippet FROM conversations WHERE address='$OTP_ADDR';")
txn_preview=$(dbq "SELECT snippet FROM conversations WHERE address='$TXN_ADDR';")

if [ "$otp_preview" = "$OTP_NEW" ] && [ "$txn_preview" = "$TXN_NEW" ]; then
    ok "the inbox previews are the later 'Thanks' messages"
else
    bad "the previews are not the newer messages: '$otp_preview' / '$txn_preview'"
fi

if [ "$otp_category" = "otp" ]; then
    ok "the OTP that opened the thread filed it under OTP"
else
    bad "the code is under '$otp_category' instead of otp"
fi

if [ "$txn_category" = "transactions" ]; then
    ok "the debit that opened the thread filed it under Transactions"
else
    bad "the debit is under '$txn_category' instead of transactions"
fi

echo
echo "  PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && echo "=== OK ===" || echo "=== FAILED ==="
exit $((FAIL > 0))
