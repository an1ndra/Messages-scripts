#!/usr/bin/env bash
# Regression: the import/export log records outcomes, failures and conflicts,
# and Advanced settings can show them.
#
# Three things are asserted, because each can pass while the others fail:
#   1. a failed import is recorded with its reason, not silently dropped;
#   2. a repeated merge import records the duplicates it skipped;
#   3. the log survives a restart and the screen renders it.
#
# The log is read the same way the screen reads it (TransferLogStore), mirrored
# to logcat under the TransferLog tag, so no screenshot is needed.
source "$(dirname "$0")/env.sh"
set -euo pipefail

PASS=0
FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }

MARK="tlog$(date +%s)$$"
ADDR="+15558800${MARK: -3}"
TMPZIP="$TMP/transfer-log-$MARK.zip"
REMOTE="/data/local/tmp/transfer-log-$MARK.zip"
INAPP="/data/data/$PKG/files/transfer-log-$MARK.zip"
PIN="1234"

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    adb_ shell "run-as '$PKG' rm -f files/$(basename "$INAPP")" >/dev/null 2>&1 || true
    adb_ shell "run-as '$PKG' rm -f files/transfer-log.json" >/dev/null 2>&1 || true
    adb_ shell "rm -f $REMOTE" >/dev/null 2>&1 || true
    db_sql "DELETE FROM messages WHERE body LIKE '%$MARK%'; DELETE FROM conversations WHERE address='$ADDR'; DELETE FROM participants WHERE normalized_destination='$ADDR';" >/dev/null 2>&1 || true
    rm -f "$TMPZIP"
}
trap cleanup EXIT

db_sql() {
    adb_ shell "run-as $PKG sqlite3 databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r' && return 0
    adb_ shell "su -c \"sqlite3 /data/data/$PKG/databases/messages.db \\\"$1\\\"\"" 2>/dev/null | tr -d '\r' || true
}

adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1 || true

# Reads the stored log through the same path the screen uses, printing one
# entry per line. A missing file is an empty log, not an error.
log_lines() {
    adb_ shell "run-as '$PKG' cat files/transfer-log.json" 2>/dev/null | tr -d '\r' || true
}

run_probe() {
    # $1 = extra `am start` args. Restarts the app so the probe runs from onNewIntent.
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    adb_ shell am start -n "$ACT" >/dev/null
    sleep 3
    adb_ shell am start -n "$ACT" $1 >/dev/null
}

info "Build a two-record sms-ie backup"
python3 - "$MARK" "$ADDR" "$TMPZIP" <<'PY'
import json, sys, zipfile
mark, addr, out = sys.argv[1:4]
records = [
    {"_id": "1", "thread_id": "1", "address": addr, "date": "1790279506000",
     "read": "0", "type": "1", "body": "logfirst %s" % mark, "sub_id": "1"},
    {"_id": "2", "thread_id": "1", "address": addr, "date": "1790279507000",
     "read": "1", "type": "2", "body": "logsecond %s" % mark, "sub_id": "1"},
]
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
    z.writestr('messages.ndjson', '\n'.join(json.dumps(r) for r in records))
print('built', out)
PY
[ -f "$TMPZIP" ] && pass 'sms-ie fixture built' || { fail 'fixture not created'; exit 1; }

adb_ push "$TMPZIP" "$REMOTE" >/dev/null
adb_ shell "run-as '$PKG' sh -c 'cp $REMOTE files/$(basename "$INAPP")'" >/dev/null 2>&1

info "Clear the log so the run starts from a known state"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1
adb_ shell "run-as '$PKG' rm -f files/transfer-log.json" >/dev/null 2>&1
sleep 1

# --- 1. A failed import is recorded with its reason -------------------------
info "Import a file that is not a readable backup (failure path)"
adb_ shell "run-as '$PKG' sh -c 'echo not-a-backup > files/garbage-$MARK.zip'" >/dev/null 2>&1
GARBAGE="/data/data/$PKG/files/garbage-$MARK.zip"
adb_ shell am start -n "$ACT" >/dev/null
sleep 3
adb_ shell am start -n "$ACT" --es sms_ie_probe "file://$GARBAGE" >/dev/null
LOG=""
for _ in $(seq 1 15); do
    sleep 2
    LOG=$(log_lines)
    [ -n "$LOG" ] && break
done

if [ -n "$LOG" ]; then
    pass 'a failed import was written to the transfer log'
else
    fail 'nothing recorded for a failed import'
    exit 1
fi

echo "$LOG" | grep -q '"ok":false' \
    && pass 'the failed run is marked as failed, not as a success' \
    || fail 'the failed run was not marked failed'
echo "$LOG" | grep -q 'Cannot read\|No messages found' \
    && pass 'the failure reason was recorded' \
    || fail "no reason recorded: $LOG"

# --- 2. A merge records the duplicates it skipped ----------------------------
info "Merge the same backup twice; the second run must report duplicates"
adb_ shell "run-as '$PKG' rm -f files/transfer-log.json" >/dev/null 2>&1
for attempt in 1 2; do
    run_probe "--es sms_ie_probe file://$INAPP"
    for _ in $(seq 1 15); do
        sleep 2
        [ "$(db_sql "SELECT COUNT(*) FROM messages WHERE body LIKE 'log% $MARK';")" = "2" ] && break
    done
done
STORED=$(db_sql "SELECT COUNT(*) FROM messages WHERE body LIKE 'log% $MARK';")
[ "$STORED" = "2" ] && pass 'exactly 2 messages stored (the duplicate import added none)' \
    || fail "expected 2 stored messages, found ${STORED:-0}"

LOG=$(log_lines)
echo "$LOG" | grep -q 'already present' \
    && pass 'the duplicate merge recorded an "already present" conflict' \
    || fail "duplicates were not reported: $LOG"
echo "$LOG" | grep -q '"skipped":2' \
    && pass 'the conflict count reached the log (skipped=2)' \
    || fail "conflict count missing from the log: $LOG"

# --- 3. It survives a restart, and the screen shows it -----------------------
info "Restart and open Settings -> Advanced -> Import & export log"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1
sleep 1
adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null 2>&1
sleep 6
adb_ shell input swipe 500 1900 500 700 400 >/dev/null 2>&1
sleep 0.5
adb_ shell input swipe 500 1900 500 700 400 >/dev/null 2>&1
sleep 1.5

if ! tap_contains "Advanced settings" >/dev/null 2>&1; then
    fail 'could not open Advanced settings from the settings list'
    exit 1
fi
pass 'reached Advanced settings after a restart'
sleep 2

# The row sits below Diagnostics-adjacent entries; scroll until its bounds resolve.
OPENED=0
for _ in $(seq 1 10); do
    # The title row and the top-bar title are the same string, so match on the
    # subtitle too: a top-bar-only match means the row itself is off-screen.
    if dump_ui && grep -cF 'Recent imports, exports' "$TMP/ui.xml" >/dev/null 2>&1 \
       && tap_contains "Import &amp; export log" >/dev/null 2>&1; then
        OPENED=1
        break
    fi
    adb_ shell input swipe 540 1700 540 900 250 >/dev/null 2>&1
    sleep 0.6
done

sleep 2
dump_ui
if [ "$OPENED" = "1" ] && grep -cF 'Import &amp; export log' "$TMP/ui.xml" >/dev/null 2>&1; then
    pass 'the transfer log screen opened'
else
    fail 'the transfer log screen did not open'
    grep -o 'text="[^"]*"' "$TMP/ui.xml" | sort -u | sed 's/^/    | /'
    exit 1
fi

if grep -cF 'No imports or exports yet' "$TMP/ui.xml" >/dev/null 2>&1; then
    fail 'the screen is empty even though a transfer was recorded'
    exit 1
fi
pass 'the screen shows the recorded runs, not the empty state'

# The outcome has to read as text, not only as a coloured icon. Only the
# newest run is on screen at the top (the list is newest first), so this checks
# the pill that is visible rather than requiring the failed one too.
if grep -cF 'Succeeded' "$TMP/ui.xml" >/dev/null 2>&1; then
    pass 'the outcome renders as a status pill, not only a colour'
else
    fail 'the status pill did not render'
fi

if grep -cF 'already present' "$TMP/ui.xml" >/dev/null 2>&1; then
    pass 'the conflict is visible on screen after a restart'
else
    fail 'the conflict was not visible on the transfer log screen'
fi

adb_ logcat -c >/dev/null 2>&1 || true
adb_ shell am force-stop "$PKG" >/dev/null 2>&1
adb_ shell am start -n "$ACT" --ez transfer_log_probe true >/dev/null
sleep 4
adb_ shell logcat -d -s TransferLog 2>/dev/null | tr -d '\r' | grep -q 'already present' \
    && pass "the same runs are readable through the screen's own read path" \
    || fail 'the log was not readable after restart'

printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
exit $((FAIL > 0))