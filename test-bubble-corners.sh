#!/usr/bin/env bash
# Regression for run-aware chat bubble corners. Consecutive messages from the
# same sender form a run whose shape must render as:
#   lone message      -> one flat "tail" corner on the sender's bottom side;
#   first of a run    -> flat bottom corner on the sender's side;
#   middle of a run   -> all four corners rounded;
#   last of a run     -> flat top corner on the sender's side.
# Outgoing tails sit on the right, incoming tails on the left.
#
# Asserted via the app's "BubbleShape" logcat marker, emitted once per composed
# bubble with `id=... position=<SINGLE|FIRST|MIDDLE|LAST> mine=<bool>` and the
# four corner radii in dp.
#
# Run: scripts/test-bubble-corners.sh
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh

PASS=0
FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }

[[ "$ANDROID_SERIAL" == emulator-* ]] || { printf 'Requires a disposable emulator.\n'; exit 1; }

STAMP="$(date +%s)"
OUT1="+1555$((STAMP % 100000000))"
OUT3="+1555$(((STAMP + 1) % 100000000))"
IN1="+1555$(((STAMP + 2) % 100000000))"
IN3="+1555$(((STAMP + 3) % 100000000))"
MARK="corners $STAMP"
NUMS=("$OUT1" "$OUT3" "$IN1" "$IN3")

shapes() { adb_ logcat -d -s BubbleShape:D 2>/dev/null; }

expect() {
    local desc="$1" pattern="$2"
    if shapes | grep -Eq "$pattern"; then
        pass "$desc"
    else
        fail "$desc (no match: $pattern)"
    fi
}

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    local n
    for n in "${NUMS[@]}"; do
        adb_ shell "run-as $PKG sqlite3 databases/messages.db \"DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$n'); DELETE FROM conversations WHERE address='$n'; DELETE FROM participants WHERE normalized_destination='$n';\"" >/dev/null 2>&1 || true
    done
}
trap cleanup EXIT

reopen() {
    local addr="$1"
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    sleep 1
    adb_ shell logcat -c >/dev/null 2>&1 || true
    adb_ shell am start -n "$ACT" --es open_conversation_address "$addr" >/dev/null
    sleep 5
}

send_out() {
    if ! tap_edittext >/dev/null 2>&1; then
        fail "could not focus the chat input"
        return 0
    fi
    sleep 0.6
    type_text "$1"
    sleep 0.6
    tap_text "Send" >/dev/null 2>&1 || adb_ shell input keyevent 66
    sleep 2.5
}

adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1 || true
bash ./grant-permissions.sh >/dev/null 2>&1 || true

info "outgoing lone message -> flat bottom-right only"
reopen "$OUT1"
send_out "lonely $MARK"
reopen "$OUT1"
expect 'outgoing single keeps bottom-right flat' \
    'position=SINGLE mine=true topStart=18.0 topEnd=18.0 bottomStart=18.0 bottomEnd=4.0'

info "outgoing run of three"
reopen "$OUT3"
send_out "run one $MARK"
send_out "run two $MARK"
send_out "run three $MARK"
reopen "$OUT3"
expect 'outgoing first of run keeps bottom-right flat' \
    'position=FIRST mine=true topStart=18.0 topEnd=18.0 bottomStart=18.0 bottomEnd=4.0'
expect 'outgoing middle of run is fully rounded' \
    'position=MIDDLE mine=true topStart=18.0 topEnd=18.0 bottomStart=18.0 bottomEnd=18.0'
expect 'outgoing last of run keeps top-right flat' \
    'position=LAST mine=true topStart=18.0 topEnd=4.0 bottomStart=18.0 bottomEnd=18.0'

info "incoming lone message -> flat bottom-left only"
adb_ emu sms send "$IN1" "lone inbound $MARK" >/dev/null
sleep 3
reopen "$IN1"
expect 'incoming single keeps bottom-left flat' \
    'position=SINGLE mine=false topStart=18.0 topEnd=18.0 bottomStart=4.0 bottomEnd=18.0'

info "incoming run of three"
adb_ emu sms send "$IN3" "in one $MARK" >/dev/null
sleep 2
adb_ emu sms send "$IN3" "in two $MARK" >/dev/null
sleep 2
adb_ emu sms send "$IN3" "in three $MARK" >/dev/null
sleep 3
reopen "$IN3"
expect 'incoming first of run keeps bottom-left flat' \
    'position=FIRST mine=false topStart=18.0 topEnd=18.0 bottomStart=4.0 bottomEnd=18.0'
expect 'incoming middle of run is fully rounded' \
    'position=MIDDLE mine=false topStart=18.0 topEnd=18.0 bottomStart=18.0 bottomEnd=18.0'
expect 'incoming last of run keeps top-left flat' \
    'position=LAST mine=false topStart=4.0 topEnd=18.0 bottomStart=18.0 bottomEnd=18.0'

printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
