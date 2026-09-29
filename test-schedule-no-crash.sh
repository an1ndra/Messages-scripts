#!/usr/bin/env bash
# Issue #281 regression: scheduling a message must not close the app.
#
# Two defects chained here:
#   1. Material's DatePicker returns midnight UTC of the tapped day, but the
#      time step read it as a local instant. West of Greenwich that lands on
#      the previous day, and any time already gone by today produced a
#      timestamp in the past — which is what the reporter saw as "yesterday's
#      date" in the toast.
#   2. addScheduledMessage() rejects a non-future timestamp by throwing, and
#      that throw escaped a fire-and-forget launch on a bare SupervisorJob, so
#      it reached the default uncaught handler and killed the process.
#
# Asserts: nothing lands in the crash buffer, the process is still alive, the
# scheduled row is stored, and its timestamp is in the future (never yesterday).
#
# Precondition: emulator booted, app installed, system locale English.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
info() { echo -e "\n=== $* ==="; }
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

NUM="+15558880301"
# Unique per run so a row left by an earlier run cannot satisfy the assertions.
TOKEN="SCHED281$(date +%s)"

local_query(){ adb_ shell "run-as '$PKG' sqlite3 databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r'; }

cleanup(){
  adb_ shell input keyevent 4 >/dev/null 2>&1 || true
  local_query "DELETE FROM scheduled_messages WHERE body LIKE 'SCHED281%';" >/dev/null 2>&1 || true
  adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
}
trap cleanup EXIT

send_button(){
  python3 - "$TMP/ui.xml" <<'PY'
import re, sys
xml = open(sys.argv[1]).read()
for n in re.findall(r'<node[^>]*>', xml):
    d = re.search(r'content-desc="([^"]*)"', n)
    b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', n)
    if d and b and d.group(1).strip().lower() in ("send", "send message"):
        print((int(b.group(1)) + int(b.group(3))) // 2,
              (int(b.group(2)) + int(b.group(4))) // 2)
        break
PY
}

info "Recording the device timezone (the date bug only shifts west of UTC)"
TZNAME=$(adb_ shell getprop persist.sys.timezone 2>/dev/null | tr -d '\r')
OFFSET=$(adb_ shell "date +%z" 2>/dev/null | tr -d '\r')
echo "   timezone=$TZNAME offset=$OFFSET"

info "Clearing the crash buffer and composing a message"
adb_ logcat -b crash -c >/dev/null 2>&1 || true
adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
adb_ shell am start -n "$ACT" --es open_conversation_address "$NUM" >/dev/null; sleep 4
dump_ui || fail "chat dump failed"

tap_edittext || fail "could not focus the message input"
type_text "$TOKEN"
sleep 1

SEND=""
for _ in 1 2 3 4 5; do
  dump_ui >/dev/null 2>&1 || true
  SEND=$(send_button)
  [ -n "$SEND" ] && break
  sleep 1
done
if [ -z "$SEND" ]; then
  fail "send button never appeared in the input bar"
else
  pass "send button found at ($SEND)"
fi

info "Long-pressing send to open the schedule date picker"
adb_ shell input swipe ${SEND% *} ${SEND#* } ${SEND% *} $(( ${SEND#* } - 3 )) 800
sleep 2.5
dump_ui
if wait_for_text "Next" 8; then
  pass "schedule date picker opened"
else
  fail "long-pressing send did not open the schedule picker"
fi

info "Confirming today's date, then confirming the time"
N=$(center_of "Next" || true)
if [ -z "$N" ]; then
  fail "could not find the date picker's Next button"
else
  adb_ shell input tap $N
  sleep 2.5
  if wait_for_text "Select time" 8; then
    pass "time picker shown"
  else
    fail "time picker did not appear after confirming the date"
  fi
fi

S=""
for _ in 1 2 3 4 5; do
  dump_ui >/dev/null 2>&1 || true
  S=$(center_of "Schedule" || true)
  [ -n "$S" ] && break
  sleep 1
done
if [ -z "$S" ]; then
  fail "could not find the Schedule button in the time picker"
else
  adb_ shell input tap $S
  sleep 3
  pass "tapped Schedule"
fi

info "Asserting the app did not crash"
sleep 2
CRASHES=$(adb_ logcat -d -b crash 2>/dev/null | grep -c "$PKG" || true)
if [ "${CRASHES:-0}" -eq 0 ]; then
  pass "crash buffer has no $PKG entries"
else
  fail "crash buffer contains $CRASHES $PKG entries — scheduling killed the app"
  adb_ logcat -d -b crash 2>/dev/null | grep -A 15 "$PKG" | head -30
fi

PID=$(adb_ shell pidof "$PKG" 2>/dev/null | tr -d '\r')
if [ -n "$PID" ]; then
  pass "app process $PID is still alive after scheduling"
else
  fail "app process is gone — scheduling killed it"
fi

dump_ui || true
if grep -qE "crash report" "$TMP/ui.xml"; then
  fail "crash report dialog is showing after scheduling"
else
  pass "no crash report prompt after scheduling"
fi

info "Asserting the scheduled row exists and is in the future"
# The insert runs on Dispatchers.IO, so poll rather than racing it.
ROW=""
for _ in $(seq 1 10); do
  ROW=$(local_query "SELECT id||'|'||timestamp FROM scheduled_messages WHERE body LIKE 'SCHED281%' ORDER BY id DESC LIMIT 1;")
  [ -n "$ROW" ] && break
  sleep 1
done
echo "   scheduled_messages: ${ROW:-<none>}"
if [ -z "$ROW" ]; then
  fail "no scheduled_messages row was stored for '$TOKEN'"
else
  pass "scheduled row stored (id=$(printf '%s' "$ROW" | cut -d'|' -f1))"
  TS=$(printf '%s' "$ROW" | cut -d'|' -f2)
  NOW_MS=$(adb_ shell "date +%s" 2>/dev/null | tr -d '\r')
  NOW_MS=$(( NOW_MS * 1000 ))
  if [ "$TS" -gt "$NOW_MS" ]; then
    pass "scheduled timestamp is in the future ($TS > $NOW_MS)"
  else
    fail "scheduled timestamp $TS is not in the future (now $NOW_MS)"
  fi
  # The reported symptom: the toast showed yesterday's date. Compare the
  # scheduled instant's own local date against the device's local date; the fix
  # may roll a time that already passed today forward to tomorrow, so accept
  # today or tomorrow but never yesterday or earlier.
  # toybox date handles "-d @<epoch>" but not "-d tomorrow", so derive the
  # device's today here and do the +1 day arithmetic on the host.
  GOT=$(adb_ shell "date -d @$(( TS / 1000 )) +%Y%m%d" 2>/dev/null | tr -d '\r')
  TODAY=$(adb_ shell "date +%Y%m%d" 2>/dev/null | tr -d '\r')
  TOMORROW=$(date -d "$TODAY + 1 day" +%Y%m%d 2>/dev/null)
  echo "   scheduled local date=$GOT (today=$TODAY tomorrow=$TOMORROW)"
  if [ -z "$GOT" ] || [ "$GOT" = "$TODAY" ] || [ "$GOT" = "$TOMORROW" ]; then
    pass "scheduled date is today or later (not rolled back a day)"
  else
    fail "scheduled date $GOT is neither today ($TODAY) nor tomorrow ($TOMORROW)"
  fi
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
