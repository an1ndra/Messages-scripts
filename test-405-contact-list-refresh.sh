#!/usr/bin/env bash
# Regression: #405 -- a contact added or deleted in the Contacts app while
# Messages is running must reach the picker on the spot.
#
# New chat and the Forward dialog share one list (`AppViewModel.contacts`).
# That list used to be the snapshot taken when the ViewModel was built, and the
# ViewModel lives as long as the activity -- the chat is a route inside it, not
# a screen of its own. So a contact deleted during the session stayed offered as
# a forward target ("not in my contacts, cannot be deleted") and one added never
# appeared at all, until the app process was killed.
#
# Pre-fix: the inserted contact never shows up. Post-fix: it appears within a
# couple of seconds, and goes away again once the Contacts provider drops it.
#
# The picker is searched with a shorter query than the contact's name, so the
# search box itself cannot satisfy the assertion -- only the result row can.
#
# Note: the Contacts provider keeps a deleted raw contact aggregated for a few
# seconds (sometimes longer). The app can only be as fresh as the provider, so
# the "gone" check polls instead of asserting once.
#
# Run: scripts/test-405-contact-list-refresh.sh
#      ANDROID_SERIAL=10BD2J03YS0006F scripts/test-405-contact-list-refresh.sh
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh

PASS=0
FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }

NAME="Probe405Refresh"
QUERY="Probe405Ref"
NUM="+919900001405"
SID="probe405-$(date +%s)"

raw_id() {
    adb_ shell "content query --uri content://com.android.contacts/raw_contacts --projection _id --where \"sourceid='$SID'\"" 2>/dev/null \
        | grep -oE '_id=[0-9]+' | head -1 | cut -d= -f2 | tr -d '\r'
}

scrub() {
    adb_ shell "content delete --uri content://com.android.contacts/raw_contacts --where \"sourceid LIKE 'probe405-%'\"" >/dev/null 2>&1 || true
}
trap scrub EXIT

wait_until_absent() {
    local target="$1" tries="${2:-15}" i
    for i in $(seq 1 "$tries"); do
        dump_ui >/dev/null 2>&1 || true
        if ! grep -cF "$target" "$TMP/ui.xml" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    return 1
}

scrub
sleep 1

# Cold start, then open the picker. New chat reads the same contact flow as the
# Forward dialog and needs no message to exist first, so it is the stable entry
# point on a freshly installed app.
#
# The device may be asleep with the keyguard up, and a locked screen renders no
# picker at all — the run would look like "the app never started".
adb_ shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
adb_ shell wm dismiss-keyguard >/dev/null 2>&1 || true
adb_ shell am force-stop "$PKG" >/dev/null 2>&1
adb_ shell am start -n "$ACT" >/dev/null 2>&1
if wait_for_text "Start chat" 20; then
    pass "app reached the inbox"
else
    fail "app never reached the inbox"
    echo "PASS=$PASS FAIL=$FAIL"
    exit 1
fi

tap_text "Start chat" >/dev/null || true
sleep 2
tap_edittext || true
type_text "$QUERY" >/dev/null 2>&1 || true
sleep 2
dump_ui >/dev/null 2>&1 || true
if grep -cF "$NAME" "$TMP/ui.xml" >/dev/null 2>&1; then
    fail "the probe contact existed before the test created it"
else
    pass "probe contact absent before it is created"
fi

# Create the contact with the app already running.
adb_ shell "content insert --uri content://com.android.contacts/raw_contacts --bind account_name:s:probe405 --bind account_type:s:com.local --bind sourceid:s:$SID" >/dev/null 2>&1 || true
RID=$(raw_id)
if [ -z "$RID" ]; then
    echo "could not create a raw contact on this device (content insert is a no-op on the AOSP-30 image)"
    echo "PASS=$PASS FAIL=$FAIL"
    exit 1
fi
adb_ shell "content insert --uri content://com.android.contacts/data --bind raw_contact_id:l:$RID --bind mimetype:s:vnd.android.cursor.item/name --bind data1:s:$NAME" >/dev/null 2>&1 || true
adb_ shell "content insert --uri content://com.android.contacts/data --bind raw_contact_id:l:$RID --bind mimetype:s:vnd.android.cursor.item/phone_v2 --bind data1:s:$NUM --bind data2:l:0" >/dev/null 2>&1 || true

if wait_for_text "$NAME" 10; then
    pass "a contact added while the app runs appears without a restart"
    ADDED=1
else
    fail "added contact never reached the picker (the list is still the launch snapshot)"
    ADDED=0
fi

# Delete it again, with the same app process still alive. Pointless when the
# contact never appeared: a row cannot vanish from a list it never joined.
adb_ shell "content delete --uri content://com.android.contacts/raw_contacts --where \"sourceid='$SID'\"" >/dev/null 2>&1 || true
if [ "$ADDED" -eq 0 ]; then
    echo "[SKIP] deleted-contact check (the row never appeared)"
elif wait_until_absent "$NAME" 30; then
    pass "a contact deleted while the app runs leaves the picker without a restart"
else
    fail "deleted contact stayed in the picker (#405: 'cannot be deleted')"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
