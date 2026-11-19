#!/usr/bin/env bash
# A thread's tab is decided once, from the message that opened it. A bank that
# starts a thread with "debited Rs 500" is filed under Transactions, so every
# OTP that arrives in that same thread was filed there too and the OTP tab never
# showed it.
#
# What it asserts:
#   * a thread opened by a debit is under Transactions,
#   * an OTP arriving in that thread moves it to OTP,
#   * the OTP tab then lists the thread.
#
# The message is injected through the emulator's own radio (`adb emu sms send`),
# so the app sees a real inbound SMS: the receiver stores it and the promotion
# runs where it runs in the app.
#
# Run: scripts/test-otp-category.sh
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

RUN=$(date +%s)
NUM="57575"                             # a shortcode: a business sender
BODY="Debited Rs.500 from A/c XX1234. $RUN"
OTP_BODY="Use 4821 to verify your login. $RUN"

dbq() { adb_su "run-as $PKG sqlite3 databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r'; }
category_of() { dbq "SELECT category FROM conversations WHERE address='$NUM';"; }

# Runtime grants and the SMS role first: without the role the app never sees the
# message at all, and the test would blame the categoriser.
for p in SEND_SMS RECEIVE_SMS READ_PHONE_STATE; do
    adb_su "pm grant $PKG android.permission.$p" >/dev/null 2>&1
done
adb_su "cmd role add-role-holder android.app.role.SMS $PKG" >/dev/null 2>&1

adb_ shell am force-stop "$PKG" >/dev/null 2>&1
dbq "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM');" >/dev/null 2>&1
dbq "DELETE FROM conversations WHERE address='$NUM';" >/dev/null 2>&1

info "A thread opened by a debit is filed under Transactions"
# Seeded as the list would have stored it: the first message decides the tab.
NOW_MS=$(( $(date +%s) * 1000 ))
dbq "INSERT INTO conversations (address,name,snippet,timestamp,archived,deleted_at,pinned,category) VALUES ('$NUM','HDFC Bank','$BODY',$NOW_MS,0,0,0,'transactions');" >/dev/null
CONV=$(dbq "SELECT id FROM conversations WHERE address='$NUM';")
dbq "INSERT INTO messages (conversation_id,body,timestamp,is_me,status,media_type,media_uri,sub_id,transport,address) VALUES ($CONV,'$BODY',$NOW_MS,0,'received','text','',1,'sms','$NUM');" >/dev/null
first=$(category_of)
if [ "$first" = "transactions" ]; then
    ok "the debit filed the thread under Transactions"
else
    bad "the seeded thread reads '$first', not transactions"
fi

info "An OTP arrives in that same thread"
adb_ shell am start -W -n "$ACT" >/dev/null 2>&1
sleep 3
adb_ emu sms send "$NUM" "$OTP_BODY" >/dev/null 2>&1

moved=1
for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 1
    [ "$(category_of)" = "otp" ] && { moved=0; break; }
done
now=$(category_of)
if [ "$moved" = 0 ]; then
    ok "the OTP moved the thread to OTP (was '$first')"
else
    bad "the thread is still '$now' after an OTP arrived"
fi

info "The OTP tab lists the thread"
# The tabs are hidden until the list is pulled down: they are a thing the user
# asks for, not a row that is always in the way.
otp_label=$(res_string inbox_category_otp)
chip=""
for _ in 1 2 3; do
    adb_ shell input swipe 540 420 540 1700 350 >/dev/null 2>&1
    sleep 1
    chip=$(center_of "$otp_label" || true)
    [ -n "$chip" ] && break
done
if [ -z "$chip" ]; then
    bad "no '$otp_label' chip in the inbox"
else
    adb_ shell input tap ${chip% *} ${chip#* }; sleep 2
    dump_ui >/dev/null 2>&1 || true
    if ui_has "$RUN"; then
        ok "the thread shows under '$otp_label'"
    else
        bad "the thread is missing from '$otp_label'"
    fi
fi

echo
echo "  PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && echo "=== OK ===" || echo "=== FAILED ==="
exit $((FAIL > 0))
