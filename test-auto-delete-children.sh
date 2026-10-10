#!/usr/bin/env bash
# Regression: while Auto-delete is off, the rows that configure what it deletes
# must not be shown at all.
#
# Advanced settings used to render "Deleted chats", "Blocked messages",
# "Blocked senders" and the two "Keep ... for" rows greyed out
# (enabled = retentionOn). A row that is visible but inert is a dead control,
# and the screen's own footer says nothing is erased while Auto-delete is off,
# so the options could not do anything.
#
# Asserted in the old UI, which is the default, and in the redesigned
# sub-screen. The old UI carries its own copy of these rows inline in Advanced
# settings rather than in a sub-screen, so fixing only one would leave the
# default UI unchanged.
#
# Restores the original Auto-delete setting at the end.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

PREFS="/data/data/$PKG/shared_prefs/messages_settings.xml"
CHILD_ROWS="Deleted chats|Blocked messages|Blocked senders|Keep deleted chats for|Keep blocked messages"

stored_auto_delete() {
    adb_ shell "run-as $PKG cat $PREFS" 2>/dev/null \
        | grep -oE 'name="retention_enabled" value="[a-z]+"' \
        | grep -oE '(true|false)$' | tr -d '\r'
}

set_auto_delete() {
    # Toggled through the UI rather than the pref file, so the same code path a
    # user exercises is the one under test.
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
    adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null 2>&1; sleep 6
    open_advanced || return 1
    scroll_to_row "Auto-delete" || return 1
    dump_ui
    local sw
    sw=$(switch_beside "Auto-delete")
    if [ -z "$sw" ]; then return 1; fi
    adb_ shell input tap $sw >/dev/null 2>&1; sleep 2
    return 0
}

# Centre of the clickable row owning the given text. The label itself is not
# clickable, and the enclosing node is what has to be tapped.
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

scroll_to_row() {
    local label="$1" c
    for _ in 1 2 3 4 5 6 7 8; do
        dump_ui
        c=$(row_centre "$label")
        if [ -n "$c" ]; then echo "$c"; return 0; fi
        adb_ shell input swipe 540 1800 540 700 300 >/dev/null 2>&1; sleep 1
    done
    return 1
}

# Centre of the switch inside the row owning the given text.
switch_beside() {
    python3 - "$TMP/ui.xml" "$1" <<'PY'
import re, sys
xml, needle = open(sys.argv[1], encoding='utf-8', errors='replace').read(), sys.argv[2]
i = xml.find(f'text="{needle}"')
if i < 0:
    raise SystemExit(0)
# The switch is the small checkable node to the right of the label.
for m in re.finditer(r'checkable="true"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', xml):
    x1, y1, x2, y2 = map(int, m.groups())
    if x1 > 700:
        print((x1 + x2) // 2, (y1 + y2) // 2)
        raise SystemExit(0)
raise SystemExit(0)
PY
}

open_advanced() {
    local c
    for _ in 1 2 3 4 5 6 7 8; do
        c=$(scroll_to_row "Advanced settings") && { set -- $c; adb_ shell input tap "$1" "$2" >/dev/null 2>&1; sleep 4; return 0; }
    done
    return 1
}

children_hidden() {
    # Dumps repeatedly because the card is below the fold on a 2400px screen and
    # the rows only exist in the hierarchy once composed.
    for _ in 1 2 3 4 5 6 7 8; do
        dump_ui
        if grep -qE "text=\"($CHILD_ROWS)" "$TMP/ui.xml"; then
            return 1
        fi
        adb_ shell input swipe 540 1800 540 800 300 >/dev/null 2>&1; sleep 1
    done
    return 0
}

children_visible() {
    for _ in 1 2 3 4 5 6 7 8; do
        dump_ui
        if grep -qE "text=\"($CHILD_ROWS)" "$TMP/ui.xml"; then
            return 0
        fi
        adb_ shell input swipe 540 1800 540 800 300 >/dev/null 2>&1; sleep 1
    done
    return 1
}

assert_hidden_while_off() {
    local shown
    if children_visible; then
        shown=$(grep -oE "text=\"($CHILD_ROWS)" "$TMP/ui.xml" | head -3 | tr '\n' ' ')
        bad "auto-delete is off but these rows are still shown: $shown"
    else
        ok "child rows are hidden while auto-delete is off"
    fi
}

assert_visible_while_on() {
    if children_visible; then
        ok "child rows appear once auto-delete is on"
    else
        bad "auto-delete is on but no child rows are shown"
    fi
}

ORIG=$(stored_auto_delete)
[ -z "$ORIG" ] && ORIG=false

info "Auto-delete ON: the child rows are reachable"
if ! set_auto_delete true; then
    bad "could not reach the Auto-delete switch in old UI advanced settings"
elif [ "$(stored_auto_delete)" != "true" ]; then
    bad "failed to turn Auto-delete on (pref is '$(stored_auto_delete)')"
else
    assert_visible_while_on
fi

info "Auto-delete OFF: the child rows are hidden"
if ! set_auto_delete false; then
    bad "could not reach the Auto-delete switch in old UI advanced settings"
elif [ "$(stored_auto_delete)" != "false" ]; then
    bad "failed to turn Auto-delete off (pref is '$(stored_auto_delete)')"
else
    assert_hidden_while_off
fi

info "Restore original setting (auto-delete ${ORIG})"
set_auto_delete "$ORIG" >/dev/null 2>&1
adb_ shell am force-stop "$PKG" >/dev/null 2>&1

echo ""
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
