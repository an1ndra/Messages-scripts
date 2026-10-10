#!/bin/bash
# Verify the MMS support row is visible in the legacy Advanced settings.
set -euo pipefail

ADB=~/android/platform-tools/adb
SERIAL="${SERIAL:-emulator-5554}"
PKG="com.anindra.messages"
ACT="$PKG/.MainActivity"

dump_ui() {
    "$ADB" -s "$SERIAL" shell uiautomator dump /sdcard/ui.xml 2>/dev/null
    "$ADB" -s "$SERIAL" shell cat /sdcard/ui.xml 2>/dev/null
}

scroll_down() {
    "$ADB" -s "$SERIAL" shell input swipe 540 1800 540 400 300
    sleep 0.5
}

# Finds the centre of a node whose text is exactly $1 and taps it.
# Returns 1 if not found in the current dump.
tap_text() {
    local text="$1"
    local xml
    xml=$(dump_ui)
    local bounds
    bounds=$(echo "$xml" | tr '>' '\n' | grep "text=\"$text\"" | grep -oP 'bounds="\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]"' | head -1 | grep -oP '\d+')
    if [[ -z "$bounds" ]]; then
        return 1
    fi
    local coords=($bounds)
    if [[ ${#coords[@]} -ne 4 ]]; then
        return 1
    fi
    local cx=$(( (${coords[0]} + ${coords[2]}) / 2 ))
    local cy=$(( (${coords[1]} + ${coords[3]}) / 2 ))
    "$ADB" -s "$SERIAL" shell input tap "$cx" "$cy"
    sleep 1
    return 0
}

# Scrolls down up to 5 times looking for $1, then taps it.
tap_text_scrolled() {
    local text="$1"
    for _ in 1 2 3 4 5; do
        if tap_text "$text"; then
            return 0
        fi
        scroll_down
    done
    echo "[FAIL] could not find text \"$text\" after scrolling"
    return 1
}

# Scrolls down up to 5 times looking for $1, then succeeds.
assert_text_scrolled() {
    local text="$1"
    for _ in 1 2 3 4 5; do
        local xml
        xml=$(dump_ui)
        if echo "$xml" | grep -q "text=\"$text\""; then
            echo "[PASS] found \"$text\""
            return 0
        fi
        scroll_down
    done
    echo "[FAIL] \"$text\" not found in UI dump after scrolling"
    return 1
}

echo "=== Navigate to legacy Advanced settings ==="

"$ADB" -s "$SERIAL" shell am force-stop "$PKG"
sleep 1
"$ADB" -s "$SERIAL" shell am start -n "$ACT" --ez open_settings true
sleep 3

tap_text_scrolled "Advanced settings" || tap_text_scrolled "Advanced"
sleep 1

echo "=== Check MMS support row ==="

assert_text_scrolled "MMS support"

echo "=== All checks passed ==="
