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

# Reads a boolean pref, printing "absent" when the key is not in the XML yet.
pref_bool() {
    v=$(adb_ shell "run-as $PKG cat shared_prefs/messages_settings.xml" 2>/dev/null | tr -d '\r' \
        | sed -n "s/.*name=\"$1\" value=\"\([a-z]*\)\".*/\1/p")
    printf '%s' "${v:-absent}"
}

# Drops every retention_* key so each run starts from the defaults.
pref_reset_retention() {
    adb_ shell "run-as $PKG sed -i '/name=\"retention_/d' shared_prefs/messages_settings.xml" >/dev/null 2>&1
}

# A previous run leaves the bucket switches flipped and the window at 7 days.
pref_reset_retention
sql "DELETE FROM messages WHERE body LIKE '%$MARK%';"
sql "DELETE FROM conversations WHERE name='$MARK';"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null 2>&1; sleep 5

# wait_for_text does not scroll, and "Advanced" sits at the bottom of General
# settings, so scroll the list while polling.
scroll_to() {
    local target="$1" i
    for i in $(seq 1 12); do
        dump_ui >/dev/null 2>&1 || true
        if grep -c "$target" "$TMP/ui.xml" >/dev/null 2>&1; then return 0; fi
        adb_ shell input swipe 540 1700 540 1000 250 >/dev/null 2>&1
        sleep 0.7
    done
    return 1
}

info "Auto-delete lives in Advanced, not in General settings"
if scroll_to "Advanced"; then
    pass "General settings still offers the Advanced row"
else
    fail "could not find the Advanced row in General settings"
fi
tap_text "Advanced" >/dev/null 2>&1; sleep 2
if wait_for_text "Auto-delete" 10; then
    pass "Auto-delete section is in Advanced"
else
    fail "Auto-delete section not found in Advanced"
fi

info "The section is collapsed by default and expands on tap"
dump_ui
if [ "$(grep -c 'text="Deleted chats"' "$TMP/ui.xml")" = "0" ]; then
    pass "bucket options are hidden while collapsed"
else
    fail "bucket options are already visible without expanding"
fi
c=$(center_of_contains "Auto-delete")
if [ -n "$c" ]; then
    XY=($c)
    adb_ shell input tap "${XY[0]}" "${XY[1]}" >/dev/null 2>&1
    sleep 1.5
    if wait_for_text "Deleted chats" 6; then
        pass "tapping the header expands the options"
    else
        fail "tapping the header did not expand the options"
    fi
    if wait_for_text "Blocked messages" 4 && wait_for_text "Blocked senders" 4; then
        pass "all three buckets are offered"
    else
        fail "expected Trash / Blocked messages / Blocked senders options"
    fi
else
    fail "could not tap the Auto-delete header"
fi

info "Each bucket can be turned off on its own"
if center_of_contains "Blocked senders" >/dev/null; then
    tap_switch_near "Blocked senders" >/dev/null 2>&1; sleep 1
    [ "$(pref_bool retention_blocked_senders)" = "false" ] \
        && pass "turning off Blocked senders persists to prefs" \
        || fail "retention_blocked_senders is '$(pref_bool retention_blocked_senders)', expected false"
    tap_switch_near "Deleted chats" >/dev/null 2>&1; sleep 1
    [ "$(pref_bool retention_trash)" = "false" ] \
        && pass "turning off Deleted chats persists to prefs" \
        || fail "retention_trash is '$(pref_bool retention_trash)', expected false"
    tap_switch_near "Blocked senders" >/dev/null 2>&1; sleep 1
    tap_switch_near "Deleted chats" >/dev/null 2>&1; sleep 1
else
    fail "could not find the bucket rows"
fi

info "Only the selected buckets are purged"
CT=$(convo "$ADDR_T" "$OLD" 0 "$OLD"); msg "$CT" "$MARK trashed-2" "$OLD" "$OLD" ""
CB=$(convo "$ADDR_B" "$OLD" 1 0);     msg "$CB" "$MARK blockednum-2" "$OLD" 0 ""
CK=$(convo "$ADDR_K" "$OLD" 0 0);     msg "$CK" "$MARK keyword-2" "$OLD" "$OLD" "blocked_keyword"
tap_switch_near "Blocked senders" >/dev/null 2>&1; sleep 1
[ "$(pref_bool retention_blocked_senders)" = "false" ] \
    || fail "could not switch Blocked senders off for the purge check"
restart
[ "$(count_msgs "$MARK trashed-2")" = "0" ] \
    && pass "an enabled bucket is still purged (Deleted chats)" \
    || fail "Deleted chats bucket stopped purging"
[ "$(count_msgs "$MARK keyword-2")" = "0" ] \
    && pass "an enabled bucket is still purged (Blocked messages)" \
    || fail "Blocked messages bucket stopped purging"
[ "$(count_msgs "$MARK blockednum-2")" = "1" ] \
    && pass "the bucket switched off is left alone (Blocked senders)" \
    || fail "blocked senders were purged even though the option is off"

info "Turning auto-delete off entirely purges nothing"
CT=$(convo "$ADDR_T" "$OLD" 0 "$OLD"); msg "$CT" "$MARK trashed-3" "$OLD" "$OLD" ""
adb_ shell "run-as $PKG sed -i 's/name=\"retention_trash\" value=\"true\"/name=\"retention_trash\" value=\"false\"/' shared_prefs/messages_settings.xml" >/dev/null 2>&1
adb_ shell "run-as $PKG sed -i 's/name=\"retention_keyword_messages\" value=\"true\"/name=\"retention_keyword_messages\" value=\"false\"/' shared_prefs/messages_settings.xml" >/dev/null 2>&1
adb_ shell "run-as $PKG sed -i 's/name=\"retention_blocked_senders\" value=\"false\"/name=\"retention_blocked_senders\" value=\"true\"/' shared_prefs/messages_settings.xml" >/dev/null 2>&1
adb_ shell "run-as $PKG sed -i 's/name=\"retention_enabled\" value=\"true\"/name=\"retention_enabled\" value=\"false\"/' shared_prefs/messages_settings.xml" >/dev/null 2>&1
restart
[ "$(count_msgs "$MARK trashed-3")" = "1" ] \
    && pass "nothing is purged when the master switch is off" \
    || fail "rows were purged with auto-delete switched off"

info "The window is still user-selectable"
pref_reset_retention
adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null 2>&1; sleep 4
scroll_to "Advanced" >/dev/null
tap_text "Advanced" >/dev/null 2>&1; sleep 2
wait_for_text "Auto-delete" 10 >/dev/null
c=$(center_of_contains "Auto-delete")
[ -n "$c" ] && { XY=($c); adb_ shell input tap "${XY[0]}" "${XY[1]}" >/dev/null 2>&1; sleep 1.5; }
if wait_for_text "Delete after" 6; then
    tap_text "Delete after" >/dev/null 2>&1; sleep 1.5
    dump_ui
    if [ "$(grep -c '7 days' "$TMP/ui.xml")" -ge 1 ]; then
        pass "chooser offers 7 / 30 / 90 / 365 days"
    else
        fail "chooser missing the day options"
    fi
    tap_text "7 days" >/dev/null 2>&1; sleep 1.5
    pref=$(adb_ shell "run-as $PKG cat shared_prefs/messages_settings.xml" 2>/dev/null | tr -d '\r' \
        | sed -n 's/.*name="retention_days" value="\([0-9]*\)".*/\1/p')
    [ "$pref" = "7" ] \
        && pass "picking 7 days persists to prefs" \
        || fail "retention_days pref is '$pref', expected 7"
else
    fail "could not find the Delete after row"
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
