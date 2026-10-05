#!/usr/bin/env bash
# Regression for scheduled messages.
#
#   1. A scheduled message renders inside its own conversation as a bubble,
#      with the send time, a live "in 2h 14m" countdown, and the SIM label —
#      the same meta line a sent bubble carries.
#   2. It is NOT listed in Settings or Settings -> Inbox. Both used to carry a
#      "Scheduled messages" list that duplicated the conversation view and
#      showed the recipient rather than the thread it belongs to.
#   3. The scheduled row keeps its position by send time: it sits after an
#      earlier message and before a later one, so the ordering in the chat is
#      chronological rather than "all real messages, then all pending".
#
# Seeds its own conversation and one scheduled row 2h out, so it does not
# depend on demo data. Non-destructive: only rows it created are removed.
# Run: scripts/test-scheduled-in-chat.sh
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh

PASS=0
FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }

NUM="+1555$(date +%s | tail -c 8)"
TOKEN="sched$(date +%s | tail -c 6)"
NOW_MS=$(( $(date +%s) * 1000 ))          # the app stores epoch MILLIS
FUTURE=$(( NOW_MS + 7200000 ))            # 2 hours out -> "2h 0m"
PAST=$(( NOW_MS - 600000 ))

db() { adb_ shell "run-as $PKG sqlite3 databases/messages.db \"$1\"" 2>/dev/null; }

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    db "DELETE FROM scheduled_messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM');" >/dev/null 2>&1 || true
    db "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM');" >/dev/null 2>&1 || true
    db "DELETE FROM conversations WHERE address='$NUM';" >/dev/null 2>&1 || true
    db "DELETE FROM participants WHERE normalized_destination='$NUM';" >/dev/null 2>&1 || true
}
trap cleanup EXIT

adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1 || true
bash ./grant-permissions.sh >/dev/null 2>&1 || true

seed() {
    local conv
    conv=$(db "INSERT INTO conversations (address,name,snippet,timestamp,archived,deleted_at,pinned) VALUES ('$NUM','Sched Target','',$NOW_MS,0,0,0); SELECT last_insert_rowid();")
    conv=$(echo "$conv" | tr -d '\r' | tail -1)
    [ -n "$conv" ] || { echo "seed failed: no conversation id"; exit 1; }
    # earlier than the scheduled row, so ordering is observable
    db "INSERT INTO messages (conversation_id,body,timestamp,is_me,status,media_type,media_uri,sub_id,transport,address) VALUES ($conv,'earlier message',$PAST,1,'sent','text','',1,'sms','$NUM');" >/dev/null
    db "INSERT INTO scheduled_messages (address,body,timestamp,conversation_id,sub_id) VALUES ('$NUM','scheduled bubble body',$FUTURE,$conv,1);" >/dev/null
    printf '%s' "$conv"
}

launch_chat() {
    local i
    adb_ shell am force-stop "$PKG"; sleep 1
    adb_ shell am start -n "$ACT" >/dev/null; sleep 5
    # the list populates from a cold start, so retry rather than trust one dump
    for i in 1 2 3 4 5; do
        dump_ui >/dev/null 2>&1
        strip_isolates < "$TMP/ui.xml" > "$TMP/ui.clean.xml"
        if grep -q "$NUM" "$TMP/ui.clean.xml"; then
            tap_row "$NUM" && sleep 2 && return 0
        fi
        sleep 2
    done
    return 1
}

# Center of the first node whose text or content-desc contains $1, computed
# from a stripped dump. env.sh's center_of_contains cannot parse the isolates,
# so the arithmetic is inlined here rather than changing a shared helper.
tap_row() {
    local q b x1 y1 x2 y2
    q=$(re_escape "$1")
    b=$(grep -oE "(text|content-desc)=\"[^\"]*${q}[^\"]*\"[^>]*bounds=\"\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]\"" \
            "$TMP/ui.clean.xml" 2>/dev/null | head -1 \
        | grep -oE '\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]' | tail -1)
    [ -z "$b" ] && return 1
    x1=$(sed -E 's/\[([0-9]+),.*/\1/' <<< "$b"); y1=$(sed -E 's/\[[0-9]+,([0-9]+)\].*/\1/' <<< "$b")
    x2=$(sed -E 's/.*\]\[([0-9]+),.*/\1/' <<< "$b"); y2=$(sed -E 's/.*\[[0-9]+,([0-9]+)\].*/\1/' <<< "$b")
    adb_ shell input tap $(( (x1 + x2) / 2 )) $(( (y1 + y2) / 2 ))
    sleep 3
}

check_present() {
    strip_isolates < "$TMP/ui.xml" > "$TMP/ui.clean.xml"
    if grep -q "$2" "$TMP/ui.clean.xml"; then pass "$1"; else fail "$1"; fi
}
check_absent() {
    strip_isolates < "$TMP/ui.xml" > "$TMP/ui.clean.xml"
    if grep -q "$2" "$TMP/ui.clean.xml"; then fail "$1"; else pass "$1"; fi
}

CONV=$(seed)

info_msg() { printf '\n=== %s ===\n' "$1"; }

info_msg "1. scheduled bubble in its conversation"
if launch_chat; then
    check_present "scheduled body renders in the chat" "scheduled bubble body"
    check_present "countdown is shown (2h out)" "in 2h"
    check_present "SIM label is shown" "SIM 1"
    check_present "earlier message is in the same chat" "earlier message"
    if python3 - "$TMP/ui.clean.xml" <<'PYCHK'
import sys
xml = open(sys.argv[1], encoding="utf-8", errors="replace").read()
a, b = xml.find("earlier message"), xml.find("scheduled bubble body")
sys.exit(0 if a != -1 and b != -1 and a < b else 1)
PYCHK
    then pass "scheduled row sorts after the earlier message"
    else fail "scheduled row is not ordered after the earlier message"
    fi
else
    fail "could not open the seeded conversation"
fi

info_msg "2. not listed in Settings / Inbox"
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" >/dev/null; sleep 4
dump_ui >/dev/null 2>&1
strip_isolates < "$TMP/ui.xml" > "$TMP/ui.clean.xml"
tap_row "Settings" >/dev/null 2>&1 || true
sleep 3
check_absent "Settings has no Scheduled messages row" "Scheduled messages"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
exit $(( FAIL > 0 ))
