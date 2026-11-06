#!/usr/bin/env bash
# Regression for the home-screen widgets: both providers must be registered with
# the launcher, and what each one would draw must follow the inbox rules (no
# archived rows) and go blank behind App lock or Privacy mode.
#
# The assertion surface is the WidgetProbe log line, not a screenshot: the
# widget itself lives in the launcher's RemoteViews and cannot be dumped, but
# WidgetProbe.line() is the same selection code the widget renders from.
#
# Run: ANDROID_SERIAL=emulator-5558 scripts/test-widgets.sh
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

MARK="widget$(date +%s)$$"
READ_NUM="+1555710${MARK: -4}"
UNREAD_NUM="+1555711${MARK: -4}"
ARCHIVED_NUM="+1555712${MARK: -4}"

adb_ root >/dev/null 2>&1; adb_ wait-for-device; sleep 1
sql() { adb_su "sqlite3 /data/data/$PKG/databases/messages.db \"$1\"" 2>/dev/null; }

# SettingsStore writes through SharedPreferences.apply(), so a force-stop one
# second later can drop the write. Every reset gives the process a few seconds
# to flush, or a previous run's lock state decides this one's result.
reset_gates() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    adb_ shell am start -n "$ACT" --es app_lock_probe disable --ez privacy_mode false >/dev/null 2>&1
    sleep 4
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
}

cleanup() {
    reset_gates
    sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address IN ('$READ_NUM','$UNREAD_NUM','$ARCHIVED_NUM'));" >/dev/null 2>&1
    sql "DELETE FROM conversations WHERE address IN ('$READ_NUM','$UNREAD_NUM','$ARCHIVED_NUM');" >/dev/null 2>&1
}
trap cleanup EXIT

# Start the app with the probe on and print the probe line, or nothing.
probe_line() {
    adb_ shell am force-stop "$PKG"; sleep 1
    adb_ shell logcat -c >/dev/null 2>&1
    adb_ shell am start "$@" >/dev/null 2>&1
    local i out
    for i in $(seq 1 20); do
        sleep 1
        out=$(adb_ shell logcat -d -s WidgetProbe:D 2>/dev/null | tr -d '\r' | grep -F "locked=" | tail -1)
        [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
    done
    return 1
}

info "Build and install"
( cd "$PROJECT_DIR" && ./gradlew assembleDebug >/dev/null 2>&1 )
adb_ install -r "$PROJECT_DIR/app/build/outputs/apk/debug/app-debug.apk" >/dev/null 2>&1 \
    && ok "apk installed" || bad "apk install failed"
for p in READ_SMS RECEIVE_SMS READ_CONTACTS POST_NOTIFICATIONS; do
    adb_ shell pm grant "$PKG" "android.permission.$p" >/dev/null 2>&1
done
adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1

info "Start from a known gate state"
reset_gates
ok "app lock and privacy mode are both off"

info "Providers registered with the launcher"
widgets=$(adb_ shell dumpsys appwidget 2>/dev/null | tr -d '\r')
printf '%s' "$widgets" | grep -qF "com.anindra.messages.widget.MessagesListWidgetReceiver" \
    && ok "list widget provider registered" || bad "list widget provider missing from dumpsys appwidget"
printf '%s' "$widgets" | grep -qF "com.anindra.messages.widget.UnreadWidgetReceiver" \
    && ok "unread widget provider registered" || bad "unread widget provider missing from dumpsys appwidget"
[ "$(printf '%s' "$widgets" | grep -cF "updatePeriodMillis=1800000")" -ge 2 ] \
    && ok "both providers ask the launcher for a 30-minute refresh" \
    || bad "updatePeriodMillis=1800000 not declared by both providers"

info "Seed one read, one unread and one archived conversation"
TS=$(date +%s000)
sql "INSERT INTO conversations(address,name,snippet,timestamp,unread_count) VALUES('$READ_NUM','Read One','read marker',$TS,0);" >/dev/null 2>&1
sql "INSERT INTO conversations(address,name,snippet,timestamp,unread_count) VALUES('$UNREAD_NUM','Unread Two','unread marker',$((TS - 1000)),2);" >/dev/null 2>&1
sql "INSERT INTO conversations(address,name,snippet,timestamp,unread_count,archived) VALUES('$ARCHIVED_NUM','Archived Three','archived marker',$((TS - 2000)),0,1);" >/dev/null 2>&1
seeded=$(sql "SELECT COUNT(*) FROM conversations WHERE address IN ('$READ_NUM','$UNREAD_NUM','$ARCHIVED_NUM');" | tr -d ' \n')
[ "$seeded" = "3" ] && ok "three conversations seeded" || bad "expected 3 seeded rows, found '$seeded'"

info "Unlocked: the widgets show the inbox, not the archive"
line=$(probe_line -n "$ACT" --ez widget_probe true) || line=""
echo "    $line"
case "$line" in
    *"locked=false"*) ok "probe reports locked=false" ;;
    *) bad "no unlocked probe line (logcat had none)" ;;
esac
case "$line" in
    *"$READ_NUM"*) ok "read conversation is in the widget list" ;;
    *) bad "read conversation missing from the probe line" ;;
esac
case "$line" in
    *"$UNREAD_NUM"*) ok "unread conversation is in the widget list" ;;
    *) bad "unread conversation missing from the probe line" ;;
esac
case "$line" in
    *"$ARCHIVED_NUM"*) bad "archived conversation leaked into the widget" ;;
    *) ok "archived conversation is excluded" ;;
esac
unread_part=$(printf '%s' "$line" | sed -E 's/.*unread=\[([^]]*)\].*/\1/')
case "$unread_part" in
    *"$UNREAD_NUM|Unread Two|2"*) ok "unread widget carries the unread row and its count" ;;
    *) bad "unread widget does not carry '$UNREAD_NUM|Unread Two|2' (saw '$unread_part')" ;;
esac
expected_total=$(sql "SELECT COALESCE(SUM(unread_count),0) FROM conversations WHERE deleted_at=0 AND blocked=0 AND archived=0;" | tr -d ' \n')
case "$line" in
    *"total=$expected_total"*) ok "unread total matches the inbox ($expected_total messages)" ;;
    *) bad "expected total=$expected_total in the probe line" ;;
esac

info "App lock blanks both widgets"
line=$(probe_line -n "$ACT" --es app_lock_probe enable --ez widget_probe true) || line=""
echo "    $line"
case "$line" in
    *"locked=true"*) ok "probe reports locked=true" ;;
    *) bad "app lock did not lock the widgets" ;;
esac
case "$line" in
    *"list=[] unread=[] total=0"*) ok "locked line carries no rows and no total" ;;
    *) bad "locked line still carries widget data: '$line'" ;;
esac
case "$line" in
    *"$READ_NUM"*|*"$UNREAD_NUM"*|*"$ARCHIVED_NUM"*|*"Read One"*|*"Unread Two"*)
        bad "a locked widget still names a conversation" ;;
    *) ok "a locked widget names nothing" ;;
esac
adb_ shell am start -n "$ACT" --es app_lock_probe disable >/dev/null 2>&1
sleep 1
info "Privacy mode blanks both widgets"
line=$(probe_line -n "$ACT" --ez privacy_mode true --ez widget_probe true) || line=""
echo "    $line"
case "$line" in
    *"locked=true"*) ok "privacy mode sets locked=true" ;;
    *) bad "privacy mode did not lock the widgets" ;;
esac
case "$line" in
    *"$READ_NUM"*|*"$UNREAD_NUM"*|*"Read One"*|*"Unread Two"*)
        bad "a privacy-locked widget still names a conversation" ;;
    *) ok "a privacy-locked widget names nothing" ;;
esac
adb_ shell am start -n "$ACT" --ez privacy_mode false >/dev/null 2>&1
sleep 1

echo
echo "widgets regression: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
