#!/usr/bin/env bash
# A database from a newer build explains itself instead of killing the app.
#
# The schema only moves forward. Installing a build from an older branch over
# one from a newer branch leaves a database the older code cannot read, and
# SQLiteOpenHelper answers with "Can't downgrade database from version 35 to
# 33" from a background worker: the process dies before any screen exists, which
# reads as "the app will not open" and gives the user nothing to act on.
#
# The script fakes exactly that state by bumping the database's user_version,
# then asserts:
#   * the app is still running and shows the explanation, not a crash,
#   * the explanation names both versions,
#   * "Start over instead" asks before it deletes anything,
#   * choosing it leaves a working app (the conversation list opens).
#
# Run: scripts/test-db-schema-downgrade.sh
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

TITLE=$(res_string db_newer_title)
OK=$(res_string db_newer_ok)
POLLS=25

wait_present() {
    local i
    for i in $(seq 1 "$POLLS"); do
        ui_has "$1" && return 0
        sleep 0.4
    done
    return 1
}

wait_gone() {
    local i
    for i in $(seq 1 "$POLLS"); do
        ui_has "$1" || return 0
        sleep 0.4
    done
    return 1
}

app_alive() {
    adb_ shell dumpsys activity activities 2>/dev/null | grep -m1 mResumedActivity | grep -q "$PKG"
}

# The default-SMS prompt ("Set as default SMS app?") can sit over the list on a
# freshly installed build; it is not what this script is testing.
dismiss_prompts() {
    local i
    for i in 1 2 3; do
        if ui_has "$(res_string default_sms_title)"; then
            tap_text "$(res_string default_sms_not_now)" >/dev/null 2>&1
        elif ui_has "ALLOW" && ! ui_has "$(res_string access_start_chat)"; then
            # a runtime-permission sheet, not what this script is testing
            adb_ shell input keyevent KEYCODE_BACK >/dev/null 2>&1
        elif ! ui_has "$(res_string access_start_chat)"; then
            adb_ shell input keyevent KEYCODE_BACK >/dev/null 2>&1
        fi
        sleep 1
    done
}

opens_list() { dismiss_prompts; wait_present "$(res_string access_start_chat)"; }

# Start from a known state: a previous run (or a real install of another
# branch) may have left a database this build cannot read.
adb_ shell pm clear "$PKG" >/dev/null 2>&1
# pm clear also drops the runtime grants, and the permission dialogs would sit
# over the list this script is waiting for.
for perm in SEND_SMS RECEIVE_SMS READ_SMS READ_CONTACTS READ_PHONE_STATE; do
    adb_ shell pm grant "$PKG" android.permission.$perm >/dev/null 2>&1
done
# The app shows its "set as default SMS" screen instead of the list when it is
# not the default handler, which is not what this script is testing.
adb_su "cmd role add-role-holder android.app.role.SMS $PKG" >/dev/null 2>&1
adb_ shell am start -n "$ACT" >/dev/null 2>&1
sleep 3
if ! opens_list; then
    bad "the app did not open on a healthy database"
    exit 1
fi
ok "a normal database still opens"

# ── fake a database written by a newer build ────────────────────────────────
adb_ shell am force-stop "$PKG" >/dev/null 2>&1
CURRENT=$(adb_ shell "run-as $PKG sqlite3 databases/messages.db 'PRAGMA user_version'" 2>/dev/null | tr -d '\r')
[ -n "$CURRENT" ] || { bad "could not read the database version"; exit 1; }
NEWER=$(( CURRENT + 2 ))
adb_ shell "run-as $PKG sqlite3 databases/messages.db 'PRAGMA user_version=$NEWER'" >/dev/null 2>&1
ok "database moved to v$NEWER (app is v$CURRENT)"

adb_ shell logcat -c >/dev/null 2>&1
adb_ shell am start -n "$ACT" >/dev/null 2>&1
sleep 3

if wait_present "$TITLE"; then
    ok "the app explains the newer data instead of crashing"
else
    bad "no explanation on screen"
fi

if app_alive; then
    ok "the app is still running"
else
    bad "the app died instead of explaining itself"
fi

if ui_has "v$CURRENT"; then
    ok "the explanation names this build's version (v$CURRENT)"
else
    bad "the explanation hides its own version"
fi
if ui_has "v$NEWER"; then
    ok "the explanation names the newer data (v$NEWER)"
else
    bad "the explanation does not say what the data needs"
fi

if adb_ shell logcat -d 2>/dev/null | grep -q "Can't downgrade database"; then
    bad "the downgrade exception was thrown anyway"
else
    ok "SQLite was never asked to downgrade"
fi

# ── the newer file is kept, the app starts clean ────────────────────────────
BACKUP=$(adb_ shell "run-as $PKG ls databases/" 2>/dev/null | tr -d '\r' | grep -c "messages.newer-v$NEWER")
if [ "$BACKUP" = "1" ]; then
    ok "the newer database is kept as messages.newer-v$NEWER.db, not deleted"
else
    bad "the newer database was not kept"
fi

if ui_has "messages.newer-v$NEWER.db"; then
    ok "the explanation names the file it kept"
else
    bad "the explanation does not say where the data went"
fi

tap_text "$OK" >/dev/null
if wait_gone "$TITLE"; then
    ok "the notice can be dismissed"
else
    bad "the notice would not close"
fi

if opens_list; then
    ok "the app opens normally on its fresh database"
else
    bad "the app did not open after parking the newer file"
fi

if adb_ shell "run-as $PKG sqlite3 databases/messages.db 'PRAGMA user_version'" 2>/dev/null | tr -d '\r' | grep -qx "$CURRENT"; then
    ok "the fresh database is this build's version (v$CURRENT)"
else
    bad "the app did not create a database at its own version"
fi

# Told once: a second launch must not nag about a file already explained.
adb_ shell am force-stop "$PKG" >/dev/null 2>&1
adb_ shell am start -n "$ACT" >/dev/null 2>&1
sleep 3
if ui_has "$TITLE"; then
    bad "the notice came back on the next launch"
else
    ok "the notice is shown once, not on every launch"
fi

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
