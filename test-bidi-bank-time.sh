#!/usr/bin/env bash
# Regression for #345 (second follow-up): bank timestamps must stay in one piece.
#
# A Mellat stamp is "1405/07/30 - 16:59" (or "05/07/30-04:05"), a Pasargad one is
# "07/30_04:00". ':' and '_' were not separators in BidiText's number run, so the
# run stopped at the hour, ":59" was left outside the isolate, and it reordered
# away from the hour — the reporter saw "19 [date] 02" with the colon adrift.
#
# uiautomator reports the text as the app hands it to the renderer, so the
# isolates are visible in the dump and the assertion is exact: the whole date+time
# sits inside one LRI…PDI pair, not just the date and the hour.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

MARK="biditime$(date +%s)$$"
NUM="+1555985${MARK: -4}"
LRI=$'\u2066'
PDI=$'\u2069'

MELLAT=$'بانک ملت\nبه سامانه همراه بانک ملت خوش آمدید\n1405/07/30 - 16:59'
MELLAT2=$'حساب 1234567\nبرداشت 300,000\nمانده 53,479,703\n05/07/30-04:05'
PASARGAD=$'شماره حساب 0284800000\nواریز -500,000\n07/30_04:00\nمانده: 1234567890'

adb_ root >/dev/null 2>&1; adb_ wait-for-device; sleep 1
sql() { adb_ shell "sqlite3 /data/data/$PKG/databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r'; }

cleanup() {
    sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM');" >/dev/null 2>&1
    sql "DELETE FROM conversations WHERE address='$NUM';" >/dev/null 2>&1
}
trap cleanup EXIT

for p in READ_SMS RECEIVE_SMS READ_CONTACTS POST_NOTIFICATIONS; do
    adb_ shell pm grant "$PKG" "android.permission.$p" >/dev/null 2>&1
done

info "Seed the three bank formats in one conversation"
TS=$(date +%s000)
sql "INSERT INTO conversations(address,name,snippet,timestamp,unread_count) VALUES('$NUM','$MARK','$MARK',$TS,0);" >/dev/null 2>&1
CID=$(sql "SELECT id FROM conversations WHERE address='$NUM';")
[ -z "$CID" ] && { bad "could not seed a conversation"; exit 1; }
BODY="$MELLAT"$'\n\n'"$MELLAT2"$'\n\n'"$PASARGAD"
sql "INSERT INTO messages(conversation_id,body,timestamp,status) VALUES($CID,'$BODY',$TS,'received');" >/dev/null 2>&1
ok "bank messages seeded"

info "Open the conversation"
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" --es open_conversation_address "$NUM" >/dev/null 2>&1
sleep 6
dump_ui
if grep -q "$MARK" "$TMP/ui.xml" || grep -q "بانک ملت" "$TMP/ui.xml"; then
    ok "conversation opened"
else
    bad "the conversation did not open on the seeded chat"
fi

# Each stamp has to appear wrapped in its own isolate, exactly once.
for stamp in "1405/07/30 - 16:59" "05/07/30-04:05" "07/30_04:00"; do
    if python3 - "$TMP/ui.xml" "$LRI" "$PDI" "$stamp" <<'PY'
import sys
xml, lri, pdi, stamp = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
body = open(xml, encoding='utf-8', errors='replace').read()
raise SystemExit(0 if (lri + stamp + pdi) in body else 1)
PY
    then
        ok "'$stamp' is rendered as one LTR block"
    else
        bad "'$stamp' is split, so its parts can reorder"
    fi
done

# The exact shape of the old bug: the isolate closed before the minutes.
if python3 - "$TMP/ui.xml" "$LRI" "$PDI" <<'PY'
import sys
xml, lri, pdi = sys.argv[1], sys.argv[2], sys.argv[3]
body = open(xml, encoding='utf-8', errors='replace').read()
split = [lri + "05/07/30-04" + pdi + ":05", lri + "1405/07/30 - 16" + pdi + ":59"]
raise SystemExit(0 if any(s in body for s in split) else 1)
PY
then
    bad "a timestamp is closed before its minutes (hour/minute split)"
else
    ok "no timestamp is closed before its minutes"
fi

info "The Pasargad negative amount keeps its sign"
if python3 - "$TMP/ui.xml" "$LRI" "$PDI" <<'PY'
import sys
xml, lri, pdi = sys.argv[1], sys.argv[2], sys.argv[3]
body = open(xml, encoding='utf-8', errors='replace').read()
raise SystemExit(0 if (lri + "-500,000" + pdi) in body else 1)
PY
then
    ok "-500,000 is rendered with its sign inside the isolate"
else
    bad "the minus sign was left outside the amount"
fi

echo ""
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
