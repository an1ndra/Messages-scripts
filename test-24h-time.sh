#!/usr/bin/env bash
# Regression: all in-app clock displays must follow the device's 12/24-hour
# setting (android.text.format.DateFormat.is24HourFormat). With the system at
# 24-hour every message timestamp must read "HH:mm" and carry no AM/PM; with the
# system at 12-hour timestamps must read "h:mm AM/PM". Before the fix the times
# were hard-coded to "h:mm a", so the 24-hour assertions failed.
#
# Seeds one inbound SMS in a fixed disposable conversation, flips
# system time_12_24, relaunches (a settings change only lands on a fresh
# process), and inspects the chat dump. Restores the original setting at the end.
source "$(dirname "$0")/env.sh"

NUMBER="+15551230987"
MARKER="clock probe"
PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

ORIG=$(adb_ shell settings get system time_12_24 | tr -d '\r')

# prints "H24 n" / "AMPM n" for the current dump
scan_clock() {
    python3 - "$TMP/ui.xml" <<'PY'
import re, sys
d = open(sys.argv[1], encoding='utf-8').read()
texts = re.findall(r'text="([^"]*)"', d)
h24 = re.compile(r'(?<![0-9])([01][0-9]|2[0-3]):[0-5][0-9](?![0-9])(?!\s?[AP]M)')
ampm = re.compile(r'(?<![0-9])(0?[1-9]|1[0-2]):[0-5][0-9]\s?[AP]M')
print("H24", "1" if any(h24.search(t) for t in texts) else "0")
print("AMPM", "1" if any(ampm.search(t) for t in texts) else "0")
PY
}

set_clock() {
    adb_ shell settings put system time_12_24 "$1" >/dev/null 2>&1
    adb_ shell am force-stop "$PKG"; sleep 1
    adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 8
}

open_chat() {
    local c i
    for i in 1 2 3; do
        c=$(center_of_contains "$MARKER") && break
        sleep 2
    done
    [ -n "$c" ] || { bad "could not find seeded conversation"; return 1; }
    adb_ shell input tap $c; sleep 2
    dump_ui && grep -q 'class="android.widget.EditText"' "$TMP/ui.xml" \
        || { bad "did not land in the chat"; return 1; }
    return 0
}

assert_clock() {
    local want="$1" h24 ampm
    dump_ui || { bad "uiautomator dump failed"; return; }
    read -r _ h24 <<< "$(scan_clock | grep '^H24')"
    read -r _ ampm <<< "$(scan_clock | grep '^AMPM')"
    echo "  [state] want=$want h24=$h24 ampm=$ampm"
    if [ "$want" = "24" ]; then
        [ "$h24" = "1" ] && ok "24-hour system -> HH:mm timestamp shown" \
                         || bad "24-hour system -> no HH:mm timestamp"
        [ "$ampm" = "0" ] && ok "24-hour system -> no AM/PM anywhere" \
                          || bad "24-hour system -> AM/PM still present"
    else
        [ "$ampm" = "1" ] && ok "12-hour system -> h:mm AM/PM timestamp shown" \
                          || bad "12-hour system -> no AM/PM timestamp"
        [ "$h24" = "0" ] && ok "12-hour system -> no bare 24-hour timestamp" \
                         || bad "12-hour system -> a 24-hour timestamp leaked in"
    fi
}

info "Seed a probe message"
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 8
adb_ emu sms send "$NUMBER" "$MARKER" >/dev/null 2>&1
sleep 3

info "System clock = 24-hour"
set_clock 24
open_chat && assert_clock 24
adb_ shell input keyevent 4 >/dev/null 2>&1; sleep 1

info "System clock = 12-hour"
set_clock 12
open_chat && assert_clock 12
adb_ shell input keyevent 4 >/dev/null 2>&1; sleep 1

info "Restore original setting (${ORIG:-unset})"
if [ -z "$ORIG" ] || [ "$ORIG" = "null" ]; then
    adb_ shell settings delete system time_12_24 >/dev/null 2>&1
else
    adb_ shell settings put system time_12_24 "$ORIG" >/dev/null 2>&1
fi

echo ""
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
