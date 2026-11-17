#!/usr/bin/env bash
# Regression for #485 — search filter operators.
#
# The home search understands `from:`, `has:attachment`, `before:` and
# `after:` — combinable, removable through the chips under the field, and
# dates are read in the calendar the app renders (Gregorian on this AVD).
# An unrecognised query must behave exactly as before, so every assertion
# carries plain text the operators were not asked to consume.
#
# Seeded through `run-as` sqlite3 like test-starred-messages.sh, which also
# lets one conversation carry a message timestamped 2010 — that is what makes
# `before:`/`after:` distinguishable from text search at all.
#
# Row visibility is asserted through the row title (the stored name, seeded
# to the address), never through a bare substring: the search field itself
# holds the query, which contains the same address, so a naive grep would
# match the field and read a filtered-out row as visible.
#
# Run: scripts/test-search-filters.sh   (emulator-5558 / 5557)
set -uo pipefail
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); [ -n "${SEARCH_DEBUG:-}" ] && cp "$TMP/ui.xml" "$TMP/debug-$FAIL.xml" 2>/dev/null; }

A="+15551230001"   # recital, one message from 2010 + one now
B="+15551230002"   # no recital at all
C="+15551230003"   # recital + an attachment

OLD_BODY="ancient recital memory"
NEW_BODY="recital rehearsal notes"
B_BODY="different words entirely"
C_BODY="recital photo attached"
OLD_MS=1276584000000          # 2010-06-15T12:00:00Z
NOW_MS=$(($(date +%s) * 1000))

sql() { adb_ shell "run-as $PKG sqlite3 databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r'; }

# The app must actually be front — a tap meant for its Search icon lands on the
# launcher's global search otherwise, and every later input goes into that box.
# uiautomator's own subprocess and `dumpsys` both race a fresh start here, so
# the start is re-issued between polls instead of failing after one attempt.
app_front() {
    local i
    for i in 1 2 3 4 5; do
        if adb_ shell dumpsys activity activities 2>/dev/null | grep -q "mResumedActivity.*$PKG"; then
            return 0
        fi
        adb_ shell am start -n "$ACT" >/dev/null 2>&1
        sleep 2
    done
    adb_ shell dumpsys activity activities 2>/dev/null | grep -q "mResumedActivity.*$PKG"
}

launch() {
    # The screen sleeps between searches on a headless AVD, and a tap meant for
    # the app's Search icon then lands on the lock screen or the launcher.
    adb_ shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1
    adb_ shell wm dismiss-keyguard >/dev/null 2>&1
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
    adb_ shell am start -n "$ACT" >/dev/null 2>&1
    app_front || { fail "app never reached the foreground"; echo "Result: $PASS passed, $FAIL failed"; exit $((FAIL > 0)); }
    sleep 5
}

# A node whose text/content-desc contains $1, ignoring the search field:
# the EditText carries the query itself, which shares the address strings.
# uiautomator segfaults intermittently on this AVD, so a *presence* check
# retries the dump until the needle turns up (or the tries run out).
seen() {
    local i
    for i in 1 2 3; do
        dump_ui >/dev/null 2>&1 || { sleep 2; continue; }
        if python3 - "$TMP/ui.xml" "$1" <<'PY'
import re, sys
xml, needle = open(sys.argv[1], encoding="utf-8", errors="replace").read(), sys.argv[2]
for m in re.finditer(r'<node[^>]*>', xml):
    n = m.group(0)
    if 'class="android.widget.EditText"' in n:
        continue
    for attr in ("text", "content-desc"):
        m = re.search(attr + r'="([^"]*)"', n)
        if m and needle in re.sub(r"&#(\d+);", lambda x: chr(int(x.group(1))), m.group(1)):
            sys.exit(0)
sys.exit(1)
PY
        then return 0; fi
        sleep 2
    done
    return 1
}

# The inverse must not inherit the flake: a row is only pronounced gone when
# three independent dumps all fail to find it.
absent() {
    local i
    for i in 1 2 3; do
        dump_ui >/dev/null 2>&1 || { sleep 2; continue; }
        if python3 - "$TMP/ui.xml" "$1" <<'PY'
import re, sys
xml, needle = open(sys.argv[1], encoding="utf-8", errors="replace").read(), sys.argv[2]
for m in re.finditer(r'<node[^>]*>', xml):
    n = m.group(0)
    if 'class="android.widget.EditText"' in n:
        continue
    for attr in ("text", "content-desc"):
        m = re.search(attr + r'="([^"]*)"', n)
        if m and needle in re.sub(r"&#(\d+);", lambda x: chr(int(x.group(1))), m.group(1)):
            sys.exit(0)
sys.exit(1)
PY
        then return 1; fi
        sleep 1
    done
    return 0
}

# What the search field currently holds.
field_text() {
    dump_ui >/dev/null 2>&1 || return 1
    python3 - "$TMP/ui.xml" <<'PY'
import re, sys
xml = open(sys.argv[1], encoding="utf-8", errors="replace").read()
for m in re.finditer(r'<node[^>]*>', xml):
    n = m.group(0)
    if 'class="android.widget.EditText"' not in n:
        continue
    t = re.search(r'text="([^"]*)"', n)
    if t:
        print(t.group(1))
        break
PY
}

search() {
    launch
    tap_contains "Search" >/dev/null 2>&1; sleep 2
    type_text "$1"
    sleep 3
}

cleanup() {
    for n in "$A" "$B" "$C"; do
        sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$n');" >/dev/null 2>&1
        sql "DELETE FROM conversations WHERE address='$n';" >/dev/null 2>&1
        sql "DELETE FROM participants WHERE normalized_destination='$n';" >/dev/null 2>&1
    done
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
}
trap cleanup EXIT

info "Seed three conversations (one message predating 2011)"
for p in READ_SMS READ_CONTACTS POST_NOTIFICATIONS; do
    adb_ shell pm grant "$PKG" "android.permission.$p" >/dev/null 2>&1
done
adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1 || true
# Keep the screen on for the whole run: the assertions below tap real
# coordinates, and a doze between searches sends them into the lock screen.
adb_ shell svc power stayon true >/dev/null 2>&1

# Idempotent: a previous run that died before its cleanup left the rows in.
for n in "$A" "$B" "$C"; do
    sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$n');" >/dev/null 2>&1
    sql "DELETE FROM conversations WHERE address='$n';" >/dev/null 2>&1
done

for n in "$A" "$B" "$C"; do
    sql "INSERT OR REPLACE INTO participants(normalized_destination,send_destination,display_destination,comparable_destination,country_code,sub_id) VALUES('$n','$n','$n','$n','',-1);" >/dev/null
done
sql "INSERT INTO conversations(address,name,snippet,timestamp,unread_count,last_is_me,archived,blocked,blocked_at,pinned,draft,draft_date,deleted_at,deleted_reason) VALUES('$A','$A','$NEW_BODY',$NOW_MS,0,0,0,0,0,0,'',0,0,'manual');" >/dev/null
sql "INSERT INTO conversations(address,name,snippet,timestamp,unread_count,last_is_me,archived,blocked,blocked_at,pinned,draft,draft_date,deleted_at,deleted_reason) VALUES('$B','$B','$B_BODY',$NOW_MS,0,0,0,0,0,0,'',0,0,'manual');" >/dev/null
sql "INSERT INTO conversations(address,name,snippet,timestamp,unread_count,last_is_me,archived,blocked,blocked_at,pinned,draft,draft_date,deleted_at,deleted_reason) VALUES('$C','$C','$C_BODY',$NOW_MS,0,0,0,0,0,0,'',0,0,'manual');" >/dev/null
CA=$(sql "SELECT id FROM conversations WHERE address='$A';")
CB=$(sql "SELECT id FROM conversations WHERE address='$B';")
CC=$(sql "SELECT id FROM conversations WHERE address='$C';")
sql "INSERT INTO messages(conversation_id,body,timestamp,is_me,status) VALUES($CA,'$OLD_BODY',$OLD_MS,0,'received');" >/dev/null
sql "INSERT INTO messages(conversation_id,body,timestamp,is_me,status) VALUES($CA,'$NEW_BODY',$NOW_MS,0,'received');" >/dev/null
sql "INSERT INTO messages(conversation_id,body,timestamp,is_me,status) VALUES($CB,'$B_BODY',$NOW_MS,0,'received');" >/dev/null
sql "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,media_type,media_uri) VALUES($CC,'$C_BODY',$NOW_MS,0,'received','image','attachments/recital.jpg');" >/dev/null
ROWS=$(sql "SELECT count(*) FROM conversations WHERE address IN ('$A','$B','$C');")
[ "$ROWS" = "3" ] || { fail "seed: expected 3 conversations, got $ROWS"; exit $((FAIL > 0)); }

info "1. Plain text search is unchanged"
search "recital"
seen "$A" && pass "recital: the conversation with both hits is shown" || fail "recital: $A missing"
absent "$B" && pass "recital: $B filtered out" || fail "recital: $B should not match"

info "2. from: narrows to who the chat is with"
search "from:$A recital"
seen "$A" && pass "from:$A recital -> $A shown" || fail "from:$A recital -> $A missing"
absent "$B" && pass "from:$A recital -> $B filtered out" || fail "from:$A recital -> $B still shown"
search "from:$B recital"
absent "$A" && pass "from:$B recital -> no rows ($B has no recital)" || fail "from:$B recital -> $A still shown"

info "3. before:/after: read message time"
search "before:2011/06/01 recital"
seen "$A" && pass "before:2011/06/01 recital -> the 2010 message surfaces $A" || fail "before:2011/06/01 recital -> $A missing"
search "before:2010/06/01 recital"
absent "$A" && pass "before:2010/06/01 recital -> no rows (day bound is exclusive)" || fail "before:2010/06/01 recital -> $A still shown"
search "after:2020/01/01 recital"
seen "$A" && pass "after:2020/01/01 recital -> the recent message surfaces $A" || fail "after:2020/01/01 recital -> $A missing"
search "after:2100/01/01 recital"
absent "$A" && pass "after:2100/01/01 recital -> no rows" || fail "after:2100/01/01 recital -> $A still shown"

info "4. has:attachment needs a media part"
search "has:attachment recital"
seen "$C" && pass "has:attachment recital -> $C shown" || fail "has:attachment recital -> $C missing"
absent "$A" && pass "has:attachment recital -> $A filtered out" || fail "has:attachment recital -> $A still shown"
search "has:attachment"
seen "$C" && pass "has:attachment alone -> $C shown" || fail "has:attachment alone -> $C missing"

info "5. Operators combine"
search "from:$C has:attachment recital"
seen "$C" && pass "from:$C has:attachment recital -> $C shown" || fail "from:$C has:attachment recital -> $C missing"
absent "$A" && pass "from:$C has:attachment recital -> $A filtered out" || fail "from:$C has:attachment recital -> $A still shown"

info "6. A chip removes exactly its operator"
search "from:$A recital"
CHIPLABEL="$(res_string search_filter_from | sed "s/%s/$A/")"
if seen "$CHIPLABEL"; then
    pass "the from chip is shown ('$CHIPLABEL')"
else
    fail "no chip labelled '$CHIPLABEL'"
fi
tap_contains "$CHIPLABEL" >/dev/null 2>&1; sleep 2
if [ "$(field_text)" = "recital" ]; then
    pass "tapping the chip leaves the plain text 'recital'"
else
    fail "tapping the chip did not leave 'recital' (field: '$(field_text)')"
fi
seen "$A" && pass "after removing from:, 'recital' still shows $A" || fail "after removing from:, $A missing"
absent "$B" && pass "after removing from:, $B filtered out" || fail "after removing from:, $B shown"

echo
echo "Result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
