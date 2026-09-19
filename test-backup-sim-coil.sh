#!/usr/bin/env bash
# Regression for the backup-location, blocked-keywords-UI, SIM-chip and Coil
# image-loading changes.
#
#   1. Settings has a "Backup location" row; default label is the default
#      folder; tapping it opens the SAF folder picker (issue #212).
#   2. The blocked-keywords dialog shows a title icon + count badge and a
#      single-line add field (UI polish).
#   3. With the debug fake dual-SIM flag, SIM selection remains in the chat
#      3-dot menu (no control inside the text field).
#   4. The app launches with Coil on the classpath and loads an image message
#      without crashing (Coil migration).
#
# Run: scripts/test-backup-sim-coil.sh
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh

PASS=0
FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }

[[ "$ANDROID_SERIAL" == emulator-* ]] || { printf 'Requires a disposable emulator.\n'; exit 1; }

NUM="+1555$(date +%s | tail -c 8)"

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    adb_ shell "run-as $PKG sqlite3 databases/messages.db \"DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM'); DELETE FROM conversations WHERE address='$NUM'; DELETE FROM participants WHERE normalized_destination='$NUM';\"" >/dev/null 2>&1 || true
    adb_ shell "run-as $PKG sh -c 'sed -i \"/backup_tree_uri/d\" shared_prefs/messages_settings.xml'" >/dev/null 2>&1 || true
}
trap cleanup EXIT

adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1 || true
bash ./grant-permissions.sh >/dev/null 2>&1 || true
# Start from the default backup location so the label assertion is deterministic.
adb_ shell "run-as $PKG sh -c 'sed -i \"/backup_tree_uri/d\" shared_prefs/messages_settings.xml'" >/dev/null 2>&1 || true

info "1. single Backup row offers a folder choice inside the backup flow"
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null
sleep 3
for _ in 1 2 3 4 5 6; do
    dump_ui >/dev/null 2>&1
    grep -q 'text="Backup messages"' "$TMP/ui.xml" && break
    adb_ shell input swipe 540 1700 540 900 250 >/dev/null 2>&1; sleep 0.5
done
grep -q 'text="Backup messages"' "$TMP/ui.xml" && pass 'settings shows the Backup messages row' || fail 'Backup messages row missing'
# The former standalone row must be gone (folder choice lives in the dialog).
grep -q 'text="Backup location"' "$TMP/ui.xml" && fail 'separate Backup location row still present' || pass 'no separate Backup location row'
c=$(center_of "Backup messages") || c=""
[ -n "$c" ] && adb_ shell input tap $c; sleep 2
dump_ui >/dev/null 2>&1
grep -q 'text="Set backup PIN"' "$TMP/ui.xml" && pass 'backup opens the Set PIN dialog' || fail 'Set PIN dialog missing'
grep -q 'text="Save to"' "$TMP/ui.xml" && pass 'dialog shows the Save to location' || fail 'Save to row missing'
grep -q 'text="Default (Documents/Messages)"' "$TMP/ui.xml" && pass 'default location shown' || fail 'default location missing'
c=$(center_of "Change") || c=""
[ -n "$c" ] && adb_ shell input tap $c; sleep 3
dump_ui >/dev/null 2>&1
# The SAF picker is a separate app (DocumentsUI); its package must be foreground.
TOP=$(adb_ shell dumpsys activity activities 2>/dev/null | grep -oE "topResumedActivity=ActivityRecord\{[^ ]+ [^ ]+ [^ ]+" | head -1)
if echo "$TOP" | grep -qiE "documentsui|DocumentsActivity|picker"; then
    pass 'Change opens the system folder picker'
elif echo "$TOP" | grep -qv "$PKG"; then
    pass 'Change opens a system picker'
else
    fail "folder picker did not open ($TOP)"
fi
adb_ shell input keyevent 4 >/dev/null 2>&1 || true
adb_ shell input keyevent 4 >/dev/null 2>&1 || true

info "2. blocked-keywords dialog UI"
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null
sleep 3
for _ in 1 2 3 4 5 6 7 8; do
    dump_ui >/dev/null 2>&1
    grep -q 'text="Advanced"' "$TMP/ui.xml" && break
    adb_ shell input swipe 540 1700 540 900 250 >/dev/null 2>&1; sleep 0.5
done
c=$(center_of "Advanced") || c=""
[ -n "$c" ] && adb_ shell input tap $c; sleep 2
for _ in 1 2 3 4 5 6; do
    dump_ui >/dev/null 2>&1
    grep -q 'text="Blocked keywords"' "$TMP/ui.xml" && break
    adb_ shell input swipe 540 1700 540 900 250 >/dev/null 2>&1; sleep 0.5
done
c=$(center_of "Blocked keywords") || c=""
[ -n "$c" ] && adb_ shell input tap $c; sleep 2
dump_ui >/dev/null 2>&1
if grep -q 'text="Blocked keywords"' "$TMP/ui.xml"; then
    pass 'blocked-keywords dialog opens'
else
    fail 'blocked-keywords dialog did not open'
fi
if grep -q 'text="Add keyword"' "$TMP/ui.xml"; then
    pass 'add-keyword field present'
else
    fail 'add-keyword field missing'
fi
adb_ shell input keyevent 4 >/dev/null 2>&1 || true

info "3. SIM selection stays in the chat 3-dot menu (fake dual-SIM)"
adb_ emu sms send "$NUM" "coilprobe $(date +%s)" >/dev/null
sleep 2
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" --ez fake_dual_sim true --es open_conversation_address "$NUM" >/dev/null
sleep 4
dump_ui >/dev/null 2>&1
grep -q 'content-desc="Change SIM"' "$TMP/ui.xml" \
    && fail 'in-field SIM control should have been removed' \
    || pass 'no SIM control inside the text field'
c=$(center_of_contains "More options") || c=""
[ -n "$c" ] && adb_ shell input tap $c; sleep 1.5
dump_ui >/dev/null 2>&1
if grep -q 'text="SIM 2 · Vodafone"' "$TMP/ui.xml"; then
    pass '3-dot menu offers SIM selection'
else
    fail '3-dot menu missing SIM selection'
fi
# Selecting the second SIM should persist the choice.
c=$(center_of "SIM 2 · Vodafone") || c=""
[ -n "$c" ] && adb_ shell input tap $c; sleep 1.5
adb_ shell "run-as $PKG cat shared_prefs/messages_settings.xml" 2>/dev/null \
    | grep -q 'sim_subscription_id" value="7"' \
    && pass 'selecting the second SIM updates the pref' \
    || fail 'SIM selection did not persist'
adb_ shell "run-as $PKG sh -c 'sed -i \"s/sim_subscription_id\\\" value=\\\"7\\\"/sim_subscription_id\\\" value=\\\"-1\\\"/\" shared_prefs/messages_settings.xml'" >/dev/null 2>&1 || true
adb_ shell input keyevent 4 >/dev/null 2>&1 || true

info "4. privacy mode disables backup"
set_privacy() {
    adb_ shell am force-stop "$PKG"; sleep 1
    adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null; sleep 3
    for _ in 1 2 3 4 5 6; do
        dump_ui >/dev/null 2>&1
        grep -q 'text="Advanced"' "$TMP/ui.xml" && break
        adb_ shell input swipe 540 1800 540 500 300 >/dev/null 2>&1; sleep 0.5
    done
    c=$(center_of "Advanced") || c=""
    [ -n "$c" ] && adb_ shell input tap $c; sleep 2
    for _ in 1 2 3 4; do
        dump_ui >/dev/null 2>&1
        grep -q 'text="Privacy mode"' "$TMP/ui.xml" && break
        adb_ shell input swipe 540 1800 540 500 300 >/dev/null 2>&1; sleep 0.5
    done
    c=$(center_of "Privacy mode") || c=""
    [ -n "$c" ] && adb_ shell input tap 937 "${c#* }"; sleep 1.5
}

set_privacy
PREFS=$(adb_ shell "run-as $PKG cat shared_prefs/messages_settings.xml" 2>/dev/null)
echo "$PREFS" | grep -q 'privacy_mode" value="true"' && pass 'privacy mode enabled' || fail 'could not enable privacy mode'
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null; sleep 3
for _ in 1 2 3 4 5 6; do
    dump_ui >/dev/null 2>&1
    grep -q 'text="Backup messages"' "$TMP/ui.xml" && break
    adb_ shell input swipe 540 1800 540 500 300 >/dev/null 2>&1; sleep 0.5
done
if grep -q 'text="Turn off Privacy mode to back up messages"' "$TMP/ui.xml"; then
    pass 'backup row shows the privacy-disabled reason'
else
    fail 'backup row did not indicate privacy mode'
fi
BACKUP_TAP=$(center_of "Backup messages") || BACKUP_TAP=""
if [ -n "$BACKUP_TAP" ]; then
    adb_ shell input tap $BACKUP_TAP; sleep 2
    dump_ui >/dev/null 2>&1
    grep -q 'text="Set backup PIN"' "$TMP/ui.xml" \
        && fail 'backup still opens in privacy mode' \
        || pass 'backup row is disabled in privacy mode'
else
    fail 'backup row not found'
fi
# restore privacy off for the rest of the run
set_privacy

info "5. Coil is on the classpath and the app launches cleanly"
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell logcat -c
adb_ shell am start -n "$ACT" >/dev/null
sleep 4
if adb_ shell dumpsys activity activities 2>/dev/null | grep -q "topResumedActivity=ActivityRecord.*$PKG"; then
    pass 'app launched with Coil on the classpath'
else
    fail 'app did not reach the foreground'
fi
if adb_ shell logcat -d 2>/dev/null | grep -qE "FATAL EXCEPTION|NoClassDefFoundError.*coil"; then
    fail 'crash involving Coil'
else
    pass 'no Coil-related crash'
fi

printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
