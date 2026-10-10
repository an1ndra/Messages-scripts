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

# Dump the current UI hierarchy to $TMP/ui.xml. uiautomator segfaults
# intermittently on this AVD; when it does, the remote file is left stale and a
# naive pull reads the previous screen. Delete the file first, confirm the dump
# actually succeeded, and retry.
dump_ui() {
    local try
    for try in 1 2 3; do
        adb_ shell rm -f /sdcard/ui.xml >/dev/null 2>&1
        if adb_ shell uiautomator dump /sdcard/ui.xml 2>/dev/null | grep -q "dumped to"; then
            rm -f "$TMP/ui.xml"
            adb_ pull /sdcard/ui.xml "$TMP/ui.xml" >/dev/null 2>&1
            [ -s "$TMP/ui.xml" ] || continue
            ui_decode
            return 0
        fi
        sleep 1
    done
    return 1
}

# uiautomator escapes emoji as numeric character references (&#128077;), so a
# search for the literal emoji never matches. Decode a copy for the matchers;
# named entities (&amp;, &quot;) are left alone so they cannot break the
# text="..." boundaries.
ui_decode() {
    python3 - "$TMP/ui.xml" "$TMP/ui.decoded.xml" <<'PY'
import re, sys
data = open(sys.argv[1], encoding="utf-8", errors="replace").read()
data = re.sub(r"&#(\d+);|&#x([0-9A-Fa-f]+);",
              lambda m: chr(int(m.group(1)) if m.group(1) else int(m.group(2), 16)),
              data)
open(sys.argv[2], "w", encoding="utf-8").write(data)
PY
}

# Split the dumped hierarchy into individual <node> tags — some builds pack
# many nodes onto one line, so line-based greps over ui.xml are unreliable.
ui_tags() { grep -oE '<node[^>]*>' "$TMP/ui.xml"; }

# The conversation list shows a loading skeleton while the startup sync settles,
# so a single dump after a fixed sleep races it and the row is simply absent.
# Poll instead. $1 = text to wait for, $2 = attempts (default 10).
# Uses grep -c, never grep -q: -q exits on first match and kills the upstream
# pipeline under `set -o pipefail`. Matched literally (-F), so a group title like
# "Alex +Carlos" is not read as a regex.
wait_for_text() {
    local target="$1" tries="${2:-10}" i
    for i in $(seq 1 "$tries"); do
        dump_ui >/dev/null 2>&1 || true
        if grep -cF "$target" "$TMP/ui.xml" >/dev/null 2>&1; then
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
            "$TMP/ui.decoded.xml" 2>/dev/null | head -1 | grep -oE '\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]' | head -1)
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

# Tap a node whose text merely CONTAINS the given string. Needed wherever a row
# renders a value the test cannot predict exactly, e.g. a phone number is shown
# grouped ("(555) 888-7777") rather than as stored ("+15558887777").
tap_contains() {
    local c
    c=$(center_of_contains "$1") || { echo "[tap] contains '$1' not found"; return 1; }
    adb_ shell input tap $c
    echo "[tap] contains '$1' at ($c)"
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
                "$TMP/ui.decoded.xml" 2>/dev/null | head -1 \
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

# True when the current dump contains $1 in any node's text/content-desc.
# Matches against the decoded copy so emoji literals work.
ui_has() {
    dump_ui || return 1
    grep -qF -- "$1" "$TMP/ui.decoded.xml"
}

# Center "x y" of the topmost node whose text/content-desc contains $1. Needed
# when the same label appears in two places (e.g. an emoji in the picker bar and
# again in a reaction badge) and only the one on top is the control.
center_of_top() {
    local query="$1" i out
    for i in 1 2 3; do
        dump_ui || { sleep 1; continue; }
        out=$(python3 - "$TMP/ui.decoded.xml" "$query" <<'PY'
import re, sys, xml.etree.ElementTree as ET
try:
    root = ET.parse(sys.argv[1]).getroot()
except Exception:
    sys.exit(1)
query = sys.argv[2]
best = None
for n in root.iter("node"):
    text = n.get("text") or n.get("content-desc") or ""
    if query not in text:
        continue
    m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", n.get("bounds", ""))
    if not m:
        continue
    x = (int(m.group(1)) + int(m.group(3))) // 2
    y = (int(m.group(2)) + int(m.group(4))) // 2
    if best is None or y < best[1]:
        best = (x, y)
if best:
    print(best[0], best[1])
else:
    sys.exit(1)
PY
) && [ -n "$out" ] && { echo "$out"; return 0; }
        sleep 1
    done
    return 1
}

info() { echo -e "\n=== $* ==="; }

# ---------------------------------------------------------------------------
# Android CLI helpers.
#
# Newer regression scripts prefer the `android` CLI over the uiautomator dump
# helpers above: `android layout` returns JSON with text/content-desc, a
# ready-made `center`, and an `off-screen` flag, so a query can tell "the row is
# here" from "the row exists but must be scrolled to". It also does not crash
# the way uiautomator intermittently does on this AVD.
ANDROID_CLI="${ANDROID_CLI:-android}"

# Dump the current layout (all windows, hidden nodes included) to $TMP/layout.json.
layout_json() {
    "$ANDROID_CLI" layout --full --device "$ANDROID_SERIAL" > "$TMP/layout.json" 2>/dev/null
    [ -s "$TMP/layout.json" ]
}

# Center "x y" of the first *on-screen* node whose text or content-desc contains
# $1. Off-screen nodes are skipped so callers can scroll until it appears.
layout_center() {
    local q="$1" i c
    for i in 1 2 3; do
        layout_json || { sleep 1; continue; }
        c=$(python3 - "$TMP/layout.json" "$q" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
q = sys.argv[2]
found = [None]
def walk(node):
    if found[0] is not None:
        return
    if isinstance(node, list):
        for child in node:
            walk(child)
    elif isinstance(node, dict):
        if not node.get("off-screen"):
            for key in ("text", "content-desc", "contentDesc"):
                value = node.get(key)
                if isinstance(value, str) and q in value and node.get("center"):
                    found[0] = node["center"]
                    return
        for key in ("content", "children"):
            for child in (node.get(key) or []):
                walk(child)
walk(data)
if found[0]:
    x, y = found[0].strip("[]").split(",")
    print(f"{x} {y}")
else:
    sys.exit(1)
PY
        ) && [ -n "$c" ] && { echo "$c"; return 0; }
        sleep 1
    done
    return 1
}

# True when the current layout (all windows) contains $1 in text/content-desc.
layout_has() {
    layout_json && python3 - "$TMP/layout.json" "$1" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
q = sys.argv[2]
def walk(node):
    if isinstance(node, list):
        return any(walk(c) for c in node)
    if isinstance(node, dict):
        for key in ("text", "content-desc", "contentDesc"):
            if isinstance(node.get(key), str) and q in node[key]:
                return True
        return any(walk(c) for key in ("content", "children") for c in (node.get(key) or []))
    return False
sys.exit(0 if walk(data) else 1)
PY
}

# Tap the center of the first on-screen node containing $1.
tap_layout() {
    local c
    c=$(layout_center "$1") || { echo "[tap] '$1' not found"; return 1; }
    adb_ shell input tap $c
    echo "[tap] '$1' at ($c)"
}

# Swipe the page up until $1 is on-screen. Settings lists are tall; a row that
# is present but off-screen cannot be tapped.
scroll_to_layout() {
    local q="$1" i
    for i in $(seq 1 6); do
        layout_center "$q" >/dev/null 2>&1 && return 0
        adb_ shell input swipe 540 1800 540 700 400
        sleep 1
    done
    return 1
}

# Exact-text variant: "Save" must not match the "Save to" backup-location row.
layout_center_exact() {
    local q="$1" i c
    for i in 1 2 3; do
        layout_json || { sleep 1; continue; }
        c=$(python3 - "$TMP/layout.json" "$q" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
q = sys.argv[2]
found = [None]
def walk(node):
    if found[0] is not None:
        return
    if isinstance(node, list):
        for child in node:
            walk(child)
    elif isinstance(node, dict):
        if not node.get("off-screen"):
            for key in ("text", "content-desc", "contentDesc"):
                if node.get(key) == q and node.get("center"):
                    found[0] = node["center"]
                    return
        for key in ("content", "children"):
            for child in (node.get(key) or []):
                walk(child)
walk(data)
if found[0]:
    x, y = found[0].strip("[]").split(",")
    print(f"{x} {y}")
else:
    sys.exit(1)
PY
        ) && [ -n "$c" ] && { echo "$c"; return 0; }
        sleep 1
    done
    return 1
}

tap_layout_exact() {
    local c
    c=$(layout_center_exact "$1") || { echo "[tap] '$1' (exact) not found"; return 1; }
    adb_ shell input tap $c
    echo "[tap] '$1' at ($c)"
}

# DocumentsUI is a separate package, so force-stopping the app under test does
# not dismiss a picker a previous failed run left on top.
close_documents_ui() {
    adb_ shell am force-stop com.android.documentsui >/dev/null 2>&1
    adb_ shell am force-stop com.google.android.documentsui >/dev/null 2>&1
}

