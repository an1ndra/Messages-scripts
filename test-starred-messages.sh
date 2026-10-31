#!/usr/bin/env bash
# Regression for #394 — bookmarked (starred) messages.
#
# Shape copied from Google Messages, verified on this AVD before the change:
# starring lives in the selection toolbar, a starred bubble carries a star
# badge, and the bookmarks are browsable through the home search's **Starred**
# scope (message, chat and time). Google Messages has no star action on
# notifications, so none is offered here either.
#
# A badge and a chip are pixels, but the string behind each one is in the
# `uiautomator` dump: the badge is a "Starred message" content description, the
# search row is the message body, the chip is its label. No screenshots.
#
# Run: scripts/test-starred-messages.sh
set -uo pipefail
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }

NUM="+1555$((RANDOM % 9000 + 1000))394"
BODY="starred probe $(date +%s)"
ADDR="$NUM"   # the app re-derives the display name when no contact exists

sql() { adb_ shell "run-as $PKG sqlite3 databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r'; }
has() { dump_ui >/dev/null 2>&1 && ui_tags | grep -qF -- "$1"; }
long_press() { adb_ shell input swipe "$1" "$2" "$1" "$2" 800; sleep 2; }

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM');" >/dev/null 2>&1
    sql "DELETE FROM conversations WHERE address='$NUM';" >/dev/null 2>&1
    sql "DELETE FROM participants WHERE normalized_destination='$NUM';" >/dev/null 2>&1
}
trap cleanup EXIT

for p in READ_SMS READ_CONTACTS POST_NOTIFICATIONS; do
    adb_ shell pm grant "$PKG" "android.permission.$p" >/dev/null 2>&1
done
adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1 || true

NOW=$(($(date +%s) * 1000))
sql "INSERT OR REPLACE INTO participants(normalized_destination,send_destination,display_destination,comparable_destination,country_code,sub_id) VALUES('$NUM','$NUM','$NUM','$NUM','',-1);" >/dev/null
sql "INSERT INTO conversations(address,name,snippet,timestamp,unread_count,last_is_me,archived,blocked,blocked_at,pinned,draft,draft_date,deleted_at,deleted_reason) VALUES('$NUM','$ADDR','$BODY',$NOW,0,0,0,0,0,0,'',0,0,'manual');" >/dev/null
CID=$(sql "SELECT id FROM conversations WHERE address='$NUM';")
sql "INSERT INTO messages(conversation_id,body,timestamp,is_me,status) VALUES($CID,'$BODY',$((NOW-1000)),0,'received');" >/dev/null
MID=$(sql "SELECT id FROM messages WHERE conversation_id=$CID ORDER BY id DESC LIMIT 1;")
[ -n "$CID" ] && [ -n "$MID" ] || { fail "seed: no conversation/message"; exit $((FAIL > 0)); }

adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
# Open the thread through the share path: a row tap races the startup sync and
# sometimes lands on the row under the finger.
adb_ shell am start -a android.intent.action.SENDTO -d "sms:$NUM" >/dev/null 2>&1
sleep 6
wait_layout_has "Message" 10 >/dev/null 2>&1 || true

# 1 + 2. long-press the bubble, star it from the toolbar
C=$(center_of_contains "$BODY" 2>/dev/null || true)
[ -n "${C:-}" ] || { sleep 2; C=$(center_of_contains "$BODY" 2>/dev/null || true); }
if [ -z "${C:-}" ]; then
    fail "chat: the bubble was not found"
    printf '\n[RESULT] %d passed, %d failed\n' "$PASS" "$FAIL"; exit $((FAIL > 0))
fi
# shellcheck disable=SC2086
long_press $C
if has 'content-desc="Star"'; then
    pass "chat: long-press offers Star"
    tap_contains "Star" >/dev/null 2>&1; sleep 2
else
    fail "chat: no Star action in the selection toolbar"
fi

if [ "$(sql "SELECT starred FROM messages WHERE id=$MID;")" = "1" ]; then
    pass "storage: the message is starred"
else
    fail "storage: the star never reached the database"
fi

if has 'Starred message'; then
    pass "chat: the bubble carries the star badge"
else
    fail "chat: no star badge on the starred bubble"
fi

# 3. the Starred scope lists it
adb_ shell input keyevent KEYCODE_BACK; sleep 2
tap_contains "Search" >/dev/null 2>&1; sleep 2
if has 'Starred'; then
    pass "search: the scope chips are present"
    tap_contains "Starred" >/dev/null 2>&1; sleep 2
    if has "$BODY"; then
        pass "search: the starred message is listed"
    else
        fail "search: the Starred scope is empty"
    fi
    if has "$ADDR"; then
        pass "search: the row names the chat it came from"
    else
        fail "search: the row does not name its chat"
    fi
else
    fail "search: no Starred scope chip"
fi

# 4. unstar clears the badge, the row and the column
adb_ shell input keyevent KEYCODE_BACK; sleep 1
adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
adb_ shell am start -a android.intent.action.SENDTO -d "sms:$NUM" >/dev/null 2>&1
sleep 6
wait_layout_has "Message" 10 >/dev/null 2>&1 || true
C=$(center_of_contains "$BODY" 2>/dev/null || true)
[ -n "${C:-}" ] || { sleep 2; C=$(center_of_contains "$BODY" 2>/dev/null || true); }
if [ -z "${C:-}" ]; then
    fail "chat: the bubble was not found the second time"
else
    # shellcheck disable=SC2086
    long_press $C
    if has 'content-desc="Remove star"'; then
        tap_contains "Remove star" >/dev/null 2>&1; sleep 2
        if [ "$(sql "SELECT starred FROM messages WHERE id=$MID;")" = "0" ]; then
            pass "storage: Remove star clears the flag"
        else
            fail "storage: the flag survived Remove star"
        fi
        if has 'Starred message'; then
            fail "chat: the badge survived Remove star"
        else
            pass "chat: the badge is gone"
        fi
    else
        fail "chat: a starred message offers Remove star"
    fi
fi

printf '\n[RESULT] %d passed, %d failed\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
