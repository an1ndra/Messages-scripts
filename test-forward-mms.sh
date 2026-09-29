#!/usr/bin/env bash
# Issue #264 (second half): forwarding an image message must forward the
# attachment, not silently downgrade it to an SMS carrying an (often empty)
# caption.
#
# forwardMessage() used to forward `msg.body` unconditionally, so an MMS was
# re-sent as a text bubble. retryMessage() already branched on mediaType; the
# forward path now does too, via ForwardPlan.
#
# The emulator has no MMSC, so the transmit is expected to end in "failed" — the
# same as test-mms-send.sh asserts. What matters here is that the row is stored
# as an image with its attachment and leaves "sending"; the pre-fix code stored
# media_type='text' with an empty body.
#
# Requires a disposable emulator (uses `adb root` for the provider DB).
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
pass(){ echo "[PASS] $1"; PASS=$((PASS+1)); }
fail(){ echo "[FAIL] $1"; FAIL=$((FAIL+1)); }
info(){ echo -e "\n=== $* ==="; }

[[ "$ANDROID_SERIAL" == emulator-* ]] || { echo "Requires a disposable emulator."; exit 1; }

# Unique per run: the provider outbox and the Sent box persist across runs.
MARK="fwdmms$(date +%s)$$"
TOKEN="FWMMS$MARK"
NOW=$(date +%s)
SRC="+15558880011"
TARGET=""
PROVDB="/data/data/com.android.providers.telephony/databases/mmssms.db"
MEDIA_URI="content://$PKG.fileprovider/camera/$MARK.png"

local_query(){ adb_ shell "run-as '$PKG' sqlite3 databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r'; }
provider(){ adb_ shell "sqlite3 '$PROVDB' \"$1\"" 2>/dev/null | tr -d '\r'; }

cleanup(){
  adb_ unroot >/dev/null 2>&1 || true
  # adbd restarts on unroot; the next run's run-as calls fail until it settles.
  sleep 3
  provider "DELETE FROM part WHERE mid IN (SELECT _id FROM pdu WHERE m_type=128 AND date >= $(( NOW - 86400 ))); DELETE FROM addr WHERE msg_id IN (SELECT _id FROM pdu WHERE m_type=128 AND date >= $(( NOW - 86400 ))); DELETE FROM pdu WHERE m_type=128 AND date >= $(( NOW - 86400 ));" >/dev/null 2>&1 || true
  local_query "DELETE FROM messages WHERE body LIKE '$TOKEN%' OR media_uri LIKE '%$MARK%';" >/dev/null 2>&1 || true
  local_query "DELETE FROM conversations WHERE address='$SRC';" >/dev/null 2>&1 || true
  adb_ shell "run-as '$PKG' rm -f cache/camera/$MARK.png" >/dev/null 2>&1 || true
  adb_ shell "rm -f /data/local/tmp/$MARK.png" >/dev/null 2>&1 || true
  adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
  rm -f "/tmp/$MARK.png"
}
trap cleanup EXIT

info "Seeding a small image the app can read through its own FileProvider"
python3 - "$MARK" <<'PY'
import struct, sys, zlib
marker = sys.argv[1]
w = h = 2
raw = b''.join(b'\x00' + b'\xff\x00\x00' * w for _ in range(h))
def chunk(tag, data):
    body = tag + data
    return struct.pack('>I', len(data)) + body + struct.pack('>I', zlib.crc32(body) & 0xffffffff)
png = (b'\x89PNG\r\n\x1a\n'
       + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
       + chunk(b'IDAT', zlib.compress(raw))
       + chunk(b'IEND', b''))
open('/tmp/%s.png' % marker, 'wb').write(png)
PY
adb_ shell "run-as '$PKG' mkdir -p cache/camera" >/dev/null 2>&1
adb_ push "/tmp/$MARK.png" "/data/local/tmp/$MARK.png" >/dev/null
adb_ shell "run-as '$PKG' sh -c 'cat /data/local/tmp/$MARK.png > cache/camera/$MARK.png'"

info "Seeding a received IMAGE message (empty caption) in the source conversation"
local_query "DELETE FROM messages WHERE media_uri LIKE '%$MARK%';" >/dev/null 2>&1
local_query "DELETE FROM conversations WHERE address='$SRC';" >/dev/null 2>&1
local_query "INSERT INTO conversations(address,name,snippet,timestamp) VALUES('$SRC','FWD MMS Source','photo',${NOW}000);" >/dev/null 2>&1
SRCID=$(local_query "SELECT id FROM conversations WHERE address='$SRC' ORDER BY id DESC LIMIT 1;")
if [ -z "$SRCID" ]; then
  fail "could not seed the source conversation"
  echo "Results: $PASS passed, $FAIL failed"; exit 1
fi
# Caption left empty on purpose: pre-fix this forwarded as an SMS with no body.
local_query "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,media_type,media_uri) VALUES($SRCID,'',${NOW}000,0,'received','image','$MEDIA_URI');" >/dev/null 2>&1
SEEDED=$(local_query "SELECT COUNT(*) FROM messages WHERE conversation_id=$SRCID AND media_type='image';")
[ "${SEEDED:-0}" -ge 1 ] && pass "seeded a received image message" || fail "could not seed the image message"

info "Clearing the provider outbox so a leftover PDU cannot satisfy the assertion"
adb_ root >/dev/null 2>&1 || true
sleep 3
provider "DELETE FROM part WHERE mid IN (SELECT _id FROM pdu WHERE m_type=128); DELETE FROM addr WHERE msg_id IN (SELECT _id FROM pdu WHERE m_type=128); DELETE FROM pdu WHERE m_type=128;" >/dev/null 2>&1 || true

info "Opening the conversation and forwarding the image"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
adb_ shell am start -n "$ACT" --es open_conversation_address "$SRC" >/dev/null
# The attachment bubble renders once the image resolves, so poll for its label.
if ! wait_for_text "Photo" 12; then
  fail "the seeded image bubble never rendered"
  echo "Results: $PASS passed, $FAIL failed"; exit 1
fi
dump_ui || fail "chat dump failed"

# The image bubble has no caption text, so target it by its "Photo" accessibility
# label (R.string.access_photo). That label lands on a content-desc node sized to
# the image itself — 2px here — so widen to the clickable bubble that contains it.
B=$(python3 - "$TMP/ui.xml" <<'PY'
import re, sys
xml = open(sys.argv[1]).read()
point = None
for n in re.findall(r'<node[^>]*>', xml):
    if re.search(r'(text|content-desc)="Photo"', n):
        b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', n)
        if b:
            y = (int(b.group(2)) + int(b.group(4))) // 2
            if 300 < y < 2000:   # the message list, not the top bar
                point = ((int(b.group(1)) + int(b.group(3))) // 2, y)
                break
if not point:
    raise SystemExit(0)
px, py = point
best = None
for n in re.findall(r'<node[^>]*>', xml):
    if 'clickable="true"' not in n:
        continue
    b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', n)
    if not b:
        continue
    x1, y1, x2, y2 = (int(b.group(i)) for i in (1, 2, 3, 4))
    if x1 <= px <= x2 and y1 <= py <= y2:
        area = (x2 - x1) * (y2 - y1)
        if best is None or area < best[0]:   # tightest containing bubble
            best = (area, (x1 + x2) // 2, (y1 + y2) // 2)
print(f"{best[1]} {best[2]}" if best else f"{px} {py}")
PY
)
if [ -z "$B" ]; then
  fail "could not locate the image bubble to forward"
  echo "Results: $PASS passed, $FAIL failed"; exit 1
fi
pass "found the image bubble at ($B)"

adb_ shell input swipe ${B% *} ${B#* } ${B% *} $(( ${B#* } + 3 )) 800
sleep 2
if wait_for_text "Forward" 8; then
  pass "selection toolbar shown with a Forward action"
else
  fail "Forward action not found in the selection toolbar"
fi
F=""
for _ in 1 2 3; do
  F=$(center_of "Forward" || true)
  [ -n "$F" ] && break
  sleep 1
done
if [ -z "$F" ]; then
  fail "Forward action not tappable"
else
  adb_ shell input tap $F
  # AVD is touchy: the picker can take a beat, and a dropped tap leaves the
  # selection toolbar up, so retry once before calling it a failure.
  opened=0
  for _ in 1 2; do
    if wait_for_text "Forward to" 8; then opened=1; break; fi
    adb_ shell input tap $F; sleep 2
  done
  if [ "$opened" = 1 ]; then
    pass "forward picker opened"
  else
    fail "forward picker did not open"
  fi
fi

info "Picking a target contact in the forward picker"
dump_ui
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
  echo "Results: $PASS passed, $FAIL failed"; exit 1
fi
PX=${pick%% *}; rest=${pick#* }; PY_=${rest%% *}; TARGET=${rest#* }
echo "   picking contact $TARGET at ($PX $PY_)"
adb_ shell input tap "$PX" "$PY_"
sleep 5
pass "forward target picked ($TARGET)"

info "Asserting the attachment was forwarded, not downgraded to a text caption"
# The pre-fix row is media_type='text' with an empty body. This is the assertion
# that distinguishes it.
ROW=$(local_query "SELECT media_type||'|'||COALESCE(media_uri,'')||'|'||COALESCE(body,'') FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$TARGET') AND is_me=1 ORDER BY id DESC LIMIT 1;")
echo "   forwarded row (media_type|media_uri|body): ${ROW:-<none>}"
if [ -z "$ROW" ]; then
  fail "no forwarded row was written to the target conversation"
else
  MTYPE=${ROW%%|*}
  if [ "$MTYPE" = "image" ]; then
    pass "forwarded row stored as media_type='image', not a text caption"
  else
    fail "forwarded row is media_type='$MTYPE' — the image was downgraded to SMS"
  fi
  MURI=$(printf '%s' "$ROW" | cut -d'|' -f2)
  if [ -n "$MURI" ]; then
    pass "forwarded row carries the attachment URI ($MURI)"
  else
    fail "forwarded row has no media_uri"
  fi
fi

info "Asserting the row left 'sending'"
STATUS=""
for _ in $(seq 1 15); do
  STATUS=$(local_query "SELECT status FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$TARGET') AND is_me=1 ORDER BY id DESC LIMIT 1;")
  [ -n "$STATUS" ] && [ "$STATUS" != "sending" ] && break
  sleep 2
done
echo "   forwarded row status: '${STATUS:-<no row>}'"
case "$STATUS" in
  sent|delivered|failed) pass "forwarded image reached '$STATUS' (not stuck on sending)" ;;
  "")                   fail "no forwarded row to check" ;;
  sending)              fail "forwarded image is still stuck on 'sending'" ;;
  *)                    fail "unexpected status '$STATUS'" ;;
esac

info "Asserting the framework was handed an MMS (provider outbox PDU)"
PDU=$(provider "SELECT _id FROM pdu WHERE m_type=128 ORDER BY _id DESC LIMIT 1;")
if [ -n "$PDU" ]; then
  pass "outgoing MMS PDU persisted to the provider (m_type=128, id=$PDU)"
  IMG=$(provider "SELECT COUNT(*) FROM part WHERE mid=$PDU AND ct LIKE 'image/%';")
  if [ "${IMG:-0}" -ge 1 ]; then
    pass "PDU carries the image attachment"
  else
    fail "PDU has no image part ($IMG)"
  fi
else
  fail "no outgoing MMS PDU in the provider outbox — sendMms was not called"
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
