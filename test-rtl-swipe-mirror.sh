#!/usr/bin/env bash
# Issue #408 (RTL): the conversation swipe ran the action for the mirrored
# direction. Compose names its settle values after the *layout-relative* start
# and end edges, but the settings labels ("Swipe left" / "Swipe right") and the
# actions they configure are physical. In RTL a leftward finger settles on
# StartToEnd, which the old code read as "travelled right" and therefore ran the
# action configured for a rightward swipe.
#
# Seed: Swipe left = Archive, Swipe right = Mark read/unread. Then a leftward
# finger in RTL must archive (not mark read), and a rightward finger must mark
# read (not archive).
source "$(dirname "$0")/env.sh"

NAME="RTL Swipe Mirror"
NUM="+15558808601"
TS=$(( $(date +%s) * 1000 ))
PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

sql() { echo "$1" | adb_ shell "run-as $PKG sqlite3 databases/messages.db"; }

PREF_BAK="$TMP/rtl-swipe-prefs.xml"
cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    if [ -s "$PREF_BAK" ]; then
        adb_ push "$PREF_BAK" /data/local/tmp/rtl-swipe-prefs.xml >/dev/null 2>&1
        adb_ shell "run-as $PKG sh -c 'cat /data/local/tmp/rtl-swipe-prefs.xml > shared_prefs/messages_settings.xml'" >/dev/null 2>&1
    fi
    sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM');" >/dev/null 2>&1
    sql "DELETE FROM conversations WHERE address='$NUM';" >/dev/null 2>&1
}
trap cleanup EXIT

set_swipe_prefs() {
    local left="$1" right="$2"
    adb_ shell am force-stop "$PKG"; sleep 1
    adb_ exec-out run-as "$PKG" cat shared_prefs/messages_settings.xml > "$TMP/prefs.xml" 2>/dev/null || true
    python3 - "$TMP/prefs.xml" "$left" "$right" <<'PY'
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
    adb_ push "$TMP/prefs.xml" /data/local/tmp/rtl-swipe-prefs-new.xml >/dev/null 2>&1
    adb_ shell "run-as $PKG sh -c 'cat /data/local/tmp/rtl-swipe-prefs-new.xml > shared_prefs/messages_settings.xml'" >/dev/null 2>&1
}

seed() {
    sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM');" >/dev/null
    sql "DELETE FROM conversations WHERE address='$NUM';" >/dev/null
    sql "INSERT INTO conversations(address,name,snippet,timestamp,unread_count,last_is_me,archived) VALUES('$NUM','$NAME','swipe me',$TS,1,0,0);" >/dev/null
    sql "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,media_type) SELECT id,'swipe test message',$TS,0,'received','text' FROM conversations WHERE address='$NUM';" >/dev/null
}

start_app() {
    adb_ shell am force-stop "$PKG"; sleep 1
    adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 5
}

row_of() {
    local i
    for i in 1 2 3 4 5 6; do
        layout_center "$1" && return 0
        sleep 1
    done
    return 1
}

wait_int() {
    # wait_int <sql expression> <expected> <seconds>
    local expr="$1" want="$2" secs="$3" i got
    for i in $(seq 1 "$secs"); do
        got=$(sql "SELECT $expr FROM conversations WHERE address='$NUM';" | tr -d '[:space:]')
        [ "$got" = "$want" ] && return 0
        sleep 1
    done
    echo "  (last $expr = '${got:-none}', wanted '$want')"
    return 1
}

info "Ensure the device is RTL"
LOC=$(adb_ shell getprop persist.sys.locale | tr -d '\r')
case "$LOC" in
    ar-*|fa-*|he-*|ur-*) ok "device locale is RTL ($LOC)" ;;
    *) bad "device locale is '$LOC', not RTL — set persist.sys.locale and restart zygote first"
       echo ""; info "Results: $PASS passed, $FAIL failed"; exit 1 ;;
esac
W=$(adb_ shell wm size | sed -E 's/.*: ([0-9]+)x([0-9]+).*/\1/' | tr -d '\r')
[ -n "$W" ] || W=1080

# Without the role the home screen is covered by the "set as default SMS app"
# prompt and no conversation row can be swiped.
info "Hold the default SMS role"
adb_su "cmd role add-role-holder android.app.role.SMS $PKG" >/dev/null 2>&1
sleep 1

info "Back up prefs, seed one unread conversation"
adb_ exec-out run-as "$PKG" cat shared_prefs/messages_settings.xml > "$PREF_BAK" 2>/dev/null || true

info "Test 1: a LEFT finger must run the LEFT action (archive)"
set_swipe_prefs 1 3     # ARCHIVE=1, MARK_READ_UNREAD=3
seed
start_app
ROW=$(row_of "$NAME") || { bad "seeded conversation not listed"; echo ""; info "Results: $PASS passed, $FAIL failed"; exit 1; }
Y=${ROW#* }
adb_ shell input swipe $((W - 60)) "$Y" 60 "$Y" 400
sleep 1
if wait_int "archived" "1" 6; then
    ok "leftward swipe in RTL ran the left action (archived)"
else
    bad "leftward swipe in RTL did not archive"
fi
UNREAD=$(sql "SELECT unread_count FROM conversations WHERE address='$NUM';" | tr -d '[:space:]')
if [ "$UNREAD" = "0" ]; then
    bad "leftward swipe in RTL ran the mirrored right action (marked read)"
else
    ok "leftward swipe did not run the right-hand action"
fi

info "Test 2: a RIGHT finger must run the RIGHT action (mark read)"
sql "UPDATE conversations SET archived=0, unread_count=1 WHERE address='$NUM';" >/dev/null
start_app
ROW=$(row_of "$NAME") || { bad "seeded conversation not listed after reset"; echo ""; info "Results: $PASS passed, $FAIL failed"; exit 1; }
Y=${ROW#* }
adb_ shell input swipe 60 "$Y" $((W - 60)) "$Y" 400
sleep 1
if wait_int "unread_count" "0" 6; then
    ok "rightward swipe in RTL ran the right action (marked read)"
else
    bad "rightward swipe in RTL did not mark the conversation read"
fi
ARCH=$(sql "SELECT archived FROM conversations WHERE address='$NUM';" | tr -d '[:space:]')
if [ "$ARCH" = "1" ]; then
    bad "rightward swipe in RTL ran the mirrored left action (archived)"
else
    ok "rightward swipe did not run the left-hand action"
fi

echo ""
info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
