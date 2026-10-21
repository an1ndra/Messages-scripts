#!/usr/bin/env bash
# Regression for the #328 follow-up: an MMS that cannot be fetched because
# mobile data is off (MMS_ERROR_NO_DATA_NETWORK / MMS_ERROR_DATA_DISABLED) is
# "waiting for data", not a manual retry. It must not spend the automatic
# attempt budget, and a background re-check must be armed so the message is
# still fetched when the app is not opened again. No network permission is
# involved — the re-check uses NetworkType.NOT_REQUIRED.
#
# The download-completion result only comes from the non-exported
# MmsDownloadReceiver, which adb cannot trigger, so a debug probe
# (--ei mms_recheck_probe <resultCode>) hands the downloader a synthetic result.
# Before the fix code 8 fell through to MANUAL_RETRY: the log said "needs manual
# retry" and no re-check was scheduled, so the classification and ENQUEUED
# assertions below both fail.
source "$(dirname "$0")/env.sh"
set -euo pipefail

PASS=0
FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
[[ "$ANDROID_SERIAL" == emulator-* ]] || { printf 'Requires a disposable emulator.\n'; exit 1; }
adb_ root >/dev/null 2>&1 || true
[[ "$(adb_ shell id -u | tr -d '\r')" == 0 ]] || { printf 'Run adb root on the test emulator first.\n'; exit 1; }

PROVDB="${PROVDB:-/data/data/com.android.providers.telephony/databases/mmssms.db}"
WORKDB="${WORKDB:-/data/data/$PKG/no_backup/androidx.work.workdb}"
NO_DATA_NETWORK=8
# Must match MainActivity.applyMmsRecheckProbe: this row id is unique per run
# and no real message uses it, so the assertions below cannot be satisfied or
# broken by an unrelated row.
PROBE_ROW=2147483000
MARKER="mmsrecheck$(date +%s)$$"
provider() { adb_ shell "sqlite3 '$PROVDB' \"$1\"" | tr -d '\r'; }

# Tracked in a file, not a variable: seed_pending runs in a command
# substitution (a subshell), so an assigned variable would be discarded and
# cleanup would remove nothing.
CREATED_FILE="$TMP/mms-recheck-created.$$"

# WorkSpec.State: ENQUEUED=0. BackoffPolicy: EXPONENTIAL=0.
work_state() {
    adb_ shell "sqlite3 '$WORKDB' \"SELECT state FROM WorkSpec WHERE worker_class_name LIKE '%MmsRecheckWorker%';\"" 2>/dev/null | tr -d '\r'
}
work_backoff() {
    adb_ shell "sqlite3 '$WORKDB' \"SELECT backoff_policy FROM WorkSpec WHERE worker_class_name LIKE '%MmsRecheckWorker%';\"" 2>/dev/null | tr -d '\r'
}

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    # Drop the re-check so it cannot wake a later test.
    adb_ shell "sqlite3 '$WORKDB' \"DELETE FROM WorkSpec WHERE worker_class_name LIKE '%MmsRecheckWorker%';\"" >/dev/null 2>&1 || true
    if [ -s "$CREATED_FILE" ]; then
        local created
        created="$(paste -sd, "$CREATED_FILE")"
        provider "DELETE FROM part WHERE mid IN ($created); DELETE FROM addr WHERE msg_id IN ($created); DELETE FROM pdu WHERE _id IN ($created);" >/dev/null || true
    fi
    rm -f "$CREATED_FILE"
}
trap cleanup EXIT

adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1 || true

# An m_type=130 row is a NotificationInd: announced by the carrier, not yet
# retrieved. One is seeded so the app has something real to keep the re-check
# alive for; an empty sweep correctly cancels the re-check.
seed_pending() {
    local id
    id="$(provider "INSERT INTO pdu(thread_id,date,msg_box,m_type,read,m_size,sub_id,ct_l) VALUES(0,$(date +%s),1,130,0,0,1,'http://mmsc.local/$MARKER'); SELECT last_insert_rowid();" | tail -1)"
    [ -n "$id" ] || return 1
    printf '%s\n' "$id" >> "$CREATED_FILE"
    printf '%s' "$id"
}

info "Seed an announced MMS so the re-check has something to keep alive"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1
ID=$(seed_pending) || { fail 'could not seed an m_type=130 row'; exit 1; }
[ -n "$ID" ] && pass "seeded announced MMS row (id=$ID)"

info "A no-data download must be classified as waiting for data, not a manual retry"
adb_ logcat -c >/dev/null 2>&1 || true
adb_ shell am start -n "$ACT" --ei mms_recheck_probe "$NO_DATA_NETWORK" >/dev/null
sleep 6

if adb_ logcat -d 2>/dev/null | grep -q "MMS content://mms/$PROBE_ROW has no data network"; then
    pass "code $NO_DATA_NETWORK classified as waiting for data"
else
    fail "code $NO_DATA_NETWORK was not classified as waiting for data"
fi
if adb_ logcat -d 2>/dev/null | grep -q "MMS content://mms/$PROBE_ROW needs manual retry"; then
    fail "code $NO_DATA_NETWORK was still treated as a manual retry"
else
    pass "code $NO_DATA_NETWORK is not a manual retry"
fi

info "The deferred re-check must be armed and permission-free"
STATE=$(work_state)
if [ "$STATE" = "0" ]; then
    pass "MmsRecheckWorker enqueued (state=ENQUEUED)"
else
    fail "MmsRecheckWorker not enqueued (state='${STATE:-none}')"
fi
BACKOFF=$(work_backoff)
if [ "$BACKOFF" = "0" ]; then
    pass "re-check uses exponential backoff"
else
    fail "re-check backoff is '${BACKOFF:-none}', expected EXPONENTIAL(0)"
fi

if adb_ logcat -d -b crash 2>/dev/null | grep -q "$PKG"; then
    fail 'app crashed handling the no-data completion'
else
    pass 'no-data completion handled without a crash'
fi

printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
