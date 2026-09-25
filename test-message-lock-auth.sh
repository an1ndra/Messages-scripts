#!/usr/bin/env bash
# Regression for the message-lock biometric path (CodeQL alert #21).
#
# The unlock callback must use the authentication result for a cryptographic
# operation (CryptoObject) instead of trusting a boolean. On this AVD there is
# no enrolled biometric/credential, so the UI flow exercises the no-auth
# fallback, but this still verifies lock/unlock works end to end. The crypto
# proof itself is covered by MessageLockCryptoTest (JVM).
source "$(dirname "$0")/env.sh"

MARK="lockauth$(date +%s)"
NUM="+1555000$(( (RANDOM % 9000) + 1000 ))"
TS=$(( $(date +%s) * 1000 ))

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

sql() { echo "$1" | adb_ shell "run-as $PKG sqlite3 databases/messages.db"; }

cleanup() {
    sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM');"
    sql "DELETE FROM conversations WHERE address='$NUM';"
}
trap cleanup EXIT

info "Seed a conversation + message"
sql "INSERT INTO conversations(address,name,snippet,timestamp,last_is_me) VALUES('$NUM','LockAuthTest','$MARK',$TS,0);"
sql "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,media_type) SELECT id,'$MARK',$TS,0,'received','text' FROM conversations WHERE address='$NUM';"

info "Launch and open the conversation"
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT"; sleep 3
C=$(center_of "LockAuthTest") || C=$(center_of_contains "$MARK") || { bad "conversation row not found"; exit 1; }
adb_ shell input tap $C; sleep 2
dump_ui
if grep -q '"Message"' "$TMP/ui.xml"; then ok "chat opened"; else bad "chat not opened"; exit 1; fi

info "Long-press the message -> selection menu -> Lock"
M=$(center_of_contains "$MARK") || { bad "message not found"; exit 1; }
MX=${M% *}; MY=${M#* }
adb_ shell input swipe $MX $MY $((MX + 2)) $MY 1000; sleep 1.5
MO=$(center_of_contains "More options") || { bad "selection toolbar missing"; exit 1; }
adb_ shell input tap $MO; sleep 1
dump_ui
L=$(center_of "Lock") || { bad "Lock item missing"; exit 1; }
adb_ shell input tap $L; sleep 1.5
dump_ui
if grep -q '@Lock' "$TMP/ui.xml"; then ok "message locked (@Lock shown)"; else bad "message not locked"; fi

info "Long-press @Lock -> selection menu -> Unlock"
LM=$(center_of "@Lock") || { bad "@Lock not found"; exit 1; }
LX=${LM% *}; LY=${LM#* }
adb_ shell input swipe $LX $LY $((LX + 2)) $LY 1000; sleep 1.5
MO=$(center_of_contains "More options") || { bad "selection toolbar missing (unlock)"; exit 1; }
adb_ shell input tap $MO; sleep 1
dump_ui
U=$(center_of "Unlock") || { bad "Unlock item missing"; exit 1; }
adb_ shell input tap $U; sleep 2
dump_ui
if grep -q "$MARK" "$TMP/ui.xml" && ! grep -q '@Lock' "$TMP/ui.xml"; then
    ok "message unlocked (body shown again)"
else
    bad "message not unlocked"
fi

echo ""
info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
