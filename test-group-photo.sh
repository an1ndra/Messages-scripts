#!/usr/bin/env bash
# A group can carry a picture of its own.
#
# The bytes are copied into the app's files directory, because a photo-picker
# grant dies with the process; the path is stored on the conversation. This
# seeds that state and asserts the app keeps it across a restart and offers the
# picker on the group's page.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

# A fresh pair per run: the chat intent opens by address, and a leftover row
# with the same primary would win the lookup and be a 1:1.
PRIMARY="+1555$(printf '%07d' $((RANDOM % 10000000)))"
SECOND="+1556$(printf '%07d' $((RANDOM % 10000000)))"
MARKER="GroupPhoto$(date +%s)"
AVATAR="files/group-avatars/group-photo-test-$MARKER.png"
CID=""

sql() { echo "$1" | adb_ shell "run-as $PKG sqlite3 databases/messages.db"; }
q()   { sql "$1" | tr -d '\r'; }

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    [ -n "$CID" ] || return 0
    adb_ shell "run-as $PKG rm -f $AVATAR" >/dev/null 2>&1 || true
    sql "DELETE FROM messages WHERE conversation_id=$CID;" >/dev/null 2>&1
    sql "DELETE FROM conversation_recipients WHERE conversation_id=$CID;" >/dev/null 2>&1
    sql "DELETE FROM conversations WHERE id=$CID;" >/dev/null 2>&1
}
trap cleanup EXIT

adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1
bash ./grant-permissions.sh >/dev/null 2>&1 || true

info "Seeding a group with a picture"
# Any decodable image will do; the app reads it through Coil like a photo.
adb_ shell "run-as $PKG mkdir -p files/group-avatars" >/dev/null
python3 - "$TMP/group-photo.png" <<'PY'
import struct, zlib, sys
w = h = 8
raw = b''.join(b'\x00' + bytes([40, 90, 200]) * w for _ in range(h))
def chunk(tag, data):
    body = tag + data
    return struct.pack('>I', len(data)) + body + struct.pack('>I', zlib.crc32(body) & 0xffffffff)
png = (b'\x89PNG\r\n\x1a\n'
       + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
       + chunk(b'IDAT', zlib.compress(raw))
       + chunk(b'IEND', b''))
open(sys.argv[1], 'wb').write(png)
PY
# Piped rather than copied through /sdcard: scoped storage hides that path from
# the app's own uid, and the redirect would leave a zero-byte file.
adb_ shell "run-as $PKG sh -c 'cat > $AVATAR'" < "$TMP/group-photo.png"

TITLE="Photo Group $MARKER"
CID=$(q "INSERT INTO conversations(address,name,snippet,timestamp,group_title) VALUES('$PRIMARY','$TITLE','',$(date +%s)000,'$TITLE'); SELECT last_insert_rowid();")
for addr in "$PRIMARY" "$SECOND"; do
    sql "INSERT OR IGNORE INTO conversation_recipients(conversation_id,address) VALUES($CID,'$addr');" >/dev/null
done
STORED="/data/user/0/$PKG/$AVATAR"
sql "UPDATE conversations SET group_avatar='$STORED' WHERE id=$CID;" >/dev/null

[[ "$(q "SELECT group_avatar FROM conversations WHERE id=$CID;")" == "$STORED" ]] \
    && ok "the conversation stores the picture path" \
    || bad "the picture path was not stored"
[[ "$(adb_ shell "run-as $PKG ls $AVATAR" | tr -d '\r')" == "$AVATAR" ]] \
    && ok "the copy exists in app files" \
    || bad "the copy is missing"

info "Restarting: the picture must survive"
adb_ shell am force-stop "$PKG" >/dev/null
adb_ shell am start -n "$ACT" >/dev/null
sleep 8
[[ "$(q "SELECT group_avatar FROM conversations WHERE id=$CID;")" == "$STORED" ]] \
    && ok "the path survives a restart" \
    || bad "the path was lost on restart"

info "The group page offers the picker"
adb_ shell am start -n "$ACT" --es open_conversation_address "$PRIMARY" >/dev/null
sleep 5
# The chat header opens the group's page. Tap the title text rather than a
# coordinate: the header row is only as wide as the name, and in RTL it sits on
# the other side of the bar.
tap_contains "$TITLE" >/dev/null 2>&1 || true
sleep 3
dump_ui >/dev/null 2>&1 || true
LABEL=$(res_string contact_group_photo)
if grep -Fq "content-desc=\"$LABEL\"" "$TMP/ui.xml" 2>/dev/null; then
    ok "the group page offers '$LABEL'"
else
    bad "no '$LABEL' control on the group page"
fi

echo ""
info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
