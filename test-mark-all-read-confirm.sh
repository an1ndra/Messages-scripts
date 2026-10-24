#!/usr/bin/env bash
# Regression (#355): "Mark all as read" must ask before it wipes every unread
# badge, in both settings UIs.
#
# It sits one tap below "Notifications", it is irreversible, and a mis-tap used
# to clear every conversation's badge with only a toast to say so. Expected
# behaviour now:
#   tap row      -> a confirmation dialog appears, nothing marked read
#   Cancel       -> dialog closes, the unread badges are untouched
#   confirm      -> everything is marked read
#
# Fails on the pre-fix build: the row marks read immediately, so no dialog ever
# appears and the unread count is 0 before any confirmation.
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

PASS=0; FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }
info() { printf '\n=== %s ===\n' "$1"; }

sql() { echo "$1" | adb_ shell "run-as $PKG sqlite3 databases/messages.db"; }
q()   { sql "$1" | tr -d '\r'; }

NUM="+1555890$(date +%s | tail -c 5)"
MARK="MARKREAD$(date +%s)"
ROW_TITLE="Mark all as read"
DIALOG_TITLE="Mark all as read?"
CONV=""

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    q "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM');" >/dev/null
    q "DELETE FROM conversations WHERE address='$NUM';" >/dev/null
    q "DELETE FROM participants WHERE normalized_destination='$NUM';" >/dev/null
    pin_new_ui on >/dev/null 2>&1 || true
}
trap cleanup EXIT

set_new_ui() {
    case "$1" in
      on)  from=false; to=true ;;
      off) from=true;  to=false ;;
    esac
    adb_ shell "run-as $PKG sh -c 'sed -i \"s#name=\\\"use_new_ui\\\" value=\\\"$from\\\"#name=\\\"use_new_ui\\\" value=\\\"$to\\\"#\" shared_prefs/messages_settings.xml'" >/dev/null 2>&1
}

pin_new_ui() {
    adb_ shell "run-as $PKG sh -c 'touch shared_prefs/messages_settings.xml'" >/dev/null 2>&1
    adb_ shell "run-as $PKG sh -c 'grep -q use_new_ui shared_prefs/messages_settings.xml || echo \"<?xml version=\\\"1.0\\\" encoding=\\\"utf-8\\\" standalone=\\\"yes\\\" ?><map><boolean name=\\\"use_new_ui\\\" value=\\\"true\\\" /></map>\" > shared_prefs/messages_settings.xml'" >/dev/null 2>&1
    set_new_ui "$1"
}

# The confirmation is its own window, so "which node is the confirm button"
# cannot be answered by text alone: the row underneath shares the same label.
# Scope every dialog query to the window that carries the question-mark title.
dialog_query() {
    python3 - "$TMP/layout.json" "$DIALOG_TITLE" "$1" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
title, want = sys.argv[2], sys.argv[3]

def nodes(node, acc):
    if isinstance(node, list):
        for child in node:
            nodes(child, acc)
    elif isinstance(node, dict):
        text = node.get("text") or node.get("content-desc")
        if text:
            acc.append((text, node.get("center")))
        for key in ("content", "children"):
            for child in (node.get(key) or []):
                nodes(child, acc)

for window in data:
    acc = []
    nodes(window, acc)
    if not any(t == title for t, _ in acc):
        continue
    if want == "--visible":
        print("yes")
        sys.exit(0)
    for text, center in acc:
        if text == want and center:
            print(center.strip("[]").replace(",", " "))
            sys.exit(0)
sys.exit(1)
PY
}

dialog_visible() {
    layout_json >/dev/null 2>&1 || return 1
    dialog_query --visible >/dev/null 2>&1
}

tap_dialog() {
    local c
    c=$(dialog_query "$1") || { echo "[tap] '$1' not in the dialog"; return 1; }
    adb_ shell input tap $c
    echo "[tap] dialog '$1' at ($c)"
}

unread_in_db() { q "SELECT unread_count FROM conversations WHERE address='$NUM';" | head -1 | tr -d ' '; }

# Seed one conversation with an unread badge while the app is not running.
seed_unread() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
    local ts=$(( $(date +%s) * 1000 ))
    q "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM');" >/dev/null
    q "DELETE FROM conversations WHERE address='$NUM';" >/dev/null
    q "INSERT INTO conversations(address,name,snippet,timestamp,last_is_me) VALUES('$NUM','$MARK','$MARK',$ts,0);" >/dev/null
    CONV=$(q "SELECT id FROM conversations WHERE address='$NUM';" | head -1 | tr -d ' ')
    [ -n "$CONV" ] || return 1
    q "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,media_type) VALUES($CONV,'$MARK',$ts,0,'received','text');" >/dev/null
    q "UPDATE conversations SET unread_count=1 WHERE id=$CONV;" >/dev/null
    [ "$(unread_in_db)" = "1" ]
}

open_settings() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
    adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null 2>&1; sleep 4
    wait_layout_has "General settings" 8 || return 1
    scroll_to_layout "$ROW_TITLE" || return 1
    return 0
}

# One full pass over a settings UI: ask, cancel, ask again, confirm.
check_ui() {
    local label="$1"

    info "$label: the row asks before marking anything read"
    if ! open_settings; then
        fail "$label: Settings never opened"
        return
    fi
    tap_layout "$ROW_TITLE" >/dev/null 2>&1 || { fail "$label: could not tap the row"; return; }
    sleep 1
    if dialog_visible; then
        pass "$label: tapping the row opens the confirmation"
    else
        fail "$label: tapping the row marked read without asking (no dialog)"
        adb_ shell input keyevent 4 >/dev/null 2>&1
        return
    fi
    if [ "$(unread_in_db)" = "1" ]; then
        pass "$label: nothing is marked read while the dialog waits"
    else
        fail "$label: the unread badge was cleared before the user confirmed"
    fi

    info "$label: Cancel leaves the unread badges alone"
    tap_dialog "Cancel" >/dev/null 2>&1 || fail "$label: no Cancel button in the dialog"
    sleep 1
    if dialog_visible; then
        fail "$label: Cancel did not close the dialog"
    else
        pass "$label: Cancel closes the dialog"
    fi
    if [ "$(unread_in_db)" = "1" ]; then
        pass "$label: Cancel left the unread badge intact"
    else
        fail "$label: Cancel still marked everything read"
    fi

    info "$label: confirming marks everything read"
    scroll_to_layout "$ROW_TITLE" >/dev/null 2>&1 || true
    tap_layout "$ROW_TITLE" >/dev/null 2>&1 || fail "$label: could not re-open the dialog"
    sleep 1
    dialog_visible && pass "$label: the dialog can be re-opened" \
        || fail "$label: the dialog did not re-open after Cancel"
    tap_dialog "$ROW_TITLE" >/dev/null 2>&1 || fail "$label: no confirm button in the dialog"
    sleep 1
    if [ "$(unread_in_db)" = "0" ]; then
        pass "$label: confirming cleared the unread badge"
    else
        fail "$label: confirming did not clear the unread badge"
    fi
    if dialog_visible; then
        fail "$label: the dialog stayed open after confirming"
    else
        pass "$label: confirming closes the dialog"
    fi
}

info "0. seed one conversation with an unread badge"
if seed_unread; then
    pass "seeded unread conversation $CONV at $NUM"
else
    fail "could not seed the unread conversation"
    printf '\n[RESULT] %d passed, %d failed\n' "$PASS" "$FAIL"
    exit 1
fi

pin_new_ui on
check_ui "new settings UI"

if seed_unread; then
    pass "re-seeded the unread conversation for the legacy pass"
else
    fail "could not re-seed the unread conversation"
fi
pin_new_ui off
check_ui "legacy settings UI"

printf '\n[RESULT] %d passed, %d failed\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
