#!/usr/bin/env bash
# Issue #468: a message arriving in an archived conversation brings it back to
# the inbox, like Google Messages.
#
# The archive flag used to be cleared only when a *trashed* thread was restored
# (#405), so a chat filed away stayed in the archive forever. This archives a
# demo thread, delivers a text with the emulator's modem, and asserts the
# conversation left the archive and the message landed.
#
# Needs the demo roster, and an emulator: `adb emu sms send` has no equivalent on
# a physical device.
#
#   bash scripts/test-archived-inbound.sh
set -uo pipefail
cd "$(dirname "$0")"
source ./env.sh

PASS=0
FAIL=0
BODY="archived-inbound-468"
THREAD="+1555771010"

ok()   { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad()  { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

if ! "$ADB" devices | grep -q "^$ANDROID_SERIAL[[:space:]]*device"; then
    echo "ABORT: no device $ANDROID_SERIAL"; exit 2
fi
if ! "$ADB" -s "$ANDROID_SERIAL" emu sms send +1555771010 probe >/dev/null 2>&1; then
    echo "ABORT: $ANDROID_SERIAL has no modem to inject an SMS; run this on an emulator." >&2
    exit 2
fi

dbq() { printf '%s' "$1" | adb_ shell "run-as $PKG sqlite3 databases/messages.db" 2>/dev/null | tr -d '\r'; }

info "Archive the demo thread"
# A previous run may have left its probe behind; the count below is what proves
# this run's text landed, so start from a clean slate.
dbq "DELETE FROM messages WHERE body='$BODY';"
dbq "UPDATE conversations SET archived=1 WHERE address='$THREAD';"
archived=$(dbq "SELECT archived FROM conversations WHERE address='$THREAD';")
[ "$archived" = "1" ] && ok "conversation '$THREAD' is archived" \
                      || bad "could not archive '$THREAD' (archived=$archived)"

info "A text arrives while the chat is filed away"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1
adb_ -s "$ANDROID_SERIAL" emu sms send "$THREAD" "$BODY" >/dev/null 2>&1

landed=""
for _ in $(seq 1 20); do
    landed=$(dbq "SELECT COUNT(*) FROM messages WHERE body='$BODY';")
    [ "$landed" != "0" ] && break
    sleep 1
done
if [ "$landed" != "0" ]; then ok "the message was stored"; else bad "message never arrived (rows=$landed)"; fi

archived=$(dbq "SELECT archived FROM conversations WHERE address='$THREAD';")
[ "$archived" = "0" ] && ok "the conversation left the archive" \
                      || bad "conversation is still archived (archived=$archived)"

deleted=$(dbq "SELECT deleted_at FROM conversations WHERE address='$THREAD';")
[ "$deleted" = "0" ] && ok "the conversation is in the inbox" \
                     || bad "conversation is trashed (deleted_at=$deleted)"

visible=$(dbq "SELECT COUNT(*) FROM conversations WHERE address='$THREAD' AND archived=0 AND deleted_at=0;")
[ "$visible" = "1" ] && ok "it appears in the inbox list" || bad "not visible in the inbox"

info "Clean up"
dbq "DELETE FROM messages WHERE body='$BODY';"
dbq "UPDATE conversations SET archived=0 WHERE address='$THREAD';"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1

info "Result"
echo "  PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && echo "=== OK ===" || echo "=== FAILED ==="
exit $((FAIL > 0))
