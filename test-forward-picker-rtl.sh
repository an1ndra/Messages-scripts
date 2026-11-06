#!/usr/bin/env bash
# Regression for #405 follow-up: phone numbers in the forward picker.
#
# A phone number is a weakly-typed run of digits and separators. Plain Text
# inherits the window direction, so on a Persian-locale (RTL) phone the bidi
# algorithm laid the run out right-to-left: "+98 912 762 0912" painted as
# "0912 762 98+", and the reporter's "*21*2258#" as "2258#*21*" (screenshots
# in the issue). Numbers must be painted as LTR isolates whatever the window
# direction, and the search box must take the direction of its own first strong
# character, as the composer already does.
#
# The paint order is invisible in a `uiautomator` dump... except that
# BidiText.ltr() inserts U+2066 LRI … U+2069 PDI into the string, and the dump
# carries them (which is why env.sh has strip_isolates()). So the row assertion
# reads the isolate characters themselves. The field's textDirection is not in
# the string, so the app reports it as:
#
#   ForwardBidi: query dir=Ltr|Rtl rows=<n>
#
# The RTL window is the developer-option force-RTL switch rather than a
# Persian system locale: the failure is the bidi algorithm reordering a run in
# an RTL paragraph, not translation, and the API-31 AVD has no per-app locale
# `cmd locale` service (it was removed before it ever shipped there).
#
# Fails on the pre-fix build: the number is dumped bare and no ForwardBidi line
# is ever logged.
#
# Run: scripts/test-forward-picker-rtl.sh
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

MARK="fwdrtl$(date +%s)$$"
CONTACT="RtlForward$MARK"
NUMBER="*21*2258#"
SELF="+1555987${MARK: -4}"
ORIG_FORCE_RTL=""

adb_ root >/dev/null 2>&1; adb_ wait-for-device; sleep 1
sql() { adb_ shell "sqlite3 /data/data/$PKG/databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r'; }

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    adb_ shell content query --uri content://com.android.contacts/data \
        --projection raw_contact_id --where "\"display_name LIKE '$CONTACT'\"" 2>/dev/null \
        | grep -oE 'raw_contact_id=[0-9]+' | cut -d= -f2 | sort -un | while read -r rid; do
            adb_ shell content delete --uri content://com.android.contacts/raw_contacts \
                --where "\"_id=$rid\"" >/dev/null 2>&1 || true
        done
    sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$SELF');" >/dev/null 2>&1
    sql "DELETE FROM conversations WHERE address='$SELF';" >/dev/null 2>&1
    if [ -n "$ORIG_FORCE_RTL" ] && [ "$ORIG_FORCE_RTL" != "null" ]; then
        adb_ shell settings put global debug.force_rtl "$ORIG_FORCE_RTL" >/dev/null 2>&1
    else
        adb_ shell settings delete global debug.force_rtl >/dev/null 2>&1
    fi
}
trap cleanup EXIT

for p in READ_SMS RECEIVE_SMS READ_CONTACTS POST_NOTIFICATIONS; do
    adb_ shell pm grant "$PKG" "android.permission.$p" >/dev/null 2>&1
done
adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1 || true
for p in READ_PHONE_STATE CALL_PHONE READ_PHONE_NUMBERS; do
    adb_ shell pm grant "$PKG" "android.permission.$p" >/dev/null 2>&1
done

info "Forcing the app window RTL"
ORIG_FORCE_RTL=$(adb_ shell settings get global debug.force_rtl 2>/dev/null | tr -d '\r')
adb_ shell settings put global debug.force_rtl 1 >/dev/null 2>&1
adb_ shell am force-stop "$PKG" >/dev/null 2>&1
sleep 1

info "Seeding a contact whose number is bidi-neutral ('$NUMBER')"
MAXID=$(adb_ shell content query --uri content://com.android.contacts/raw_contacts \
    --projection _id 2>/dev/null | grep -oE '_id=[0-9]+' | cut -d= -f2 | sort -n | tail -1)
RID=$(( ${MAXID:-0} + 1 ))
adb_ shell content insert --uri content://com.android.contacts/raw_contacts \
    --bind account_type:s:local --bind account_name:s:regression \
    --bind _id:i:"$RID" >/dev/null 2>&1
adb_ shell content insert --uri content://com.android.contacts/data \
    --bind raw_contact_id:i:"$RID" \
    --bind mimetype:s:vnd.android.cursor.item/name \
    --bind data1:s:"$CONTACT" --bind data2:s:1 >/dev/null 2>&1
adb_ shell content insert --uri content://com.android.contacts/data \
    --bind raw_contact_id:i:"$RID" \
    --bind mimetype:s:vnd.android.cursor.item/phone_v2 \
    --bind data1:s:"$NUMBER" --bind data2:s:2 >/dev/null 2>&1
if adb_ shell content query --uri content://com.android.contacts/data \
    --projection data1 --where "\"data1='$NUMBER'\"" 2>/dev/null | grep -q "data1="; then
    ok "contact with a separator-heavy number is on the device"
else
    bad "could not seed the contact"
    exit 1
fi

info "Seeding a message to forward, and opening its chat"
TS=$(date +%s000)
sql "INSERT INTO conversations(address,name,snippet,timestamp,unread_count) VALUES('$SELF','$MARK','$MARK',$TS,0);" >/dev/null 2>&1
CID=$(sql "SELECT id FROM conversations WHERE address='$SELF';")
[ -z "$CID" ] && { bad "could not seed a conversation"; exit 1; }
sql "INSERT INTO messages(conversation_id,body,timestamp,status) VALUES($CID,'$MARK',$TS,'received');" >/dev/null 2>&1
adb_ shell am force-stop "$PKG" >/dev/null 2>&1
adb_ shell am start -n "$ACT" --es open_conversation_address "$SELF" >/dev/null 2>&1
if ! wait_for_text "$MARK" 14; then
    bad "seeded message never rendered in the chat"
    exit 1
fi
ok "message bubble opened"

BUBBLE=$(center_of "$MARK") || { bad "could not locate the bubble"; exit 1; }
adb_ shell input swipe $BUBBLE $BUBBLE 800; sleep 3
FWD=""
for _ in $(seq 1 6); do
    FWD=$(center_of "Forward" 2>/dev/null) && [ -n "$FWD" ] && break
    sleep 1
done
if [ -n "$FWD" ]; then
    ok "long-press opened the selection toolbar with a Forward button"
else
    bad "no Forward button on the selection toolbar"
    exit 1
fi
adb_ shell input tap $FWD; sleep 3

if wait_for_text "Forward to" 8; then
    ok "Forward opened the target picker"
else
    bad "Forward did not open the target picker"
    exit 1
fi

info "The number row paints as an LTR isolate (U+2066 … U+2069)"
ISOLATED=0
for _ in $(seq 1 6); do
    if dump_ui >/dev/null 2>&1 && python3 - "$TMP/ui.decoded.xml" "$NUMBER" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
sys.exit(0 if ("⁦" + sys.argv[2] + "⁩") in text else 1)
PY
    then
        ISOLATED=1; break
    fi
    sleep 1
done
if [ "$ISOLATED" -eq 1 ]; then
    ok "the picker paints '$NUMBER' inside an LTR isolate"
else
    bad "'$NUMBER' is painted bare — an RTL window will reorder it"
fi

info "Typing digits into the search box reports an LTR field"
adb_ shell logcat -c >/dev/null 2>&1
if tap_edittext >/dev/null 2>&1; then
    type_text "0912"; sleep 2
    SEEN=""
    for _ in $(seq 1 8); do
        SEEN=$(adb_ logcat -d -s ForwardBidi:D 2>/dev/null | grep -o 'query dir=.*' | tr -d '\r' | tail -1)
        [ -n "$SEEN" ] && break
        sleep 1
    done
    if [ "$SEEN" = "query dir=Ltr rows=0" ] || [[ "$SEEN" == query\ dir=Ltr* ]]; then
        ok "a numeric query is painted LTR (ForwardBidi: $SEEN)"
    else
        bad "expected a ForwardBidi 'query dir=Ltr' line, got '${SEEN:-nothing}'"
    fi
else
    bad "could not focus the picker's search box"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
