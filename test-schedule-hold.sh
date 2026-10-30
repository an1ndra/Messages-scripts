#!/usr/bin/env bash
# Holding Send is how a message is scheduled: the send circle shrinks, and the
# date picker opens once it has played. This replaced an in-composer clock
# button that was added for #386 and then removed on request.
#
# Fails on a build without the animation: no "ScheduleHold" log line and no
# "Select date" dialog, because the press gave no feedback at all.
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
adb_ root >/dev/null 2>&1

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { printf '\n=== %s ===\n' "$1"; }

PREFS="shared_prefs/messages_settings.xml"
MARK="hold$(date +%s)"

set_scheduling() {   # true|false
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    adb_ shell "run-as $PKG sh -c 'if grep -q name=\"scheduled_messages_enabled\" $PREFS; then sed -i \"s#name=\\\"scheduled_messages_enabled\\\" value=\\\"[^\\\"]*\\\"#name=\\\"scheduled_messages_enabled\\\" value=\\\"$1\\\"#\" $PREFS; else sed -i \"s#</map>#    <boolean name=\\\"scheduled_messages_enabled\\\" value=\\\"$1\\\" />\\n</map>#\" $PREFS; fi'" >/dev/null 2>&1
}

open_chat_with_draft() {
    adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 5
    adb_ shell input tap 500 300 >/dev/null 2>&1; sleep 4
    # Focus the composer wherever it sits, then type.
    local field
    field=$(layout_center "Message")
    if [ -n "$field" ]; then set -- $field; adb_ shell input tap "$1" "$2" >/dev/null 2>&1; else adb_ shell input tap 460 2109 >/dev/null 2>&1; fi
    sleep 2
    adb_ shell input text "$MARK" >/dev/null 2>&1; sleep 2
}

send_center() {
    layout_json || return 1
    python3 - "$TMP/layout.json" <<'PY'
import json, re, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
found = []
def walk(node):
    if isinstance(node, list):
        for c in node: walk(c)
    elif isinstance(node, dict):
        if node.get("content-desc") == "Send" and isinstance(node.get("bounds"), str):
            m = re.findall(r"\d+", node["bounds"])
            if len(m) == 4:
                found.append(((int(m[0]) + int(m[2])) // 2, (int(m[1]) + int(m[3])) // 2))
        for key in ("content", "children"):
            for c in (node.get(key) or []): walk(c)
walk(data)
if found:
    print(found[0][0], found[0][1])
PY
}

cleanup() {
    adb_ shell input keyevent 4 >/dev/null 2>&1
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    set_scheduling true
    adb_ shell am start -n "$ACT" >/dev/null 2>&1
}
trap cleanup EXIT

info "Preconditions"
adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1
set_scheduling true
ok "scheduling enabled, app is the SMS handler"

info "Holding Send shrinks the circle and opens the calendar"
open_chat_with_draft
center=$(send_center)
if [ -z "$center" ]; then bad "could not locate the Send button"; else
    set -- $center
    adb_ shell logcat -c
    adb_ shell input swipe "$1" "$2" "$1" "$2" 900 >/dev/null 2>&1
    sleep 2
    if adb_ shell logcat -d -s ScheduleHold:D 2>/dev/null | grep -q "shrunk, opening the picker"; then
        ok "the hold played the shrink before opening the picker"
    else
        bad "no shrink was played on hold"
    fi
    if wait_layout_has "Select date" 8; then
        ok "the date picker appeared"
    else
        bad "the date picker did not appear"
    fi
    adb_ shell input keyevent 4 >/dev/null 2>&1; sleep 2
fi

info "With scheduling off the gesture does nothing"
set_scheduling false
open_chat_with_draft
center=$(send_center)
if [ -z "$center" ]; then bad "could not locate the Send button"; else
    set -- $center
    adb_ shell logcat -c
    adb_ shell input swipe "$1" "$2" "$1" "$2" 900 >/dev/null 2>&1
    sleep 2
    if adb_ shell logcat -d -s ScheduleHold:D 2>/dev/null | grep -q "shrunk"; then
        bad "the hold still ran although scheduling is disabled"
    else
        ok "no schedule animation with the setting off"
    fi
    if layout_has "Select date"; then bad "the picker opened anyway"; else ok "no picker either"; fi
fi

echo ""
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
exit $((FAIL > 0))
