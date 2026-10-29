#!/usr/bin/env bash
# Reported after installing a build: notifications the user had already cleared
# came back, and "Mark all as read" left the shade untouched.
#
# Two causes, both covered here:
#   1. the boot/app-update re-post had no idea a notification had been dismissed,
#      so `install -r` (ACTION_MY_PACKAGE_REPLACED) resurrected it;
#   2. mark-all-read only zeroed the counter in the database and never cancelled
#      the notifications it had just read.
#
# Fails on the pre-fix build: the notification comes back after the reinstall,
# and survives Mark all as read.
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
adb_ root >/dev/null 2>&1

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { printf '\n=== %s ===\n' "$1"; }

APK=app/build/outputs/apk/debug/app-debug.apk
MARK="repost$(date +%s)"
NUM="+1555$(( (RANDOM % 9000) + 1000 ))"
TEXT="repost probe $MARK"

sql() { adb_ shell "sqlite3 /data/data/$PKG/databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r'; }
notif_has_mark() {
    # Not `dumpsys … | grep -q`: under `pipefail` grep exits on the first match,
    # dumpsys dies of SIGPIPE, and the pipeline reports 141 — so a notification
    # that was there read as absent. Capture first, match second.
    local dump
    dump=$(adb_ shell "dumpsys notification --noredact" 2>/dev/null | tr -d '\r')
    case "$dump" in *"$MARK"*) return 0;; *) return 1;; esac
}

# The notification is posted from the receiver, so give it time rather than
# sampling once: a fixed 3s sleep made this read "no notification" on a busy AVD.
wait_for_mark() {   # seconds
    local i
    for i in $(seq 1 "${1:-15}"); do
        notif_has_mark && return 0
        sleep 1
    done
    return 1
}

wait_for_mark_gone() {
    local i
    for i in $(seq 1 "${1:-15}"); do
        notif_has_mark || return 0
        sleep 1
    done
    return 1
}

cleanup() {
    adb_ shell input keyevent 4 >/dev/null 2>&1
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    sql "DELETE FROM messages WHERE body LIKE '%$MARK%';" >/dev/null 2>&1
    sql "DELETE FROM conversations WHERE address='$NUM';" >/dev/null 2>&1
    adb_ shell am start -n "$ACT" >/dev/null 2>&1
}
trap cleanup EXIT

info "Preconditions"
adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1
# Bubbles off for this run: a conversation held by a live bubble is deliberately
# skipped by the mark-all-read sweep (GM keeps its bubble too), which would make
# that assertion test the wrong rule.
adb_ shell cmd notification set_bubbles "$PKG" 0 >/dev/null 2>&1
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 4
ok "app started with the SMS role"

info "A new message posts a notification"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1
adb_ emu sms send "$NUM" "$TEXT" >/dev/null 2>&1
for _ in $(seq 1 20); do [ -n "$(sql "SELECT id FROM conversations WHERE address='$NUM'")" ] && break; sleep 1; done
if wait_for_mark 20; then ok "the message posted a notification"; else bad "no notification for the new message"; fi

info "Dismissing it from the shade"
adb_ shell cmd statusbar expand-notifications >/dev/null 2>&1; sleep 3
# Swipe the card itself away: dismissal is what runs the delete intent, and the
# card's place in the shade depends on how many notifications precede it.
card=$(layout_center "$TEXT")
if [ -n "$card" ]; then
    set -- $card
    adb_ shell input swipe $(( $1 + 250 )) $2 $(( $1 - 500 )) $2 300 >/dev/null 2>&1
else
    adb_ shell input swipe 900 700 100 700 300 >/dev/null 2>&1
fi
sleep 3
adb_ shell input keyevent 4 >/dev/null 2>&1; sleep 2
if wait_for_mark_gone 10; then ok "the notification was dismissed"; else bad "the notification is still up after the swipe"; fi

info "Reinstalling (ACTION_MY_PACKAGE_REPLACED) must not resurrect it"
adb_ install -r "$APK" >/dev/null 2>&1
sleep 8
if notif_has_mark; then
    bad "the dismissed notification came back after the update (#345 follow-up)"
else
    ok "the dismissed notification stayed dismissed across the update"
fi

info "A genuinely new message still posts"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1
MARK="$MARK-b"
adb_ emu sms send "$NUM" "$MARK" >/dev/null 2>&1
if wait_for_mark 20; then ok "a newer message still notifies"; else bad "a newer message did not notify"; fi

info "Mark all as read clears the shade"
reached=0
# The gear tap can land before General settings has settled, so retry the whole
# entry rather than failing the assertion on one missed tap.
for _ in 1 2 3; do
    adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 4
    adb_ shell input tap 970 143 >/dev/null 2>&1; sleep 4
    if scroll_to_layout "Mark all as read" >/dev/null 2>&1 &&
        tap_layout "Mark all as read" >/dev/null 2>&1; then
        reached=1
        break
    fi
    adb_ shell input keyevent 4 >/dev/null 2>&1; sleep 2
done
if [ "$reached" = "1" ]; then
    sleep 3
    tap_layout_exact "Mark all as read" >/dev/null 2>&1 || tap_layout "Mark all as read" >/dev/null 2>&1
    sleep 5
    if notif_has_mark; then
        bad "the notification survived Mark all as read"
    else
        ok "Mark all as read cancels the notifications it read"
    fi
else
    bad "could not reach Mark all as read"
fi

echo ""
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
exit $((FAIL > 0))
