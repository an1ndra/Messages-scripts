#!/usr/bin/env bash
# The inbox offers a shortcut back to the top once the list is scrolled far
# enough that scrolling back is a chore, and takes it away at the top where it
# would only sit on the conversations.
#
# What it asserts:
#   * scrolled a few screens down, the "Back to top" button is there,
#   * tapping it returns the list to the top,
#   * and the button is gone again once it is,
#   * and Diagnostics states that it enters from the bottom edge, not the side.
#
# Run: scripts/test-back-to-top.sh
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

BACK=$(res_string conversations_back_to_top)
# An empty label would match every node on screen, so a build without the
# button has to fail here rather than "find" it everywhere.
if [ -z "$BACK" ]; then
    echo "  [FAIL] this build has no '$BACK' string: the button is missing"
    echo; echo "  PASS=0 FAIL=1"; echo "=== FAILED ==="; exit 1
fi
PREFIX="+15559998"

dbq() { adb_su "run-as $PKG sqlite3 databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r'; }

# A dump that failed must not leave the previous one behind: every ui_has would
# then answer about the last screen, which is how this script once read the
# button as present at the top of the list.
fresh_dump() {
    rm -f "$TMP/ui.xml" "$TMP/ui.decoded.xml"
    for _ in 1 2 3; do
        dump_ui >/dev/null 2>&1 && [ -s "$TMP/ui.xml" ] && return 0
        sleep 0.5
    done
    return 1
}
cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    dbq "DELETE FROM conversations WHERE address LIKE '$PREFIX%';" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# The button appears past a screenful or two of rows, so the list has to be
# long enough to scroll that far: the AVD's own 12 conversations are not.
dbq "DELETE FROM conversations WHERE address LIKE '$PREFIX%';" >/dev/null 2>&1
values=""
NOW_MS=$(( $(date +%s) * 1000 ))
for i in $(seq 0 39); do
    addr="$PREFIX$(printf '%02d' "$i")"
    # Newer than anything already in the inbox, so "Scroll 0" is the row the
    # list returns to and the check at the end names something real.
    ts=$((NOW_MS + (40 - i) * 60000))
    values="$values${values:+,}('$addr','Scroll $i','scroll seed $i',$ts,0,0,0,'personal')"
done
dbq "INSERT INTO conversations (address,name,snippet,timestamp,archived,deleted_at,pinned,category) VALUES $values;" >/dev/null 2>&1
seeded=$(dbq "SELECT COUNT(*) FROM conversations WHERE address LIKE '$PREFIX%';")
if [ "$seeded" = "40" ]; then
    ok "seeded 40 conversations to scroll through"
else
    bad "could only seed ${seeded:-0} conversations"
    echo; echo "  PASS=$PASS FAIL=$FAIL"; exit 1
fi

adb_ shell am force-stop "$PKG" >/dev/null 2>&1
adb_ shell am start -W -n "$ACT" >/dev/null 2>&1
sleep 3
fresh_dump || true
if ui_has "$BACK"; then
    bad "the button is on screen before the list is scrolled"
else
    ok "no button at the top of the list"
fi

# Three flicks down: the rows pass the threshold and the list stays put.
for _ in 1 2 3; do
    adb_ shell input swipe 540 1800 540 500 250 >/dev/null 2>&1
    sleep 0.6
done
sleep 1
fresh_dump || true
if ui_has "$BACK"; then
    ok "scrolled down, the '$BACK' button is there"
else
    bad "no '$BACK' button after scrolling down"
fi

# It belongs in the middle of the bottom edge: the start-chat button owns the
# corner, and a shortcut tucked beside it is one more thing to aim at.
centre=$(python3 - "$TMP/ui.xml" "$BACK" <<'PY'
import re, sys
xml = open(sys.argv[1]).read()
want = sys.argv[2]
for m in re.finditer(r'<node[^>]*content-desc="' + re.escape(want) + r'"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', xml):
    x1, y1, x2, y2 = map(int, m.groups())
    print((x1 + x2) // 2)
    sys.exit(0)
sys.exit(1)
PY
)
width=$(adb_ shell wm size | tr -d '\r' | sed -E 's/.*: ([0-9]+)x([0-9]+)/\1/')
if [ -n "$centre" ] && [ -n "$width" ]; then
    off=$(( centre - width / 2 )); [ "$off" -lt 0 ] && off=$(( -off ))
    if [ "$off" -le 40 ]; then
        ok "the button sits in the middle of the bottom edge"
    else
        bad "the button is ${off}px off the middle of the screen"
    fi
else
    bad "could not measure the button's position"
fi

at=$(center_of "$BACK" || true)
if [ -n "$at" ]; then
    adb_ shell input tap ${at% *} ${at#* }; sleep 2
    fresh_dump || true
    if ui_has "$BACK"; then
        bad "the button stayed after tapping it (the list did not reach the top)"
    else
        ok "tapping it returns the list to the top"
    fi
    # The first row is what proves the list actually moved, not just the button.
    if fresh_dump && grep -q "Scroll 0" "$TMP/ui.decoded.xml" 2>/dev/null; then
        ok "the first conversation is on screen again"
    else
        bad "the list is not back at its first row"
    fi
fi

# The 200 ms entry animation is gone before a uiautomator dump returns, so the
# direction is read from the app's own Diagnostics report. The line is printed
# from the same constant the button's enter transition uses, not re-derived.
row_centre() {
    python3 - "$TMP/ui.xml" "$1" <<'PY'
import re, sys
xml, needle = open(sys.argv[1], encoding='utf-8', errors='replace').read(), sys.argv[2]
i = xml.find(f'text="{needle}"')
if i < 0:
    raise SystemExit(0)
hits = re.findall(r'clickable="true"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', xml[:i])
if not hits:
    raise SystemExit(0)
x1, y1, x2, y2 = map(int, hits[-1])
print((x1 + x2) // 2, (y1 + y2) // 2)
PY
}

scroll_to_and_tap() {
    local label="$1" c
    for _ in 1 2 3 4 5 6 7 8; do
        dump_ui >/dev/null 2>&1 || true
        c=$(row_centre "$label")
        if [ -n "$c" ]; then
            set -- $c
            adb_ shell input tap "$1" "$2" >/dev/null 2>&1
            return 0
        fi
        adb_ shell input swipe 540 1800 540 700 300 >/dev/null 2>&1; sleep 1
    done
    return 1
}

info "Diagnostics states the edge the shortcut enters from"
adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null 2>&1; sleep 3
if scroll_to_and_tap "Advanced settings"; then
    sleep 3
    if scroll_to_and_tap "Diagnostics"; then
        sleep 5
        found=0
        for _ in 1 2 3 4; do
            fresh_dump || true
            if grep -q "Back-to-top entry: from bottom" "$TMP/ui.xml" 2>/dev/null; then
                found=1; break
            fi
            adb_ shell input swipe 540 1800 540 800 300 >/dev/null 2>&1; sleep 1
        done
        if [ "$found" = 1 ]; then
            ok "Diagnostics says the button enters from the bottom edge"
        else
            bad "Diagnostics does not report a bottom-edge entry"
        fi
    else
        bad "could not open Diagnostics from Advanced settings"
    fi
else
    bad "could not open Advanced settings from Settings"
fi

echo
echo "  PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && echo "=== OK ===" || echo "=== FAILED ==="
exit $((FAIL > 0))
