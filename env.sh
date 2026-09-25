#!/usr/bin/env bash
# Shared environment for Messages UI test scripts.
# Source this file from other scripts: source "$(dirname "$0")/env.sh"

export ANDROID_SERIAL=${ANDROID_SERIAL:-emulator-5554}
ADB="${ADB:-$HOME/android/platform-tools/adb}"
PKG="${PKG:-com.anindra.messages}"
ACT="$PKG/.MainActivity"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHOTS_DIR="${SHOTS_DIR:-$PROJECT_DIR/screenshots}"
TMP="/tmp/opencode/messages-tests"
mkdir -p "$SHOTS_DIR" "$TMP"

adb_() { "$ADB" -s "$ANDROID_SERIAL" "$@"; }

# Take a screenshot into screenshots/<name>.png
shot() {
    adb_ exec-out screencap -p > "$SHOTS_DIR/$1.png"
    echo "[screenshot] $SHOTS_DIR/$1.png"
}

# Type text into the focused field (handles spaces)
type_text() {
    local t="${1// /%s}"
    adb_ shell input text "$t"
}

# Dump the current UI hierarchy to $TMP/ui.xml
dump_ui() {
    adb_ shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1
    adb_ pull /sdcard/ui.xml "$TMP/ui.xml" >/dev/null 2>&1
    [ -f "$TMP/ui.xml" ]
}

# Split the dumped hierarchy into individual <node> tags — some builds pack
# many nodes onto one line, so line-based greps over ui.xml are unreliable.
ui_tags() { grep -oE '<node[^>]*>' "$TMP/ui.xml"; }

# The conversation list shows a loading skeleton while the startup sync settles,
# so a single dump after a fixed sleep races it and the row is simply absent.
# Poll instead. $1 = text to wait for, $2 = attempts (default 10).
# Uses grep -c, never grep -q: -q exits on first match and kills the upstream
# pipeline under `set -o pipefail`.
wait_for_text() {
    local target="$1" tries="${2:-10}" i
    for i in $(seq 1 "$tries"); do
        dump_ui >/dev/null 2>&1 || true
        if grep -c "$target" "$TMP/ui.xml" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# Strip the Unicode bidi isolates (U+2066 LRI … U+2069 PDI) that BidiText.ltr()
# wraps values in, so an assertion can match the visible text.
strip_isolates() {
    python3 -c 'import sys; s=sys.stdin.read(); print(s.replace("⁦","").replace("⁩",""), end="")'
}

# Escape ERE metacharacters so queries like "+1-555-333-4444" match literally.
re_escape() {
    python3 -c 'import re, sys; sys.stdout.write(re.escape(sys.stdin.read().rstrip("\n")))' <<< "$1"
}

# Find node by text/content-desc and print "x y" of its center, or fail.
# Usage: center_of "Start chat"
center_of() {
    dump_ui || return 1
    local q b
    q=$(re_escape "$1")
    b=$(grep -oE "(text|content-desc)=\"$q\"[^>]*bounds=\"\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]\"" \
            "$TMP/ui.xml" 2>/dev/null | head -1 | grep -oE '\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]' | head -1)
    [ -z "$b" ] && return 1
    local x1 y1 x2 y2
    x1=$(sed -E 's/\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]/\1/' <<< "$b")
    y1=$(sed -E 's/\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]/\2/' <<< "$b")
    x2=$(sed -E 's/\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]/\3/' <<< "$b")
    y2=$(sed -E 's/\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]/\4/' <<< "$b")
    echo "$(( (x1 + x2) / 2 )) $(( (y1 + y2) / 2 ))"
}

# Tap the center of a node matching text/content-desc. Returns 0 on success.
tap_text() {
    local c
    c=$(center_of "$1") || { echo "[tap] '$1' not found"; return 1; }
    adb_ shell input tap $c
    echo "[tap] '$1' at ($c)"
}

# Tap the switch (right side) near a text label. Used for toggle rows.
tap_switch_near() {
    local c
    c=$(center_of "$1") || { echo "[tap] '$1' not found"; return 1; }
    local y=${c#* }
    adb_ shell input tap 937 "$y"
    echo "[tap] switch near '$1' at (937 $y)"
}

# Tap the chat input field (EditText) wherever it currently is.
tap_edittext() {
    dump_ui || return 1
    local b
    b=$(grep -oE 'class="android.widget.EditText"[^>]*bounds="\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]"' \
            "$TMP/ui.xml" 2>/dev/null | head -1 | grep -oE '\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]' | head -1)
    [ -z "$b" ] && { echo "[tap] no EditText found"; return 1; }
    local x1 y1 x2 y2
    x1=$(sed -E 's/\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]/\1/' <<< "$b")
    y1=$(sed -E 's/\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]/\2/' <<< "$b")
    x2=$(sed -E 's/\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]/\3/' <<< "$b")
    y2=$(sed -E 's/\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]/\4/' <<< "$b")
    adb_ shell input tap $(( (x1 + x2) / 2 )) $(( (y1 + y2) / 2 ))
}

# Center "X Y" of first node whose text contains $1 (retrying dump 3x)
center_of_contains() {
    local query="$1" b i x1 y1 x2 y2
    local q; q=$(re_escape "$query")
    for i in 1 2 3; do
        dump_ui || { sleep 1; continue; }
        b=$(grep -oE "(text|content-desc)=\"[^\"]*$q[^\"]*\"[^>]*bounds=\"\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]\"" \
                "$TMP/ui.xml" 2>/dev/null | head -1 \
            | grep -oE '\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]' | tail -1)
        if [ -n "$b" ]; then
            x1=$(sed -E 's/\[([0-9]+),([0-9]+)\].*/\1/' <<< "$b")
            y1=$(sed -E 's/\[[0-9]+,([0-9]+)\].*/\1/' <<< "$b")
            x2=$(sed -E 's/.*\]\[([0-9]+),[0-9]+\]/\1/' <<< "$b")
            y2=$(sed -E 's/.*\]\[[0-9]+,([0-9]+)\]/\1/' <<< "$b")
            echo "$(( (x1 + x2) / 2 )) $(( (y1 + y2) / 2 ))"
            return 0
        fi
        sleep 1
    done
    return 1
}

info() { echo -e "\n=== $* ==="; }
