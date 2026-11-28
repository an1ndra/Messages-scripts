#!/usr/bin/env bash
# Turning MMS off should show the emoji button in the plus's empty slot, but the
# button must stay under the user's control after that: switching the Emoji
# button setting off hides it while MMS is still off.
#
# The debug probe calls the same helper as the MMS switch, so it performs the
# automatic turn-on. The later "user switched it off" state is written straight
# to the preferences while the app is stopped, then the composer is read with no
# probe at all.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

EMOJI=$(res_string icon_emoji)
ATTACH=$(res_string icon_attach)
if [ -z "$EMOJI" ] || [ -z "$ATTACH" ]; then
    echo "  [FAIL] this build has no emoji/attach label"
    echo; echo "  PASS=0 FAIL=1"; echo "=== FAILED ==="; exit 1
fi

adb_su "cmd role add-role-holder android.app.role.SMS $PKG" >/dev/null 2>&1
adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1 || true

PREFS="/data/data/$PKG/shared_prefs/messages_settings.xml"
BACKUP="$TMP/emoji-mms-off-prefs.bak.xml"
adb_ shell "run-as $PKG cat $PREFS" > "$BACKUP" 2>/dev/null || true

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    if [ -s "$BACKUP" ]; then
        adb_ shell "run-as $PKG sh -c 'cat > $PREFS'" < "$BACKUP" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

pref_get() {
    local key="$1"
    adb_ shell "run-as $PKG cat $PREFS" 2>/dev/null | tr -d '\r' > "$TMP/prefs.xml"
    python3 - "$TMP/prefs.xml" "$key" <<'PY'
import re, sys
try:
    s = open(sys.argv[1]).read()
except OSError:
    s = ""
m = re.search(r'name="' + re.escape(sys.argv[2]) + r'" value="([^"]*)"', s)
print(m.group(1) if m else "")
PY
}

write_prefs() {
    local mms="$1" emoji="$2"
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    cat > "$TMP/emoji-mms-off-prefs.xml" <<XML
<?xml version="1.0" encoding="utf-8" standalone="yes" ?>
<map>
    <boolean name="first_import_done" value="true" />
    <boolean name="mms_enabled" value="$mms" />
    <boolean name="emoji_button_enabled" value="$emoji" />
</map>
XML
    adb_ shell "run-as $PKG sh -c 'cat > $PREFS'" < "$TMP/emoji-mms-off-prefs.xml" >/dev/null 2>&1
}

launch() {
    local probe="$1" extra
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    if [ -n "$probe" ]; then extra="--es mms_probe $probe"; else extra=""; fi
    adb_ shell am start -W -n "$ACT" $extra >/dev/null 2>&1
    sleep 3
}

open_chat() {
    rm -f "$TMP/ui.xml" "$TMP/ui.decoded.xml"
    dump_ui >/dev/null 2>&1 || dump_ui >/dev/null 2>&1 || true
    local row
    row=$(python3 - "$TMP/ui.xml" 2>/dev/null <<'PY'
import re, sys
xml = open(sys.argv[1]).read()
best = None
for m in re.finditer(r'<node[^>]*content-desc="([^"]+)"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', xml):
    y1 = int(m.group(3))
    if y1 > 300 and (best is None or y1 < best[0]):
        best = (y1, (int(m.group(2)) + int(m.group(4))) // 2, (int(m.group(3)) + int(m.group(5))) // 2)
print(f"{best[1]} {best[2]}" if best else "")
PY
)
    [ -n "$row" ] || return 1
    adb_ shell input tap ${row% *} ${row#* }
    sleep 2
    rm -f "$TMP/ui.xml" "$TMP/ui.decoded.xml"
    dump_ui >/dev/null 2>&1 || dump_ui >/dev/null 2>&1 || true
}

info "Start with MMS on and the emoji setting off"
write_prefs true false
launch ""
if [ "$(pref_get emoji_button_enabled)" = "false" ]; then
    ok "emoji setting is off before MMS is turned off"
else
    bad "could not set the emoji setting off"
fi

info "Turning MMS off shows the emoji button"
launch off
for i in 1 2 3 4 5; do
    [ "$(pref_get mms_enabled)" = "false" ] && \
        [ "$(pref_get emoji_button_enabled)" = "true" ] && break
    sleep 1
done
if [ "$(pref_get mms_enabled)" = "false" ] && \
   [ "$(pref_get emoji_button_enabled)" = "true" ]; then
    ok "turning MMS off turned the emoji setting on"
else
    bad "turning MMS off did not turn the emoji setting on"
fi
open_chat || bad "could not open a conversation"
if ui_has "$ATTACH"; then
    bad "the attach button is still there with MMS off"
else
    ok "no '$ATTACH' button with MMS off"
fi
if ui_has "$EMOJI"; then
    ok "the '$EMOJI' button appeared in the empty slot"
else
    bad "the '$EMOJI' button did not appear with MMS off"
fi

info "Turning the emoji setting off later hides it again"
write_prefs false false
launch ""
if [ "$(pref_get emoji_button_enabled)" = "false" ]; then
    ok "the emoji setting is off again"
else
    bad "could not turn the emoji setting off with MMS off"
fi
open_chat || bad "could not open a conversation after hiding emoji"
if ui_has "$EMOJI"; then
    bad "the '$EMOJI' button is still there after the user disabled it"
else
    ok "the '$EMOJI' button is gone while MMS stays off"
fi

echo
echo "  PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && echo "=== OK ===" || echo "=== FAILED ==="
exit $((FAIL > 0))
