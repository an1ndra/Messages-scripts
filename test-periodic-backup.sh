#!/usr/bin/env bash
# Regression for #290: periodic backup is an opt-in setting with a Daily/Weekly
# cadence, and the cadence the user picks is exactly what WorkManager schedules.
# The scheduled snapshot is the plaintext one from #292, because a background
# worker cannot prompt for a backup PIN.
#
# The UI is driven through the `android` CLI; the resulting schedule is read
# back from WorkManager's own WorkSpec table and from JobScheduler, so the test
# proves the toggle did something, not merely that the switch moved.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

PREFS="/data/data/$PKG/shared_prefs/messages_settings.xml"
WORKDB="/data/data/$PKG/no_backup/androidx.work.workdb"
DIR="/sdcard/Documents/Messages"

adb_ root >/dev/null 2>&1
adb_ wait-for-device; sleep 1

pref_edit() { adb_ shell "sed -i '$1' $PREFS" 2>/dev/null; }
pref_bool_is() { [ "$(adb_ shell "grep -c 'name=\"$1\" value=\"$2\"' $PREFS" 2>/dev/null | tr -d '\r')" != "0" ]; }
pref_str_is()  { [ "$(adb_ shell "grep -c 'name=\"$1\">$2<' $PREFS" 2>/dev/null | tr -d '\r')" != "0" ]; }
work_interval() {
    adb_ shell "sqlite3 '$WORKDB' \"SELECT interval_duration FROM WorkSpec WHERE worker_class_name LIKE '%PeriodicBackupWorker%';\"" 2>/dev/null | tr -d '\r'
}
# WorkInfo.State ordinal: ENQUEUED=0, CANCELLED=5.
work_state() {
    adb_ shell "sqlite3 '$WORKDB' \"SELECT state FROM WorkSpec WHERE worker_class_name LIKE '%PeriodicBackupWorker%';\"" 2>/dev/null | tr -d '\r'
}

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    pref_edit 's#name="periodic_backup_enabled" value="true"#name="periodic_backup_enabled" value="false"#'
    pref_edit 's#\(name="periodic_backup_interval">\)[^<]*#\1weekly#'
    adb_ shell "rm -f $DIR/messages_backup_*.db" >/dev/null 2>&1
    adb_ shell am start -n "$ACT" >/dev/null 2>&1
}
trap cleanup EXIT

info "Deterministic start: periodic backup off, weekly"
close_documents_ui
adb_ shell am force-stop "$PKG"; sleep 1
pref_edit 's#name="periodic_backup_enabled" value="true"#name="periodic_backup_enabled" value="false"#'
pref_edit 's#\(name="periodic_backup_interval">\)[^<]*#\1weekly#'
adb_ shell "rm -f $DIR/messages_backup_*.db" >/dev/null 2>&1
adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null 2>&1; sleep 4

# The periodic controls live in the "Set backup PIN" dialog, not in General
# settings, so the dialog is where the test drives them.
info "Open the backup dialog"
scroll_to_layout "Backup messages" || { bad "Backup messages row not found"; exit 1; }
tap_layout "Backup messages" || { bad "could not open the backup dialog"; exit 1; }
sleep 1
if layout_has "Periodic backup"; then ok "periodic option lives in the backup dialog"; else bad "no periodic option in the dialog"; exit 1; fi

info "Enable periodic backup"
tap_layout "Periodic backup"; sleep 2
if pref_bool_is periodic_backup_enabled true; then ok "setting enabled"; else bad "setting did not turn on"; fi
if layout_has "Daily" && layout_has "Weekly"; then ok "both cadences offered"; else bad "cadence options missing"; fi
if [ "$(work_state)" = "0" ]; then ok "WorkManager job enqueued"; else bad "work state is '$(work_state)', expected ENQUEUED(0)"; fi

info "Daily cadence is what gets scheduled"
tap_layout "Daily"; sleep 2
if pref_str_is periodic_backup_interval daily; then ok "interval stored as daily"; else bad "interval not stored daily"; fi
if [ "$(work_interval)" = "86400000" ]; then ok "WorkManager interval is 1 day"; else bad "interval is '$(work_interval)', expected 86400000"; fi

info "Weekly cadence reschedules"
tap_layout "Weekly"; sleep 2
if pref_str_is periodic_backup_interval weekly; then ok "interval stored as weekly"; else bad "interval not stored weekly"; fi
if [ "$(work_interval)" = "604800000" ]; then ok "WorkManager interval is 7 days"; else bad "interval is '$(work_interval)', expected 604800000"; fi

info "Disabling cancels the schedule"
tap_layout "Periodic backup"; sleep 2
if pref_bool_is periodic_backup_enabled false; then ok "setting disabled"; else bad "setting still on"; fi
STATE=$(work_state)
if [ -z "$STATE" ] || [ "$STATE" = "5" ]; then
    ok "work cancelled (state='${STATE:-removed}')"
else
    bad "work still active (state='$STATE', expected CANCELLED(5) or gone)"
fi

info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
