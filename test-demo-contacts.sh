#!/usr/bin/env bash
# Guards the F-Droid demo data: the phone book and the seeded inbox must stay
# aligned, and every "photo" contact must hold a decodable thumbnail.
#
# Re-seeds first, so it fails against the state the old scripts produced:
#   - conversations used numbers that were not in the phone book, so every
#     avatar fell back to a placeholder
#   - multi-word names were lost, because the unquoted --bind value was split
#     by the device shell and the row insert failed silently
#   - a photo row with an undecodable blob renders as a bare coloured circle:
#     PersonAvatar only draws the silhouette when photo_uri resolves to null
set -uo pipefail
cd "$(dirname "$0")"
source ./env.sh
source ./demo-data.sh

PASS=0; FAIL=0
ok()   { echo "  PASS  $1"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

PROVIDER_DIR=/data/user/0/com.android.providers.contacts
DB=$PROVIDER_DIR/databases/contacts2.db
NAME_MIME=7; PHONE_MIME=5; PHOTO_MIME=10

dbq() { printf '%s' "$1" | adb_ shell "run-as $PKG sqlite3 databases/messages.db" 2>/dev/null | tr -d '\r'; }
sq()  { printf '%s' "$1" | adb_ shell "su 0 sqlite3 $DB" 2>/dev/null | tr -d '\r'; }
# One row, trimmed at the edges only - internal spaces matter for names.
sq1() { sq "$1" | head -1 | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }

info "Seeding demo data"
bash ./insert-demo-contacts.sh >/dev/null 2>&1 || { echo "  FAIL  insert-demo-contacts.sh errored"; exit 1; }
# --wipe also clears the system SMS provider, which syncFromSystem() would
# otherwise re-import from the stock AVD image on the next launch.
bash ./seed-demo-conversations.sh --wipe >/dev/null 2>&1 || { echo "  FAIL  seed-demo-conversations.sh errored"; exit 1; }
sleep 2

info "Every seeded conversation has a phone-book contact"
for n in $(dbq "SELECT address FROM conversations;"); do
    if ! printf '%s\n' "${DEMO_CONTACTS[@]}" | cut -d'|' -f1 | grep -qxF "$n"; then
        # Anything else is stray data - a stock AVD image ships a few hundred
        # sample messages, and they would dominate every screenshot.
        bad "unexpected conversation $n is in the inbox"
        continue
    fi
    hits=$(sq "SELECT COUNT(*) FROM data WHERE mimetype_id=$PHONE_MIME AND data1='$n';")
    if [ "${hits:-0}" -ge 1 ]; then ok "$n has a contact"
    else bad "$n has no contact - its avatar will be a placeholder"; fi
done

info "Every roster contact has a conversation-facing number"
for entry in "${DEMO_CONTACTS[@]}"; do
    n=$(demo_field "$entry" 1)
    hits=$(sq "SELECT COUNT(*) FROM data WHERE mimetype_id=$PHONE_MIME AND data1='$n';")
    if [ "${hits:-0}" -ge 1 ]; then ok "$(demo_field "$entry" 2) reachable as $n"
    else bad "$(demo_field "$entry" 2) is not reachable as $n"; fi
done

info "Every roster contact exists with a name"
for entry in "${DEMO_CONTACTS[@]}"; do
    n=$(demo_field "$entry" 1); display=$(demo_field "$entry" 2)
    name=$(sq1 "SELECT n.data1 FROM data n JOIN raw_contacts rc ON rc._id=n.raw_contact_id
                 WHERE n.mimetype_id=$NAME_MIME AND rc.sourceid='fdroid-$n';")
    if [ -n "$name" ]; then ok "$display saved as \"$name\""
    else bad "$display ($n) has no saved name"; fi
    # The app reads PhoneLookup.DISPLAY_NAME, which resolves to
    # raw_contacts.display_name - not to the data row. A structured name whose
    # display name style is set gets rebuilt from given+family, which is how
    # "Work Group" used to reach the conversation list as "GroupWork".
    resolved=$(sq1 "SELECT rc.display_name FROM raw_contacts rc
                     WHERE rc.sourceid='fdroid-$n';")
    if [ "$resolved" = "$display" ]; then ok "$display resolves to \"$resolved\""
    else bad "$display resolves to \"${resolved:-<none>}\" via phone_lookup"; fi
done

info "Photo contacts hold a decodable thumbnail"
for entry in "${DEMO_CONTACTS[@]}"; do
    [ "$(demo_field "$entry" 5)" = "photo" ] || continue
    n=$(demo_field "$entry" 1); display=$(demo_field "$entry" 2)
    # hex(): sqlite3 prints a BLOB column raw, which would corrupt the shell pipe.
    hex=$(sq1 "SELECT hex(d.data15) FROM data d JOIN raw_contacts rc ON rc._id=d.raw_contact_id
                WHERE d.mimetype_id=$PHOTO_MIME AND rc.sourceid='fdroid-$n';")
    if [ -z "$hex" ]; then bad "$display ($n) has no photo"; continue; fi
    if printf '%s' "$hex" | xxd -r -p 2>/dev/null | python3 -c "
import sys
d = sys.stdin.buffer.read()
sys.exit(0 if d[:2] in (b'\xff\xd8', b'\x89P') else 1)"; then
        ok "$display photo is a decodable JPEG/PNG"
    else
        bad "$display photo blob is not a decodable image"
    fi
    # data14/photo_file_id make the provider serve a file from the photo store
    # instead of the thumbnail; a stale one renders an empty avatar.
    fileid=$(sq1 "SELECT c.photo_file_id FROM contacts c JOIN raw_contacts rc ON rc.contact_id=c._id
                   WHERE rc.sourceid='fdroid-$n';")
    if [ -z "$fileid" ]; then ok "$display serves its thumbnail"
    else bad "$display points at photo-store file $fileid, which may not exist"; fi
done

info "No stale photo-store files"
if [ -z "$(sq 'SELECT _id FROM photo_files LIMIT 1;')" ]; then ok "photo_files is empty"
else bad "photo_files has leftover rows"; fi

echo
echo "PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0))
