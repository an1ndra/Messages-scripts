#!/usr/bin/env bash
# Regression: opening a chat must land on the newest message, even when the
# last rows grow only after the picture in them has been decoded.
#
# `ImageBubble` has no size until its bitmap is decoded, so
# `scrollToItem(Int.MAX_VALUE)` reaches what was the last row at the time it
# ran, and the chat then settles a few rows short of the bottom. The chat now
# follows its own growth for a short window and stops the moment the user drags
# the list, so it never fights their scrolling.
#
# The user-drag case is the half that matters for trust: an effect that keeps
# pinning the view to the bottom makes an old chat unreadable, so the drag has
# to win immediately and permanently.
source "$(dirname "$0")/env.sh"

NUM="+1555880$(date +%s | tail -c 4)"
MARK="chatbottom$(date +%s)"
TEXT_ROWS=58
TS=$(( $(date +%s) * 1000 ))

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

sql() { printf '%s' "$1" | adb_ shell "run-as $PKG sqlite3 databases/messages.db" 2>/dev/null | tr -d '\r'; }

# A photo-sized 3000x2400 PNG. It has to be big enough that Coil's decode takes
# real time, because the defect is a race: a small image lands before the first
# frame is measured and the script passes on unfixed code.
SEED_IMG="$TMP/chat-bottom-seed.png"
python3 - "$SEED_IMG" <<'PY'
import struct, sys, zlib

w, h = 3000, 2400
raw = b"".join(
    b"\x00" + bytes(v for x in range(w) for v in ((x * 255) // w, 40, 200 - (x * 70) // w))
    for _ in range(h)
)

def chunk(tag, data):
    body = tag + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

open(sys.argv[1], "wb").write(
    b"\x89PNG\r\n\x1a\n"
    + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    + chunk(b"IDAT", zlib.compress(raw, 6))
    + chunk(b"IEND", b"")
)
PY

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM');" >/dev/null
    sql "DELETE FROM conversations WHERE address='$NUM';" >/dev/null
    sql "DELETE FROM participants WHERE normalized_destination='$NUM';" >/dev/null
}
trap cleanup EXIT

info "0. seed a chat whose last rows are images that decode late"
adb_ shell pm clear "$PKG" >/dev/null 2>&1
adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1 || true
# The database does not exist until the app has run once, so open it before
# writing rather than after.
adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 4
adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1

# A real, decodable PNG. `ImageBubble` only caps the size (widthIn/heightIn),
# it never sets one, so a row carrying an image has no height until Coil
# decodes it. A text-only seed cannot reproduce the defect at all: text rows are
# measured before the first frame, so the chat already opens at the bottom and
# the script passes on unfixed code.
adb_ push "$SEED_IMG" /data/local/tmp/chat-bottom-seed.png >/dev/null 2>&1
adb_ shell "run-as $PKG cp /data/local/tmp/chat-bottom-seed.png cache/chat-bottom-seed.png" >/dev/null 2>&1
IMG_URI="file:///data/user/0/$PKG/cache/chat-bottom-seed.png"
if [ -z "$(adb_ shell "run-as $PKG ls cache/chat-bottom-seed.png" 2>/dev/null | tr -d '\r')" ]; then
    bad "could not stage the seed image into the app cache"
    printf '\n[RESULT] %d passed, %d failed\n' "$PASS" "$FAIL"
    exit 1
fi
ok "staged a real PNG in the app cache"

sql "INSERT INTO conversations(address,name,snippet,timestamp,last_is_me) VALUES('$NUM','$MARK','tail',$TS,0);" >/dev/null
CONV=$(sql "SELECT id FROM conversations WHERE address='$NUM';")
if [ -z "$CONV" ]; then
    bad "could not seed the conversation"
    printf '\n[RESULT] %d passed, %d failed\n' "$PASS" "$FAIL"
    exit 1
fi
ok "seeded conversation $CONV at $NUM"

for i in $(seq 1 $((TEXT_ROWS - 1))); do
    sql "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,media_type) SELECT id,'filler $i',$((TS + i * 60000)),1,'sent','text' FROM conversations WHERE address='$NUM';" >/dev/null
done
# Two image rows, then the newest text row. The images sit between the filler
# and the marker precisely because they are the rows that grow late: when they
# decode, everything after them is pushed, and an unfixed chat leaves the
# newest message below the fold.
sql "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,media_type,media_uri) SELECT id,'',$((TS + TEXT_ROWS * 60000)),1,'sent','image','$IMG_URI' FROM conversations WHERE address='$NUM';" >/dev/null
sql "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,media_type,media_uri) SELECT id,'',$((TS + (TEXT_ROWS + 1) * 60000)),1,'sent','image','$IMG_URI' FROM conversations WHERE address='$NUM';" >/dev/null
sql "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,media_type) SELECT id,'newest text',$((TS + (TEXT_ROWS + 2) * 60000)),1,'sent','text' FROM conversations WHERE address='$NUM';" >/dev/null

COUNT=$(sql "SELECT COUNT(*) FROM messages WHERE conversation_id=$CONV;")
[ "${COUNT:-0}" -eq "$((TEXT_ROWS + 2))" ] \
    && ok "seeded $COUNT messages ($((TEXT_ROWS + 2)) expected)" \
    || bad "expected $((TEXT_ROWS + 2)) messages, found ${COUNT:-0}"

info "1. open the chat and confirm the newest message is on screen"
adb_ shell am start -n "$ACT" --es open_conversation_address "$NUM" >/dev/null 2>&1
sleep 5

# Coil loads asynchronously and the follow window is 4s, so poll rather than
# reading a single dump.
BOTTOM=0
for _ in $(seq 1 8); do
    dump_ui >/dev/null 2>&1 || { sleep 1; continue; }
    if grep -q "newest text" "$TMP/ui.xml"; then
        BOTTOM=1; break
    fi
    sleep 1
done
[ "$BOTTOM" = "1" ] \
    && ok "chat opened on the newest message" \
    || bad "chat did not settle on the newest message (opened a few rows short)"

info "2. the user can still scroll away from the bottom"
# Drag down from the middle of the list: a chat old enough to page in history
# is what a stuck follow-effect would trap.
adb_ shell input swipe 540 900 540 2000 400 >/dev/null 2>&1
sleep 1
adb_ shell input swipe 540 900 540 2000 400 >/dev/null 2>&1
sleep 2

STAYED=0
for _ in $(seq 1 6); do
    dump_ui >/dev/null 2>&1 || { sleep 1; continue; }
    if ! grep -q "newest text" "$TMP/ui.xml"; then
        STAYED=1; break
    fi
    sleep 1
done
[ "$STAYED" = "1" ] \
    && ok "scrolling away from the bottom is not fought by the follow effect" \
    || bad "chat snapped back to the newest message after the user scrolled"

info "3. no crash"
if adb_ shell logcat -d 2>/dev/null | grep -q "FATAL EXCEPTION"; then
    bad "FATAL EXCEPTION in logcat"
else
    ok "no FATAL EXCEPTION"
fi

printf '\n[RESULT] %d passed, %d failed\n' "$PASS" "$FAIL"
exit $((FAIL > 0))