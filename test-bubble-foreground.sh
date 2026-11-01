#!/usr/bin/env bash
# Regression for #354: a bubble tapped while the app is already on screen.
#
# A conversation shortcut's bubble PendingIntent used to target MainActivity
# itself. When the app was resumed, singleTop delivered that launch to the
# running instance instead of creating a task, so the app navigated to the
# conversation and the expanded bubble had nothing to host — the reported
# "bubble opens blank, but the app goes to that conversation". Google Messages
# launches a separate task; so do we, through the BubbleChatActivity alias.
#
# Asserts, from the system dumps (no screenshots):
#   * an incoming SMS while the app is foreground still bubbles,
#   * tapping the collapsed bubble creates a task in multi-window mode (the
#     bubble's own task) that renders the conversation,
#   * the app's own task stays fullscreen and keeps its notification,
#   * Back inside the bubble retires that task.
#
# Run: scripts/test-bubble-foreground.sh
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { printf '\n=== %s ===\n' "$1"; }

MARK="bubblefg$(date +%s)"
TEXT="bubble foreground $MARK"
NUM="+1555$(( (RANDOM % 9000) + 1000 ))"
FLAG_BUBBLE=0x1000

adb_ root >/dev/null 2>&1
adb_ wait-for-device

sql() { adb_ shell "sqlite3 /data/data/$PKG/databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r'; }
notif_dump() { adb_ shell "dumpsys notification --noredact" 2>/dev/null | tr -d '\r'; }
window_dump() { adb_ shell "dumpsys window windows" 2>/dev/null | tr -d '\r'; }
activity_dump() { adb_ shell "dumpsys activity activities" 2>/dev/null | tr -d '\r'; }

record() {
    notif_dump | awk -v m="$MARK" '
        /NotificationRecord\(/ { if (buf ~ m) print buf; buf = "" }
        { buf = buf $0 "\n" }
        END { if (buf ~ m) print buf }
    '
}

record_is_bubble() {
    local hex
    hex=$(record | grep -o "flags=0x[0-9a-fA-F]*" | head -1 | cut -d= -f2)
    if [ -n "$hex" ]; then
        [ $(( hex & FLAG_BUBBLE )) -ne 0 ]
    else
        record | grep -q "flags=[^ ]*BUBBLE"
    fi
}

# The collapsed bubble's touchable region, e.g. SkRegion((-41,335,190,566)).
# An expanded bubble reports a union of four rects and is not tapped here.
bubble_region() {
    window_dump | awk '/Bubbles!/{f=1}
        f && /touchable region=SkRegion\(\(-?[0-9]+,-?[0-9]+,-?[0-9]+,-?[0-9]+\)\)/ { print; exit }'
}

# Tasks this package runs, one line each, so mode can be asserted per task.
app_tasks() {
    activity_dump | grep -E "^ +\* Task\{" | grep "$PKG"
}

task_modes() { app_tasks | grep -o "mode=[a-z-]*" | sort -u | tr '\n' ' '; }

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    sql "DELETE FROM messages WHERE body='$TEXT';" >/dev/null 2>&1
    sql "DELETE FROM conversations WHERE address='$NUM';" >/dev/null 2>&1
}
trap cleanup EXIT

# --- inbound SMS ------------------------------------------------------------
# `adb emu sms send` needs the emulator's modem simulator, which is missing on
# some hosts (qemu reports "Unable to connect character device modem"). Fall
# back to handing the app a real SMS_DELIVER broadcast built from a GSM-7 PDU.
INJECT_DIR="$(dirname "$0")/lib/inject-sms"

build_injector() {
    local dex="$TMP/inject.dex" src="$INJECT_DIR/InjectSms.java"
    if [ -f "$dex" ] && [ "$dex" -nt "$src" ]; then return 0; fi
    local aj="$HOME/android/platforms/android-33/android.jar"
    local d8
    d8=$(ls -d "$HOME"/android/build-tools/*/d8 2>/dev/null | sort -V | tail -1)
    [ -f "$aj" ] && [ -x "$d8" ] || return 1
    local work="$TMP/inject-src"
    rm -rf "$work"; mkdir -p "$work"
    cp "$src" "$work/" || return 1
    ( cd "$work" \
        && javac -source 8 -target 8 -bootclasspath "$aj" -d . InjectSms.java >/dev/null 2>&1 \
        && "$d8" --lib "$aj" --output . InjectSms.class >/dev/null 2>&1 ) || return 1
    cp "$work/classes.dex" "$dex" || return 1
    adb_ push "$dex" /data/local/tmp/inject.dex >/dev/null || return 1
}

inject_sms() {
    build_injector || return 1
    local pdu
    pdu=$(python3 "$INJECT_DIR/pdu.py" "$1" "$2") || return 1
    adb_ shell "su -c 'CLASSPATH=/data/local/tmp/inject.dex app_process /system/bin InjectSms $pdu $PKG'" >/dev/null 2>&1
}

sms_arrived() { [ -n "$(sql "SELECT id FROM messages WHERE body='$TEXT' LIMIT 1;")" ]; }

send_sms() {
    adb_ emu sms send "$NUM" "$TEXT" >/dev/null 2>&1
    local i
    for i in 1 2 3 4 5 6; do
        sleep 1
        sms_arrived && return 0
    done
    inject_sms "$NUM" "$TEXT"
    for i in 1 2 3 4 5 6; do
        sleep 1
        sms_arrived && return 0
    done
    return 1
}

# --- setup ------------------------------------------------------------------
info "Setting up: default SMS role, platform bubbles on, app on its list"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1
adb_ shell "cmd role add-role-holder android.app.role.SMS $PKG" >/dev/null 2>&1
adb_ shell "cmd notification set_bubbles $PKG 1" >/dev/null 2>&1
adb_ shell am start -n "$ACT" >/dev/null 2>&1
sleep 6

focus=$(adb_ shell "dumpsys window" 2>/dev/null | tr -d '\r' | grep mCurrentFocus)
case "$focus" in
    *"$PKG/"*MainActivity*) ok "the app is in the foreground" ;;
    *) bad "the app did not come to the foreground ($focus)" ;;
esac

info "An incoming SMS while the app is on screen still bubbles"
if ! send_sms; then
    bad "no SMS reached the app (emulator modem and the PDU injector both failed)"
fi
sleep 4
if record_is_bubble; then
    ok "the notification carries the BUBBLE flag while the app is foreground"
else
    bad "the message did not bubble"
fi

info "Tapping the collapsed bubble"
region=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
    region=$(bubble_region)
    [ -n "$region" ] && break
    sleep 1
done
if [ -z "$region" ]; then
    bad "no collapsed bubble is on screen to tap"
else
    read -r x1 y1 x2 y2 <<<"$(echo "$region" | grep -o "(-\?[0-9]*,[0-9]*,[0-9]*,-\?[0-9]*)" | tr -d '()' | tr ',' ' ')"
    x=$(( (x1 + x2) / 2 )); y=$(( (y1 + y2) / 2 ))
    [ "$x" -lt 0 ] && x=8
    adb_ shell input tap "$x" "$y"
    sleep 5
fi

modes=$(task_modes)
info "Tasks after the tap: $modes"

# The whole defect: with a single task the bubble has nothing to host.
case "$modes" in
    *multi-window*) ok "the bubble opened in a task of its own (mode=multi-window)" ;;
    *) bad "the bubble has no task of its own: the launch landed on the app's task ($modes)" ;;
esac
case "$modes" in
    *fullscreen*) ok "the app's own window stayed fullscreen behind the bubble" ;;
    *) bad "the app's fullscreen task disappeared ($modes)" ;;
esac

info "The bubble renders the conversation"
if wait_layout_has "$TEXT" 10; then
    ok "the bubble shows the chat instead of a blank window"
else
    bad "the bubble window is empty"
fi

if record_is_bubble; then
    ok "the notification outlives the open bubble"
else
    bad "opening the bubble dropped its notification"
fi

info "Back inside the bubble retires it"
adb_ shell input keyevent KEYCODE_BACK
sleep 4
if app_tasks | grep -q "mode=multi-window"; then
    bad "Back left the bubble task behind"
else
    ok "Back closed the bubble's task"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
