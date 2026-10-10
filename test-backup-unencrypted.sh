#!/usr/bin/env bash
# Regression for #292: the backup flow offers a passwordless option behind a
# warning, and it writes a plain SQLite database (the RAW format the importer
# already recognises) rather than an encrypted blob.
#
# Navigation uses the `android` CLI (`layout`/`tap`) so the assertions read the
# real UI text; the written file is checked on disk for the SQLite magic.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

DIR="/sdcard/Documents/Messages"
PREFS="/data/data/$PKG/shared_prefs/messages_settings.xml"

adb_ root >/dev/null 2>&1
adb_ wait-for-device; sleep 1

# sed -i on the prefs XML while the app is stopped: deterministic starting state
# without a `pm clear` that would wipe the seeded database too.
pref_edit() { adb_ shell "sed -i '$1' $PREFS" 2>/dev/null; }

cleanup() {
    adb_ shell "rm -f $DIR/messages_backup_*.db" >/dev/null 2>&1
}
trap cleanup EXIT

info "Deterministic start: privacy off, default backup location, no stale backups"
close_documents_ui
adb_ shell am force-stop "$PKG"; sleep 1
pref_edit 's#name="privacy_mode" value="true"#name="privacy_mode" value="false"#'
pref_edit 's#\(name="backup_tree_uri">\)[^<]*#\1#'
adb_ shell "rm -f $DIR/messages_backup_*.db" >/dev/null 2>&1
adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null 2>&1; sleep 4

info "Saving with no PIN opens the unencrypted warning"
scroll_to_layout "Backup messages" || { bad "Backup messages row not found"; exit 1; }
tap_layout "Backup messages" || { bad "could not open the backup dialog"; exit 1; }
sleep 1
# Leave the PIN fields empty: Save itself means "back up without a PIN".
tap_layout_exact "Save"; sleep 1
if layout_has "not be encrypted"; then
    ok "warning shown when saving without a PIN"
else
    bad "no unencrypted warning shown"
    exit 1
fi

info "Confirming writes a plain SQLite database"
tap_layout "Back up anyway"; sleep 3
NAME=$(adb_ shell "ls $DIR" 2>/dev/null | tr -d '\r' | grep 'messages_backup_.*\.db' | tail -1)
if [ -n "$NAME" ]; then
    ok "unencrypted backup file created ($NAME)"
else
    bad "no .db backup file in $DIR"
    exit 1
fi

HEAD=$(adb_ exec-out "cat '$DIR/$NAME'" 2>/dev/null | head -c 16 | od -An -tx1 | tr -d ' \n')
case "$HEAD" in
    53514c69746520666f726d6174*) ok "file starts with the SQLite header ($HEAD)";;
    *) bad "file is not a plain SQLite database ($HEAD)";;
esac

info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
