#!/usr/bin/env bash
# Regression for #395: "numbers in the ##,###.## format are displayed
# incorrectly in right-to-left languages" - "20,980.01" painted as "980.01,20".
#
# The run regex has to swallow the ',' or the amount is matched as two runs
# ("20" and "980.01") that are isolated separately; two adjacent isolates in an
# RTL paragraph paint right-to-left, which is exactly the reported reversal.
# uiautomator reports the text as handed to the renderer, so the isolates the
# app inserts are visible in the dump - that is the assertion. Painted order is
# the platform's job once one isolate holds the whole number; BidiTextTest
# asserts that order with java.text.Bidi.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

MARK="num$(date +%s)$$"
NUM="+1555974${MARK: -4}"
LRI=$'\u2066'
PDI=$'\u2069'

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

info "Seed the #395 amount"
TS=$(date +%s000)
sql "INSERT INTO conversations(address,name,snippet,timestamp,unread_count) VALUES('$NUM','$MARK','$MARK',$TS,0);" >/dev/null 2>&1
CID=$(sql "SELECT id FROM conversations WHERE address='$NUM';")
[ -z "$CID" ] && { bad "could not seed a conversation"; exit 1; }
sql "INSERT INTO messages(conversation_id,body,timestamp,status) VALUES($CID,'مبلغ 20,980.01 ریال',$TS,'received');" >/dev/null 2>&1
ok "message seeded"

# Re-render the chat on a new body and print the isolated spans the renderer was
# handed, joined by \x1f. Prints nothing and returns 1 when the dump fails.
render() {
    sql "UPDATE messages SET body='$1' WHERE conversation_id=$CID;" >/dev/null 2>&1
    adb_ shell am force-stop "$PKG"; sleep 1
    adb_ shell am start -n "$ACT" --es open_conversation_address "$NUM" >/dev/null 2>&1
    sleep 6
    dump_ui 2>/dev/null || return 1
    python3 - "$TMP/ui.xml" "$LRI" "$PDI" <<'PY'
import sys
xml = open(sys.argv[1], encoding='utf-8', errors='replace').read()
lri, pdi = sys.argv[2], sys.argv[3]
spans, i = [], 0
while True:
    a = xml.find(lri, i)
    if a < 0:
        break
    b = xml.find(pdi, a)
    if b < 0:
        break
    spans.append(xml[a + 1:b])
    i = b + 1
print("\x1f".join(spans), end="")
PY
}

# $1 = body, $2 = expected isolate content, $3 = label
check_body() {
    local spans
    spans=$(render "$1") || { bad "$3: uiautomator dump failed"; return; }
    if [ "$spans" = "$2" ]; then
        ok "$3: the amount sits in one LTR isolate"
    else
        bad "$3: isolated spans were [$spans], expected [$2]"
    fi
}

info "The reported body keeps its amount in one isolate"
check_body 'مبلغ 20,980.01 ریال' '20,980.01' 'Persian'
if grep -qF "20,980.01" "$TMP/ui.xml"; then
    ok "the amount reads contiguously on screen"
else
    bad "the amount is split in the rendered text, so a reader sees two groups"
fi

info "A Hebrew message reads the same"
check_body 'הסכום 20,980.01 שח' '20,980.01' 'Hebrew'

info "A space-grouped amount is isolated too"
# A plain space is a neutral, not a number separator: Unicode splits the amount
# there on its own, so the isolate is the only thing holding it together.
check_body 'مبلغ 20 980.01 ریال' '20 980.01' 'space-grouped'

echo ""
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
