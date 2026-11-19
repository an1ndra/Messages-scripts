#!/usr/bin/env bash
# Regression for the participant write that needed SQLite 3.24.
#
# Android 10 ships SQLite 3.22, where `INSERT … ON CONFLICT … DO UPDATE` is a
# syntax error. The participant migration uses that write and runs on a
# background thread at startup, so on an installation that already had message
# history the process died before any screen appeared.
#
# This drives the migration itself: conversations are seeded, the "already
# migrated" flag and the participants table are cleared, and the app is
# launched. Before the fix the launch crashes and no participant row is ever
# written; after it the app stays up and every seeded number has its row.
#
# Run: scripts/test-participant-upsert.sh   (emulator-5556)
set -uo pipefail
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }

NUM1="+15551230071"
NUM2="+15551230072"
NUM3="15551230073"   # stored without the plus: it must normalise to +1555…

PREFS="shared_prefs/messages_settings.xml"

sql() { adb_ shell "run-as $PKG sqlite3 databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r'; }

seed_conversation() {
    local addr="$1" name="$2" ts
    ts=$(( $(date +%s) * 1000 ))
    sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$addr');" >/dev/null
    sql "DELETE FROM conversations WHERE address='$addr';" >/dev/null
    sql "INSERT INTO conversations(address,name,snippet,timestamp,unread_count,last_is_me,deleted_at)
         VALUES('$addr','$name','hello',$ts,0,1,0);" >/dev/null
}

# The migration only runs when the flag says it has not — or when the stored
# phone region changed — so it is cleared here, along with the table it fills.
forget_migration() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
    adb_ shell "run-as $PKG sh -c 'sed -i \"/name=\\\"participants_migrated\\\"/d\" $PREFS'" >/dev/null 2>&1
    sql "DELETE FROM participants;" >/dev/null
}

launch() {
    local i act
    for i in 1 2 3; do
        adb_ shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1
        adb_ shell wm dismiss-keyguard >/dev/null 2>&1
        adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 6
        act=$(adb_ shell dumpsys activity activities 2>/dev/null | tr -d '\r')
        case "$act" in
            *mResumedActivity*"$PKG"*) return 0 ;;
        esac
        echo "[info] launch attempt $i did not come up; retrying"
        sleep 3
    done
    return 1
}

cleanup() {
    for n in "$NUM1" "$NUM2" "$NUM3"; do
        sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$n');" >/dev/null 2>&1
        sql "DELETE FROM conversations WHERE address='$n';" >/dev/null 2>&1
        sql "DELETE FROM participants WHERE normalized_destination='$n';" >/dev/null 2>&1
    done
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
}
trap cleanup EXIT

info "Set up: permissions, role, three seeded conversations"
mkdir -p "$TMP"
for p in READ_SMS READ_CONTACTS POST_NOTIFICATIONS; do
    adb_ shell pm grant "$PKG" "android.permission.$p" >/dev/null 2>&1
done
adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1 || true
adb_ shell svc power stayon true >/dev/null 2>&1
adb_ shell "run-as $PKG sh -c 'rm -f files/crash_reports/*.txt'" >/dev/null 2>&1
seed_conversation "$NUM1" "Upsert One"
seed_conversation "$NUM2" "Upsert Two"
seed_conversation "$NUM3" "Upsert Three"
forget_migration
pass "seeded three conversations with the migration un-run"

info "1. The app survives the participant migration"
if launch; then
    pass "the app is up after the migration ran"
else
    fail "the app never came up: the migration took the process down"
fi

info "2. Every conversation got its participant row"
BEFORE=$(sql "SELECT count(*) FROM participants;")
if [ "${BEFORE:-0}" -ge 3 ]; then
    pass "the participants table was filled ($BEFORE rows)"
else
    fail "the participants table holds ${BEFORE:-0} rows, expected at least 3"
fi
if [ -n "$(sql "SELECT id FROM participants WHERE normalized_destination='$NUM1';")" ]; then
    pass "the first number was stored"
else
    fail "no participant row for $NUM1"
fi
if [ -n "$(sql "SELECT id FROM participants WHERE normalized_destination='+$NUM3';")" ]; then
    pass "a number stored without its plus was normalised to E.164"
else
    fail "no normalised participant row for $NUM3"
fi
if [ -n "$(sql "SELECT display_destination FROM participants WHERE normalized_destination='$NUM1' AND display_destination<>'';")" ]; then
    pass "the display form was written too"
else
    fail "the participant row has no display form"
fi

info "3. The migration left no crash behind, and is marked done"
NEWER=$(adb_ shell "run-as $PKG sh -c 'ls files/crash_reports/*.txt 2>/dev/null | wc -l'" | tr -d '\r')
if [ "${NEWER:-0}" = "0" ]; then
    pass "no crash report was written"
else
    fail "the app wrote $NEWER crash report(s)"
fi
if adb_ shell "run-as $PKG cat $PREFS" 2>/dev/null | tr -d '\r' | grep -q 'name="participants_migrated" value="true"'; then
    pass "the pass marked itself done, so it will not repeat"
else
    fail "the migration flag was not written"
fi

echo
echo "Result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
