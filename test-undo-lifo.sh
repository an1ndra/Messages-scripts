#!/usr/bin/env bash
# Issue #374 regression: several swipe actions in a row must undo LIFO.
#
# Material's SnackbarHostState queues showSnackbar callers first-in-first-out, so
# with one showSnackbar per swipe the snackbar on screen belonged to the OLDEST
# archived chat and its Undo restored that one. Here two chats are archived back
# to back; tapping Undo once must bring back the chat archived LAST.
#
# Run: scripts/test-undo-lifo.sh
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh

FAIL=0; PASS=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }

# The old row is archived first, the newer one second; a single Undo must
# return only the newer one. Subscriber part only: rows render numbers grouped.
NUM_OLD="+15551230741"
NUM_NEW="+15551230742"
QUERY_OLD="123-0741"
QUERY_NEW="123-0742"
PREFS="/data/data/$PKG/shared_prefs/messages_settings.xml"

fresh_launch() {
    adb_ shell am force-stop "$PKG"; sleep 1
    adb_ shell am start -n "$ACT" >/dev/null; sleep 4
}

dbq() { printf '%s' "$1" | adb_ shell "run-as $PKG sqlite3 databases/messages.db" 2>/dev/null | tr -d '\r\n'; }

# Reading state costs a fast sqlite query; uiautomator dumps take seconds and a
# negative "the row is gone" check costs three of them, which outlives the
# 10-second snackbar and hides the very thing this script tests.
archived_of() { dbq "SELECT archived FROM conversations WHERE address='$1';"; }

drop_test_rows() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    dbq "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address IN ('$NUM_OLD','$NUM_NEW'));" >/dev/null
    dbq "DELETE FROM conversations WHERE address IN ('$NUM_OLD','$NUM_NEW');" >/dev/null
    adb_ shell "su 0 content delete --uri content://sms --where \"address='$NUM_OLD' OR address='$NUM_NEW'\"" >/dev/null 2>&1 || true
}

# Both directions archive, so the direction the finger travels cannot make this
# script pass or fail for the wrong reason. Archiving stays enabled.
write_prefs() {
    local left="$1" right="$2"
    adb_ shell am force-stop "$PKG"; sleep 1
    adb_ shell "run-as $PKG cat $PREFS" > "$TMP/prefs.xml" 2>/dev/null || true
    LEFT="$left" RIGHT="$right" python3 - "$TMP/prefs.xml" <<'PY' > "$TMP/prefs.new"
import os, re, sys
try:
    xml = open(sys.argv[1], encoding="utf-8").read()
except FileNotFoundError:
    xml = ""
if "</map>" not in xml:
    xml = '<?xml version="1.0" encoding="utf-8" standalone="yes" ?>\n<map>\n</map>\n'
want = {
    "swipe_left_action": ("int", int(os.environ["LEFT"])),
    "swipe_right_action": ("int", int(os.environ["RIGHT"])),
    "swipe_actions_enabled": ("boolean", True),
    "archiving_enabled": ("boolean", True),
}
for key, (kind, value) in want.items():
    if kind == "boolean":
        line = '<boolean name="%s" value="%s" />' % (key, "true" if value else "false")
    else:
        line = '<int name="%s" value="%d" />' % (key, value)
    pat = re.compile(r'<%s name="%s"[^>]*/>' % ("boolean" if kind == "boolean" else "int", key))
    if pat.search(xml):
        xml = pat.sub(line, xml)
    else:
        xml = xml.replace("</map>", "    " + line + "\n</map>")
sys.stdout.write(xml)
PY
    adb_ shell "run-as $PKG sh -c 'cat > $PREFS'" < "$TMP/prefs.new" >/dev/null 2>&1
}

row_y() {
    local c
    c=$(center_of_contains "$1") || return 1
    awk '{print $2}' <<< "$c"
}

# Long and slow enough that the row's dismiss threshold is certainly crossed.
swipe_archive() {
    adb_ shell input swipe 80 "$1" 1000 "$1" 400
}

# Tap the Undo action from the hierarchy the caller just dumped, without paying
# for another dump (the snackbar only lives 10 seconds).
tap_undo_from_dump() {
    local b
    b=$(grep -oE 'text="Undo"[^>]*bounds="\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]"' "$TMP/ui.xml" | head -1 \
        | grep -oE '\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]')
    [ -z "$b" ] && return 1
    local x1 y1 x2 y2
    x1=$(sed -E 's/\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]/\1/' <<< "$b")
    y1=$(sed -E 's/\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]/\2/' <<< "$b")
    x2=$(sed -E 's/\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]/\3/' <<< "$b")
    y2=$(sed -E 's/\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]/\4/' <<< "$b")
    adb_ shell input tap $(( (x1 + x2) / 2 )) $(( (y1 + y2) / 2 ))
}

cleanup() {
    write_prefs 1 2        # ARCHIVE left, DELETE right: the shipped defaults
    drop_test_rows
    adb_ shell am start -n "$ACT" >/dev/null 2>&1 || true
}
trap cleanup EXIT

info "0. Seed two fresh conversations and force both swipes to archive"
drop_test_rows
write_prefs 1 1
# The app must be running to receive the injected SMS: a force-stopped app gets
# no broadcast, so the message never reaches the provider.
fresh_launch
adb_ emu sms send "$NUM_OLD" "undo lifo seed old" >/dev/null 2>&1
sleep 2
adb_ emu sms send "$NUM_NEW" "undo lifo seed new" >/dev/null 2>&1
sleep 2
if ! wait_for_text "$QUERY_OLD" 8; then
    fresh_launch
    wait_for_text "$QUERY_OLD" 15 || { fail "old test conversation never appeared"; exit 1; }
fi
wait_for_text "$QUERY_NEW" 15 || { fail "new test conversation never appeared"; exit 1; }
pass "both test conversations are in the inbox"

info "1. Archive the old chat, then the new one"
Y_OLD=$(row_y "$QUERY_OLD") || { fail "no row for $QUERY_OLD"; exit 1; }
swipe_archive "$Y_OLD"
sleep 3
[ "$(archived_of "$NUM_OLD")" = "1" ] && pass "old chat archived" || fail "the old chat was not archived"

Y_NEW=$(row_y "$QUERY_NEW") || { fail "no row for $QUERY_NEW"; exit 1; }
swipe_archive "$Y_NEW"
sleep 1
[ "$(archived_of "$NUM_NEW")" = "1" ] && pass "new chat archived" || fail "the new chat was not archived"

info "2. One Undo returns the LAST archived chat"
dump_ui || { fail "could not dump the UI after both swipes"; exit 1; }
if grep -q 'text="Undo"' "$TMP/ui.xml"; then
    pass "Undo is offered after consecutive swipes"
else
    fail "no Undo snackbar after two swipes"
    exit 1
fi
tap_undo_from_dump || { fail "could not tap Undo"; exit 1; }
sleep 2

if [ "$(archived_of "$NUM_NEW")" = "0" ]; then
    pass "Undo restored the most recently archived chat (LIFO)"
else
    fail "Undo did not restore the most recently archived chat"
fi
if [ "$(archived_of "$NUM_OLD")" = "1" ]; then
    pass "the older archived chat stays archived after one Undo"
else
    fail "the first archived chat came back from the first Undo (FIFO, issue #374)"
fi

info "3. The undo stack keeps walking back"
dump_ui || { fail "could not dump the UI after the first Undo"; exit 1; }
if grep -q 'text="Undo"' "$TMP/ui.xml"; then
    pass "the remaining action still offers Undo"
else
    fail "the older action lost its Undo when the snackbar was replaced"
fi
tap_undo_from_dump || { fail "could not tap the second Undo"; exit 1; }
sleep 2
if [ "$(archived_of "$NUM_OLD")" = "0" ]; then
    pass "a second Undo restored the older chat"
else
    fail "the older archived chat is unrecoverable after its snackbar was replaced"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0))
