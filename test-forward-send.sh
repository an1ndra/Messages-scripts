#!/usr/bin/env bash
# Issue #264 regression: forwarding a message must reach a terminal status.
#
# forwardMessage() used to stop after inserting the outgoing row, so nothing
# registered the SmsStatusReceiver PendingIntent and the bubble sat on
# "Sending…" forever. This drives a real forward through the UI and asserts the
# stored row leaves "sending" — and that the framework actually took the message
# (system Sent box), not just that the local row was rewritten.
#
# Self-contained: it seeds its own source conversation, picks whatever contact
# the forward picker offers, and cleans up its rows afterwards.
#
# Precondition: emulator booted, app installed, at least one contact exists
# (scripts/insert-demo-contacts.sh).
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
pass(){ echo "[PASS] $1"; PASS=$((PASS+1)); }
fail(){ echo "[FAIL] $1"; FAIL=$((FAIL+1)); }
info(){ echo -e "\n=== $* ==="; }

# Unique per run: the system Sent box keeps rows from earlier runs, so a fixed
# marker would let a stale "sent" row satisfy the hand-off assertion.
TOKEN="FWD264$(date +%s)"
NOW=$(date +%s)
SRC="+15558880001"
TARGET=""

local_query(){ adb_ shell "run-as '$PKG' sqlite3 databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r'; }

cleanup(){
  local_query "DELETE FROM messages WHERE body LIKE '%$TOKEN%';" >/dev/null 2>&1 || true
  local_query "DELETE FROM conversations WHERE address='$SRC';" >/dev/null 2>&1 || true
  if [ -n "$TARGET" ]; then
    local_query "DELETE FROM conversations WHERE address='$TARGET' AND id NOT IN (SELECT conversation_id FROM messages WHERE conversation_id IS NOT NULL);" >/dev/null 2>&1 || true
  fi
  adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
}
trap cleanup EXIT

seed(){
  local_query "DELETE FROM messages WHERE body LIKE '%$TOKEN%';" >/dev/null 2>&1
  local_query "DELETE FROM conversations WHERE address='$SRC';" >/dev/null 2>&1
  local_query "INSERT INTO conversations(address,name,snippet,timestamp) VALUES('$SRC','FWD Source','src',${NOW}000);" >/dev/null 2>&1
  local src
  src=$(local_query "SELECT id FROM conversations WHERE address='$SRC' ORDER BY id DESC LIMIT 1;")
  [ -z "$src" ] && return 1
  local_query "INSERT INTO messages(conversation_id,body,timestamp,is_me,status) VALUES($src,'$TOKEN original',${NOW}000,0,'received');" >/dev/null 2>&1
  [ "$(local_query "SELECT COUNT(*) FROM messages WHERE conversation_id=$src AND body LIKE '%$TOKEN%';")" -ge 1 ]
}

info "Seeding a source conversation with one message"
seed || { fail "could not seed the source conversation"; echo "Results: $PASS passed, $FAIL failed"; exit 1; }
pass "seeded a message into $SRC"

info "Opening the source conversation"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
adb_ shell am start -n "$ACT" --es open_conversation_address "$SRC" >/dev/null; sleep 4
dump_ui || fail "chat dump failed"
if grep -qF "$TOKEN original" "$TMP/ui.xml"; then
  pass "source bubble rendered"
else
  fail "source bubble '$TOKEN original' not rendered"
fi

info "Long-pressing the bubble and tapping Forward"
B=$(center_of "$TOKEN original" || true)
if [ -z "$B" ]; then
  fail "could not locate the source bubble"
else
  adb_ shell input swipe ${B% *} ${B#* } ${B% *} $(( ${B#* } + 3 )) 800
  sleep 2
  if wait_for_text "Forward" 8; then
    pass "selection toolbar shown with a Forward action"
  else
    fail "Forward action not found in the selection toolbar"
  fi
  F=$(center_of "Forward" || true)
  if [ -z "$F" ]; then
    fail "Forward action not tappable"
  else
    adb_ shell input tap $F; sleep 2.5
  fi
fi

info "Picking a target contact in the forward picker"
if wait_for_text "Forward to" 8; then
  pass "forward picker opened"
else
  fail "forward picker did not open"
fi
# Take the first contact row offered: the picker lists a name with its number
# underneath, so the first phone-number node identifies both the row and target.
pick=$(python3 - "$TMP/ui.xml" <<'PY'
import re, sys
xml = open(sys.argv[1]).read()
for n in re.findall(r'<node[^>]*>', xml):
    t = re.search(r'text="(\+[\d \-()]{7,})"', n)
    b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', n)
    if t and b:
        print(f"{(int(b.group(1)) + int(b.group(3))) // 2} "
              f"{(int(b.group(2)) + int(b.group(4))) // 2} {t.group(1).strip()}")
        break
PY
)
if [ -z "$pick" ]; then
  fail "forward picker offered no contacts (run scripts/insert-demo-contacts.sh)"
else
  PX=${pick%% *}; rest=${pick#* }; PY_=${rest%% *}; TARGET=${rest#* }
  echo "   picking contact $TARGET at ($PX $PY_)"
  adb_ shell input tap "$PX" "$PY_"
  sleep 3
  pass "forward target picked ($TARGET)"
fi

info "Asserting the forwarded row reached a terminal status"
# The bug: the row is inserted but stays on "sending" forever.
STATUS=""
for _ in $(seq 1 12); do
  STATUS=$(local_query "SELECT status FROM messages WHERE body LIKE '%$TOKEN%' AND is_me=1 ORDER BY id DESC LIMIT 1;")
  [ -n "$STATUS" ] && [ "$STATUS" != "sending" ] && break
  sleep 2
done
echo "   forwarded row status: '${STATUS:-<no row>}'"
case "$STATUS" in
  sent|delivered) pass "forwarded message reached '$STATUS' (not stuck on sending)" ;;
  failed)         fail "framework rejected the forward — row went to 'failed'" ;;
  "")             fail "no forwarded row was written at all" ;;
  *)              fail "forwarded message status is '$STATUS', expected sent/delivered" ;;
esac

info "Asserting the framework actually took the message (system Sent box)"
SENT=$(adb_ shell content query --uri content://sms/sent --projection body \
    --where "\"body LIKE '%$TOKEN%'\"" 2>/dev/null | grep -cF "$TOKEN" || true)
if [ "${SENT:-0}" -ge 1 ]; then
  pass "message mirrored to the system Sent box"
else
  fail "nothing in the system Sent box — the forward never reached the framework"
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
