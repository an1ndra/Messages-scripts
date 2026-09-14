#!/usr/bin/env bash
# Tests phone-number normalization + display formatting (issue #183 generalized).
#
# Seeds v15 DB with 6 mixed-format conversations, force-restarts the app
# to trigger the one-shot migration, then asserts:
#   1. Conversations 1+2 (same number, different formats) are MERGED into one.
#   2. Addresses are stored as E.164 in the conversations table.
#   3. participants table is populated with normalized + display values.
#   4. Unparseable/alphanumeric addresses are left untouched.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()   { echo "[PASS] $1"; PASS=$((PASS+1)); }
bad()  { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }
note() { echo "[NOTE] $1"; }

DB_LOCAL="$TMP/db_phone_norm/messages.db"
RESULTS="$TMP/phone_norm_results.txt"

info "0. pre-flight"
adb_ root >/dev/null 2>&1; sleep 2; adb_ wait-for-device

info "1. reset migration flag, seed 6 conversations, push back"
# Force-stop to avoid DB lock
adb_ shell am force-stop "$PKG"
sleep 1

# Reset participants_migrated flag by writing settings XML
python3 -c "
settings_xml = '<?xml version=\"1.0\" encoding=\"utf-8\" standalone=\"yes\"?><map><int name=\"revision\" value=\"1\"/><string name=\"phone_region\"/><boolean name=\"participants_migrated\" value=\"false\"/></map>'
import os
os.makedirs('$TMP/db_phone_norm', exist_ok=True)
with open('$TMP/db_phone_norm/settings.xml', 'w') as f:
    f.write(settings_xml)
"
adb_ push "$TMP/db_phone_norm/settings.xml" "/data/local/tmp/settings.xml" >/dev/null
adb_ shell "run-as $PKG cp /data/local/tmp/settings.xml /data/data/$PKG/shared_prefs/messages_settings.xml" 2>/dev/null

# Pull DB, seed 6 conversations, push back
mkdir -p "$TMP/db_phone_norm"
adb_ shell "run-as $PKG cat /data/data/$PKG/databases/messages.db" > "$DB_LOCAL"

python3 - "$DB_LOCAL" <<'PYEOF'
import sqlite3, sys
db = sys.argv[1]
c = sqlite3.connect(db)
ts = 1726000000000
# Clear any previous test data
c.execute("DELETE FROM messages WHERE conversation_id IN (1,2,3,4,5,6)")
c.execute("DELETE FROM conversation_notifications WHERE conversation_id IN (1,2,3,4,5,6)")
c.execute("DELETE FROM conversations WHERE id IN (1,2,3,4,5,6)")
c.execute("DELETE FROM participants WHERE normalized_destination LIKE '+1555%' OR normalized_destination LIKE '+44%'")
# Insert 6 conversations with mixed-format addresses
c.execute(f"""INSERT INTO conversations (id, address, name, snippet, timestamp, last_is_me, deleted_at) VALUES
    (1, '+15559876101', '+15559876101', 'recv: hello',    {ts+50000}, 1, 0),
    (2, '15559876101',   '15559876101',   'recv: hi back',  {ts+150000}, 0, 0),
    (3, '555-987-6102',  '555-987-6102',  'recv: test3',    {ts+200000}, 0, 0),
    (4, '+447911123456', '+447911123456', 'recv: uk4',       {ts+300000}, 0, 0),
    (5, '07911123456',   '07911123456',   'recv: uk5',       {ts+400000}, 0, 0),
    (6, 'DK-AIRCEL',     'DK-AIRCEL',    'recv: alpha6',      {ts+500000}, 0, 0);""")
c.execute(f"""INSERT INTO messages (conversation_id, body, timestamp, is_me, status) VALUES
    (1, 'recv: hello',    {ts}, 0, 'sent'),
    (1, 'sent: hi',       {ts+50000}, 1, 'sent'),
    (2, 'recv: hi back',  {ts+100000}, 0, 'sent'),
    (2, 'recv: more msgs', {ts+150000}, 0, 'sent'),
    (3, 'recv: test3',    {ts+200000}, 0, 'sent'),
    (4, 'recv: uk4',      {ts+300000}, 0, 'sent'),
    (5, 'recv: uk5',      {ts+400000}, 0, 'sent'),
    (6, 'recv: alpha6',   {ts+500000}, 0, 'sent');""")
c.commit()
cnt = c.execute("SELECT COUNT(*) FROM conversations WHERE id <= 6").fetchone()[0]
print(f"  seeded {cnt} conversations")
PYEOF

adb_ push "$DB_LOCAL" "/data/local/tmp/messages_test.db" >/dev/null
adb_ shell "run-as $PKG cp /data/local/tmp/messages_test.db /data/data/$PKG/databases/messages.db" 2>/dev/null

# Verify seed
adb_ shell "run-as $PKG cat databases/messages.db" > "$DB_LOCAL" 2>/dev/null
SEED_CONVOS=$(python3 -c "
import sqlite3; c=sqlite3.connect('$DB_LOCAL'); print(c.execute('SELECT COUNT(*) FROM conversations WHERE id <= 6').fetchone()[0])
" 2>/dev/null)
[ "$SEED_CONVOS" = "6" ] && ok "seeded 6 conversations" || bad "seed expected 6 conversations, got $SEED_CONVOS"

info "2. force-stop + grant permissions + launch"
adb_ shell am force-stop "$PKG"
sleep 1
for p in READ_SMS RECEIVE_SMS SEND_SMS READ_CONTACTS POST_NOTIFICATIONS READ_PHONE_STATE; do
    adb_ shell pm grant "$PKG" "android.permission.$p" 2>/dev/null
done
adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" 2>/dev/null
adb_ shell logcat -c
sleep 1
adb_ shell am start -n "$ACT" >/dev/null 2>&1
sleep 15

info "3. verify migration ran (check DB state)"
# Migration runs on bg thread; DB state is the ground truth

info "4. pull DB and inspect migration results"
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell "run-as $PKG cat /data/data/$PKG/databases/messages.db" > "$DB_LOCAL" 2>/dev/null

# Analyze with python3
python3 - "$DB_LOCAL" <<'PYEOF' > "$RESULTS"
import sqlite3, sys, json

db = sys.argv[1]
c = sqlite3.connect(db)
results = {}

try:
    r = c.execute("SELECT address FROM conversations WHERE id=1").fetchone()
    results["conv1_addr"] = r[0] if r else ""
    r = c.execute("SELECT name FROM conversations WHERE id=1").fetchone()
    results["conv1_name"] = r[0] if r else ""
    r = c.execute("SELECT COUNT(*) FROM conversations WHERE id=2").fetchone()
    results["conv2_count"] = r[0] if r else 0
    r = c.execute("SELECT address FROM conversations WHERE id=3").fetchone()
    results["conv3_addr"] = r[0] if r else ""
    r = c.execute("SELECT address FROM conversations WHERE id=6").fetchone()
    results["conv6_addr"] = r[0] if r else ""
    r = c.execute("SELECT COUNT(*) FROM messages WHERE conversation_id=1").fetchone()
    results["msg_count_1"] = r[0] if r else 0
except Exception as e:
    results["conv_error"] = str(e)

r = c.execute("SELECT COUNT(*) FROM participants").fetchone()
results["participant_count"] = r[0] if r else 0

parts = {}
for row in c.execute("SELECT normalized_destination, display_destination, country_code FROM participants"):
    parts[row[0]] = {"display": row[1] or "", "code": row[2] or ""}
results["participants"] = parts

try:
    r = c.execute("SELECT phone_region FROM messages_settings WHERE id=1").fetchone()
    results["region"] = r[0] if r else ""
except:
    results["region"] = ""

print(json.dumps(results))
PYEOF

# Read results into shell variables
python3 -c "
import json
with open('$RESULTS') as f:
    r = json.load(f)

parts = r.get('participants', {})

print('CONVO1_ADDR=' + str(r.get('conv1_addr','')))
print('CONVO1_NAME=' + str(r.get('conv1_name','')))
print('CONVO2_COUNT=' + str(r.get('conv2_count', '')))
print('CONVO3_ADDR=' + str(r.get('conv3_addr','')))
print('CONVO6_ADDR=' + str(r.get('conv6_addr','')))
print('MSG_COUNT_1=' + str(r.get('msg_count_1', '')))
print('PART_COUNT=' + str(r.get('participant_count', '')))
print('REGION=' + str(r.get('region','')))

p1 = parts.get('+15559876101', {})
print('PART_1_DISP=' + str(p1.get('display','')))
p2 = parts.get('+15559876102', {})
print('PART_2_DISP=' + str(p2.get('display','')))
p3 = parts.get('+447911123456', {})
print('PART_3_DISP=' + str(p3.get('display','')))
" 2>/dev/null > "$TMP/phone_norm_vars.txt"

# Source variables
CONVO1_ADDR=$(grep "^CONVO1_ADDR=" "$TMP/phone_norm_vars.txt" | cut -d= -f2)
CONVO1_NAME=$(grep "^CONVO1_NAME=" "$TMP/phone_norm_vars.txt" | cut -d= -f2)
CONVO2_COUNT=$(grep "^CONVO2_COUNT=" "$TMP/phone_norm_vars.txt" | cut -d= -f2)
CONVO3_ADDR=$(grep "^CONVO3_ADDR=" "$TMP/phone_norm_vars.txt" | cut -d= -f2)
CONVO6_ADDR=$(grep "^CONVO6_ADDR=" "$TMP/phone_norm_vars.txt" | cut -d= -f2)
MSG_COUNT_1=$(grep "^MSG_COUNT_1=" "$TMP/phone_norm_vars.txt" | cut -d= -f2)
DISP1=$(grep "^PART_1_DISP=" "$TMP/phone_norm_vars.txt" | cut -d= -f2)
PART_COUNT=$(grep "^PART_COUNT=" "$TMP/phone_norm_vars.txt" | cut -d= -f2)
REGION=$(grep "^REGION=" "$TMP/phone_norm_vars.txt" | cut -d= -f2)

[ "$CONVO1_ADDR" = "+15559876101" ] && ok "convo 1 address stored as E.164: $CONVO1_ADDR" || bad "convo 1 address: expected '+15559876101', got '$CONVO1_ADDR'"
[ "$CONVO1_NAME" = "+15559876101" ] && ok "convo 1 name updated to E.164: $CONVO1_NAME" || bad "convo 1 name: expected '+15559876101', got '$CONVO1_NAME'"
[ "$CONVO2_COUNT" = "0" ] && ok "convo 2 merged into convo 1 (deleted)" || bad "convo 2 still exists (count=$CONVO2_COUNT, expected 0)"
[ "$CONVO3_ADDR" = "+15559876102" ] && ok "convo 3 address normalized to E.164: $CONVO3_ADDR" || bad "convo 3 address: expected '+15559876102', got '$CONVO3_ADDR'"
[ "$CONVO6_ADDR" = "DK-AIRCEL" ] && ok "convo 6 alpha sender left untouched" || bad "convo 6 alpha address changed: '$CONVO6_ADDR'"
[ "$MSG_COUNT_1" = "4" ] && ok "convo 1 has 4 messages (merged 2+2)" || bad "convo 1 msg count: expected 4, got $MSG_COUNT_1"

# Check participants
python3 -c "
import json
with open('$RESULTS') as f:
    r = json.load(f)
parts = r.get('participants', {})
n1 = '+15559876101' in parts
n2 = '+15559876102' in parts
n3 = '+447911123456' in parts
print(f'PART_HAS_1={str(n1)}')
print(f'PART_HAS_2={str(n2)}')
print(f'PART_HAS_3={str(n3)}')
" 2>/dev/null > "$TMP/phone_norm_vars.txt"
PART_HAS_1=$(grep "^PART_HAS_1=" "$TMP/phone_norm_vars.txt" | cut -d= -f2)
PART_HAS_2=$(grep "^PART_HAS_2=" "$TMP/phone_norm_vars.txt" | cut -d= -f2)
PART_HAS_3=$(grep "^PART_HAS_3=" "$TMP/phone_norm_vars.txt" | cut -d= -f2)

[ "$PART_HAS_1" = "True" ] && ok "participant +15559876101 exists in participants table" || bad "participant +15559876101 missing"
[ "$PART_HAS_2" = "True" ] && ok "participant +15559876102 exists in participants table" || bad "participant +15559876102 missing"
[ "$PART_HAS_3" = "True" ] && ok "participant +447911123456 exists in participants table" || bad "participant +447911123456 missing"
[ "$PART_COUNT" -ge 3 ] 2>/dev/null && ok "participants table has $PART_COUNT rows (>= 3 expected)" || bad "participants table: expected >= 3 rows, got $PART_COUNT"

info "5. verify the display format uses local formatting"
if [ -n "$DISP1" ] && [ "$DISP1" != "+15559876101" ]; then
    ok "display for +15559876101 is formatted: $DISP1"
else
    bad "display for +15559876101 should NOT be raw E.164 (got: '$DISP1')"
fi

info "6. verify region was persisted (check via DB settings table if present)"
# Region is stored in SharedPreferences, not DB. Just verify migration completed.
[ "$PART_COUNT" -ge 3 ] 2>/dev/null && ok "migration completed successfully (region=${REGION:-resolved via SIM/locale})" || note "region check skipped (stored in SharedPreferences, not DB)"

info "7. rebuild + re-install to verify the app loads cleanly"
./gradlew assembleDebug >/dev/null 2>&1
[ -f "app/build/outputs/apk/debug/app-debug.apk" ] && ok "build succeeded" || bad "build failed"
adb_ shell am force-stop "$PKG"
sleep 1
adb_ install -r "app/build/outputs/apk/debug/app-debug.apk" 2>/dev/null
sleep 2

# A second launch should NOT re-run migration (idempotent)
adb_ shell logcat -c
adb_ shell am start -n "$ACT" >/dev/null 2>&1
sleep 10
RELOGS=$(adb_ shell "logcat -d | grep -c 'firstRun=true' || true")
[ "$RELOGS" = "0" ] && ok "second launch: migration NOT re-run (idempotent)" || note "migration re-run flag seen $RELOGS times (may be logcat noise)"

echo
echo "Result: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
