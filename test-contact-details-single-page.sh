#!/usr/bin/env bash
# There is exactly one contact-details page, and it looks the same whichever UI
# the app is rendering.
#
# The screen used to exist twice and `use_new_ui` chose between them, so they
# drifted: a group still offered Call/Info and Block number on one and not the
# other, and the rename was a dialog on one and an inline field on the other.
#
# This asserts the same page under both flag values, then the group-only
# behaviour -- no per-person actions, no number under the name, no block row --
# and that the group name is edited in place rather than through a dialog.
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

PASS=0; FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }
info() { printf '\n=== %s ===\n' "$1"; }

sql() { echo "$1" | adb_ shell "run-as $PKG sqlite3 databases/messages.db"; }
q()   { sql "$1" | tr -d '\r'; }

SARAH="+15551230010"
DAD="+1555771010"

set_new_ui() {
    case "$1" in
      on)  from=false; to=true ;;
      off) from=true;  to=false ;;
    esac
    adb_ shell "run-as $PKG sh -c 'sed -i \"s#name=\\\"use_new_ui\\\" value=\\\"$from\\\"#name=\\\"use_new_ui\\\" value=\\\"$to\\\"#\" shared_prefs/messages_settings.xml'" >/dev/null 2>&1
}

# Force the key to exist whatever the current value is, then set it.
pin_new_ui() {
    adb_ shell "run-as $PKG sh -c 'touch shared_prefs/messages_settings.xml'" >/dev/null 2>&1
    adb_ shell "run-as $PKG sh -c 'grep -q use_new_ui shared_prefs/messages_settings.xml || echo \"<?xml version=\\\"1.0\\\" encoding=\\\"utf-8\\\" standalone=\\\"yes\\\" ?><map><boolean name=\\\"use_new_ui\\\" value=\\\"true\\\" /></map>\" > shared_prefs/messages_settings.xml'" >/dev/null 2>&1
    set_new_ui "$1"
}

open_details_for() {
    adb_ shell am force-stop "$PKG"; sleep 1
    adb_ shell am start -n "$ACT" --es open_conversation_address "$1" >/dev/null 2>&1; sleep 6
    inline_more_details
}

# Two conversations share Sarah's address, and opening by address resolves to
# the 1:1 -- correctly, since that is where a new chat with her goes. The group
# has to be reached from the home list, which is where a user would.
open_group_details() {
    adb_ shell am force-stop "$PKG"; sleep 1
    adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 7
    local c
    c=$(center_of_contains "GROUPMARKER" 2>/dev/null) || c=""
    [ -z "$c" ] && return 1
    adb_ shell input tap $c; sleep 5
    inline_more_details
}

inline_more_details() {
    local c
    c=$(center_of_contains "More options" 2>/dev/null) || c=""
    [ -n "$c" ] && adb_ shell input tap $c; sleep 2
    c=$(center_of "Details" 2>/dev/null) || c=""
    [ -n "$c" ] && adb_ shell input tap $c; sleep 3
    dump_ui >/dev/null 2>&1
}

tap_label() {
    local c
    c=$(center_of "$1" 2>/dev/null) || c=""
    [ -n "$c" ] && adb_ shell input tap $c; sleep 3
    dump_ui >/dev/null 2>&1
}

cleanup() { pin_new_ui on; }
trap cleanup EXIT

# --- Arrange: a 1:1 with Sarah, and a group containing her -------------------
sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$SARAH');" >/dev/null
sql "DELETE FROM conversation_recipients WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$SARAH');" >/dev/null
sql "DELETE FROM conversations WHERE address='$SARAH';" >/dev/null

# The 1:1 first: it must be the older row, because a new chat with Sarah has to
# resolve to it rather than to the group that also contains her.
sql "INSERT INTO conversations(address,name,snippet,timestamp,last_is_me) VALUES('$SARAH','Sarah','hello',$(($(date +%s)-100))000,0);" >/dev/null
CHAT_ID=$(q "select id from conversations where address='$SARAH'" || true); CHAT_ID=${CHAT_ID:--1}
sql "INSERT INTO conversation_recipients(conversation_id,address) VALUES($CHAT_ID,'$SARAH');" >/dev/null
sql "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,media_type) VALUES($CHAT_ID,'hello there',$(date +%s)000,0,'received','text');" >/dev/null

# The group, made the way the app makes one: its own row, both recipients, and
# nothing in it. The snippet is a marker because the row has to be findable by
# something other than its title -- the redesigned list still titles a group by
# its primary contact, so "Sarah +Dad" is not on screen to match against.
sql "INSERT INTO conversations(address,name,snippet,timestamp,last_is_me,group_title) VALUES('$SARAH','Sarah','GROUPMARKER',$(date +%s)000,1,'Sarah +Dad');" >/dev/null
GROUP_ID=$(q "select id from conversations where address='$SARAH' AND id<>$CHAT_ID" || true); GROUP_ID=${GROUP_ID:--1}
sql "INSERT INTO conversation_recipients(conversation_id,address) VALUES($GROUP_ID,'$SARAH');" >/dev/null
sql "INSERT INTO conversation_recipients(conversation_id,address) VALUES($GROUP_ID,'$DAD');" >/dev/null
info "seeded 1:1=$CHAT_ID group=$GROUP_ID"

# --- The one page renders the same under both UI flags ----------------------
for mode in off on; do
    pin_new_ui "$mode"
    open_details_for "$SARAH"
    got=$(adb_ shell "run-as $PKG cat shared_prefs/messages_settings.xml" 2>/dev/null | grep -o 'use_new_ui" value="[a-z]*"' | head -1 | tr -d '\r')
    if grep -q 'text="Notifications"' "$TMP/ui.xml"; then
        pass "details page renders with use_new_ui=$got"
    else
        fail "details page did not render with use_new_ui=$got"
    fi
    if grep -qE 'text="[^"]*Sarah[^"]*"' "$TMP/ui.xml"; then
        pass "contact name shown with use_new_ui=$got"
    else
        fail "contact name missing with use_new_ui=$got"
    fi
    if grep -q 'text="Add people"' "$TMP/ui.xml"; then
        pass "Add people shown with use_new_ui=$got"
    else
        fail "Add people missing with use_new_ui=$got"
    fi
done

# --- A group shows no per-person rows --------------------------------------
pin_new_ui on
open_group_details || true
if ! grep -q 'text="Notifications"' "$TMP/ui.xml"; then
    fail 'could not open the group details page from the list'
fi
if grep -q 'text="Call"' "$TMP/ui.xml"; then
    fail 'a group still offers Call'
else
    pass 'a group offers no Call action'
fi
if grep -qE 'text="(Info|Contact)"' "$TMP/ui.xml"; then
    fail 'a group still offers an Info/Contact action'
else
    pass 'a group offers no Info/Contact action'
fi
if grep -q 'text="Block number"' "$TMP/ui.xml"; then
    fail 'a group still offers Block number'
else
    pass 'a group offers no Block row'
fi
# One member's number under a group name reads as though the thread is theirs.
# Scoped to the header only. The member list legitimately numbers each person,
# so a whole-file grep for digits is not the test; what must be absent is a
# number sitting directly under the group's name, where one member's number
# reads as though the whole thread belongs to them.
header=$(python3 - <<'PY'
import re
xml=open("/tmp/opencode/messages-tests/ui.xml").read()
nodes=re.findall(r"<node[^>]*>",xml)
texts=[(re.search(r'text="([^"]*)"',n).group(1) if re.search(r'text="([^"]*)"',n) else "") for n in nodes]
try:
    i=next(n for n,t in enumerate(texts) if t=="Sarah +Dad")
except StopIteration:
    i=-1
print("|".join(t for t in texts[i+1:i+3] if t) if i>=0 else "")
PY
)
if printf '%s' "$header" | grep -qE '[0-9]{3}'; then
    fail "a group shows a member phone number under its name (header: $header)"
else
    pass 'a group shows no number under its name'
fi
if grep -q 'text="Add people"' "$TMP/ui.xml"; then
    pass 'a group still offers Add people'
else
    fail 'a group lost Add people'
fi

# --- The group name is edited in place -------------------------------------
dump_ui >/dev/null 2>&1
if python3 -c "
import re,sys
xml=open('$TMP/ui.xml').read()
sys.exit(0 if 'Sarah +Dad' in xml else 1)
"; then pass 'group name is shown'; else fail 'group name is not shown'; fi

# The pencil is a real IconButton a tap can reach, and tapping it turns the name
# into a field with no dialog and no outlined box over the screen.
pencil=$(center_of_contains "Group name" 2>/dev/null) || pencil=""
if [ -n "$pencil" ]; then
    adb_ shell input tap $pencil; sleep 3
    dump_ui >/dev/null 2>&1
    if grep -q 'class="android.widget.EditText"' "$TMP/ui.xml"; then
        pass 'the pencil opens an inline name field'
    else
        fail 'the pencil did not open a name field'
        info "what the page actually showed:"
        grep -oE '(class|text|content-desc)="[^"]*"' "$TMP/ui.xml" | sort -u | head -25
    fi
    if grep -q 'text="OK"' "$TMP/ui.xml"; then
        fail 'the name still opens a rename dialog'
    else
        pass 'the name is not edited through a dialog'
    fi
else
    fail 'could not find the pencil button on a group'
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
pin_new_ui on >/dev/null 2>&1
[ "$FAIL" -eq 0 ]