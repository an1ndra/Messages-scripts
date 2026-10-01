#!/usr/bin/env bash
# Per-direction swipe actions: each direction is configured independently.
# Verifies the picker persists every action, that "None" makes a direction
# unswipeable rather than merely inert, that a legacy reverse_swipe install
# migrates to the matching pair, and that a swipe is undoable.
source "$(dirname "$0")/env.sh"

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

TEST_NUM="+1555-123-0731"
# The row shows the number grouped as "(555) 123-0731", so match the subscriber
# part only.
QUERY="123-0731"
PREFS="/data/data/$PKG/shared_prefs/messages_settings.xml"

fresh_launch() {
    adb_ shell am force-stop "$PKG"; sleep 1
    adb_ shell am start -n "$ACT" >/dev/null; sleep 4
}

# The app relaunches onto whichever screen it was left on, so navigate
# explicitly rather than assuming a cold start lands on the conversation list.
open_inbox_settings() {
    adb_ shell am force-stop "$PKG"; sleep 1
    adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null; sleep 4
    dump_ui >/dev/null
    tap_text "Inbox settings" >/dev/null || return 1
    sleep 2.5
    dump_ui >/dev/null
}

# The row's action is the text node right after its title.
# The Inbox settings page is scrollable, so a row may be below the fold. Scroll
# until it appears rather than assuming it is on screen.
tap_row() {
    local i
    for i in 0 1 2 3 4 5 6; do
        dump_ui >/dev/null
        center_of "$1" >/dev/null && { tap_text "$1" >/dev/null; return 0; }
        [ "$i" -eq 3 ] && adb_ shell input swipe 540 1700 540 700 300
        sleep 0.7
    done
    echo "could not find row: $1" >&2
    return 1
}

row_action() {
    python3 - "$1" <<'PY'
import re, sys
xml = open('/tmp/opencode/messages-tests/ui.xml').read()
texts = re.findall(r'text="([^"]+)"', xml)
title = sys.argv[1]
if title not in texts:
    sys.exit(1)
i = texts.index(title)
if i + 1 >= len(texts):
    sys.exit(1)
print(texts[i + 1])
PY
}

stored() {
    adb_ shell "run-as $PKG cat $PREFS 2>/dev/null" \
        | grep -oE "name=\"$1\" value=\"[0-9]+\"" | grep -oE '[0-9]+' | tail -1
}

# Rewrite the prefs file to look like a pre-per-direction install, so the
# migration can be exercised. Edits locally and copies back: nested sed quoting
# through `adb shell` is far too easy to get subtly wrong.
write_legacy_prefs() {
    adb_ shell am force-stop "$PKG"; sleep 1
    adb_ shell "run-as $PKG cat $PREFS" 2>/dev/null | python3 -c '
import re, sys
xml = sys.stdin.read()
xml = re.sub(r"\s*<(int|boolean) name=\"swipe_(left|right)_action\"[^>]*/>", "", xml)
xml = re.sub(r"\s*<(int|boolean) name=\"(swipe_actions_enabled|reverse_swipe_enabled)\"[^>]*/>", "", xml)
legacy = ("    <boolean name=\"swipe_actions_enabled\" value=\"true\" />\n"
          "    <boolean name=\"reverse_swipe_enabled\" value=\"true\" />\n")
sys.stdout.write(xml.replace("</map>", legacy + "</map>"))
' > "$TMP/legacy.xml" || return 1
    adb_ shell "run-as $PKG rm -f $PREFS.bak" >/dev/null 2>&1
    adb_ shell "run-as $PKG sh -c 'cat > $PREFS'" < "$TMP/legacy.xml" >/dev/null 2>&1
}

set_stored() {
    adb_ shell "run-as $PKG sh -c 'sed -i \"s|<name>$1</name><long value=\\\"[^\\\"]*\\\" />|<name>$1</name><int value=\\\"$2\\\" />|\" $PREFS'" >/dev/null
    fresh_launch
}

# Pick an action for a direction through the real UI, so the picker, the
# summary and the store are all exercised together.
pick() {
    local title="$1" label="$2"
    open_inbox_settings || { fail "could not open Inbox settings"; return 1; }
    tap_row "$title" || { fail "no '$title' row"; return 1; }
    sleep 2
    dump_ui >/dev/null
    tap_text "$label" >/dev/null || { fail "no '$label' option for $title"; return 1; }
    sleep 2
    dump_ui >/dev/null
}

row_y() {
    local c
    c=$(center_of_contains "$QUERY") || return 1
    awk '{print $2}' <<< "$c"
}

# Deliberate, slow, near-full-width swipes. Slow and long because the gesture
# is gated on travelled distance, not velocity.
#
# These are named for the direction the FINGER travels, matching the "Swipe
# left" / "Swipe right" settings rows. The old helper was called
# swipe_row_right() while moving 950 -> 25, i.e. leftward, and the tests below
# leaned on that to reach the *right* action -- which only held while the app
# had left and right swapped.
swipe_row_leftward() {
    local y="$1"
    adb_ shell input swipe 950 "$y" 25 "$y" 900
}

swipe_row_rightward() {
    local y="$1"
    adb_ shell input swipe 25 "$y" 950 "$y" 900
}

# The Undo snackbar is transient, so poll for it rather than dumping once.
wait_for_undo() {
    local i
    for i in 1 2 3 4 5; do
        sleep 1
        dump_ui >/dev/null
        grep -q "Undo" "$TMP/ui.xml" && return 0
    done
    return 1
}

ensure_row() {
    fresh_launch
    dump_ui >/dev/null
    row_y >/dev/null && return 0
    adb_ emu sms send "$TEST_NUM" "swipe action test" >/dev/null 2>&1
    sleep 3
    fresh_launch
    dump_ui >/dev/null
    row_y >/dev/null
}

info "=== 0. Disposable conversation row ==="
ensure_row || { echo "FAIL: could not prepare test row"; exit 1; }
pass "test row present"

info "=== 0b. The option rows are spaced for a finger, not for a mouse ==="
# The rows used to sit ~25dp apart, so each option's touch target overlapped its
# neighbours and the list read as one crowded block. A choice row wants the
# standard 48dp minimum, measured here as the pitch between option centres.
open_inbox_settings || { fail "could not open Inbox settings"; exit 1; }
tap_row "Swipe left" || { fail "no 'Swipe left' row"; exit 1; }
sleep 2
dump_ui >/dev/null
PITCH=$(python3 - "$TMP/ui.xml" <<'PY'
import re, sys
xml = open(sys.argv[1], encoding="utf-8").read()
labels = ("None", "Archive", "Delete", "Mark read/unread", "Pin", "Block")
ys = {}
for tag in re.findall(r'<node[^>]*>', xml):
    t = re.search(r'text="([^"]*)"', tag)
    b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', tag)
    if t and b and t.group(1) in labels:
        ys[labels.index(t.group(1))] = (int(b.group(2)) + int(b.group(4))) // 2
if len(ys) < len(labels):
    print("")
else:
    gaps = [ys[i + 1] - ys[i] for i in range(len(labels) - 1)]
    dpi = 2.75
    print(f"{min(gaps) / dpi:.1f}")
PY
)
if [ -z "$PITCH" ]; then
    fail "could not read the option row positions"
else
    MIN_DP=$(python3 -c "print(f'{$PITCH:.1f}')")
    ok=$(python3 -c "print(1 if $MIN_DP >= 44 else 0)")
    if [ "$ok" = "1" ]; then
        pass "tightest option gap is ${MIN_DP}dp (>= 44dp)"
    else
        fail "options only ${MIN_DP}dp apart — they overlap as touch targets"
    fi
fi
tap_contains "Close" >/dev/null 2>&1 || adb_ shell input keyevent 4
sleep 1

info "=== 1. Every action is offered and persists for both directions ==="
for pair in "Swipe left:Archive:1" "Swipe left:Delete:2" "Swipe left:Mark read/unread:3" \
            "Swipe left:Pin:4" "Swipe left:Block:5" "Swipe left:None:0" \
            "Swipe right:Archive:1" "Swipe right:Delete:2" "Swipe right:Mark read/unread:3" \
            "Swipe right:Pin:4" "Swipe right:Block:5" "Swipe right:None:0"; do
    title="${pair%%:*}"; rest="${pair#*:}"; label="${rest%%:*}"; want="${rest##*:}"
    key=swipe_left_action; [ "$title" = "Swipe right" ] && key=swipe_right_action
    pick "$title" "$label" >/dev/null
    got=$(row_action "$title")
    stored_v=$(stored "$key")
    if [ "$got" = "$label" ] && [ "$stored_v" = "$want" ]; then
        pass "$title = $label (stored $want)"
    else
        fail "$title = $label: summary '$got', stored '${stored_v:-none}' (want $want)"
    fi
done

info "=== 2. Both directions can differ at the same time ==="
pick "Swipe left" "Pin" >/dev/null
pick "Swipe right" "Block" >/dev/null
left=$(row_action "Swipe left"); right=$(row_action "Swipe right")
if [ "$left" = "Pin" ] && [ "$right" = "Block" ]; then
    pass "left=Pin and right=Block coexist"
else
    fail "left='$left' right='$right' (want Pin / Block)"
fi

info "=== 3. 'None' makes a direction unswipeable, not just inert ==="
# Disable the direction the finger is about to travel in, and leave the other
# one enabled, so a bounce cannot be mistaken for "nothing is wired up".
pick "Swipe left" "None" >/dev/null
pick "Swipe right" "Archive" >/dev/null
fresh_launch
dump_ui >/dev/null
Y=$(row_y) || { fail "test row vanished"; exit 1; }
# A full, slow, leftward swipe. With 'Swipe left' off it must bounce.
swipe_row_leftward "$Y"
sleep 2.5
dump_ui >/dev/null
if center_of_contains "$QUERY" >/dev/null; then
    pass "left swipe disabled: row survived a full leftward swipe"
else
    fail "row disappeared after a leftward swipe while 'Swipe left' was 'None'"
fi

info "=== 3b. Each direction runs the action configured for it ==="
pick "Swipe left" "Pin" >/dev/null
pick "Swipe right" "Block" >/dev/null
fresh_launch
dump_ui >/dev/null
Y=$(row_y) || { fail "test row vanished"; exit 1; }
swipe_row_leftward "$Y"
sleep 2.5
dump_ui >/dev/null
if center_of_contains "$QUERY" >/dev/null; then
    fail "a leftward swipe did not run the 'Swipe left' action"
else
    pass "leftward swipe ran the 'Swipe left' action (Pin, not Block)"
fi

info "=== 4. Undo restores a conversation deleted by swipe ==="
pick "Swipe left" "Delete" >/dev/null
fresh_launch
dump_ui >/dev/null
Y=$(row_y) || { fail "test row vanished"; exit 1; }
swipe_row_leftward "$Y"
if wait_for_undo; then
    pass "delete swipe offered Undo"
    tap_text "Undo" >/dev/null && sleep 2
    fresh_launch
    dump_ui >/dev/null
    if center_of_contains "$QUERY" >/dev/null; then
        pass "Undo restored the conversation"
    else
        fail "Undo did not restore the conversation"
    fi
else
    fail "no Undo snackbar after a delete swipe"
fi

info "=== 5. A legacy reverse_swipe install migrates to the matching pair ==="
# enabled + reverse meant "delete on the left, archive on the right".
write_legacy_prefs || { fail "could not write legacy prefs"; }
fresh_launch
open_inbox_settings
left=$(row_action "Swipe left"); right=$(row_action "Swipe right")
if [ "$left" = "Delete" ] && [ "$right" = "Archive" ]; then
    pass "legacy enabled+reverse migrated to left=Delete, right=Archive"
else
    fail "legacy migration gave left='$left' right='$right' (want Delete / Archive)"
fi

info "=== 6. Migration writes the new keys so it only happens once ==="
lv=$(stored swipe_left_action); rv=$(stored swipe_right_action)
if [ "$lv" = "2" ] && [ "$rv" = "1" ]; then
    pass "new keys written (left=$lv right=$rv)"
else
    fail "new keys not written (left='${lv:-none}' right='${rv:-none}', want 2 / 1)"
fi

echo
if [ "$FAIL" = 0 ]; then
    echo "ALL SWIPE ACTION TESTS PASSED"
else
    echo "SOME SWIPE ACTION TESTS FAILED"
    exit 1
fi
