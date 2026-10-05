#!/usr/bin/env bash
# Regression: a large sms-ie backup imports, and messages deleted outside the app
# disappear from it.
#
# Two defects, both reported against a real 50k backup:
#
#  1. The import held the whole archive in memory -- the file as a ByteArray plus
#     every decompressed MMS part in a map -- so a backup with images needed the
#     entire thing resident before a single row was written. It also rescanned the
#     whole conversations table for every message, which is quadratic, and wrote
#     all rows in one transaction with insertOrThrow, so one bad record discarded
#     the rest.
#
#  2. Messages deleted in the system provider by another app (SMS Import /
#     Export's "Wipe messages") stayed on screen, because the sync only ever
#     added rows. The local database is a store of its own, not a view.
#
# The wipe half needs the SMS role handed to SMS Import / Export, since only the
# default handler can wipe. Doing so kills this app's process -- Android kills
# the outgoing default handler -- so the prune is asserted on the next launch,
# which is the path a user actually takes.
source "$(dirname "$0")/env.sh"

SMSIE=com.github.tmo1.sms_ie
PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

db() { adb_ shell "run-as $PKG sqlite3 databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r'; }
count() { db 'SELECT COUNT(*) FROM messages;' | tr -d ' \r'; }
provider_count() {
    adb_ shell content query --uri content://sms --projection _id 2>/dev/null | grep -c 'Row:'
}

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1 || true
    adb_ shell "run-as '$PKG' sh -c 'rm -f files/large-*.zip'" >/dev/null 2>&1 || true
    adb_ shell "rm -f /data/local/tmp/large-*.zip" >/dev/null 2>&1 || true
    rm -f "$TMP"/large-*.zip
}
trap cleanup EXIT

# --- 1. a large backup with images ---------------------------------------

info "Build a 50k-message backup carrying MMS images"
python3 - "$TMP/large-50k.zip" <<'PY'
import json, sys, zipfile

out = sys.argv[1]
COUNT, IMAGES, IMG_KB, CONVS = 50000, 200, 64, 500
BASE = 1_500_000_000_000
blob = b"\x00" * (IMG_KB * 1024)
parts = ["PART_%05d.jpg" % i for i in range(IMAGES)]
recs, img = [], 0
step = max(1, COUNT // IMAGES)
for i in range(COUNT):
    c = i % CONVS
    addr = "+1555%07d" % (1000000 + c * 7)
    if i % step == 0 and img < IMAGES:
        recs.append(json.dumps({
            "_id": str(i + 1), "thread_id": str(c),
            "date": str(BASE + i * 30_000), "msg_box": "1", "read": "1",
            "m_type": "132",
            "__sender_address": {"address": addr, "type": "137", "charset": "106"},
            "__recipient_addresses": [],
            "__parts": [
                {"ct": "text/plain", "text": "photo %d" % i, "chset": "106"},
                {"ct": "image/jpeg", "_data": "/data/user_de/0/x/app_parts/" + parts[img]},
            ],
        }))
        img += 1
    else:
        recs.append(json.dumps({
            "_id": str(i + 1), "thread_id": str(c), "address": addr,
            "date": str(BASE + i * 30_000), "date_sent": "0", "read": "1",
            "status": "-1", "type": "1", "body": "text %d" % i,
            "locked": "0", "sub_id": "1", "error_code": "-1",
            "creator": "x", "seen": "0", "__display_name": "Contact %d" % c,
        }))
with zipfile.ZipFile(out, "w", zipfile.ZIP_STORED) as z:
    z.writestr("messages.ndjson", "\n".join(recs))
    for n in parts:
        z.writestr("data/" + n, blob)
print("  built %d records, %d images" % (COUNT, IMAGES))
PY
[ -s "$TMP/large-50k.zip" ] && ok "large backup built ($(du -h "$TMP/large-50k.zip" | cut -f1))" \
    || { bad "could not build the backup"; exit 1; }

info "Import it"
db "DELETE FROM messages;" >/dev/null 2>&1
db "DELETE FROM conversations;" >/dev/null 2>&1
db "DELETE FROM participants;" >/dev/null 2>&1
adb push "$TMP/large-50k.zip" /data/local/tmp/large-50k.zip >/dev/null 2>&1
adb shell "run-as '$PKG' sh -c 'cp /data/local/tmp/large-50k.zip files/large-50k.zip'" >/dev/null 2>&1
adb logcat -c >/dev/null 2>&1 || true
START=$(date +%s)
adb shell am force-stop "$PKG" >/dev/null 2>&1
adb shell am start -n "$ACT" --es sms_ie_probe \
    "file:///data/data/$PKG/files/large-50k.zip" >/dev/null 2>&1
N=0
for _ in $(seq 1 900); do
    sleep 2
    N=$(count)
    [ "${N:-0}" -ge 50000 ] && break
done
ELAPSED=$(( $(date +%s) - START ))
[ "${N:-0}" -ge 50000 ] && ok "50000 records imported in ${ELAPSED}s" \
    || { bad "only ${N:-0} of 50000 imported after ${ELAPSED}s"; adb logcat -d -s SmsIeImport 2>/dev/null | tr -d '\r' | tail -5; }

REPORTED=$(adb logcat -d -s SmsIeImport 2>/dev/null | tr -d '\r' \
    | grep -oE 'count=[0-9]+' | tail -1 | cut -d= -f2)
[ "${REPORTED:-0}" = "50000" ] && ok "every record in the backup was read" \
    || bad "reported ${REPORTED:-?} records imported, expected 50000"

info "MMS attachments survive"
MMS=$(db "SELECT COUNT(*) FROM messages WHERE transport='mms';")
IMG=$(db "SELECT COUNT(*) FROM messages WHERE media_type='image' AND media_uri<>'';")
[ "${MMS:-0}" -gt 0 ] && ok "$MMS MMS rows stored" || bad "no MMS rows stored"
[ "${IMG:-0}" = "${MMS:-0}" ] && ok "every MMS row has its image copied into app storage" \
    || bad "only $IMG of $MMS MMS rows have an image"

info "No out-of-memory, and nothing left staged"
if adb logcat -d 2>/dev/null | grep -qiE "OutOfMemoryError"; then
    bad "the import ran out of memory"
else
    ok "no OutOfMemoryError"
fi
STAGED=$(adb shell "run-as '$PKG' sh -c 'ls -d cache/smsie-stage-* 2>/dev/null | wc -l'" 2>/dev/null | tr -d ' \r')
[ "${STAGED:-1}" = "0" ] && ok "the staging directory was cleaned up" \
    || bad "$STAGED staging directories left behind"
if adb logcat -d -b crash 2>/dev/null | grep -q "$PKG"; then
    bad "the app crashed during the import"
else
    ok "no crash"
fi

# --- 2. an oversized part must not lose the whole backup ------------------

info "One oversized MMS part costs that part, not the backup"
python3 - "$TMP/large-bigpart.zip" <<'PY'
import json, sys, zipfile
out = sys.argv[1]
recs = [json.dumps({
    "_id": str(i + 1), "thread_id": "0", "address": "+15551230001",
    "date": str(1_600_000_000_000 + i * 60_000), "date_sent": "0",
    "read": "1", "status": "-1", "type": "1", "body": "kept %d" % i,
    "locked": "0", "sub_id": "1", "error_code": "-1", "creator": "x", "seen": "0",
}) for i in range(300)]
recs.append(json.dumps({
    "_id": "9999", "thread_id": "0", "date": "1600000000000", "msg_box": "1",
    "read": "1", "m_type": "132",
    "__sender_address": {"address": "+15551230001", "type": "137", "charset": "106"},
    "__recipient_addresses": [],
    "__parts": [{"ct": "text/plain", "text": "big photo"},
                {"ct": "image/jpeg", "_data": "/data/x/PART_HUGE.jpg"}],
}))
with zipfile.ZipFile(out, "w", zipfile.ZIP_STORED) as z:
    # The oversized part is written FIRST, which is the order that used to throw
    # out of the whole zip loop before the message list had been read.
    z.writestr("data/PART_HUGE.jpg", b"\x00" * (9 * 1024 * 1024))
    z.writestr("messages.ndjson", "\n".join(recs))
PY
db "DELETE FROM messages;" >/dev/null 2>&1
db "DELETE FROM conversations;" >/dev/null 2>&1
adb push "$TMP/large-bigpart.zip" /data/local/tmp/large-bigpart.zip >/dev/null 2>&1
adb shell "run-as '$PKG' sh -c 'cp /data/local/tmp/large-bigpart.zip files/large-bigpart.zip'" >/dev/null 2>&1
adb logcat -c >/dev/null 2>&1 || true
adb shell am force-stop "$PKG" >/dev/null 2>&1
adb shell am start -n "$ACT" --es sms_ie_probe \
    "file:///data/data/$PKG/files/large-bigpart.zip" >/dev/null 2>&1
N=0
for _ in $(seq 1 60); do sleep 2; N=$(count); [ "${N:-0}" -ge 301 ] && break; done
[ "${N:-0}" -ge 301 ] && ok "all 301 messages imported despite the oversized part" \
    || bad "only ${N:-0} of 301 imported; the oversized part cost the whole backup"
adb logcat -d -s SmsIeImport 2>/dev/null | tr -d '\r' | grep -q 'part too large' \
    && ok "the skipped part was reported" || bad "the oversized part was not reported"

# --- 3. a delete made by another app must be reflected -------------------

info "Wipe the system provider through SMS Import / Export"
if ! adb shell pm list packages 2>/dev/null | grep -q "$SMSIE"; then
    bad "$SMSIE is not installed, so the wipe half cannot run"
else
    # Give it some messages to lose.
    adb shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1
    for i in 1 2 3 4 5; do adb emu sms send "+1555999$i" "wipe probe $i" >/dev/null 2>&1; done
    sleep 15
    for _ in $(seq 1 30); do
        [ "$(provider_count)" -ge 5 ] && break
        sleep 2
    done
    [ "$(provider_count)" -ge 5 ] && ok "provider seeded with $(provider_count) messages" \
        || bad "could not seed the provider"

    adb shell cmd role add-role-holder android.app.role.SMS "$SMSIE" >/dev/null 2>&1
    adb shell am start -n "$SMSIE/.MainActivity" >/dev/null 2>&1; sleep 6
    if tap_text "WIPE MESSAGES" >/dev/null 2>&1; then
        sleep 4
        if tap_text "WIPE" >/dev/null 2>&1; then
            sleep 8
            [ "$(provider_count)" = "0" ] && ok "the provider is now empty" \
                || bad "provider still has $(provider_count) messages; the wipe did not happen"
        else
            bad "could not confirm the wipe"
        fi
    else
        bad "could not find WIPE MESSAGES in $SMSIE"
    fi

    # Hand the role back and relaunch: taking the role away kills this app's
    # process, so the prune lands on the next launch, which is the real path.
    adb shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1
    adb shell am force-stop "$SMSIE" >/dev/null 2>&1
    FROM_PROVIDER_BEFORE=$(db 'SELECT COUNT(*) FROM messages WHERE sys_id>0;' | tr -d ' \r')
    LOCAL_BEFORE=$(db 'SELECT COUNT(*) FROM messages WHERE sys_id=0;' | tr -d ' \r')
    adb logcat -c >/dev/null 2>&1 || true
    adb shell am start -n "$ACT" >/dev/null 2>&1
    for _ in $(seq 1 30); do
        sleep 2
        [ "$(db 'SELECT COUNT(*) FROM messages WHERE sys_id>0;' | tr -d ' \r')" = "0" ] && break
    done
    FROM_PROVIDER_AFTER=$(db 'SELECT COUNT(*) FROM messages WHERE sys_id>0;' | tr -d ' \r')
    LOCAL_AFTER=$(db 'SELECT COUNT(*) FROM messages WHERE sys_id=0;' | tr -d ' \r')

    [ "${FROM_PROVIDER_BEFORE:-0}" -ge 5 ] \
        && ok "the app was still showing ${FROM_PROVIDER_BEFORE} provider messages after the wipe (the bug)" \
        || bad "the app had no provider messages to prune, so this proves nothing"
    [ "${FROM_PROVIDER_AFTER:-1}" = "0" ] \
        && ok "on relaunch every message deleted outside the app is gone" \
        || bad "$FROM_PROVIDER_AFTER provider-backed messages survived the wipe"
    # Messages that only ever existed in this app (imported ones) have no
    # provider id and must not be swept up by a provider wipe.
    [ "${LOCAL_AFTER:-0}" = "${LOCAL_BEFORE:-1}" ] \
        && ok "locally-imported messages are untouched by a provider wipe ($LOCAL_AFTER kept)" \
        || bad "the provider wipe also removed $((LOCAL_BEFORE - LOCAL_AFTER)) local-only message(s)"
    adb logcat -d -s RepoSync 2>/dev/null | tr -d '\r' | grep -q 'pruned' \
        && ok "the prune was logged" || bad "no prune was logged"

    EMPTY=$(db 'SELECT COUNT(*) FROM conversations c WHERE NOT EXISTS (SELECT 1 FROM messages m WHERE m.conversation_id=c.id);' | tr -d ' \r')
    [ "${EMPTY:-1}" = "0" ] && ok "no empty conversations left behind" \
        || bad "$EMPTY empty conversations survived the wipe"
fi

echo ""
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
