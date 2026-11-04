#!/usr/bin/env bash
# Issue #408 (RTL): while a conversation row is being swiped, the background
# showed the action for the mirrored direction -- its colour and icon were the
# other action's -- and the icon sat under the row instead of on the side the
# drag had uncovered. The completed swipe was already correct; only the live
# drag was wrong.
#
# Seed: Swipe left = Archive, Swipe right = Mark read/unread. Hold a leftward
# drag and assert the exposed icon is Archive on the physical right; hold a
# rightward drag and assert it is Mark as read on the physical left.
#
# `adb shell input swipe` cannot be used here: it keeps moving the pointer for
# its whole duration, so the UI never goes idle and `uiautomator dump` waits
# until it is killed (rc 137), leaving UiAutomation registered and every later
# dump failing until a reboot. Raw sendevent writes a DOWN, a short MOVE run,
# and then stops, so the row stays displaced while the hierarchy is dumped.
source "$(dirname "$0")/env.sh"
set -uo pipefail

NAME="RTL Swipe Background"
NUM="+15558808602"
TS=$(( $(date +%s) * 1000 ))
PASS=0
FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
info(){ echo -e "\n=== $* ==="; }

sql() { echo "$1" | adb_ shell "run-as $PKG sqlite3 databases/messages.db"; }

# The swipe background's icon labels come from the app's own resources, so the
# assertions read the same text the current locale renders.
LOC=$(adb_ shell getprop persist.sys.locale | tr -d '\r')
LANG_CODE=${LOC%%-*}
QUAL="$LANG_CODE"
case "$LOC" in *-*) QUAL="$LANG_CODE-r${LOC#*-}" ;; esac

localized() {
    local key="$1" dir f val
    for dir in "values-$QUAL" "values-$LANG_CODE" values; do
        f=$(grep -l "name=\"$key\"" "$PROJECT_DIR/app/src/main/res/$dir"/*.xml 2>/dev/null | head -1)
        [ -n "$f" ] || continue
        val=$(sed -nE "s/.*<string name=\"$key\"[^>]*>([^<]*)<\/string>.*/\1/p" "$f" | head -1)
        [ -n "$val" ] && { python3 -c 'import html,sys; sys.stdout.write(html.unescape(sys.argv[1]))' "$val"; return 0; }
    done
    return 1
}

LABEL_ARCHIVE=$(localized access_archive)            || { echo "missing access_archive"; exit 1; }
LABEL_READ=$(localized access_mark_read)             || { echo "missing access_mark_read"; exit 1; }
LABEL_UNREAD=$(localized access_mark_unread)         || { echo "missing access_mark_unread"; exit 1; }
LABEL_DELETE=$(localized sheet_delete)               || { echo "missing sheet_delete"; exit 1; }
LABEL_PIN=$(localized swipe_action_pin)              || { echo "missing swipe_action_pin"; exit 1; }
LABEL_BLOCK=$(localized swipe_action_block)          || { echo "missing swipe_action_block"; exit 1; }

PREF_BAK="$TMP/rtl-swipe-bg-prefs.xml"
TOUCH=""
DRAG_DX1=0
DRAG_DX2=0
DRAG_DY=0

find_touch() {
    TOUCH=$(adb_ shell getevent -pl 2>/dev/null | tr -d '\r' |
        awk '/^add device/{dev=$4}
             /name:/ && /virtio_input_multi_touch_1"/{print dev; exit}')
    [ -n "$TOUCH" ] && return 0
    TOUCH=$(adb_ shell getevent -pl 2>/dev/null | tr -d '\r' |
        awk '/^add device/{dev=$4} /ABS_MT_POSITION_X/{print dev; exit}')
    [ -n "$TOUCH" ]
}

# Lift any pointer a previous run left down. Harmless when none is down.
release_touch() {
    [ -n "$TOUCH" ] || return 0
    local cmd="" i xv
    if [ "$DRAG_DX1" -ne 0 ] && [ "$DRAG_DY" -ne 0 ]; then
        for i in 9 8 7 6 5 4 3 2 1 0; do
            xv=$(( DRAG_DX1 + (DRAG_DX2 - DRAG_DX1) * i / 10 ))
            cmd="$cmd sendevent $TOUCH 3 53 $xv; sendevent $TOUCH 0 0 0; sleep 0.02;"
        done
    fi
    adb_su "$cmd sendevent $TOUCH 3 57 -1; sendevent $TOUCH 0 0 0" >/dev/null 2>&1 || true
    DRAG_DX1=0
    DRAG_DY=0
}

cleanup() {
    release_touch
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    if [ -s "$PREF_BAK" ]; then
        adb_ push "$PREF_BAK" /data/local/tmp/rtl-swipe-bg-prefs.xml >/dev/null 2>&1
        adb_ shell "run-as $PKG sh -c 'cat /data/local/tmp/rtl-swipe-bg-prefs.xml > shared_prefs/messages_settings.xml'" >/dev/null 2>&1
    fi
    sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM');" >/dev/null 2>&1
    sql "DELETE FROM conversations WHERE address='$NUM';" >/dev/null 2>&1
}
trap cleanup EXIT

set_swipe_prefs() {
    local left="$1" right="$2"
    adb_ shell am force-stop "$PKG"; sleep 1
    adb_ exec-out run-as "$PKG" cat shared_prefs/messages_settings.xml > "$TMP/rtl-swipe-bg.xml" 2>/dev/null || true
    python3 - "$TMP/rtl-swipe-bg.xml" "$left" "$right" <<'PY'
import re, sys
path, left, right = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    s = open(path).read()
except OSError:
    s = '<?xml version="1.0" encoding="utf-8" standalone="yes" ?>\n<map>\n</map>\n'
s = re.sub(r'\s*<(?:int|boolean|string) name="swipe_(?:left|right)_action"[^>]*/>', '', s)
block = ('  <int name="swipe_left_action" value="%s" />\n'
         '  <int name="swipe_right_action" value="%s" />\n' % (left, right))
if '</map>' not in s:
    s = '<?xml version="1.0" encoding="utf-8" standalone="yes" ?>\n<map>\n</map>\n'
s = s.replace('</map>', block + '</map>')
open(path, 'w').write(s)
PY
    adb_ push "$TMP/rtl-swipe-bg.xml" /data/local/tmp/rtl-swipe-bg-new.xml >/dev/null 2>&1
    adb_ shell "run-as $PKG sh -c 'cat /data/local/tmp/rtl-swipe-bg-new.xml > shared_prefs/messages_settings.xml'" >/dev/null 2>&1
}

seed() {
    sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM');" >/dev/null
    sql "DELETE FROM conversations WHERE address='$NUM';" >/dev/null
    sql "INSERT INTO conversations(address,name,snippet,timestamp,unread_count,last_is_me,archived) VALUES('$NUM','$NAME','swipe me',$TS,1,0,0);" >/dev/null
    sql "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,media_type) SELECT id,'swipe background test',$TS,0,'received','text' FROM conversations WHERE address='$NUM';" >/dev/null
}

start_app() {
    adb_ shell am force-stop "$PKG"; sleep 1
    adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 5
}

row_y() {
    local i c
    for i in 1 2 3 4 5 6; do
        c=$(center_of_contains "$NAME" 2>/dev/null || true)
        [ -n "$c" ] && { echo "${c#* }"; return 0; }
        sleep 1
    done
    return 1
}

# Down at x1, drag to x2 and stop there. The pointer stays down, so the row
# remains displaced while the caller dumps the hierarchy.
hold_swipe() {
    local x1="$1" x2="$2" y="$3" cmd i xv
    DRAG_DX1=$(( x1 * 32767 / (W - 1) ))
    DRAG_DX2=$(( x2 * 32767 / (W - 1) ))
    DRAG_DY=$(( y * 32767 / (H - 1) ))
    cmd="sendevent $TOUCH 3 47 0; sendevent $TOUCH 3 57 1"
    cmd="$cmd; sendevent $TOUCH 3 53 $DRAG_DX1; sendevent $TOUCH 3 54 $DRAG_DY"
    cmd="$cmd; sendevent $TOUCH 3 48 5; sendevent $TOUCH 3 58 50; sendevent $TOUCH 0 0 0"
    for i in 1 2 3 4 5 6 7 8 9 10; do
        xv=$(( DRAG_DX1 + (DRAG_DX2 - DRAG_DX1) * i / 10 ))
        cmd="$cmd; sendevent $TOUCH 3 53 $xv; sendevent $TOUCH 0 0 0; sleep 0.02"
    done
    adb_su "$cmd" >/dev/null 2>&1 || return 1
    sleep 2
}

# Print "<label> <x>" for the swipe background icon currently in the tree.
background_icon() {
    dump_ui >/dev/null 2>&1 || return 1
    python3 - "$TMP/ui.decoded.xml" "$LABEL_ARCHIVE" "$LABEL_READ" "$LABEL_UNREAD" \
        "$LABEL_DELETE" "$LABEL_PIN" "$LABEL_BLOCK" <<'PY'
import html, re, sys
labels = set(sys.argv[2:])
data = open(sys.argv[1], encoding='utf-8', errors='replace').read()
for tag in re.findall(r'<node[^>]*>', data):
    cd = re.search(r'content-desc="([^"]*)"', tag)
    b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', tag)
    if not cd or not b:
        continue
    label = html.unescape(cd.group(1))
    if label in labels:
        x1, y1, x2, y2 = map(int, b.groups())
        print(label, (x1 + x2) // 2)
        break
PY
}

info "Ensure the device is RTL"
case "$LOC" in
    ar-*|fa-*|he-*|ur-*) ok "device locale is RTL ($LOC)" ;;
    *) bad "device locale is '$LOC', not RTL — set persist.sys.locale and restart zygote first"
       echo ""; info "Results: $PASS passed, $FAIL failed"; exit 1 ;;
esac

info "Check root for raw touch injection"
if ! find_touch; then
    bad "no touchscreen input device found"
    echo ""; info "Results: $PASS passed, $FAIL failed"; exit 1
fi
if ! adb_su "id" 2>/dev/null | grep -q "uid=0"; then
    bad "no root shell — sendevent needs it to hold the row mid-swipe"
    echo ""; info "Results: $PASS passed, $FAIL failed"; exit 1
fi
ok "raw touch injection via $TOUCH"
release_touch

W=$(adb_ shell wm size | sed -E 's/.*: ([0-9]+)x([0-9]+).*/\1/' | tr -d '\r')
H=$(adb_ shell wm size | sed -E 's/.*: [0-9]+x([0-9]+).*/\1/' | tr -d '\r')
[ -n "$W" ] || W=1080
[ -n "$H" ] || H=2340
MID=$((W / 2))

info "Hold the default SMS role"
adb_su "cmd role add-role-holder android.app.role.SMS $PKG" >/dev/null 2>&1
sleep 1

info "Back up prefs, seed one unread conversation"
adb_ exec-out run-as "$PKG" cat shared_prefs/messages_settings.xml > "$PREF_BAK" 2>/dev/null || true

info "Test 1: a leftward drag exposes the left action on the physical right"
set_swipe_prefs 1 3     # ARCHIVE=1, MARK_READ_UNREAD=3
seed
start_app
Y=$(row_y) || { bad "seeded conversation not listed"; echo ""; info "Results: $PASS passed, $FAIL failed"; exit 1; }
ICON=""
if hold_swipe $((W - 60)) $((W / 5)) "$Y"; then
    ICON=$(background_icon)
fi
release_touch
DESC=${ICON% *}
IX=${ICON##* }
if [ -z "$ICON" ]; then
    bad "leftward drag shows the swipe background icon"
    bad "leftward drag shows the Archive icon"
    bad "leftward drag puts the icon on the uncovered (right) side"
else
    ok "leftward drag shows the swipe background icon ($DESC)"
    [ "$DESC" = "$LABEL_ARCHIVE" ] && ok "leftward drag shows the Archive icon" \
        || bad "leftward drag shows '$DESC', not Archive"
    [ "$IX" -gt "$MID" ] && ok "leftward drag puts the icon on the uncovered (right) side" \
        || bad "leftward drag puts the icon at x=$IX, not right of $MID"
fi

info "Test 2: a rightward drag exposes the right action on the physical left"
sql "UPDATE conversations SET archived=0, unread_count=1 WHERE address='$NUM';" >/dev/null
start_app
Y=$(row_y) || { bad "seeded conversation not listed after reset"; echo ""; info "Results: $PASS passed, $FAIL failed"; exit 1; }
ICON=""
if hold_swipe 60 $((W * 4 / 5)) "$Y"; then
    ICON=$(background_icon)
fi
release_touch
DESC=${ICON% *}
IX=${ICON##* }
if [ -z "$ICON" ]; then
    bad "rightward drag shows the swipe background icon"
    bad "rightward drag shows the Mark as read icon"
    bad "rightward drag puts the icon on the uncovered (left) side"
else
    ok "rightward drag shows the swipe background icon ($DESC)"
    [ "$DESC" = "$LABEL_READ" ] && ok "rightward drag shows the Mark as read icon" \
        || bad "rightward drag shows '$DESC', not Mark as read"
    [ "$IX" -lt "$MID" ] && ok "rightward drag puts the icon on the uncovered (left) side" \
        || bad "rightward drag puts the icon at x=$IX, not left of $MID"
fi

echo ""
info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
