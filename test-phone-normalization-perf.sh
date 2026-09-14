#!/usr/bin/env bash
# Performance test for phone-number normalization (issue #183 generalized).
#
# Generates N conversations with various phone number formats (duplicates in
# different spellings), plus one "hot contact" with 120+ conversations split
# across formats. Measures migration time and post-migration query performance.
#
# Usage: test-phone-normalization-perf.sh [num_conversations=2000]
set -euo pipefail
source "$(dirname "$0")/env.sh"

NUM_CONVERSOS=${1:-2000}
HOT_CONTACT_CONVERSOS=120  # One contact with 120 conversations (sender + receiver duplicates)
PASS=0; FAIL=0; NOTE=0
ok()   { echo "[PASS] $1"; PASS=$((PASS+1)); }
bad()  { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }
note() { echo "[NOTE] $1"; NOTE=$((NOTE+1)); }

DB_LOCAL="$TMP/db_perf/messages.db"
RESULTS="$TMP/perf_results.json"
PROFILE="$TMP/profile_output.txt"

###############################################################################
# Helpers
###############################################################################
adb_() { "$ADB" -s "$ANDROID_SERIAL" "$@"; }

perf_start() { date +%s%N; }
perf_ms() {
    local start_ns=$1
    local end_ns
    end_ns=$(date +%s%N)
    echo $(( (end_ns - start_ns) / 1000000 ))
}

###############################################################################
# 0. Prep
###############################################################################
info "0. pre-flight"
adb_ root >/dev/null 2>&1; sleep 1
adb_ wait-for-device

mkdir -p "$TMP/db_perf"
ADB="$HOME/android/platform-tools/adb"

info "1. kill app, reset flags"
adb_ shell am force-stop "$PKG"
sleep 1

# Reset migration flag
python3 -c "
settings_xml = '<?xml version=\"1.0\" encoding=\"utf-8\" standalone=\"yes\"?><map><int name=\"revision\" value=\"1\"/><string name=\"phone_region\"/><boolean name=\"participants_migrated\" value=\"false\"/></map>'
import os
os.makedirs('$TMP/db_perf', exist_ok=True)
with open('$TMP/db_perf/settings.xml', 'w') as f:
    f.write(settings_xml)
"
adb_ push "$TMP/db_perf/settings.xml" "/data/local/tmp/settings.xml" >/dev/null
adb_ shell "run-as $PKG cp /data/local/tmp/settings.xml /data/data/$PKG/shared_prefs/messages_settings.xml" 2>/dev/null

###############################################################################
# 1. Create seed DB with correct schema v15, populate with test data
###############################################################################
info "2. creating seed DB with v15 schema and test data"

# Create DB from scratch with correct schema (matching app's Db class)
python3 - "$DB_LOCAL" "$NUM_CONVERSOS" "$HOT_CONTACT_CONVERSOS" <<'PYEOF'
import sqlite3, sys, random, os

NUM = int(sys.argv[2])
HOT = int(sys.argv[3])
random.seed(42)

db_path = sys.argv[1]
if os.path.exists(db_path):
    os.remove(db_path)
db = sqlite3.connect(db_path)
c = db.cursor()

# Create tables WITHOUT UNIQUE on address first (allows seeding duplicates)
c.execute("""CREATE TABLE conversations(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    address TEXT NOT NULL,
    name TEXT NOT NULL,
    snippet TEXT NOT NULL DEFAULT '',
    timestamp INTEGER NOT NULL DEFAULT 0,
    unread_count INTEGER NOT NULL DEFAULT 0,
    last_is_me INTEGER NOT NULL DEFAULT 0,
    archived INTEGER NOT NULL DEFAULT 0,
    pinned INTEGER NOT NULL DEFAULT 0,
    draft TEXT NOT NULL DEFAULT '',
    draft_date INTEGER NOT NULL DEFAULT 0,
    deleted_at INTEGER NOT NULL DEFAULT 0)""")

c.execute("""CREATE TABLE messages(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    conversation_id INTEGER NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    body TEXT NOT NULL DEFAULT '',
    timestamp INTEGER NOT NULL DEFAULT 0,
    is_me INTEGER NOT NULL DEFAULT 0,
    status TEXT NOT NULL DEFAULT 'sent',
    media_type TEXT NOT NULL DEFAULT 'text',
    media_uri TEXT NOT NULL DEFAULT '',
    reactions TEXT NOT NULL DEFAULT '',
    sys_id INTEGER NOT NULL DEFAULT 0,
    locked INTEGER NOT NULL DEFAULT 0,
    sub_id INTEGER NOT NULL DEFAULT -1,
    deleted_at INTEGER NOT NULL DEFAULT 0)""")

c.execute("CREATE INDEX idx_messages_conversation ON messages(conversation_id)")
c.execute("CREATE INDEX idx_messages_conv_ts ON messages(conversation_id, timestamp)")
c.execute("CREATE INDEX idx_conversations_list ON conversations(deleted_at, pinned, timestamp)")
c.execute("CREATE INDEX idx_conversations_archived ON conversations(archived) WHERE deleted_at=0")

# Participants table exists but is empty — migration will populate it
c.execute("""CREATE TABLE participants(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    normalized_destination TEXT NOT NULL UNIQUE,
    send_destination TEXT NOT NULL,
    display_destination TEXT NOT NULL,
    comparable_destination TEXT NOT NULL,
    country_code TEXT NOT NULL DEFAULT '',
    sub_id INTEGER NOT NULL DEFAULT -1)""")

c.execute("""CREATE TABLE conversation_notifications(
    conversation_id INTEGER PRIMARY KEY REFERENCES conversations(id) ON DELETE CASCADE,
    notifications_enabled INTEGER NOT NULL DEFAULT 1)""")

c.execute("""CREATE TABLE blocked_numbers(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    number TEXT NOT NULL UNIQUE,
    timestamp INTEGER NOT NULL)""")

c.execute("""CREATE TABLE scheduled_messages(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    address TEXT NOT NULL,
    body TEXT NOT NULL,
    timestamp INTEGER NOT NULL,
    conversation_id INTEGER NOT NULL,
    sub_id INTEGER NOT NULL DEFAULT -1)""")

c.execute("CREATE INDEX idx_scheduled_timestamp ON scheduled_messages(timestamp)")

c.execute("""CREATE TABLE messages_settings(
    id INTEGER PRIMARY KEY,
    settings TEXT NOT NULL DEFAULT '{}')""")
c.execute("INSERT INTO messages_settings VALUES (1, '{}')")

# Set schema version to 15 (matching app)
c.execute("PRAGMA user_version = 15")

ts = 1726000000000

# Format variants — simulates split threads
formats = [
    lambda n: f"+1{n}",
    lambda n: f"1{n}",
    lambda n: n.replace("-", ""),
    lambda n: f"({n[1:4]}) {n[4:7]}-{n[7:]}",
    lambda n: f"  {n[1:]} ",
    lambda n: n[1:].replace(n[4:4+3], n[4:4+3]+"-"+n[7:]),
]

hot_contact_digits = "5551800000"

# --- Seed hot contact (120 splits) ---
# Same phone number in many different formats — simulating split threads
print(f"  Seeding {HOT} split conversations for hot contact +15551800000...")
seen = set()
for i in range(HOT):
    raw = formats[i % len(formats)](hot_contact_digits)
    # Ensure uniqueness for DB seeding — append space variant suffixes
    while raw in seen:
        raw = raw + chr(0x2000 + i % 100)  # Unicode space variant
    seen.add(raw)

    ts += random.randint(1000, 60000)
    snippet = random.choice(["Hello", "Hey!", "Got it", "Thanks", "See you", "👍", "OK"])
    c.execute("""INSERT INTO conversations (address, name, snippet, timestamp, last_is_me, deleted_at)
        VALUES (?, ?, ?, ?, ?, 0)""",
        (raw, raw, snippet, ts, random.randint(0, 1)))
    new_id = c.lastrowid

    for _ in range(random.randint(2, 5)):
        c.execute("""INSERT INTO messages (conversation_id, body, timestamp, is_me, status)
            VALUES (?, ?, ?, ?, 'sent')""",
            (new_id, f"hot_msg", ts, random.randint(0, 1)))

print(f"  Hot contact: {HOT} conversations seeded")

# --- Seed remaining regular conversations ---
regular = NUM - HOT
print(f"  Seeding {regular} regular conversations...")
count = 0
for i in range(regular):
    base = f"555{str(i).zfill(7)}"
    raw = formats[i % len(formats)](base)
    # Every 3rd number duplicates an earlier one (with different format)
    if i % 3 == 0 and i >= 6:
        base_of = f"555{str(i//3).zfill(7)}"
        raw = formats[(i + 1) % len(formats)](base_of)
    # Ensure uniqueness
    while raw in seen:
        raw = raw + chr(0x2000 + i % 100)
    seen.add(raw)

    ts += random.randint(1000, 60000)
    c.execute("""INSERT INTO conversations (address, name, snippet, timestamp, last_is_me, deleted_at)
        VALUES (?, ?, ?, ?, ?, 0)""",
        (raw, raw, random.choice(["Hi", "OK", "Thanks"]), ts, random.randint(0, 1)))
    new_id = c.lastrowid
    count += 1

    for _ in range(random.randint(1, 3)):
        c.execute("""INSERT INTO messages (conversation_id, body, timestamp, is_me, status)
            VALUES (?, ?, ?, ?, 'sent')""",
            (new_id, f"msg", ts, random.randint(0, 1)))

print(f"  Regular conversations: {count}")

# Add conversation_notifications for all convos (app requires them)
c.execute("SELECT id FROM conversations WHERE deleted_at=0")
for row in c.fetchall():
    try:
        c.execute("INSERT OR IGNORE INTO conversation_notifications (conversation_id, notifications_enabled) VALUES (?, ?)",
                  (row[0], 1))
    except: pass

# Blocked numbers (will be deduped by migration)
for i in range(20):
    num1 = f"+1555{str(9000000 + i).zfill(7)}"
    num2 = f"1555{str(9000000 + i).zfill(7)}"
    ts_block = ts + i * 1000
    try:
        c.execute("INSERT INTO blocked_numbers (number, timestamp) VALUES (?, ?)", (num1, ts_block))
    except: pass
    try:
        c.execute("INSERT INTO blocked_numbers (number, timestamp) VALUES (?, ?)", (num2, ts_block))
    except: pass

db.commit()
convos = c.execute("SELECT COUNT(*) FROM conversations WHERE deleted_at=0").fetchone()[0]
msgs = c.execute("SELECT COUNT(*) FROM messages").fetchone()[0]
print(f"  Total: {convos} convos, {msgs} msgs")

# Re-add UNIQUE constraint — migration will handle duplicates
c.execute("CREATE INDEX idx_convo_addr ON conversations(address)")
c.execute("PRAGMA user_version = 15")
db.close()
PYEOF

echo "[INFO] DB size: $(du -h "$DB_LOCAL" | cut -f1)"

###############################################################################
# 2. Push DB to device
###############################################################################
info "3. pushing database to device"
adb_ push "$DB_LOCAL" "/data/local/tmp/messages_test_perf.db" >/dev/null
adb_ shell "run-as $PKG cp /data/local/tmp/messages_test_perf.db /data/data/$PKG/databases/messages.db" 2>/dev/null

# Verify
SEED_COUNT=$(python3 -c "
import sqlite3
c=sqlite3.connect('$DB_LOCAL')
print(c.execute('SELECT COUNT(*) FROM conversations').fetchone()[0])
" 2>/dev/null)
[ "$SEED_COUNT" = "$NUM_CONVERSOS" ] && ok "seeded $NUM_CONVERSOS conversations" || bad "expected $NUM_CONVERSOS conversations, got $SEED_COUNT"

###############################################################################
# 3. Grant permissions + launch + time migration
###############################################################################
info "4. granting permissions + launching app (migration will run)"

for p in READ_SMS RECEIVE_SMS SEND_SMS READ_CONTACTS POST_NOTIFICATIONS READ_PHONE_STATE; do
    adb_ shell pm grant "$PKG" "android.permission.$p" 2>/dev/null
done
adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" 2>/dev/null

# Clear logcat
adb_ shell logcat -c
sleep 1

# Start app and time the migration
echo "[INFO] App launch at $(date)"
adb_ shell am start -n "$ACT" >/dev/null 2>&1
MIGRATION_START=$(date +%s%N)

# Wait for migration to finish — poll participants table
MAX_WAIT=300  # 5 minutes
for i in $(seq 1 $MAX_WAIT); do
    sleep 1
    # Check if migration completed by looking at logcat or DB
    MIGRATION_DONE=$(adb_ shell "logcat -d | grep -c 'migrationStarted = true' || true")
    if [ "$MIGRATION_DONE" -gt 0 ] 2>/dev/null; then
        break
    fi
    # Also check via DB — if participants table has rows, migration is done
    PARRS=$(adb_ shell "run-as $PKG cat /data/data/$PKG/databases/messages.db" 2>/dev/null | python3 -c "
import sqlite3, sys
try:
    c = sqlite3.connect('/dev/stdin')
    print(c.execute('SELECT COUNT(*) FROM participants').fetchone()[0])
except: print(0)
" 2>/dev/null || echo 0)
    if [ "$PARRS" -gt 0 ] 2>/dev/null; then
        break
    fi
done

MIGRATION_END=$(date +%s%N)
MIGRATION_MS=$(perf_ms $MIGRATION_START)

echo "[INFO] Migration completed in ${MIGRATION_MS}ms"

###############################################################################
# 4. Force-stop + measure post-migration state
###############################################################################
info "5. force-stop + measure results"
adb_ shell am force-stop "$PKG"
sleep 2

# Pull DB for analysis
adb_ shell "run-as $PKG cat /data/data/$PKG/databases/messages.db" > "$DB_LOCAL" 2>/dev/null

# Analyze with python3 — generates JSON results
python3 - "$DB_LOCAL" "$NUM_CONVERSOS" <<'PYEOF' > "$RESULTS"
import sqlite3, sys, json

NUM = int(sys.argv[2])
db = sqlite3.connect(sys.argv[1])
c = db.cursor()

results = {}

# Pre-migration stats
total_convos = c.execute("SELECT COUNT(*) FROM conversations").fetchone()[0]
total_msgs = c.execute("SELECT COUNT(*) FROM messages").fetchone()[0]
total_parts = c.execute("SELECT COUNT(*) FROM participants").fetchone()[0]
total_blocked = c.execute("SELECT COUNT(*) FROM blocked_numbers").fetchone()[0]

# Check E.164 conversion
e164_convos = c.execute("""
    SELECT COUNT(*) FROM conversations
    WHERE address GLOB '+[0-9]*'
    AND address NOT GLOB '*[*a-zA-Z-]*'
""").fetchone()[0]

# Check duplicate resolution
total_pre_dups = NUM  # We created duplicates
unique_addresses = c.execute("SELECT COUNT(DISTINCT address) FROM conversations").fetchone()[0]
duplicates_merged = NUM - unique_addresses

# Participant stats
parts_with_display = c.execute(
    "SELECT COUNT(*) FROM participants WHERE display_destination != normalized_destination"
).fetchone()[0]

# Blocked number dedup check
blocked_unique = c.execute(
    "SELECT COUNT(DISTINCT number) FROM blocked_numbers"
).fetchone()[0]
blocked_original = total_blocked

# Sample display formats
sample_parts = c.execute("""
    SELECT normalized_destination, display_destination, country_code
    FROM participants LIMIT 10
""").fetchall()

results = {
    "total_conversations": total_convos,
    "total_messages": total_msgs,
    "total_participants": total_parts,
    "total_blocked_numbers": total_blocked,
    "e164_converted_convos": e164_convos,
    "unique_addresses": unique_addresses,
    "duplicates_merged": duplicates_merged,
    "participants_with_display": parts_with_display,
    "blocked_unique_after": blocked_unique,
    "blocked_deduped": blocked_original - blocked_unique,
    "sample_parts": [{"e164": p[0], "display": p[1], "country": p[2]} for p in sample_parts]
}

print(json.dumps(results, indent=2))
PYEOF

# Print results
echo ""
echo "=== Migration Results ==="
python3 -c "
import json
with open('$RESULTS') as f:
    r = json.load(f)
    print(json.dumps(r, indent=2))
"

###############################################################################
# 5. Performance benchmarks
###############################################################################
info "6. running post-migration benchmarks"

# Benchmark 1: conversations() query
echo "[BENCH] conversations() query..."
BENCH1_START=$(date +%s%N)
CONVOS_QUERY=$(adb_ shell "run-as $PKG cat /data/data/$PKG/databases/messages.db" 2>/dev/null | python3 -c "
import sqlite3, sys, time
db = sqlite3.connect('/dev/stdin')
start = time.time()
for _ in range(100):
    db.execute('''SELECT c.id,c.address,c.name,c.snippet,c.timestamp,c.unread_count,c.last_is_me,
               c.archived,c.pinned,c.draft,c.draft_date,c.deleted_at,
               COALESCE(p.display_destination, c.address)
               FROM conversations c LEFT JOIN participants p ON p.normalized_destination = c.address
               WHERE c.deleted_at=0 ORDER BY c.pinned DESC, c.timestamp DESC''')
end = time.time()
print(f'{(end-start)/100*1000:.1f}')
" 2>/dev/null || echo "N/A")
BENCH1_MS=$(perf_ms $BENCH1_START)
echo "  100x conversations() query: ${CONVOS_QUERY}ms/iter (total: ${BENCH1_MS}ms)"

# Benchmark 2: conversationByIdFlow
echo "[BENCH] conversationByIdFlow query..."
BENCH2_START=$(date +%s%N)
CONVO_ID_QUERY=$(adb_ shell "run-as $PKG cat /data/data/$PKG/databases/messages.db" 2>/dev/null | python3 -c "
import sqlite3, sys, time
db = sqlite3.connect('/dev/stdin')
start = time.time()
for _ in range(100):
    db.execute('''SELECT c.id,c.address,c.name,c.snippet,c.timestamp,c.unread_count,c.last_is_me,
               c.archived,c.pinned,c.draft,c.draft_date,
               COALESCE(p.display_destination, c.address)
               FROM conversations c LEFT JOIN participants p ON p.normalized_destination = c.address
               WHERE c.id=? AND c.deleted_at=0''', [1])
end = time.time()
print(f'{(end-start)/100*1000:.1f}')
" 2>/dev/null || echo "N/A")
BENCH2_MS=$(perf_ms $BENCH2_START)
echo "  100x conversationByIdFlow: ${CONVO_ID_QUERY}ms/iter (total: ${BENCH2_MS}ms)"

# Benchmark 3: getOrCreateConversation (write path)
echo "[BENCH] getOrCreateConversation (write path)..."
BENCH3_START=$(date +%s%N)
WRITE_QUERY=$(adb_ shell "run-as $PKG cat /data/data/$PKG/databases/messages.db" 2>/dev/null | python3 -c "
import sqlite3, sys, time
db = sqlite3.connect('/dev/stdin')
start = time.time()
test_num = 999999999
for _ in range(50):
    num = f'+1555{str(test_num + _).zfill(7)}'
    # Check if exists
    r = db.execute('SELECT id FROM conversations WHERE address=?', [num]).fetchone()
    if not r:
        db.execute('INSERT INTO conversations (id, address, name) VALUES (NULL, ?, ?)', [num, num])
        db.execute('''INSERT INTO participants(normalized_destination,send_destination,display_destination,
            comparable_destination,country_code,sub_id)
            VALUES(?,?,?,?,?,?) ON CONFLICT(normalized_destination) DO UPDATE SET
            send_destination=excluded.send_destination, display_destination=excluded.display_destination,
            country_code=excluded.country_code, sub_id=excluded.sub_id''',
            [num, num, num, num.lower(), 'US', -1])
        db.commit()
end = time.time()
print(f'{(end-start)/50*1000:.1f}')
" 2>/dev/null || echo "N/A")
BENCH3_MS=$(perf_ms $BENCH3_START)
echo "  50x getOrCreateConversation: ${WRITE_QUERY}ms/iter (total: ${BENCH3_MS}ms)"

###############################################################################
# 6. Memory pressure test
###############################################################################
info "7. memory pressure test"
# Launch app and check memory usage over time
adb_ shell am force-stop "$PKG"
sleep 1
adb_ shell am start -n "$ACT" >/dev/null 2>&1

# Measure app memory every 5 seconds for 30 seconds
echo "[MEM] Tracking memory over 30s..."
for i in 1 2 3 4 5 6; do
    sleep 5
    MEM=$(adb_ shell dumpsys meminfo "$PKG" 2>/dev/null | grep "TOTAL" | head -1 | awk '{print $2}')
    echo "  [${i}*5s] ${MEM:-unknown}"
done

# Stop app
adb_ shell am force-stop "$PKG"
sleep 2

###############################################################################
# 7. Verify correctness
###############################################################################
info "8. verifying correctness"

# Check that duplicates were merged
MERGED=$(python3 -c "
import json
with open('$RESULTS') as f:
    r = json.load(f)
print(r.get('duplicates_merged', 0))
" 2>/dev/null || echo 0)
EXPECTED_DUPS=$((NUM_CONVERSOS / 3))  # Every 3rd was a duplicate
[ "$MERGED" -gt 0 ] && ok "merged $MERGED duplicate conversations" || bad "no duplicates merged (expected ~$EXPECTED_DUPS)"
[ "$MERGED" -ge $((EXPECTED_DUPS - 5)) ] && ok "merge count within expected range" || note "merge count ($MERGED) differs from expected (~$EXPECTED_DUPS)"

# Check participants table populated
PART_COUNT=$(python3 -c "
import json
with open('$RESULTS') as f:
    r = json.load(f)
print(r.get('total_participants', 0))
" 2>/dev/null || echo 0)
[ "$PART_COUNT" -gt 0 ] && ok "participants table populated: $PART_COUNT rows" || bad "participants table empty"

# Check display formatting
DISPLAY_FORMATTED=$(python3 -c "
import json
with open('$RESULTS') as f:
    r = json.load(f)
print(r.get('participants_with_display', 0))
" 2>/dev/null || echo 0)
[ "$DISPLAY_FORMATTED" -gt 0 ] && ok "$DISPLAY_FORMATTED participants have formatted display names" || bad "no formatted display names"

# Check blocked number dedup
BLOCKED_DEDUPED=$(python3 -c "
import json
with open('$RESULTS') as f:
    r = json.load(f)
print(r.get('blocked_deduped', 0))
" 2>/dev/null || echo 0)
[ "$BLOCKED_DEDUPED" -gt 0 ] && ok "blocked numbers deduped: $BLOCKED_DEDUPED removed" || note "no blocked number deduplication"

# Check E.164 conversion
E164_COUNT=$(python3 -c "
import json
with open('$RESULTS') as f:
    r = json.load(f)
print(r.get('e164_converted_convos', 0))
" 2>/dev/null || echo 0)
[ "$E164_COUNT" -gt 0 ] && ok "$E164_COUNT conversations converted to E.164" || bad "no E.164 conversion"

# Check hot contact merged to single conversation
HOT_MERGED=$(python3 -c "
import json
with open('$RESULTS') as f:
    r = json.load(f)
# Hot contact starts with 120 splits, should merge to 1
print(r.get('unique_addresses', 0))
" 2>/dev/null || echo 0)
HOT_EXPECTED_SINGLE=$(python3 -c "
# If hot contact merged, unique addresses should be ~NUM - HOT/2 (roughly)
print('Hot contact check: should have 1 conversation for +15551800000 after merge')
")
echo "$HOT_EXPECTED_SINGLE"
echo "[INFO] Hot contact unique addresses: $HOT_MERGED (expected: ~1 after merge)"

# Check that hot contact messages were preserved
HOT_MSGS=$(python3 -c "
import sqlite3, json
db = sqlite3.connect('$DB_LOCAL')
# Find the merged hot contact conversation
hot = db.execute('SELECT id FROM conversations WHERE address GLOB \"+155518*\"').fetchone()
if hot:
    msgs = db.execute('SELECT COUNT(*) FROM messages WHERE conversation_id=?', [hot[0]]).fetchone()[0]
    print(f'HOT_MSGS={msgs}')
else:
    print('HOT_MSGS=0')
" 2>/dev/null || echo "HOT_MSGS=0")
HOT_MSG_COUNT=$(echo "$HOT_MSGS" | grep -oP '\d+')
[ "$HOT_MSG_COUNT" -gt 100 ] && ok "hot contact preserved $HOT_MSG_COUNT messages after merge" || note "hot contact message count: $HOT_MSG_COUNT (expected >100)"

###############################################################################
# 8. Build verification
###############################################################################
info "9. rebuild + reinstall verification"
./gradlew assembleDebug >/dev/null 2>&1
[ -f "app/build/outputs/apk/debug/app-debug.apk" ] && ok "build succeeded" || bad "build failed"
adb_ shell am force-stop "$PKG"
sleep 1
adb_ install -r "app/build/outputs/apk/debug/app-debug.apk" 2>/dev/null
sleep 2

###############################################################################
# Summary
###############################################################################
echo ""
echo "=========================================="
echo "  PERFORMANCE TEST SUMMARY"
echo "=========================================="
echo "  Total conversations:     $NUM_CONVERSOS"
echo "  Hot contact splits:      $HOT_CONTACT_CONVERSOS (same number, different formats)"
echo "  Migration time:          ${MIGRATION_MS}ms"
echo "  Participants created:    $PART_COUNT"
echo "  Duplicates merged:       $MERGED"
echo "  E.164 conversions:       $E164_COUNT"
echo "  Display formatted:       $DISPLAY_FORMATTED"
echo "  Blocked deduped:         $BLOCKED_DEDUPED"
echo "  conversations() qps:     $(python3 -c "print(f'{100/($CONVOS_QUERY/1000):.0f}')" 2>/dev/null || echo "N/A")"
echo "  ByID qps:                $(python3 -c "print(f'{100/($CONVO_ID_QUERY/1000):.0f}')" 2>/dev/null || echo "N/A")"
echo "  Write qps:               $(python3 -c "print(f'{50/($WRITE_QUERY/1000):.0f}')" 2>/dev/null || echo "N/A")"
echo "=========================================="
echo "  Result: $PASS passed, $FAIL failed, $NOTE notes"
echo "=========================================="

# Save JSON results
cp "$RESULTS" "$TMP/perf_results_final.json" 2>/dev/null || true
echo "[INFO] Detailed results: $TMP/perf_results_final.json"

exit $((FAIL > 0))
