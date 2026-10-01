#!/usr/bin/env bash
# Forward picker must offer every contact, not just the alphabetically first few.
#
# Two bugs covered:
#
#   1. On API 34+ the contact load queried only ENTERPRISE_CONTENT_URI, which
#      returns work-profile contacts exclusively, so every personal contact was
#      dropped and the picker showed work contacts or nothing.
#   2. ForwardTargets capped the list at 60 targets. Targets are ordered by
#      contact name, so a phone with many contacts could scroll no further than
#      the names beginning with A and reaching anyone else meant having to know
#      to search first.
#
# Seeds device contacts whose names sort LAST ("Zzq...") so they fall past any
# alphabetical cut-off, seeds a message through the UI (as test-forward.sh does,
# so it never depends on the messages table schema), then scrolls the forward
# picker to the end and requires a seeded contact to be there.
#
# Asserted from uiautomator dumps, no screenshots.
# Run: scripts/test-forward-contacts.sh
set -uo pipefail
cd "$(dirname "$0")"
source ./env.sh

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

PREFIX="Zzq"
SEED_COUNT=80
MARK="FW$(date +%s)$$"
SELF="+1555999$$"
LAST="$PREFIX$(printf '%03d' "$SEED_COUNT")"

cleanup() {
    info "Cleanup: removing seeded contacts and messages"
    adb_ shell content query --uri content://com.android.contacts/data \
        --projection raw_contact_id --where "\"display_name LIKE '$PREFIX%'\"" 2>/dev/null \
        | grep -oE 'raw_contact_id=[0-9]+' | cut -d= -f2 | sort -un | while read -r rid; do
            adb_ shell content delete --uri content://com.android.contacts/raw_contacts \
                --where "\"_id=$rid\"" >/dev/null 2>&1 || true
        done
    adb_ shell "run-as $PKG sqlite3 databases/messages.db \"delete from messages where body like '%$MARK%';\"" \
        >/dev/null 2>&1 || true
    echo "[cleanup] done"
}
trap cleanup EXIT

info "Granting contacts permission"
adb_ shell pm grant "$PKG" android.permission.READ_CONTACTS >/dev/null 2>&1 || true

info "Seeding $SEED_COUNT contacts named ${PREFIX}* (sorts last)"
MAXID=$(adb_ shell content query --uri content://com.android.contacts/raw_contacts \
    --projection _id 2>/dev/null | grep -oE '_id=[0-9]+' | cut -d= -f2 | sort -n | tail -1)
RID=$(( ${MAXID:-0} + 1 ))
SEEDED=0
for i in $(seq 1 "$SEED_COUNT"); do
    adb_ shell content insert --uri content://com.android.contacts/raw_contacts \
        --bind account_type:s:local --bind account_name:s:regression \
        --bind _id:i:$(( RID + i )) >/dev/null 2>&1 || continue
    adb_ shell content insert --uri content://com.android.contacts/data \
        --bind raw_contact_id:i:$(( RID + i )) \
        --bind mimetype:s:vnd.android.cursor.item/name \
        --bind data1:s:"$PREFIX$(printf '%03d' "$i")" \
        --bind data2:s:1 >/dev/null 2>&1 || continue
    adb_ shell content insert --uri content://com.android.contacts/data \
        --bind raw_contact_id:i:$(( RID + i )) \
        --bind mimetype:s:vnd.android.cursor.item/phone_v2 \
        --bind data1:s:"+15559$(printf '%06d' "$i")" \
        --bind data2:s:2 >/dev/null 2>&1 || continue
    SEEDED=$(( SEEDED + 1 ))
done
[ "$SEEDED" -ge 20 ] || { bad "could not seed contacts (only $SEEDED)"; exit 1; }
ok "seeded $SEEDED contacts sorting after any real name"

info "Restarting the app so the contact list is re-read"
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" >/dev/null; sleep 8

info "Seeding a message to forward (via the UI, as test-forward.sh does)"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1
adb_ shell am start -a android.intent.action.SENDTO -d "smsto:$SELF" "$ACT" >/dev/null 2>&1
sleep 5
tap_edittext || true
type_text "$MARK"
sleep 1
dump_ui || true
SEND=$(python3 - "$TMP/ui.xml" <<'PY'
import re, sys
xml = open(sys.argv[1], encoding="utf-8").read()
for tag in re.findall(r'<node[^>]*>', xml):
    d = re.search(r'content-desc="Send"', tag)
    b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', tag)
    if d and b:
        x1, y1, x2, y2 = map(int, b.groups())
        print((x1 + x2) // 2, (y1 + y2) // 2); break
PY
)
[ -n "$SEND" ] && adb_ shell input tap $SEND
sleep 4

info "Opening the target picker"
if ! wait_for_text "$MARK" 8; then
    bad "seeded message never rendered in the chat"
    exit 1
fi
ok "seeded message is in the chat"
BUBBLE=$(center_of "$MARK")
adb_ shell input swipe $BUBBLE $BUBBLE 800; sleep 2
dump_ui
if ui_tags | grep -q 'content-desc="Forward"'; then
    ok "long-press opened the selection toolbar with a Forward button"
else
    bad "no Forward button on the selection toolbar"
    exit 1
fi
FWD=$(python3 - "$TMP/ui.xml" <<'PY'
import re, sys
xml = open(sys.argv[1], encoding="utf-8").read()
for tag in re.findall(r'<node[^>]*>', xml):
    d = re.search(r'content-desc="Forward"', tag)
    b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', tag)
    if d and b:
        x1, y1, x2, y2 = map(int, b.groups())
        print((x1 + x2) // 2, (y1 + y2) // 2); break
PY
)
[ -n "$FWD" ] || { bad "no Forward button to tap"; exit 1; }
adb_ shell input tap $FWD; sleep 3
dump_ui
if grep -q 'text="Forward to"' "$TMP/ui.xml"; then
    ok "Forward opened the target picker"
else
    bad "Forward did not open the target picker"
    exit 1
fi

info "Personal device contacts are offered (not only the work profile)"
dump_ui >/dev/null 2>&1 || true
if grep -qF "${PREFIX}001" "$TMP/ui.xml"; then
    ok "a seeded personal contact is listed in the picker"
else
    bad "no seeded personal contact in the picker — personal profile not loaded"
fi

info "The picker is not truncated at 60 targets"
FOUND=0
for _ in $(seq 1 40); do
    if dump_ui >/dev/null 2>&1 && grep -qF "$LAST" "$TMP/ui.xml"; then
        FOUND=1; break
    fi
    adb_ shell input swipe 540 1400 540 900 250; sleep 0.4
done
if [ "$FOUND" -eq 1 ]; then
    ok "reached $LAST by scrolling: the target list is not capped"
else
    bad "could not reach $LAST by scrolling — the target list is still truncated"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]