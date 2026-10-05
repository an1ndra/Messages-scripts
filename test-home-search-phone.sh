#!/usr/bin/env bash
# Issue #284 (A): the home-screen search must find a conversation by phone
# number, however it is formatted or prefixed. The address is stored as E.164
# (+15550001234) while the user types it as dialled (555-000-1234).
source "$(dirname "$0")/env.sh"

NAME="PhoneSearchTest"
NUM="+15550001234"
MARK="phonesearch$(date +%s)"
TS=$(( $(date +%s) * 1000 ))
PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

sql() { echo "$1" | adb_ shell "run-as $PKG sqlite3 databases/messages.db"; }

cleanup() {
    sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM');"
    sql "DELETE FROM conversations WHERE address='$NUM';"
}
trap cleanup EXIT

info "Seed a conversation"
sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM');"
sql "DELETE FROM conversations WHERE address='$NUM';"
sql "INSERT INTO conversations(address,name,snippet,timestamp,last_is_me) VALUES('$NUM','$NAME','$MARK',$TS,0);"
sql "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,media_type) SELECT id,'$MARK',$TS,0,'received','text' FROM conversations WHERE address='$NUM';"

# One query per app start, so the search field is always clean.
check() { # query expected(found|missing) label
    adb_ shell am force-stop "$PKG"; sleep 1
    adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 5
    if ! tap_text "Search" >/dev/null 2>&1; then
        bad "$3: no Search button"
        return
    fi
    sleep 1
    type_text "$1" >/dev/null 2>&1
    sleep 2
    if ui_has "$NAME"; then got=found; else got=missing; fi
    if [ "$got" = "$2" ]; then
        ok "$3 ('$1' -> $got)"
    else
        bad "$3 ('$1' -> expected $2, got $got)"
    fi
}

info "Phone-number queries must find the conversation"
check "555-000-1234" found "formatted number"
check "5550001234"  found "digits only"
check "0001234"     found "trailing digits"
check "15550001234" found "no plus / country code"

info "Unrelated input must not"
check "5550000000" missing "unrelated number"

info "Name search still works"
check "$NAME" found "name"

echo ""
info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
