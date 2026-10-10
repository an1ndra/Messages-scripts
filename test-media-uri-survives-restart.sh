#!/usr/bin/env bash
# Regression: a sent picture must still render after the app is restarted.
#
# `Repository.sendMedia` stores the URI the photo picker returned. That grant
# only lasts as long as the app's process, so on reopening the chat the bubble
# has nothing to read and shows an empty black box. Linking the sent message to
# its provider outbox row removed the imported duplicate that used to survive a
# restart, which is what made this visible.
#
# `Repository.adoptProviderImage` repoints `media_uri` at the provider's own
# copy of the picture (`content://mms/part/<id>`), which stays readable for as
# long as the message exists -- the same source an imported or received MMS
# picture is read from.
#
# The send itself cannot succeed on this AVD (the carrier config has no MMS
# keys, so every send is answered with code 12), so the stored row is the
# signal, exactly as in test-share-intent-filters.sh.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

ADDR="+1555$(date +%s | tail -c 6)"
MARK="MediaUri$$"

dbq() { printf '%s' "$1" | adb_ shell "run-as $PKG sqlite3 databases/messages.db" 2>/dev/null | tr -d '\r'; }

# A real 400x400 PNG. A hand-rolled few-byte file cannot be decoded by Coil, so
# the bubble would be empty for a reason that has nothing to do with the URI.
SHARED_IMG="$TMP/media-uri-source.png"
python3 - "$SHARED_IMG" <<'PY'
import struct, sys, zlib

w = h = 400
raw = b"".join(
    b"\x00" + bytes(v for x in range(w) for v in ((x * 255) // w, 60, 210 - (x * 90) // w))
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
    adb_ shell "run-as $PKG sqlite3 databases/messages.db \"DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$ADDR'); DELETE FROM conversations WHERE address='$ADDR'; DELETE FROM participants WHERE normalized_destination='$ADDR';\"" >/dev/null 2>&1 || true
}
trap cleanup EXIT

adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1 || true

info "0. share a photo into a new conversation"
# A file:// URI is enough to exercise the whole path: the app copies whatever
# it is handed into its own storage before sending, and that copy is exactly
# the URI this test is checking gets replaced.
SHARED_URI="file:///sdcard/media-uri-source.png"
adb_ push "$SHARED_IMG" "$SHARED_URI" >/dev/null 2>&1

adb_ shell am start -a android.intent.action.SEND -t "image/png" \
    --eu android.intent.extra.STREAM "$SHARED_URI" \
    "$PKG" >/dev/null 2>&1
sleep 3
# The default-SMS prompt can sit over the picker; dismiss it if it is there.
dump_ui >/dev/null 2>&1 || true
if grep -qF "Set as default" "$TMP/ui.xml" 2>/dev/null; then
    adb_ shell input keyevent KEYCODE_BACK >/dev/null 2>&1
    sleep 1
fi
tap_edittext >/dev/null 2>&1 || true
type_text "$ADDR" >/dev/null 2>&1 || true
sleep 2

c=$(python3 - "$TMP/ui.xml" <<'PY'
import re, sys, os
p = sys.argv[1]
if not os.path.exists(p):
    raise SystemExit(0)
xml = open(p, encoding="utf-8", errors="replace").read()
for node in re.finditer(r'<node[^>]*>', xml):
    s = node.group(0)
    if "Send to" not in s:
        continue
    b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', s)
    if b:
        x1, y1, x2, y2 = (int(g) for g in b.groups())
        print((x1 + x2) // 2, (y1 + y2) // 2)
        break
PY
)
if [ -n "$c" ]; then
    adb_ shell input tap $c
    ok "tapped the 'Send to' row for $ADDR"
else
    bad "could not reach the 'Send to' row for $ADDR"
fi
sleep 6

info "1. the sent row is stored"
ROW=$(dbq "select count(*) from messages m join conversations c on c.id=m.conversation_id
    where c.address='$ADDR' and m.media_type='image';")
if [ "${ROW:-0}" -gt 0 ]; then
    ok "sent picture stored in the picked chat"
else
    bad "no image row stored for $ADDR"
fi

info "2. media_uri points at the provider copy, not the picker's URI"
URI=$(dbq "select media_uri from messages m join conversations c on c.id=m.conversation_id
    where c.address='$ADDR' and m.media_type='image' order by m.id desc limit 1;")
case "$URI" in
    content://mms/part/*)
        ok "media_uri repointed at the provider part ($URI)" ;;
    content://mms/*)
        bad "media_uri is a bare provider row URI, not a part: $URI" ;;
    */shared/*)
        bad "media_uri is still the app's cached copy, not the provider's: $URI" ;;
    file://*|content://media/*)
        bad "media_uri is still the picker's grant, dead after restart: $URI" ;;
    "")
        bad "media_uri is empty" ;;
    *)
        bad "media_uri is not a provider part URI: $URI" ;;
esac

info "3. it still renders after a full restart"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1
sleep 2
adb_ shell am start -n "$ACT" --es open_conversation_address "$ADDR" >/dev/null 2>&1
sleep 4
for _ in 1 2 3 4 5; do
    dump_ui >/dev/null 2>&1 || { sleep 1; continue; }
    grep -q "$ADDR" "$TMP/ui.xml" && break
    sleep 1
done
SHOWN=0
for _ in 1 2 3 4 5 6; do
    dump_ui >/dev/null 2>&1 || { sleep 1; continue; }
    # An image bubble carries a content description; the broken one is a bare
    # empty box with no image node behind it.
    if grep -qE 'content-desc="[^"]*(Photo|Image|photo|image)' "$TMP/ui.xml"; then
        SHOWN=1; break
    fi
    sleep 1
done
[ "$SHOWN" = "1" ] \
    && ok "picture bubble still present after restart" \
    || bad "picture did not render after restart (empty black box)"

info "4. no crash"
if adb_ shell logcat -d 2>/dev/null | grep -q "FATAL EXCEPTION"; then
    bad "FATAL EXCEPTION in logcat"
else
    ok "no FATAL EXCEPTION"
fi

printf '\n[RESULT] %d passed, %d failed\n' "$PASS" "$FAIL"
exit $((FAIL > 0))