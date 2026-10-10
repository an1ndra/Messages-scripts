#!/usr/bin/env bash
# Opt-in scale regression for backup/restore self-healing: seed 5000
# conversations / 10000 messages, then prove
#   1. a backup that fails twice transiently still lands, complete and valid;
#   2. an interrupted replace-restore is recovered at startup, losing nothing.
#
# This OVERWRITES the app's local history. It is not part of run-all-tests.sh;
# run it by hand on emulator-5554 when touching the backup or recovery paths.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

CONVS=5000
MSGS=10000
PREFS="/data/data/$PKG/shared_prefs/messages_settings.xml"
DB="/data/data/$PKG/databases/messages.db"
DIR="/sdcard/Documents/Messages"
SQL="$TMP/backup-scale-seed.sql"

adb_ root >/dev/null 2>&1
adb_ wait-for-device; sleep 1

db() { adb_ shell "sqlite3 $DB \"$1\"" 2>/dev/null | tr -d '\r'; }
backup_count() { adb_ shell "sqlite3 $1 \"SELECT COUNT(*) FROM messages;\"" 2>/dev/null | tr -d '\r'; }

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    adb_ shell "rm -f $DIR/messages_backup_*.db" >/dev/null 2>&1
    adb_ shell "rm -f /data/data/$PKG/databases/pre_import_backup.db /data/data/$PKG/databases/import_temp.db" >/dev/null 2>&1
    adb_ shell "sed -i '/name=\"periodic_backup_enabled\"/d' $PREFS" 2>/dev/null
    adb_ shell "sed -i 's#</map>#    <boolean name=\"periodic_backup_enabled\" value=\"false\" />\n</map>#' $PREFS" 2>/dev/null
}
trap cleanup EXIT

info "Seeding $CONVS conversations / $MSGS messages"
cat > "$SQL" <<SQL
BEGIN;
DELETE FROM messages;
DELETE FROM conversations;
DELETE FROM participants;
INSERT INTO conversations(id,address,name,snippet,timestamp,unread_count,last_is_me,archived,blocked,blocked_at,pinned,draft,draft_date,deleted_at,deleted_reason,group_title)
SELECT i, '+1555'||substr('0000000'||i, -7), 'Contact '||i, '', 1600000000000+i, 0, 0, 0, 0, 0, 0, '', 0, 0, 'manual', ''
FROM (WITH RECURSIVE s(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM s WHERE i<$CONVS) SELECT i FROM s);
INSERT INTO messages(id,conversation_id,address,body,timestamp,is_me,status,media_type,media_uri,reactions,sys_id,transport,delivered_at,locked,sub_id,deleted_at,blocked_reason)
SELECT i, ((i-1)/2)+1, (SELECT address FROM conversations WHERE id=((i-1)/2)+1), 'message '||i, 1600000000000+i, 0, 'sent', 'text', '', '', 0, 'sms', 0, 0, -1, 0, ''
FROM (WITH RECURSIVE s(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM s WHERE i<$MSGS) SELECT i FROM s);
COMMIT;
SQL
adb_ shell am force-stop "$PKG"; sleep 1
adb_ push "$SQL" /data/local/tmp/backup-scale-seed.sql >/dev/null 2>&1
adb_ shell "sqlite3 $DB < /data/local/tmp/backup-scale-seed.sql" >/dev/null 2>&1
SEEDED_MSGS=$(db 'SELECT COUNT(*) FROM messages;')
SEEDED_CONVS=$(db 'SELECT COUNT(*) FROM conversations;')
if [ "$SEEDED_MSGS" = "$MSGS" ] && [ "$SEEDED_CONVS" = "$CONVS" ]; then
    ok "seeded $SEEDED_MSGS messages across $SEEDED_CONVS conversations"
else
    bad "seed mismatch: messages=$SEEDED_MSGS conversations=$SEEDED_CONVS"
    exit 1
fi

# ---------- 1. large backup, transient failures retried ----------
info "Backup with 2 injected transient failures"
adb_ shell "rm -f $DIR/messages_backup_*.db" >/dev/null 2>&1
adb_ logcat -c
T0=$(date +%s%3N)
adb_ shell am start -n "$ACT" --ez backup_export_probe true --ei backup_fail_first 2 >/dev/null 2>&1
for _ in $(seq 1 60); do
    adb_ logcat -d 2>/dev/null | grep -q 'BackupProbe: export ok=' && break
    sleep 1
done
T1=$(date +%s%3N)

if adb_ logcat -d 2>/dev/null | grep -q 'BackupProbe: export ok=true attempts=3'; then
    ok "backup succeeded after 3 attempts"
else
    bad "no successful retry: $(adb_ logcat -d 2>/dev/null | grep BackupProbe | tail -1)"
fi

FILE=$(adb_ shell "ls $DIR/messages_backup_*.db" 2>/dev/null | tr -d '\r' | head -1)
if [ -n "$FILE" ]; then
    BCOUNT=$(backup_count "$FILE")
    if [ "$BCOUNT" = "$MSGS" ]; then
        ok "backup holds all $BCOUNT messages"
    else
        bad "backup holds $BCOUNT of $MSGS messages"
    fi
    INTEGRITY=$(adb_ shell "sqlite3 $FILE 'PRAGMA integrity_check;'" 2>/dev/null | tr -d '\r')
    [ "$INTEGRITY" = "ok" ] && ok "backup integrity_check is ok" || bad "integrity_check said '$INTEGRITY'"
else
    bad "no .db backup produced"
fi
ELAPSED_MS=$((T1 - T0))
if [ "$ELAPSED_MS" -lt 60000 ]; then
    ok "retried backup completed in ${ELAPSED_MS} ms"
else
    bad "backup took ${ELAPSED_MS} ms (over 60 s)"
fi

# ---------- 2. interrupted restore recovered at startup ----------
info "Interrupt a replace-restore and recover at startup"
adb_ shell am force-stop "$PKG"; sleep 2
adb_ shell "run-as $PKG sh -c 'cp databases/messages.db databases/pre_import_backup.db && rm -f databases/messages.db databases/messages.db-journal databases/messages.db-wal databases/messages.db-shm'" >/dev/null 2>&1
if adb_ shell "ls /data/data/$PKG/databases/" 2>/dev/null | tr -d '\r' | grep -q 'messages.db$'; then
    bad "live database still present, so the crash was not simulated"
fi
adb_ logcat -c
T0=$(date +%s%3N)
adb_ shell am start -n "$ACT" >/dev/null 2>&1
for _ in $(seq 1 60); do
    adb_ logcat -d 2>/dev/null | grep -q 'recovered an interrupted restore' && break
    sleep 1
done
T1=$(date +%s%3N)

adb_ logcat -d 2>/dev/null | grep -q 'recovered an interrupted restore' \
    && ok "startup recovery ran" || bad "no recovery log line"

AFTER=$(db 'SELECT COUNT(*) FROM messages;')
# The provider sync may add its own rows; the seeded ones must all survive.
if [ "${AFTER:-0}" -ge "$MSGS" ]; then
    ok "recovered database still has at least $MSGS messages ($AFTER)"
else
    bad "only $AFTER of $MSGS messages survived recovery"
fi
adb_ shell "ls /data/data/$PKG/databases/" 2>/dev/null | tr -d '\r' | grep -q 'pre_import_backup.db' \
    && bad "scratch file left behind" || ok "scratch file cleaned up"
ELAPSED_MS=$((T1 - T0))
if [ "$ELAPSED_MS" -lt 60000 ]; then
    ok "recovery completed in ${ELAPSED_MS} ms"
else
    bad "recovery took ${ELAPSED_MS} ms (over 60 s)"
fi
if adb_ logcat -d 2>/dev/null | grep -qiE 'OutOfMemoryError|FATAL EXCEPTION'; then
    bad "the run hit an OOM or a crash"
else
    ok "no OOM or crash"
fi

info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
