#!/usr/bin/env bash
# Regression for #460: pinch-to-zoom and Save in the full-screen picture viewer.
#
# The viewer used to be a fixed fit-to-screen image with one Close control, so a
# screenshot or a photographed document stayed as small as the 260dp bubble
# allowed and the picture could only be saved by backing out and using the
# selection toolbar.
#
# The fixture is one picture message whose bytes are the device's own
# screenshot, written into the app's files directory and linked from a seeded
# row: no provider, no MMS hand-off, so the script runs on any debuggable
# install. Double tap is driven with two `input tap`s and read back from the
# `ImageViewer: scale=` line the viewer logs, because a transform cannot be
# asserted from a layout dump. Save is asserted by the file MediaStore wrote,
# which is the only proof the control is wired to the real save path.
source "$(dirname "$0")/env.sh"

PASS=0
FAIL=0
ok()   { printf '  [PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
info() { printf '\n=== %s ===\n' "$*"; }

# run-as reaches the app's own database and files on any debuggable install, so
# this script needs no root — unlike the MMS provider fixtures.
app_sql() { adb_ shell "run-as '$PKG' sqlite3 databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r'; }

command -v sqlite3 >/dev/null 2>&1 || true
ADDRESS="+1555$(date +%s | tail -c 8)"
STAMP=$(date +%s)
PHOTO="/data/data/$PKG/files/viewer-probe.png"
SAVED_STAMP="${STAMP}000"

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    app_sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$ADDRESS'); DELETE FROM conversations WHERE address='$ADDRESS';" >/dev/null 2>&1 || true
    adb_ shell "ls /sdcard/Pictures/Messages/*'$SAVED_STAMP'* 2>/dev/null | while read -r f; do rm -f \"\$f\"; done" >/dev/null 2>&1 || true
    adb_ shell "run-as '$PKG' rm -f files/viewer-probe.png" >/dev/null 2>&1 || true
}
trap cleanup EXIT

info "Preflight"
if adb_ shell pm path "$PKG" >/dev/null 2>&1 && adb_ shell pm path "$PKG" | grep -q package; then
    ok "the app is installed"
else
    bad "the app is not installed"
    exit 1
fi
if adb_ shell "run-as '$PKG' ls databases/messages.db" >/dev/null 2>&1; then
    ok "the app's database is reachable without root"
else
    bad "run-as cannot reach the database (is this a debuggable build?)"
    exit 1
fi
adb_ shell am force-stop "$PKG" >/dev/null 2>&1
adb_ shell am start -n "$ACT" >/dev/null 2>&1
sleep 4
adb_ shell am force-stop "$PKG" >/dev/null 2>&1

info "Fixture: one picture message and a conversation to hold it"
adb_ exec-out screencap -p > "$TMP/viewer.png" 2>/dev/null
if [ -s "$TMP/viewer.png" ]; then
    ok "a PNG fixture was captured"
else
    bad "could not capture a PNG fixture"
    exit 1
fi
adb_ shell "run-as '$PKG' sh -c 'cat > files/viewer-probe.png'" < "$TMP/viewer.png" 2>/dev/null
if [ "$(adb_ shell "run-as '$PKG' stat -c %s files/viewer-probe.png" | tr -d '\r')" -gt 0 ] 2>/dev/null; then
    ok "the fixture is readable inside the app's files directory"
else
    bad "the fixture could not be written into the app"
    exit 1
fi
app_sql "INSERT INTO conversations(address,name,snippet,timestamp,unread_count) VALUES('$ADDRESS','Viewer probe','',${STAMP}000,0);" >/dev/null
CID=$(app_sql "SELECT id FROM conversations WHERE address='$ADDRESS';")
app_sql "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,media_type,media_uri) VALUES($CID,'',${STAMP}000,0,'received','image','file://$PHOTO');" >/dev/null
if [ "$(app_sql "SELECT COUNT(*) FROM messages WHERE conversation_id=$CID AND media_type='image';")" = "1" ]; then
    ok "the picture message is stored"
else
    bad "the picture message was not stored"
    exit 1
fi

photo_desc=$(res_string access_photo)
save_label=$(res_string chat_save_image)
close_label=$(res_string chat_close)

# `android layout` rather than uiautomator: the dump service registers itself
# globally and on a physical handset a killed dump leaves it registered until a
# reboot, which made every later dump fail with "already registered".
open_chat() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    adb_ shell am start -n "$ACT" --es open_conversation_address "$ADDRESS" >/dev/null 2>&1
    local i
    for i in $(seq 1 15); do
        sleep 1
        wait_layout_has "$photo_desc" 1 && return 0
        if layout_has "Allow"; then
            layout_center "Allow" >/dev/null 2>&1 && tap_layout "Allow" >/dev/null 2>&1
        fi
    done
    return 1
}

tap_photo() { tap_layout "$photo_desc"; }

info "Tapping the picture opens the viewer with Save and Close"
open_chat || { bad "the conversation did not open with the picture"; exit 1; }
tap_photo
sleep 2
if layout_has "$save_label"; then
    ok "the viewer offers Save"
else
    bad "the viewer has no Save control"
fi
if layout_has "$close_label"; then
    ok "the viewer still offers Close"
else
    bad "the viewer lost its Close control"
fi
if layout_has "$photo_desc"; then
    ok "the picture itself is still on screen"
else
    bad "the picture was not rendered"
fi

info "A double tap zooms, and a tap still dismisses"
adb_ shell logcat -c >/dev/null 2>&1
read -r W H < <(adb_ shell wm size | tr -d '\r' | sed -E 's/.*: ([0-9]+)x([0-9]+)/\1 \2/')
CX=$((W / 2)); CY=$((H / 2))
adb_ shell "input tap $CX $CY; sleep 0.09; input tap $CX $CY" >/dev/null 2>&1
sleep 2
adb_ shell logcat -d > "$TMP/logcat.txt" 2>/dev/null || true
if grep -q 'ImageViewer: scale=2.50' "$TMP/logcat.txt"; then
    ok "a double tap jumped the picture to 2.5x"
else
    bad "a double tap did not zoom (no scale=2.50)"
fi
# The double tap must be a zoom, not a dismissal: the viewer is still up and
# the transformed picture can be dragged back by a second double tap.
adb_ shell "input tap $CX $CY; sleep 0.09; input tap $CX $CY" >/dev/null 2>&1
sleep 2
adb_ shell logcat -d > "$TMP/logcat.txt" 2>/dev/null || true
if grep -q 'ImageViewer: scale=1.00' "$TMP/logcat.txt"; then
    ok "a second double tap returned it to fit"
else
    bad "the picture did not return to fit"
fi
if layout_has "$save_label"; then
    ok "the double tap did not dismiss the viewer"
else
    bad "the viewer closed on a double tap, so zoom never lands"
fi
adb_ shell input tap $CX $CY >/dev/null 2>&1
sleep 2
if layout_has "$save_label"; then
    bad "a single tap no longer dismisses the viewer"
else
    ok "a single tap still dismisses the viewer"
fi

info "Save writes the picture to Pictures/Messages"
open_chat || { bad "the chat did not reopen"; exit 1; }
tap_photo
sleep 2
adb_ shell ls /sdcard/Pictures/Messages 2>/dev/null | tr -d '\r' > "$TMP/before.txt"
tap_layout "$save_label" >/dev/null 2>&1 || true
sleep 3
adb_ shell ls /sdcard/Pictures/Messages 2>/dev/null | tr -d '\r' > "$TMP/after.txt"
# The name carries the conversation label when one resolves and the address
# otherwise, so the picture's own timestamp is what identifies the file.
if grep -qF "$SAVED_STAMP" "$TMP/after.txt"; then
    ok "Save wrote $(grep -F "$SAVED_STAMP" "$TMP/after.txt" | head -1)"
else
    bad "Save wrote no file for timestamp $SAVED_STAMP; got: $(tr '\n' ' ' < "$TMP/after.txt")"
fi
if diff -q "$TMP/before.txt" "$TMP/after.txt" >/dev/null 2>&1; then
    bad "the Save control did nothing"
else
    ok "the Save control is wired to the save path"
fi

printf '\n[%s] %d passed, %d failed\n' "$([ "$FAIL" -eq 0 ] && echo PASS || echo FAIL)" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
