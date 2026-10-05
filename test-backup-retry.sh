#!/usr/bin/env bash
# Regression: backup/restore self-healing.
#
#   Phase 1  a transient backup failure is retried with backoff and still lands,
#            and the retry count reaches the transfer log;
#   Phase 2  a failed automatic backup schedules a one-shot retry on next launch;
#   Phase 3  a replace-restore interrupted mid-swap is recovered at startup.
#
# The first phase drives the debug `backup_export_probe` intent, which injects N
# transient failures into the destination write; the rest assert on the real DB
# and the persisted state, never on a screenshot.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

PREFS="/data/data/$PKG/shared_prefs/messages_settings.xml"
WORKDB="/data/data/$PKG/no_backup/androidx.work.workdb"
TLOG="/data/data/$PKG/files/transfer-log.json"
DBDIR="/data/data/$PKG/databases"
DIR="/sdcard/Documents/Messages"

adb_ root >/dev/null 2>&1
adb_ wait-for-device; sleep 1

pref_del()      { adb_ shell "sed -i '/name=\"$1\"/d' $PREFS" 2>/dev/null; }
pref_put_bool() { pref_del "$1"; adb_ shell "sed -i 's#</map>#    <boolean name=\"$1\" value=\"$2\" />\n</map>#' $PREFS" 2>/dev/null; }
pref_put_str()  { pref_del "$1"; adb_ shell "sed -i 's#</map>#    <string name=\"$1\">$2</string>\n</map>#' $PREFS" 2>/dev/null; }
pref_put_long() { pref_del "$1"; adb_ shell "sed -i 's#</map>#    <long name=\"$1\" value=\"$2\" />\n</map>#' $PREFS" 2>/dev/null; }

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    pref_put_bool periodic_backup_enabled false
    pref_put_bool last_backup_ok true
    adb_ shell "rm -f $DIR/messages_backup_*.db" >/dev/null 2>&1
    adb_ shell "rm -f $DBDIR/pre_import_backup.db $DBDIR/import_temp.db" >/dev/null 2>&1
    adb_ shell am start -n "$ACT" >/dev/null 2>&1
}
trap cleanup EXIT

# ---------- Phase 1: transient failure is retried and still lands ----------
info "Phase 1: forced transient backup failure is retried with backoff"
adb_ shell am force-stop "$PKG"; sleep 1
pref_put_bool privacy_mode false
adb_ shell "rm -f $DIR/messages_backup_*.db" >/dev/null 2>&1
adb_ shell "rm -f $TLOG" >/dev/null 2>&1
adb_ logcat -c
adb_ shell am start -n "$ACT" --ez backup_export_probe true --ei backup_fail_first 2 >/dev/null 2>&1
sleep 7

if adb_ logcat -d 2>/dev/null | grep -q 'BackupProbe: export ok=true attempts=3'; then
    ok "backup succeeded after 3 attempts (2 injected transient failures)"
else
    bad "no successful retry: $(adb_ logcat -d 2>/dev/null | grep BackupProbe | tail -1)"
fi

if adb_ shell "ls $DIR" 2>/dev/null | tr -d '\r' | grep -q 'messages_backup_.*\.db'; then
    ok "a .db backup landed despite the failures"
else
    bad "no .db backup file in $DIR"
fi

if adb_ shell "cat $TLOG 2>/dev/null" | tr -d '\r' | grep -q 'after 3 attempts'; then
    ok "transfer log records the retry count"
else
    bad "transfer log does not show the retry"
fi

# ---------- Phase 2: a failed automatic backup is retried on next launch -----
info "Phase 2: failed automatic backup schedules a one-shot retry on launch"
adb_ shell am force-stop "$PKG"; sleep 1
pref_put_bool periodic_backup_enabled true
pref_put_str periodic_backup_interval weekly
pref_put_bool last_backup_ok false
pref_put_long last_backup_at "$(date +%s%3N)"
adb_ shell am start -n "$ACT" >/dev/null 2>&1
sleep 6

if adb_ shell "sqlite3 $WORKDB \"SELECT name FROM WorkName;\"" 2>/dev/null | tr -d '\r' | grep -q 'messages-backup-retry'; then
    ok "a one-shot retry is enqueued after a failed backup"
else
    bad "no messages-backup-retry work enqueued"
fi

adb_ shell am force-stop "$PKG"; sleep 1
pref_put_bool periodic_backup_enabled false
pref_put_bool last_backup_ok true

# ---------- Phase 3: interrupted replace-restore is recovered at startup -----
info "Phase 3: interrupted restore is recovered at startup"
adb_ shell am force-stop "$PKG"; sleep 2
adb_ shell "rm -f $TLOG" >/dev/null 2>&1
# Plant a pre-import copy as the app user and remove the live database: exactly
# the state a crash between db.close() and the rename leaves behind. It must be
# app-owned, as the importer's own file would be.
adb_ shell "run-as $PKG sh -c 'cp databases/messages.db databases/pre_import_backup.db && rm -f databases/messages.db databases/messages.db-journal databases/messages.db-wal databases/messages.db-shm'" >/dev/null 2>&1
BEFORE=$(adb_ shell "sqlite3 $DBDIR/pre_import_backup.db 'SELECT COUNT(*) FROM messages;'" 2>/dev/null | tr -d '\r')
adb_ logcat -c
adb_ shell am start -n "$ACT" >/dev/null 2>&1
sleep 5

if adb_ logcat -d 2>/dev/null | grep -q 'recovered an interrupted restore'; then
    ok "startup recovery ran"
else
    bad "no recovery log line"
fi

AFTER=$(adb_ shell "sqlite3 $DBDIR/messages.db 'SELECT COUNT(*) FROM messages;'" 2>/dev/null | tr -d '\r')
if [ -n "$BEFORE" ] && [ "$BEFORE" != "0" ] && [ "$AFTER" = "$BEFORE" ]; then
    ok "recovered database has the same $AFTER messages"
else
    bad "message count wrong after recovery: before='$BEFORE' after='$AFTER'"
fi

if adb_ shell "cat $TLOG 2>/dev/null" | tr -d '\r' | grep -q 'Recovered an interrupted restore'; then
    ok "recovery is recorded in the transfer log"
else
    bad "recovery missing from transfer log"
fi

if adb_ shell "ls $DBDIR" 2>/dev/null | tr -d '\r' | grep -q 'pre_import_backup.db'; then
    bad "pre-import copy was left behind after a successful recovery"
else
    ok "recovery cleaned up its scratch file"
fi

info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
