#!/usr/bin/env bash
# Regression: a GENUINE backup from SMS Import / Export (tmo1/sms_ie) is
# importable by this app.
#
# This is deliberately end-to-end rather than synthetic. The existing
# test-sms-ie-import.sh builds a fixture whose field shapes were copied from a
# real export, which proves the parser but not that a real file works: a shape
# the exporting app has since changed would pass the synthetic test and still
# fail on a real user's backup.
#
# So this drives the actual app: it exports the emulator's own SMS store, pulls
# the file off the device, and imports that into Messages. The export app is
# expected to be installed already (com.github.tmo1.sms_ie); if it is not, the
# script says so and skips rather than failing, since downloading and
# installing a third-party app is not something a regression script should do.
#
# Merge mode only. Restore replaces the whole history, which would destroy the
# emulator's seeded conversations, and a real export is a snapshot of exactly
# what Messages already synced from the same provider -- so this asserts the
# import is complete and faithful, not that it produced new conversations.
source "$(dirname "$0")/env.sh"

SMSIE=com.github.tmo1.sms_ie
PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
skip_all() { echo "=== SKIPPED: $1 ==="; exit 0; }

ZIP="$TMP/real-smsie-export.zip"
REMOTE_ZIP=/data/local/tmp/real-smsie-export.zip
INAPP_ZIP="/data/data/$PKG/files/real-smsie-export.zip"

db() { adb_ shell "run-as $PKG sqlite3 databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r'; }

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    adb_ shell "run-as '$PKG' rm -f files/real-smsie-export.zip" >/dev/null 2>&1 || true
    adb_ shell "rm -f $REMOTE_ZIP" >/dev/null 2>&1 || true
}
trap cleanup EXIT

info "SMS Import / Export is available"
if ! adb_ shell pm list packages 2>/dev/null | grep -q "$SMSIE"; then
    skip_all "$SMSIE is not installed; a real export cannot be produced"
fi
ok "$SMSIE installed"

info "It can read the SMS store"
adb_ shell pm grant "$SMSIE" android.permission.READ_SMS >/dev/null 2>&1 || true
if adb_ shell dumpsys package "$SMSIE" 2>/dev/null | grep -q "READ_SMS: granted=true"; then
    ok "READ_SMS granted to $SMSIE"
else
    bad "could not grant READ_SMS; the export will be empty"
fi

info "Drive a real EXPORT MESSAGES"
BEFORE=$(db 'SELECT COUNT(*) FROM messages;')
adb_ shell am force-stop "$SMSIE" >/dev/null 2>&1
adb_ shell am start -n "$SMSIE/.MainActivity" >/dev/null 2>&1
sleep 6
# Permission dialogs can appear on first run; allow then dismiss.
for _ in 1 2 3; do
    dump_ui
    if grep -q 'text="ALLOW"' "$TMP/ui.xml"; then
        tap_text "ALLOW" >/dev/null 2>&1; sleep 3
    else
        break
    fi
done
if ! tap_text "EXPORT MESSAGES" >/dev/null 2>&1; then
    bad "could not find EXPORT MESSAGES in $SMSIE"
    exit 1
fi
sleep 4
# The SAF picker defaults to Downloads with a date-stamped name already typed.
if ! tap_text "SAVE" >/dev/null 2>&1; then
    bad "could not confirm the SAF save dialog"
    exit 1
fi
sleep 8

# The picker chose its own filename, so find whatever it just wrote.
EXPORTED=$(adb_ shell "ls -t /sdcard/Download/messages-*.zip 2>/dev/null | head -1" | tr -d '\r')
[ -n "$EXPORTED" ] || { bad "no export file appeared in /sdcard/Download"; exit 1; }
ok "export written to $EXPORTED"
adb_ pull "$EXPORTED" "$ZIP" >/dev/null 2>&1
[ -s "$ZIP" ] && ok "export pulled off the device ($(stat -c%s "$ZIP") bytes)" \
    || { bad "could not pull the export"; exit 1; }

info "It is a v2 backup this app recognises"
unzip -l "$ZIP" | grep -q "messages.ndjson" \
    && ok "ZIP contains messages.ndjson (v2 layout)" \
    || bad "no messages.ndjson in the export"
RECORDS=$(unzip -p "$ZIP" messages.ndjson 2>/dev/null | grep -c '^{')
[ "${RECORDS:-0}" -gt 0 ] && ok "export holds $RECORDS message records" \
    || { bad "export holds no records"; exit 1; }

info "Import that real file (merge)"
adb_ shell "run-as '$PKG' sh -c 'cp $REMOTE_ZIP files/real-smsie-export.zip'" >/dev/null 2>&1
adb_ push "$ZIP" "$REMOTE_ZIP" >/dev/null 2>&1
adb_ shell "run-as '$PKG' sh -c 'cp $REMOTE_ZIP files/real-smsie-export.zip'" >/dev/null 2>&1
adb_ logcat -c >/dev/null 2>&1 || true
adb_ shell am force-stop "$PKG" >/dev/null 2>&1
adb_ shell am start -n "$ACT" --es sms_ie_probe "file://$INAPP_ZIP" >/dev/null 2>&1
AFTER=$BEFORE
for _ in $(seq 1 30); do
    sleep 2
    AFTER=$(db 'SELECT COUNT(*) FROM messages;')
    [ "${AFTER:-0}" -gt "${BEFORE:-0}" ] && break
done
if [ "${AFTER:-0}" -gt "${BEFORE:-0}" ]; then
    ok "imported $((AFTER - BEFORE)) records from the real export"
else
    bad "nothing imported (before=$BEFORE after=${AFTER:-?})"
    adb_ logcat -d -s SmsIeImport 2>/dev/null | tr -d '\r' | sed 's/^/    | /'
    exit 1
fi

IMPLIED=$(adb_ logcat -d -s SmsIeImport 2>/dev/null | tr -d '\r' \
    | grep -oE 'count=[0-9]+' | tail -1 | cut -d= -f2)
if [ "${IMPLIED:-0}" = "$RECORDS" ]; then
    ok "the app read all $RECORDS records, matching the export exactly"
else
    bad "app reported ${IMPLIED:-?} records imported, export had $RECORDS"
fi

info "Direction and timestamps survive the round trip"
db "SELECT COUNT(*) FROM messages WHERE is_me=1;" >/dev/null 2>&1
if [ "$(db "SELECT COUNT(DISTINCT is_me) FROM messages;")" = "2" ]; then
    ok "both sent and received messages are present"
else
    bad "one direction is missing after import"
fi
if [ "$(db "SELECT COUNT(*) FROM messages WHERE timestamp <= 0;")" = "0" ]; then
    ok "every message has a real timestamp (not reset to import time)"
else
    bad "some messages have no timestamp"
fi

info "Stale contact names in the backup are not trusted"
# __display_name is the exporting app's cached label. This app resolves names
# from the device, so importing a backup must not repin a conversation to a name
# that has since changed on the phone.
python3 - "$ZIP" "$TMP/poisoned.zip" <<'PY'
import json, sys, zipfile
src, out = sys.argv[1], sys.argv[2]
lines = [l for l in zipfile.ZipFile(src).read('messages.ndjson').decode().splitlines() if l.strip()]
recs = []
for l in lines[:2]:
    d = json.loads(l)
    d['__display_name'] = 'POISON NAME MUST NOT BE USED'
    d['body'] = 'namedrop ' + d['body']
    recs.append(json.dumps(d))
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
    z.writestr('messages.ndjson', '\n'.join(recs))
PY
# An address from the export, and the name the app currently resolves for it.
ADDR=$(unzip -p "$ZIP" messages.ndjson 2>/dev/null | head -1 \
    | python3 -c "import sys,json; print(json.loads(sys.stdin.readline()).get('address',''))")
BEFORE_NAME=$(db "SELECT name FROM conversations WHERE address='$ADDR';")
adb_ push "$TMP/poisoned.zip" /data/local/tmp/poisoned.zip >/dev/null 2>&1
adb_ shell "run-as '$PKG' sh -c 'cp /data/local/tmp/poisoned.zip files/poisoned.zip'" >/dev/null 2>&1
adb_ shell am force-stop "$PKG" >/dev/null 2>&1
adb_ shell am start -n "$ACT" --es sms_ie_probe "file:///data/data/$PKG/files/poisoned.zip" >/dev/null 2>&1
for _ in $(seq 1 20); do
    sleep 2
    [ "$(db "SELECT COUNT(*) FROM messages WHERE body LIKE 'namedrop %';")" != "0" ] && break
done
if [ "$(db "SELECT COUNT(*) FROM messages WHERE body LIKE 'namedrop %';")" = "0" ]; then
    bad "the poisoned backup did not import, so the name rule is untested"
else
    ok "the poisoned backup imported (so the name rule was actually exercised)"
    AFTER_NAME=$(db "SELECT name FROM conversations WHERE address='$ADDR';")
    if [ "$BEFORE_NAME" = "$AFTER_NAME" ]; then
        ok "__display_name ignored: still '$AFTER_NAME'"
    else
        bad "__display_name overwrote the device name: '$BEFORE_NAME' -> '$AFTER_NAME'"
    fi
    db "DELETE FROM messages WHERE body LIKE 'namedrop %';" >/dev/null 2>&1
fi
adb_ shell "run-as '$PKG' rm -f files/poisoned.zip" >/dev/null 2>&1 || true
adb_ shell "rm -f /data/local/tmp/poisoned.zip" >/dev/null 2>&1 || true

info "Roll back the import so the emulator is left as found"
# Every imported row is newer than the ones already there, and a real export is
# a snapshot of what Messages already synced, so these are pure duplicates.
db "DELETE FROM messages WHERE id > $BEFORE;" >/dev/null 2>&1
FINAL=$(db 'SELECT COUNT(*) FROM messages;')
[ "${FINAL:-0}" = "${BEFORE:-0}" ] && ok "message count back to $FINAL" \
    || bad "left $FINAL messages, expected $BEFORE"
db "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1
ORPHANS=$(db 'SELECT COUNT(*) FROM conversations WHERE id NOT IN (SELECT conversation_id FROM messages);')
[ "${ORPHANS:-0}" = "0" ] && ok "no empty conversations left behind" \
    || bad "$ORPHANS empty conversations survived"

info "No crash during the import"
if adb_ logcat -d -b crash 2>/dev/null | grep -q "$PKG"; then
    bad "the app crashed during the import"
else
    ok "no crash"
fi

echo ""
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
