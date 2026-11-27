#!/usr/bin/env bash
# Task 3: General settings must not offer "Scheduled messages" until there is
# a scheduled message to manage. The Advanced master switch stays where it is;
# this is only about the entry point into the list.
#
# Requires a disposable emulator. The scheduled_messages table is cleared so a
# row left by an earlier script cannot make the empty case look populated.
source "$(dirname "$0")/env.sh"
set -uo pipefail

PASS=0; FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
info() { printf '\n=== %s ===\n' "$1"; }
[[ "$ANDROID_SERIAL" == emulator-* ]] || { printf 'Requires a disposable emulator.\n'; exit 1; }

SCHED=$(res_string settings_scheduled_title)
[ -n "$SCHED" ] || { printf 'env.sh: settings_scheduled_title is missing\n'; exit 1; }
NUM="+1555900$(date +%s | tail -c 7)"
NOW_MS=$(date +%s%3N)
FUTURE=$((NOW_MS + 3600000))
sql() { adb_ shell "run-as $PKG sqlite3 databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r'; }

cleanup() {
    sql "DELETE FROM scheduled_messages;" >/dev/null 2>&1 || true
    sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM');" >/dev/null 2>&1 || true
    sql "DELETE FROM conversations WHERE address='$NUM';" >/dev/null 2>&1 || true
}
trap cleanup EXIT

open_settings() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    sleep 1
    adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null 2>&1
    sleep 5
    dump_ui >/dev/null 2>&1 || return 1
    if grep -q 'text="Not now"' "$TMP/ui.xml"; then
        adb_ shell input tap 540 1200 >/dev/null 2>&1
        sleep 2
        dump_ui >/dev/null 2>&1 || return 1
    fi
}

visible() { grep -qF "text=\"$SCHED\"" "$TMP/ui.xml"; }

cleanup
info "No scheduled messages: the row is absent"
open_settings || { fail 'settings did not open'; exit 1; }
if visible; then fail 'Scheduled messages is shown with an empty queue'; else pass 'the row is hidden'; fi

info "One scheduled message: the row returns"
conv=$(sql "INSERT INTO conversations (address,name,snippet,timestamp,archived,deleted_at,pinned) VALUES ('$NUM','Schedule probe','',$NOW_MS,0,0,0); SELECT last_insert_rowid();")
sql "INSERT INTO scheduled_messages (address,body,timestamp,conversation_id,sub_id) VALUES ('$NUM','probe body',$FUTURE,$conv,-1);" >/dev/null
open_settings || { fail 'settings did not reopen'; exit 1; }
if visible; then pass 'the row returns with one scheduled message'; else fail 'the row did not return'; fi

info "Queue emptied again: the row goes away"
cleanup
open_settings || { fail 'settings did not reopen'; exit 1; }
if visible; then fail 'the row stayed after the queue was emptied'; else pass 'the row is hidden again'; fi

printf '\n=== RESULTS: %s passed, %s failed ===\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
