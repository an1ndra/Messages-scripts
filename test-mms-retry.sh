#!/usr/bin/env bash
# MMS download retry must distinguish transient from permanent failures.
#
# Before the fix every announced MMS was fetched exactly once and then dropped
# for five minutes regardless of why it failed, so a message lost to a brief
# data-network outage was never recovered, while a message the carrier had
# already discarded kept being reconsidered forever.
#
# The classification itself is unit-tested in MmsRetryTest; this script asserts
# the app-side bookkeeping that the unit tests cannot reach — that a completed
# download is forgotten, and that an announced-but-unsent row is not re-requested
# inside its backoff window.
source "$(dirname "$0")/env.sh"
set -euo pipefail

PASS=0
FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
[[ "$ANDROID_SERIAL" == emulator-* ]] || { printf 'Requires a disposable emulator.\n'; exit 1; }
[[ "$(adb_ shell id -u | tr -d '\r')" == 0 ]] || { printf 'Run adb root on the test emulator first.\n'; exit 1; }

PROVDB="${PROVDB:-/data/data/com.android.providers.telephony/databases/mmssms.db}"
MARKER="mmsretry$(date +%s)$$"
provider() { adb_ shell "sqlite3 '$PROVDB' \"$1\"" | tr -d '\r'; }

# Rows created by this test, tracked so cleanup can remove exactly them.
CREATED=""

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    if [ -n "$CREATED" ]; then
        provider "DELETE FROM part WHERE mid IN ($CREATED); DELETE FROM addr WHERE msg_id IN ($CREATED); DELETE FROM pdu WHERE _id IN ($CREATED);" >/dev/null || true
    fi
    rm -f "$TMP/$MARKER"*.png
}
trap cleanup EXIT

adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1 || true

# An m_type=130 row is a NotificationInd: announced by the carrier, not yet
# retrieved. That is the state MmsDownloader.requestPending() acts on.
seed_pending() {
    local id
    id="$(provider "INSERT INTO pdu(thread_id,date,msg_box,m_type,read,m_size,sub_id) VALUES(0,$(date +%s),1,130,0,0,1); SELECT last_insert_rowid();" | tail -1)"
    [ -n "$id" ] || return 1
    CREATED="${CREATED:+$CREATED,}$id"
    printf '%s' "$id"
}

info "The downloader must skip an announced MMS it already requested"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1
adb_ logcat -c >/dev/null 2>&1 || true
adb_ shell am start -n "$ACT" >/dev/null
sleep 4

ID1=$(seed_pending)
[ -n "$ID1" ] && pass "seeded announced MMS row (id=$ID1)" || { fail 'could not seed an m_type=130 row'; exit 1; }

# A cold start runs requestPending, which requests every m_type=130 row once.
adb_ shell input keyevent KEYCODE_HOME >/dev/null 2>&1
adb_ shell am start -n "$ACT" >/dev/null
sleep 6

REQUESTS=$(adb_ logcat -d 2>/dev/null | grep -c "MMS download requested for content://mms/$ID1 " || true)
if [ "${REQUESTS:-0}" -ge 1 ]; then
    pass "announced MMS requested on start (count=$REQUESTS)"
else
    fail "announced MMS was never requested (id=$ID1)"
fi
if [ "${REQUESTS:-0}" -le 1 ]; then
    pass "announced MMS not re-requested inside the backoff window (count=$REQUESTS)"
else
    fail "announced MMS re-requested $REQUESTS times without a completed attempt"
fi

info "A finished transfer must be classified and the row released from backoff"
# No synthetic broadcast: on the emulator the platform itself completes the
# download and reports a result code on the PendingIntent, so this exercises the
# real path. Before the fix the result was never looked at at all.
for i in $(seq 1 20); do
    CLASSIFIED=$(adb_ logcat -d 2>/dev/null | grep -oE "MMS content://mms/$ID1 (permanently failed|needs manual retry|failed \(code [0-9]+\), retrying)" | tail -1 || true)
    [ -n "${CLASSIFIED:-}" ] && break
    sleep 2
done

if [ -n "${CLASSIFIED:-}" ]; then
    pass "download result classified: $CLASSIFIED"
else
    fail 'download result was never classified (row left in the retry map untouched)'
fi

if adb_ logcat -d -b crash 2>/dev/null | grep -q "$PKG"; then
    fail 'app crashed handling the download completion'
else
    pass 'download completion handled without a crash'
fi

# Only an AUTO_RETRY outcome stays in the backoff map. Every other outcome must
# release the row so the next rescan is free to try again; the old flat cooldown
# held every row for five minutes regardless of the outcome.
if [[ "${CLASSIFIED:-}" == *"retrying"* ]]; then
    info "outcome is transient, so the row correctly stays in backoff"
else
    adb_ shell input keyevent KEYCODE_HOME >/dev/null 2>&1
    adb_ logcat -c >/dev/null 2>&1 || true
    adb_ shell am start -n "$ACT" >/dev/null
    sleep 6
    ELIGIBLE=$(adb_ logcat -d 2>/dev/null | grep -c "MMS download requested for content://mms/$ID1 " || true)
    if [ "${ELIGIBLE:-0}" -ge 1 ]; then
        pass 'non-transient outcome released the row from backoff'
    else
        fail 'row still in backoff after a non-transient outcome'
    fi
fi

info "The downloader must survive a provider with no pending rows"
adb_ shell input keyevent KEYCODE_HOME >/dev/null 2>&1
adb_ shell am start -n "$ACT" >/dev/null
sleep 4
if adb_ logcat -d -b crash 2>/dev/null | grep -q "$PKG"; then
    fail 'app crashed scanning for pending downloads'
else
    pass 'pending-download scan survived with no crash'
fi

printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
