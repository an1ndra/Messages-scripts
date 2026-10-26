#!/usr/bin/env bash
# Regression for #345 (first half): a boot or an app update wipes the
# notification shade, and the launcher badge sums the numbers of the app's live
# notifications — so unread messages that survived in the database lost their
# badge ("the phone turned off and on again; the counter no longer shows any
# number"). The BootReceiver must re-post one silent notification per unread
# conversation for both broadcasts:
#
#   BOOT_COMPLETED       -> adb reboot
#   MY_PACKAGE_REPLACED  -> adb install -r (same versionCode)
#
# Fails on the pre-fix build: nothing re-posts, so the shade stays empty after
# both steps.
source "$(dirname "$0")/env.sh"
set -uo pipefail

PASS=0
FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }

MARK="boot$(date +%s)$$"
A="+1555992${MARK: -3}"
B="+1555993${MARK: -3}"
APK="$PROJECT_DIR/app/build/outputs/apk/debug/app-debug.apk"

db_sql() {
    adb_ shell "run-as $PKG sqlite3 databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r' && return 0
    adb_ shell "su -c \"sqlite3 /data/data/$PKG/databases/messages.db \\\"$1\\\"\"" 2>/dev/null | tr -d '\r' || true
}
notif_count() { adb_ shell "dumpsys notification --noredact 2>/dev/null" | tr -d '\r' | grep -cE "NotificationRecord.*pkg=$PKG"; }
id_for() { db_sql "SELECT id FROM conversations WHERE address='$1';" | tr -d '\r\n'; }

# The number carried by one specific notification id (the launcher badge sums
# these across the app's live notifications).
number_for_id() {
    adb_ shell "dumpsys notification --noredact" 2>/dev/null | tr -d '\r' | awk -v want="$1" -v pkg="$PKG" '
        /NotificationRecord\(/ { i=($0 ~ ("pkg=" pkg)); if (i) { match($0, /id=[0-9-]+/); id=substr($0, RSTART+3, RLENGTH-3) } }
        i && id == want && /^[[:space:]]+number=/ { gsub(/[^0-9]/, "", $0); print $0; exit }
    '
}

# Poll until every address=number pair holds, so a slow boot or a slow re-post
# is indistinguishable from a missing one only after the budget runs out.
await_badges() {
    local i pair a want n good
    for i in $(seq 1 30); do
        good=yes
        for pair in "$@"; do
            a=${pair%%=*}; want=${pair##*=}
            n=$(number_for_id "$(id_for "$a")")
            [ "$n" = "$want" ] || good=no
        done
        [ "$good" = yes ] && return 0
        sleep 3
    done
    return 1
}

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    db_sql "DELETE FROM messages WHERE body LIKE '%$MARK%'; DELETE FROM conversations WHERE address IN ('$A','$B'); DELETE FROM participants WHERE normalized_destination IN ('$A','$B');" >/dev/null 2>&1 || true
    adb_ shell settings put global debug.force_rtl 0 >/dev/null 2>&1 || true
}
trap cleanup EXIT

for p in READ_SMS RECEIVE_SMS SEND_SMS READ_CONTACTS POST_NOTIFICATIONS; do
    adb_ shell pm grant "$PKG" "android.permission.$p" >/dev/null 2>&1
done
adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1 || true

# Clear any notification left by an earlier run: the assertions read specific
# conversation ids, but a shade full of stale badges is noise either way.
for id in $(adb_ shell "dumpsys notification --noredact" 2>/dev/null | tr -d '\r' \
        | grep -oE "NotificationRecord\(.*pkg=$PKG.*id=[0-9-]+" | grep -oE "id=[0-9-]+" | cut -d= -f2 | sort -u); do
    adb_ shell cmd notification cancel "$PKG" "$id" tag 0 >/dev/null 2>&1
done

info "Seed unread conversations the way the badge is built: real arrivals"
# Two from A, one from B - after settling, A's notification must carry 2 and
# B's 1, which is exactly what the re-post has to reproduce from the database.
adb_ shell am force-stop "$PKG" >/dev/null 2>&1
adb_ shell am start -n "$ACT" >/dev/null 2>&1
sleep 5
adb_ shell input keyevent KEYCODE_HOME >/dev/null 2>&1
sleep 2
adb_ emu sms send "$A" "boot probe one $MARK" >/dev/null 2>&1
sleep 5
adb_ emu sms send "$A" "boot probe two $MARK" >/dev/null 2>&1
sleep 5
adb_ emu sms send "$B" "boot probe $MARK" >/dev/null 2>&1
sleep 7
UA=$(db_sql "SELECT unread_count FROM conversations WHERE address='$A';")
UB=$(db_sql "SELECT unread_count FROM conversations WHERE address='$B';")
if [ "$UA" = "2" ] && [ "$UB" = "1" ]; then
    pass "seeded 2 unread for A and 1 for B"
else
    fail "seed left unread at A='$UA' B='$UB' (expected 2 and 1)"
fi

if await_badges "$A=2" "$B=1"; then
    pass "the shade carries A=2 and B=1 before the wipe"
else
    fail "notifications not posted with numbers A=$(number_for_id "$(id_for "$A")") B=$(number_for_id "$(id_for "$B")") (expected 2 and 1)"
fi

info "A reboot must not take the badge with it"
adb_ reboot
adb_ wait-for-device
until [ "$(adb_ shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; do sleep 5; done
adb_ shell wm dismiss-keyguard >/dev/null 2>&1
UA=$(db_sql "SELECT unread_count FROM conversations WHERE address='$A';")
UB=$(db_sql "SELECT unread_count FROM conversations WHERE address='$B';")
if [ "$UA" = "2" ] && [ "$UB" = "1" ]; then
    pass "unread counts survived the reboot in the database"
else
    fail "unread counts after reboot: A='$UA' B='$UB' (expected 2 and 1)"
fi
if await_badges "$A=2" "$B=1"; then
    pass "the boot re-post put A=2 and B=1 back in the shade"
else
    fail "after reboot the shade holds A=$(number_for_id "$(id_for "$A")") B=$(number_for_id "$(id_for "$B")") (expected 2 and 1) - the badge died with the reboot"
fi

info "An app update must not take the badge with it either"
if [ ! -s "$APK" ]; then
    fail "no debug APK at $APK - build the app first"
else
    adb_ install -r "$APK" >/dev/null 2>&1 || fail "the reinstall itself failed"
    if await_badges "$A=2" "$B=1"; then
        pass "the update re-post put A=2 and B=1 back in the shade"
    else
        fail "after update the shade holds A=$(number_for_id "$(id_for "$A")") B=$(number_for_id "$(id_for "$B")") (expected 2 and 1) - the badge died with the update"
    fi
fi

if adb_ shell "logcat -d -b crash" 2>/dev/null | grep -q "$PKG"; then
    fail 'app crashed during the boot re-post regression'
else
    pass 'no crashes'
fi

printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
