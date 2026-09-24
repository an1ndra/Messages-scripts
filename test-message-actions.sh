#!/usr/bin/env bash
# Regression for #232 (Select all), #231 (Select text) and #235 (Save image).
# Seeds two text MMS and one image MMS into the provider, then drives the chat
# selection overflow for each new action and asserts the observable result.
source "$(dirname "$0")/env.sh"
set -euo pipefail

PASS=0
FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
[[ "$ANDROID_SERIAL" == emulator-* ]] || { printf 'Requires a disposable emulator.\n'; exit 1; }
[[ "$(adb_ shell id -u | tr -d '\r')" == 0 ]] || { printf 'Run adb root on the test emulator first.\n'; exit 1; }
PROVDB="${PROVDB:-/data/data/com.android.providers.telephony/databases/mmssms.db}"
PROVAPP="${PROVAPP:-/data/data/com.android.providers.telephony}"
MARK="act$(date +%s)$$"
STAMP=$(date +%s)
ADDR="+1555444$(echo "$STAMP" | tail -c 5)"
PART="/data/user_de/0/com.android.providers.telephony/app_parts/PART_${MARK}.png"
provider() { adb_ shell "sqlite3 '$PROVDB' \"$1\"" | tr -d '\r'; }
local_query() { adb_ shell "run-as '$PKG' sqlite3 databases/messages.db \"$1\"" | tr -d '\r'; }

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    provider "DELETE FROM part WHERE mid IN (SELECT _id FROM pdu WHERE tr_id='$MARK'); DELETE FROM addr WHERE msg_id IN (SELECT _id FROM pdu WHERE tr_id='$MARK'); DELETE FROM pdu WHERE tr_id='$MARK'; DELETE FROM threads WHERE recipient_ids IN (SELECT CAST(_id AS TEXT) FROM canonical_addresses WHERE address='$ADDR'); DELETE FROM canonical_addresses WHERE address='$ADDR';" >/dev/null || true
    local_query "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$ADDR'); DELETE FROM conversations WHERE address='$ADDR'; DELETE FROM participants WHERE normalized_destination='$ADDR';" >/dev/null || true
    adb_ shell "content delete --uri content://media/external/images/media --where \"_display_name LIKE '$ADDR%'\"" >/dev/null 2>&1 || true
    adb_ shell "rm -f $PART" >/dev/null 2>&1 || true
    rm -f "/tmp/$MARK.png"
}
trap cleanup EXIT

adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1 || true

info "Seed two text MMS and one image MMS into the provider"
python3 - "$MARK" <<'PY'
import struct, sys, zlib
marker = sys.argv[1]
w = h = 4
raw = b''.join(b'\x00' + b'\x10\x60\xf0' * w for _ in range(h))
def chunk(tag, data):
    body = tag + data
    return struct.pack('>I', len(data)) + body + struct.pack('>I', zlib.crc32(body) & 0xffffffff)
png = (b'\x89PNG\r\n\x1a\n'
       + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
       + chunk(b'IDAT', zlib.compress(raw))
       + chunk(b'IEND', b''))
open('/tmp/%s.png' % marker, 'wb').write(png)
PY
adb_ push "/tmp/$MARK.png" /data/local/tmp/$MARK.png >/dev/null
adb_ shell "mkdir -p $PROVAPP/app_parts && cp /data/local/tmp/$MARK.png $PART" >/dev/null

provider "BEGIN;
  INSERT INTO canonical_addresses(address) VALUES('$ADDR');
  INSERT INTO threads(recipient_ids,date) VALUES(CAST(last_insert_rowid() AS TEXT),$STAMP);
  INSERT INTO pdu(thread_id,date,msg_box,m_type,read,sub_id,tr_id) VALUES(last_insert_rowid(),$STAMP,1,132,1,-1,'${MARK}a');
  INSERT INTO pdu(thread_id,date,msg_box,m_type,read,sub_id,tr_id) VALUES((SELECT thread_id FROM pdu WHERE tr_id='${MARK}a'),$STAMP,1,132,1,-1,'${MARK}b');
  INSERT INTO pdu(thread_id,date,msg_box,m_type,read,sub_id,tr_id) VALUES((SELECT thread_id FROM pdu WHERE tr_id='${MARK}a'),$STAMP,1,132,1,-1,'${MARK}c');
  INSERT INTO addr(msg_id,address,type,charset) SELECT _id,'$ADDR',137,106 FROM pdu WHERE tr_id IN ('${MARK}a','${MARK}b','${MARK}c');
  INSERT INTO part(mid,ct,text,chset,seq) SELECT _id,'text/plain','first body $MARK',106,0 FROM pdu WHERE tr_id='${MARK}a';
  INSERT INTO part(mid,ct,text,chset,seq) SELECT _id,'text/plain','second body $MARK',106,0 FROM pdu WHERE tr_id='${MARK}b';
  INSERT INTO part(mid,ct,cid,seq,_data) SELECT _id,'image/png','<img>',0,'$PART' FROM pdu WHERE tr_id='${MARK}c';
  COMMIT;" >/dev/null
SEEDED=$(provider "SELECT COUNT(*) FROM pdu WHERE tr_id LIKE '${MARK}%';")
[ "$SEEDED" = "3" ] && pass 'provider fixture holds 3 MMS' || { fail "fixture incomplete ($SEEDED)"; exit 1; }

info "Cold start into the conversation so the provider sync imports the MMS"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1
adb_ shell am start -n "$ACT" --es open_conversation_address "$ADDR" >/dev/null
sleep 8
IMPORTED=$(local_query "SELECT COUNT(*) FROM messages WHERE body LIKE '%$MARK%' OR media_uri LIKE 'content://mms/part/%' AND conversation_id=(SELECT id FROM conversations WHERE address='$ADDR');")
[ "$IMPORTED" -ge 2 ] && pass "MMS imported into the conversation ($IMPORTED)" || { fail "import failed ($IMPORTED)"; exit 1; }

long_press_text() {
    for _ in 1 2 3 4 5; do
        dump_ui || true
        local b
        b=$(python3 - "$1" <<'PY'
import re, sys
needle = sys.argv[1]
s = open('/tmp/opencode/messages-tests/ui.xml', encoding='utf-8', errors='replace').read()
m = re.search(r'text="[^"]*%s[^"]*"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"' % re.escape(needle), s)
if m:
    x1, y1, x2, y2 = map(int, m.groups())
    print((x1 + x2) // 2, (y1 + y2) // 2)
PY
)
        [ -n "$b" ] && { adb_ shell input swipe $b $b 800; return 0; }
        adb_ shell input swipe 540 1700 540 1200 250 >/dev/null 2>&1
        sleep 1
    done
    return 1
}

open_overflow() {
    local c
    c=$(center_of_contains "More options" 2>/dev/null || true)
    [ -n "$c" ] && adb_ shell input tap $c
    sleep 1
    dump_ui || true
}

info "#232 Select all picks up every message in one tap"
if long_press_text "first body $MARK"; then
    pass 'long-press entered selection mode'
else
    fail 'could not long-press the seeded message'
fi
open_overflow
if ui_tags | grep -q 'text="Select all"'; then
    pass 'overflow offers Select all'
    tap_text "Select all" >/dev/null 2>&1 || true
    sleep 1
    dump_ui || true
    COUNT=$(ui_tags | grep -oE 'text="[0-9]+"' | head -1 | grep -oE '[0-9]+')
    [ "${COUNT:-0}" -ge 2 ] && pass "Select all selected $COUNT messages" || fail "Select all selected ${COUNT:-0} (expected >=2)"
else
    fail 'Select all missing from the overflow'
fi

info "#232 Select all never picks up locked messages"
local_query "UPDATE messages SET locked=1 WHERE body='second body $MARK' AND conversation_id=(SELECT id FROM conversations WHERE address='$ADDR');" >/dev/null 2>&1
LOCKED=$(local_query "SELECT COUNT(*) FROM messages WHERE locked=1 AND body='second body $MARK';")
[ "$LOCKED" = "1" ] && pass 'locked message seeded' || fail "could not lock the message ($LOCKED)"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1
adb_ shell am start -n "$ACT" --es open_conversation_address "$ADDR" >/dev/null
sleep 5
if long_press_text "first body $MARK"; then
    open_overflow
    tap_text "Select all" >/dev/null 2>&1 || true
    sleep 1
    dump_ui || true
    COUNT=$(ui_tags | grep -oE 'text="[0-9]+"' | head -1 | grep -oE '[0-9]+')
    [ "${COUNT:-0}" = "2" ] && pass "Select all skipped the locked message ($COUNT of 3)" \
        || fail "Select all selected ${COUNT:-0} (expected 2: locked message must be skipped)"
else
    fail 'could not long-press after locking a message'
fi
adb_ shell input keyevent 4 >/dev/null 2>&1; sleep 1

info "#231 Select text opens a copy dialog without swallowing the chat options"
# The locked-message block above already left selection mode with a Back press;
# another one here would leave the chat entirely.
if long_press_text "first body $MARK"; then
    open_overflow
    if ui_tags | grep -q 'text="Select text"'; then
        pass 'overflow offers Select text'
        tap_text "Select text" >/dev/null 2>&1 || true
        # The dialog is deferred a beat so the dropdown dismiss cannot hit it.
        FOUND=0
        for _ in 1 2 3 4 5 6; do
            sleep 1
            dump_ui || true
            if ui_tags | grep -q 'text="Select text"' && ui_tags | grep -q 'text="Close"'; then
                FOUND=1; break
            fi
        done
        [ "$FOUND" = 1 ] && pass 'copy dialog opened with the message text' || fail 'copy dialog did not open'
        if ui_tags | grep -q "first body $MARK"; then
            pass 'dialog shows the full message text for range selection'
        else
            fail 'dialog is missing the message text'
        fi
        if ui_tags | grep -q 'class="android.widget.EditText"'; then
            fail 'dialog draws an input box; the message text must stay plain'
        else
            pass 'dialog shows plain selectable text (no input box)'
        fi
        tap_text "Close" >/dev/null 2>&1 || true
        sleep 1
        dump_ui || true
        if ui_tags | grep -q 'text="Select text"'; then
            fail 'dialog stayed open after Close'
        else
            pass 'Close returns to the chat'
        fi
        # The reported bug: the contextual options must still be reachable by
        # holding a message again.
        if long_press_text "first body $MARK"; then
            open_overflow
            if ui_tags | grep -q 'text="Select all"'; then
                pass 'hold-message options are still present after using Select text'
            else
                fail 'hold-message options disappeared after Select text'
            fi
        else
            fail 'could not long-press again after closing the dialog'
        fi
    else
        fail 'Select text missing from the overflow'
    fi
else
    fail 'could not long-press for Select text'
fi
adb_ shell input keyevent 4 >/dev/null 2>&1; sleep 1

info "#235 Save image writes the attachment to the gallery"
adb_ shell input keyevent 4 >/dev/null 2>&1; sleep 1
adb_ shell am start -n "$ACT" --es open_conversation_address "$ADDR" >/dev/null 2>&1
sleep 4
# The image bubble is the only node whose content description is exactly the
# photo accessibility label; match it exactly so conversation-list avatars
# (whose description ends in ". Photo.") cannot be mistaken for a bubble.
for _ in 1 2 3 4 5 6; do
    dump_ui || true
    b=$(python3 <<'PY'
import re
s = open('/tmp/opencode/messages-tests/ui.xml', encoding='utf-8', errors='replace').read()
best = None
for m in re.finditer(r'content-desc="Photo"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', s):
    x1, y1, x2, y2 = map(int, m.groups())
    y = (y1 + y2) // 2
    if best is None or y > best[1]:
        best = ((x1 + x2) // 2, y)
if best:
    print(best[0], best[1])
PY
)
    [ -n "$b" ] && break
    adb_ shell input swipe 540 1700 540 1200 250 >/dev/null 2>&1
    sleep 1
done
if [ -n "${b:-}" ]; then
    adb_ shell input swipe $b $b 800
    sleep 2
    open_overflow
    if ui_tags | grep -q 'text="Save image"'; then
        pass 'overflow offers Save image for the attachment'
        tap_text "Save image" >/dev/null 2>&1 || true
        sleep 3
        SAVED=$(adb_ shell "content query --uri content://media/external/images/media --projection _display_name:relative_path --where \"_display_name LIKE '$ADDR%'\"" 2>/dev/null | tr -d '\r')
        if echo "$SAVED" | grep -q "Pictures/Messages" && echo "$SAVED" | grep -q "$ADDR"; then
            pass "attachment saved under Pictures/Messages ($(echo "$SAVED" | grep -o "${ADDR}_[0-9]*\.[a-z]*" | head -1))"
        else
            fail "no gallery row was created for the saved image"
        fi
    else
        fail 'Save image missing from the overflow for an image message'
    fi
else
    fail 'could not locate the image bubble'
fi

printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
