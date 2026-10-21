#!/usr/bin/env bash
# test-mms-timestamp-units.sh
# Verifies: timestamps are stored in milliseconds, so a conversation is not
# sorted out of the way by a row in the wrong unit.
#
# The provider date is seconds on some carriers and milliseconds on others. The
# reader scaled every value by 1000, so a millisecond MMS landed in the year
# 58000 and sorted above every real message in the list forever, hiding any
# conversation sent afterwards (#317). The SMS import did the opposite and stored
# seconds unscaled, which read as 1970. Both are healed by the v27 migration.
set -euo pipefail
source "$(dirname "$0")/env.sh"
FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

# 10^12 ms is 2001-09-09. A real millisecond timestamp sits in [1e12, 1e16);
# anything outside that is a unit error.
FLOOR=1000000000000
CEIL=10000000000000000

sq() { adb_ shell "run-as $PKG sqlite3 databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r\n'; }

info "Seed rows in both wrong units, as pre-fix builds wrote them"
# Each seeded conversation carries a message, because refreshConversationSnippets
# recomputes a conversation's timestamp from its newest message on every sync. A
# bare conversation would have its seeded value overwritten and the healing of it
# would go untested.
sq "INSERT INTO conversations(address,name,snippet,timestamp,unread_count,last_is_me)
    VALUES('+15551110001','+15551110001','inflated',1791706107000000,0,1);"
sq "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,transport)
    SELECT id,'inflated',1791706107000000,1,'sent','sms'
    FROM conversations WHERE address='+15551110001';"
sq "INSERT INTO conversations(address,name,snippet,timestamp,unread_count,last_is_me)
    VALUES('+15551110002','+15551110002','seconds',1791706107,0,1);"
sq "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,transport)
    SELECT id,'seconds',1791706107,1,'sent','sms'
    FROM conversations WHERE address='+15551110002';"
SEEDED_INFLATED=$(sq "SELECT count(*) FROM conversations WHERE address='+15551110001' AND timestamp=1791706107000000;")
SEEDED_SECONDS=$(sq "SELECT count(*) FROM conversations WHERE address='+15551110002' AND timestamp=1791706107;")
if [ "$SEEDED_INFLATED" = "1" ] && [ "$SEEDED_SECONDS" = "1" ]; then
  pass "seeded one millisecond-scaled and one seconds-valued conversation"
else
  fail "seeding failed (inflated=$SEEDED_INFLATED seconds=$SEEDED_SECONDS)"
  exit 1
fi

info "A conversation sent now must sort above them"
sq "INSERT INTO conversations(address,name,snippet,timestamp,unread_count,last_is_me)
    VALUES('+15551110003','+15551110003','newest',$(date +%s)000,0,1);"
sq "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,transport)
    SELECT id,'newest',$(date +%s)000,1,'sent','sms'
    FROM conversations WHERE address='+15551110003';"

info "Rewind the schema so the migration runs, then launch"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1
sq "PRAGMA user_version=26;"
adb_ shell am start -n "$ACT" >/dev/null 2>&1
sleep 8

VERSION=$(sq "PRAGMA user_version;")
if [ "$VERSION" -ge 27 ] 2>/dev/null; then
  pass "schema upgraded to $VERSION"
else
  fail "schema is still at '$VERSION', migration did not run"
fi

info "Both tables are free of unit errors"
CONV_BAD=$(sq "SELECT count(*) FROM conversations WHERE timestamp>0 AND (timestamp<$FLOOR OR timestamp>=$CEIL);")
MSG_BAD=$(sq "SELECT count(*) FROM messages WHERE timestamp>0 AND (timestamp<$FLOOR OR timestamp>=$CEIL);")
if [ "$CONV_BAD" = "0" ]; then
  pass "no conversation holds an out-of-unit timestamp"
else
  fail "$CONV_BAD conversations hold an out-of-unit timestamp"
fi
if [ "$MSG_BAD" = "0" ]; then
  pass "no message holds an out-of-unit timestamp"
else
  fail "$MSG_BAD messages hold an out-of-unit timestamp"
fi

info "The healed rows kept their instant"
# 1791706107000 ms is 2026-10-11; the scaling must undo, not reapply.
HEALED=$(sq "SELECT timestamp FROM conversations WHERE address='+15551110001';")
if [ "$HEALED" = "1791706107000" ]; then
  pass "the inflated row was divided back to $HEALED"
else
  fail "the inflated row is now '$HEALED', expected 1791706107000"
fi

info "The newest conversation is at the top of the list"
TOP=$(sq "SELECT address FROM conversations WHERE address LIKE '+155511100%' AND deleted_at=0 ORDER BY pinned DESC, timestamp DESC LIMIT 1;")
if [ "$TOP" = "+15551110003" ]; then
  pass "the newest conversation sorts first"
else
  fail "top row is '$TOP', expected +15551110003"
fi

info "Clean up"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1
sq "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address LIKE '+155511100%');"
sq "DELETE FROM conversation_recipients WHERE conversation_id IN (SELECT id FROM conversations WHERE address LIKE '+155511100%');"
sq "DELETE FROM conversations WHERE address LIKE '+155511100%';"

echo
if [ "$FAIL" -gt 0 ]; then
  echo "FAILED: $FAIL check(s)"
  exit 1
fi
echo "ALL CHECKS PASSED"
exit 0