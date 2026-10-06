#!/usr/bin/env bash
# Issue #284 (A): the home-screen search must find a conversation by phone
# number, however it is formatted or prefixed. The address is stored as E.164
# (+15550001234) while the user types it as dialled (555-000-1234).
#
# It also covers the saved-contact case: a contact's number is dialled and typed
# in national form, keeping the local trunk zero and dropping the country code
# (+919876543210 stored, typed 09876543210). Neither digit run is then a suffix
# of the other, so only a subscriber-digit comparison finds it.
source "$(dirname "$0")/env.sh"

NAME="PhoneSearchTest"
NUM="+15550001234"
NATIONAL_NAME="NationalContactTest"
NATIONAL_NUM="+919876543210"
MARK="phonesearch$(date +%s)"
TS=$(( $(date +%s) * 1000 ))
PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

sql() { echo "$1" | adb_ shell "run-as $PKG sqlite3 databases/messages.db"; }

cleanup() {
    for n in "$NUM" "$NATIONAL_NUM"; do
        sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$n');"
        sql "DELETE FROM conversations WHERE address='$n';"
    done
}
trap cleanup EXIT

info "Seed the conversations"
cleanup
sql "INSERT INTO conversations(address,name,snippet,timestamp,last_is_me) VALUES('$NUM','$NAME','$MARK',$TS,0);"
sql "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,media_type) SELECT id,'$MARK',$TS,0,'received','text' FROM conversations WHERE address='$NUM';"
sql "INSERT INTO conversations(address,name,snippet,timestamp,last_is_me) VALUES('$NATIONAL_NUM','$NATIONAL_NAME','$MARK',$((TS+1)),0);"
sql "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,media_type) SELECT id,'$MARK',$((TS+1)),0,'received','text' FROM conversations WHERE address='$NATIONAL_NUM';"

# One query per app start, so the search field is always clean.
check() { # query expected(found|missing) label row
    adb_ shell am force-stop "$PKG"; sleep 1
    adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 5
    if ! tap_text "Search" >/dev/null 2>&1; then
        bad "$3: no Search button"
        return
    fi
    sleep 1
    type_text "$1" >/dev/null 2>&1
    sleep 2
    if ui_has "${4:-$NAME}"; then got=found; else got=missing; fi
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

info "A saved contact is found by its national-form number"
check "09876543210"     found "trunk zero, no country code" "$NATIONAL_NAME"
check "09876 543 210"   found "national grouping"        "$NATIONAL_NAME"
check "00919876543210"  found "00 international prefix"  "$NATIONAL_NAME"

info "Unrelated input must not"
check "5550000000" missing "unrelated number"
check "09876500000" missing "unrelated national number" "$NATIONAL_NAME"

info "Name search still works"
check "$NAME" found "name"

echo ""
info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
