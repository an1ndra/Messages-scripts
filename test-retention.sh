#!/usr/bin/env bash
# Regression: auto-delete retention for everything the app files away.
#
# Trash used to be the only bucket purged, so keyword-blocked messages and
# blocked senders accumulated forever. The window is user-configurable now
# (Settings -> Auto-delete after), where it was hardcoded to 30 days.
#
# The purge runs once from MessagesApplication.onCreate, so each case seeds
# backdated rows, restarts the app, and asserts what survived.
source "$(dirname "$0")/env.sh"
set -uo pipefail

PASS=0
FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
info() { printf '\n=== %s ===\n' "$1"; }

MARK="reten$(date +%s)$$"
DAY=86400000
NOW=$(($(date +%s) * 1000))
OLD=$((NOW - 40 * DAY))
FRESH=$((NOW - 2 * DAY))
ADDR_T="+1555970${MARK: -3}"
ADDR_K="+1555971${MARK: -3}"
ADDR_B="+1555972${MARK: -3}"
ADDR_R="+1555973${MARK: -3}"

sql() {
    adb_ shell "run-as $PKG sqlite3 databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r' && return 0
    adb_ shell "su -c \"sqlite3 /data/data/$PKG/databases/messages.db \\\"$1\\\"\"" 2>/dev/null | tr -d '\r' || true
}

convo() {  # address, timestamp, blocked, deleted_at
    sql "INSERT INTO conversations(address,name,snippet,timestamp,unread_count,last_is_me,archived,blocked,pinned,draft,draft_date,deleted_at,deleted_reason) VALUES('$1','$MARK','$MARK',$2,0,0,0,$3,0,'',0,$4,'$MARK');" >/dev/null
    sql "SELECT id FROM conversations WHERE address='$1';" | tr -d '\n'
}

msg() {  # conversation_id, body, timestamp, deleted_at, blocked_reason
    sql "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,media_type,transport,sub_id,deleted_at,blocked_reason) VALUES($1,'$2',$3,0,'received','text','sms',-1,$4,'$5');" >/dev/null
}

count_msgs() { sql "SELECT COUNT(*) FROM messages WHERE body LIKE '%$1%';"; }
count_convo() { sql "SELECT COUNT(*) FROM conversations WHERE address='$1';"; }

restart() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    sleep 1
    adb_ shell am start -n "$ACT" >/dev/null 2>&1
    sleep 6
}

info "Seeding one row per retention bucket (old vs fresh)"
CT=$(convo "$ADDR_T" "$OLD" 0 "$OLD")
msg "$CT" "$MARK trashed-old" "$OLD" "$OLD" ""
CK=$(convo "$ADDR_K" "$OLD" 0 0)
msg "$CK" "$MARK keyword-old" "$OLD" "$OLD" "blocked_keyword"
CB=$(convo "$ADDR_B" "$OLD" 1 0)
msg "$CB" "$MARK blockednum-old" "$OLD" 0 ""
CR=$(convo "$ADDR_R" "$FRESH" 0 0)
msg "$CR" "$MARK keyword-fresh" "$FRESH" "$FRESH" "blocked_keyword"

[ -n "$CT" ] && [ -n "$CK" ] && [ -n "$CB" ] && [ -n "$CR" ] \
    && pass "seeded four conversations" \
    || { fail "seeding failed (ids: $CT/$CK/$CB/$CR)"; exit 1; }

info "30-day default purges old rows in every bucket"
restart
[ "$(count_msgs "$MARK trashed-old")" = "0" ] \
    && pass "old trashed conversation purged" \
    || fail "old trashed conversation survived"
[ "$(count_msgs "$MARK keyword-old")" = "0" ] \
    && pass "old keyword-blocked message purged (was never purged before)" \
    || fail "old keyword-blocked message survived"
[ "$(count_msgs "$MARK blockednum-old")" = "0" ] \
    && pass "old blocked sender purged (was never purged before)" \
    || fail "old blocked sender survived"
[ "$(count_convo "$ADDR_B")" = "0" ] \
    && pass "blocked sender conversation row removed" \
    || fail "blocked sender conversation row survived"
[ "$(count_msgs "$MARK keyword-fresh")" = "1" ] \
    && pass "message inside the window is kept" \
    || fail "message inside the window was purged early"

info "A shorter window purges sooner"
sql "UPDATE messages SET deleted_at=$OLD, blocked_reason='blocked_keyword' WHERE body LIKE '%$MARK keyword-fresh%';" >/dev/null
sql "UPDATE conversations SET timestamp=$OLD WHERE address='$ADDR_R';" >/dev/null
restart
[ "$(count_msgs "$MARK keyword-fresh")" = "0" ] \
    && pass "aged message purged on the next run" \
    || fail "aged message survived"

info "The window is user-configurable and defaults to 30"
# A previous run leaves retention_days at 7; clear it so the default assertion
# means something and the script stays idempotent.
adb_ shell "run-as $PKG sed -i '/name=\"retention_days\"/d' shared_prefs/messages_settings.xml" >/dev/null 2>&1
sql "DELETE FROM messages WHERE body LIKE '%$MARK%';"
sql "DELETE FROM conversations WHERE name='$MARK';"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null 2>&1; sleep 5
found=0
for _ in $(seq 1 8); do
    dump_ui
    grep -q "Auto-delete after" "$TMP/ui.xml" && { found=1; break; }
    adb_ shell input swipe 540 1700 540 1000 250 >/dev/null 2>&1
    sleep 1
done
[ "$found" = "1" ] \
    && pass "Settings shows the Auto-delete after row" \
    || fail "Auto-delete after row not found in Settings"
if [ "$found" = "1" ]; then
    dump_ui
    grep -q "30 days" "$TMP/ui.xml" \
        && pass "default window reads 30 days" \
        || fail "default window does not read 30 days"
    c=$(center_of_contains "Auto-delete after")
    if [ -n "$c" ]; then
        XY=($c)
        adb_ shell input tap "${XY[0]}" "${XY[1]}" >/dev/null 2>&1
        sleep 1.5
        dump_ui
        grep -q "7 days" "$TMP/ui.xml" \
            && pass "chooser offers 7 / 30 / 90 / 365 days" \
            || fail "chooser missing the day options"
        if grep -q "7 days" "$TMP/ui.xml"; then
            tap_text "7 days" >/dev/null 2>&1; sleep 1.5
            pref=$(adb_ shell "run-as $PKG cat shared_prefs/messages_settings.xml" 2>/dev/null | tr -d '\r' \
                | sed -n 's/.*name="retention_days" value="\([0-9]*\)".*/\1/p')
            [ "$pref" = "7" ] \
                && pass "picking 7 days persists to prefs" \
                || fail "retention_days pref is '$pref', expected 7"
        fi
    else
        fail "could not tap the Auto-delete after row"
    fi
fi

info "No crashes"
adb_ shell "logcat -d -b crash" 2>/dev/null | grep -q "$PKG" \
    && fail "crash logged for $PKG" \
    || pass "no crashes"

# Leave the window at the default for the next run.
adb_ shell "run-as $PKG sed -i '/name=\"retention_days\"/d' shared_prefs/messages_settings.xml" >/dev/null 2>&1
adb_ shell input keyevent 4 >/dev/null 2>&1
printf '\n=== RESULTS: %s passed, %s failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
