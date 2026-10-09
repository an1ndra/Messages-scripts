#!/usr/bin/env bash
# Regression for issue #304: app must appear in SMS/text/image share sheets from
# other apps, accept a shared body into the composer, and send a shared image
# once a recipient is picked.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

MARKER1="ShareBodyTest$$"
MARKER2="PlainTextShare$$"

# A real, decodable 400x400 PNG generated on the fly. It has to be a genuine
# image at a realistic size: a hand-rolled few-byte "JPEG" cannot be decoded by
# Coil at all, and a tiny one renders sub-threshold — either would make the
# bubble assertion pass or fail for a reason unrelated to the share path.
SHARED_IMG="$TMP/share-source.png"
python3 - "$SHARED_IMG" <<'PY'
import struct, sys, zlib

w = h = 400
raw = b"".join(
    b"\x00" + bytes(v for x in range(w) for v in ((x * 255) // w, 90, 200 - (x * 90) // w))
    for _ in range(h)
)

def chunk(tag, data):
    body = tag + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

png = (
    b"\x89PNG\r\n\x1a\n"
    + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    + chunk(b"IDAT", zlib.compress(raw, 6))
    + chunk(b"IEND", b"")
)
open(sys.argv[1], "wb").write(png)
PY

query_has_main() {
    adb_ shell cmd package query-activities "$@" 2>/dev/null | grep -qF "name=$PKG.MainActivity"
}

dbq() { printf '%s' "$1" | adb_ shell "run-as $PKG sqlite3 databases/messages.db" 2>/dev/null | tr -d '\r'; }

# Taps the "Send to …" row on the New Chat screen. Its label carries curly
# quotes around the typed number, so match the stable prefix and tap the
# enclosing clickable node's centre — the text node's own bounds sit above the
# touch target.
tap_share_row() {
    local c
    dump_ui || return 1
    c=$(python3 - "$TMP/ui.xml" <<'PY'
import re, sys
xml = open(sys.argv[1], encoding="utf-8", errors="replace").read()
for m in re.finditer(r'<node[^>]*>', xml):
    node = m.group(0)
    if 'Send to' not in node:
        continue
    b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', node)
    if not b:
        continue
    x1, y1, x2, y2 = (int(g) for g in b.groups())
    print((x1 + x2) // 2, (y1 + y2) // 2)
    break
PY
    ) || return 1
    [ -n "$c" ] || return 1
    adb_ shell input tap $c
    echo "[tap] 'Send to' at ($c)"
}

# Centre "x y" of the node carrying the photo content description — the image
# bubble in the chat, or the full-screen preview once it is open.
photo_node_bounds() {
    dump_ui || return 1
    python3 - "$TMP/ui.xml" <<'PY'
import re, sys
xml = open(sys.argv[1], encoding="utf-8", errors="replace").read()
for n in re.findall(r'<node[^>]*>', xml):
    if 'content-desc="Photo"' not in n:
        continue
    b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', n)
    if not b:
        continue
    x1, y1, x2, y2 = (int(g) for g in b.groups())
    print((x1 + x2) // 2, (y1 + y2) // 2)
    break
PY
}

# True when the photo is shown full-screen rather than as a chat bubble: the
# preview letterboxes the image across the window, the bubble caps it at
# 260dp (~683px at 420dpi) and sits inside the message list. Anything wider
# than the bubble's own maximum can only be the preview.
photo_is_fullscreen() {
    python3 - "$TMP/ui.xml" <<'PY'
import re, sys
xml = open(sys.argv[1], encoding="utf-8", errors="replace").read()
for n in re.findall(r'<node[^>]*>', xml):
    if 'content-desc="Photo"' not in n:
        continue
    b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', n)
    if b:
        x1, _, x2, _ = (int(g) for g in b.groups())
        sys.exit(0 if (x2 - x1) > 800 else 1)
sys.exit(1)
PY
}

unlock_device() {
    adb_ shell input keyevent 26 >/dev/null 2>&1 || true
    sleep 0.5
    adb_ shell input keyevent 26 >/dev/null 2>&1 || true
    sleep 1
    adb_ shell input swipe 540 1800 540 700 400 >/dev/null 2>&1 || true
    adb_ shell locksettings set-disabled true >/dev/null 2>&1 || true
    sleep 0.5
}

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
}
trap cleanup EXIT

# This AVD drops off the bus under sustained UI driving. Checking before every
# interaction matters: without it the run keeps going against a dead device and
# reports each step as a product failure.
require_device() {
    adb_ shell true >/dev/null 2>&1 && return 0
    echo "ABORT: $ANDROID_SERIAL stopped responding; results would be meaningless."
    exit 2
}

unlock_device
cleanup

# A fresh install (or any install that is not the SMS role holder) puts a
# "Set as default SMS app?" dialog over the first screen, which swallows the
# share flow and makes every assertion below fail for the wrong reason.
# Dismissing it is part of setup, not a thing the test is asserting.
dismiss_default_sms_prompt() {
    for i in 1 2 3; do
        dump_ui >/dev/null 2>&1 || { sleep 1; continue; }
        grep -q "Set as default SMS app" "$TMP/ui.decoded.xml" || return 0
        tap_text "Not now" >/dev/null 2>&1 || adb_ shell input keyevent KEYCODE_BACK
        sleep 1.5
    done
}

info "Manifest declares the filters the platform resolves for share intents"
if query_has_main -a android.intent.action.SENDTO -d "smsto:+15551230000"; then
    ok "SENDTO smsto resolves to MainActivity"
else
    bad "SENDTO smsto does not resolve to MainActivity"
fi

if query_has_main -a android.intent.action.SENDTO -d "sms:+15551230000"; then
    ok "SENDTO sms resolves to MainActivity"
else
    bad "SENDTO sms does not resolve to MainActivity"
fi

if query_has_main -a android.intent.action.SEND -t "text/plain"; then
    ok "ACTION_SEND text/plain resolves to MainActivity"
else
    bad "ACTION_SEND text/plain does not resolve to MainActivity"
fi

# A shared image becomes an outgoing MMS, so the app has to answer for
# image/* or it is missing from a photo's share sheet entirely.
if query_has_main -a android.intent.action.SEND -t "image/jpeg"; then
    ok "ACTION_SEND image/jpeg resolves to MainActivity"
else
    bad "ACTION_SEND image/jpeg does not resolve to MainActivity"
fi

if query_has_main -a android.intent.action.SEND_MULTIPLE -t "image/jpeg"; then
    ok "ACTION_SEND_MULTIPLE image/jpeg resolves to MainActivity"
else
    bad "ACTION_SEND_MULTIPLE image/jpeg does not resolve to MainActivity"
fi

info "SENDTO with recipient + body opens the target chat with body pre-filled"
require_device
adb_ shell am start -a android.intent.action.SENDTO \
    -d "smsto:+15551230000?body=$MARKER1" \
    "$PKG" >/dev/null 2>&1
sleep 3
dismiss_default_sms_prompt
dump_ui >/dev/null 2>&1 || true
if grep -qF "$MARKER1" "$TMP/ui.decoded.xml" 2>/dev/null; then
    ok "shared body from SENDTO uri appears in the chat composer"
else
    bad "shared body from SENDTO uri not found in UI"
fi
cleanup; sleep 1

info "ACTION_SEND text/plain without recipient opens the new-chat picker"
require_device
adb_ shell am start -a android.intent.action.SEND -t "text/plain" \
    --es android.intent.extra.TEXT "$MARKER2" \
    "$PKG" >/dev/null 2>&1
sleep 3
dismiss_default_sms_prompt
dump_ui >/dev/null 2>&1 || true
if grep -qF "Enter name or phone number" "$TMP/ui.decoded.xml" 2>/dev/null || \
   grep -qF "New conversation" "$TMP/ui.decoded.xml" 2>/dev/null; then
    ok "ACTION_SEND opens the contact picker"
else
    bad "ACTION_SEND did not open the contact picker"
fi
cleanup; sleep 1

info "ACTION_SEND image/* with no recipient asks who to send it to"
require_device
adb_ push "$SHARED_IMG" /sdcard/share-intent-test.png >/dev/null 2>&1
SHARED_URI="file:///sdcard/share-intent-test.png"
adb_ shell am start -a android.intent.action.SEND -t "image/png" \
    --eu android.intent.extra.STREAM "$SHARED_URI" \
    "$PKG" >/dev/null 2>&1
sleep 3
dismiss_default_sms_prompt
dump_ui >/dev/null 2>&1 || true
if grep -qF "Enter name or phone number" "$TMP/ui.decoded.xml" 2>/dev/null || \
   grep -qF "New conversation" "$TMP/ui.decoded.xml" 2>/dev/null; then
    ok "shared image with no recipient opens the contact picker"
else
    bad "shared image did not open the contact picker"
fi
cleanup; sleep 1

info "Picking a recipient sends the shared image into that chat"
require_device
IMAGE_ADDR="+15551238877"
adb_ shell am start -a android.intent.action.SEND -t "image/png" \
    --eu android.intent.extra.STREAM "$SHARED_URI" \
    "$PKG" >/dev/null 2>&1
sleep 3
dismiss_default_sms_prompt
tap_edittext >/dev/null 2>&1 || true
type_text "$IMAGE_ADDR" >/dev/null 2>&1 || true
sleep 1.5
# The row label is 'Send to “<number>”' with curly quotes, so match on its
# stable prefix and tap the clickable ancestor rather than the text node.
if ! tap_share_row; then
    bad "could not reach the 'Send to' row for the shared image"
else
    sleep 4
    # The MMS hand-off cannot succeed on this AVD (the carrier config has no
    # MMS keys), so the stored row is the signal, not the delivery status.
    ROW=$(dbq "select count(*) from messages m join conversations c
        on c.id=m.conversation_id
        where c.address='$IMAGE_ADDR' and m.media_type='image';")
    [ "${ROW:-0}" -gt 0 ] \
        && ok "shared image stored in the picked chat" \
        || bad "shared image never reached the picked chat"
    CACHED=$(dbq "select count(*) from messages where media_type='image'
        and media_uri like '%/shared/%';")
    [ "${CACHED:-0}" -gt 0 ] \
        && ok "shared image was copied into app storage before use" \
        || bad "shared image was read straight from the caller's URI"

    # The stored URI is handed to Coil, which asks the resolver for a MIME type
    # and FileProvider derives that from the file name. An extensionless copy
    # resolves no type, which downstream consumers (the MMS part's MIME, any
    # strict decoder) then have to guess at.
    EXT=$(dbq "select media_uri from messages where media_type='image'
        and media_uri like '%/shared/%' order by id desc limit 1;")
    case "$EXT" in
        *.png|*.jpg|*.jpeg|*.webp|*.heic|*.gif)
            ok "cached copy keeps an image extension ($EXT)" ;;
        *)
            bad "cached copy has no image extension, Coil cannot decode it: $EXT" ;;
    esac

    # The end of the chain: the bubble is actually on screen. Coil loads
    # asynchronously, so poll rather than reading a single dump.
    SHOWN=0
    for i in 1 2 3 4 5 6; do
        dump_ui >/dev/null 2>&1 || { sleep 1; continue; }
        grep -q 'content-desc="Photo"' "$TMP/ui.decoded.xml" && { SHOWN=1; break; }
        sleep 1
    done
    [ "$SHOWN" = "1" ] && ok "shared image renders as a bubble in the chat" \
        || bad "shared image stored but no image bubble rendered"

    # Tapping the bubble must open the full-screen preview. The thumbnail is
    # cropped to a fixed size, so this is the only place the whole frame shows.
    BUBBLE=$(photo_node_bounds)
    if [ -z "$BUBBLE" ]; then
        bad "could not locate the image bubble to tap"
    else
        adb_ shell input tap $BUBBLE; sleep 2.5
        dump_ui >/dev/null 2>&1 || true
        if photo_is_fullscreen; then
            ok "tapping the image opens the full-screen preview"
        else
            bad "tapping the image did not open a preview"
        fi

        adb_ shell input keyevent KEYCODE_BACK; sleep 2
        dump_ui >/dev/null 2>&1 || true
        if photo_is_fullscreen; then
            bad "back did not close the preview"
        else
            ok "back closes the preview and returns to the chat"
        fi
    fi
fi
adb_ shell "run-as $PKG sqlite3 databases/messages.db \"delete from messages
    where conversation_id in (select id from conversations
    where address='$IMAGE_ADDR'); delete from conversations
    where address='$IMAGE_ADDR';\"" >/dev/null 2>&1
adb_ shell rm -f /sdcard/share-intent-test.jpg >/dev/null 2>&1

echo ""
info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
