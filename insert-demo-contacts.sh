#!/usr/bin/env bash
# Seeds the F-Droid demo phone book: one contact per conversation in
# demo-data.sh, each with a real name and (for people) a monogram photo, so the
# app's avatar lookup resolves instead of falling back to a placeholder.
#
# Names, numbers and message history are not test fixtures - the committed
# screenshots are taken from this data, so the numbers must stay fixed.
#
# Photo storage: the ContactsProvider keeps a contact photo as a thumbnail blob
# in data.data15 of the mimetype=photo row, with data14 (the photo-store file
# id) left NULL. That is what DataRowHandlerForPhoto writes for an image
# smaller than the display-photo threshold, and it is what the provider serves
# for contacts/<id>/photo when contacts.photo_file_id is NULL. `content` cannot
# bind a blob (`b` is boolean), so those writes go through sqlite3 as root.
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh
source ./demo-data.sh

PROVIDER_PKG=com.android.providers.contacts
PROVIDER_DIR=/data/user/0/$PROVIDER_PKG
DB=$PROVIDER_DIR/databases/contacts2.db
AVATAR_DIR="${AVATAR_DIR:-/tmp/opencode/messages-demo-avatars}"
PROVIDER_UID=$(adb_ shell "pm list packages -U $PROVIDER_PKG" | tr -d '\r' | sed -E 's/.*uid:([0-9]+)/\1/')

dbq() { adb_ shell "su 0 sqlite3 $DB" 2>/dev/null | tr -d '\r'; }
sq() { printf '%s' "$1" | dbq; }
mime_id() { sq "SELECT _id FROM mimetypes WHERE mimetype='$1';"; }

NAME_MIME=$(mime_id vnd.android.cursor.item/name)
PHONE_MIME=$(mime_id vnd.android.cursor.item/phone_v2)
PHOTO_MIME=$(mime_id vnd.android.cursor.item/photo)
[ -n "$NAME_MIME" ] && [ -n "$PHONE_MIME" ] && [ -n "$PHOTO_MIME" ] \
    || { echo "ERROR: could not resolve mimetype ids in $DB"; exit 1; }

info "Generating monogram avatars"
mkdir -p "$AVATAR_DIR"
python3 ./make-demo-avatars.py --out "$AVATAR_DIR" <<<"$(for e in "${DEMO_CONTACTS[@]}"; do
    echo "$(demo_field "$e" 2)|$(demo_field "$e" 3)|$(demo_field "$e" 4)|$(demo_field "$e" 1)"
done)"

info "Clearing previous demo contacts"
# Legacy runs used sourceid demo-N with unrelated numbers; those rows would
# otherwise linger in the phone book and show up in the contact picker.
stale_ids() {
    sq "SELECT group_concat(_id) FROM raw_contacts
          WHERE sourceid LIKE 'demo-%' OR sourceid LIKE 'fdroid-%';"
}
stale=$(stale_ids)
if [ -n "$stale" ]; then
    adb_ shell "content delete --uri content://com.android.contacts/raw_contacts --where \"_id IN ($stale)\"" >/dev/null 2>&1 || true
fi
# sourceid is not unique, so leftovers would make every lookup below ambiguous.
if [ -n "$(stale_ids)" ]; then
    sq "DELETE FROM data WHERE raw_contact_id IN ($(stale_ids));
        DELETE FROM raw_contacts WHERE _id IN ($(stale_ids));" >/dev/null
fi
# Stale photo-store rows from earlier experiments: the thumbnails below are the
# only photo source, so a leftover data14 would make the provider serve a file
# that no longer exists.
sq "DELETE FROM photo_files; UPDATE data SET data14=NULL WHERE mimetype_id=$PHOTO_MIME AND data14 IS NOT NULL; UPDATE contacts SET photo_file_id=NULL;" >/dev/null
adb_ shell "rm -rf $PROVIDER_DIR/files/photos" >/dev/null 2>&1 || true

seed_one() { # number, display, given, family, photo
    local num="$1" display="$2" given="$3" family="$4" photo="$5"
    local sid="fdroid-$num" rid cid rowid

    adb_ shell "content insert --uri content://com.android.contacts/raw_contacts --bind account_name:s:fdroid --bind account_type:s:com.local --bind sourceid:s:$sid" >/dev/null
    rid=$(sq "SELECT _id FROM raw_contacts WHERE sourceid='$sid';")
    [ "$(printf '%s' "$rid" | grep -c .)" = "1" ] \
        || { echo "ERROR: expected one raw contact for $display ($num), got [$(echo "$rid" | tr '\n' ' ')]"; exit 1; }

    # adb_ runs the command through the device shell, so a multi-word value
    # must be quoted or it is split into two arguments; and the command has to
    # stay on one line, since a newline would end it there. An unquoted name
    # made insert fail silently, which is why the old demo phone book had
    # contacts with no name at all.
    # data10 (display name style) must stay UNDEFINED. The provider rebuilds
    # raw_contacts.display_name from given+family for the other styles, and
    # FULL_NAME joins them the wrong way round: "Work Group" becomes
    # "GroupWork" in every phone_lookup result the app reads. UNDEFINED keeps
    # data1 verbatim, which is the display string demo-data.sh defines.
    adb_ shell "content insert --uri content://com.android.contacts/data --bind raw_contact_id:i:$rid --bind mimetype:s:vnd.android.cursor.item/name --bind data1:s:\"$display\" --bind data2:s:\"$given\" --bind data3:s:\"$family\" --bind data10:i:0" >/dev/null
    adb_ shell "content insert --uri content://com.android.contacts/data --bind raw_contact_id:i:$rid --bind mimetype:s:vnd.android.cursor.item/phone_v2 --bind data1:s:\"$num\" --bind data2:i:2 --bind is_primary:i:1" >/dev/null

    rowid=$(sq "SELECT _id FROM data WHERE raw_contact_id=$rid AND mimetype_id=$PHOTO_MIME LIMIT 1;")
    if [ -z "$rowid" ]; then
        adb_ shell "content insert --uri content://com.android.contacts/data --bind raw_contact_id:i:$rid --bind mimetype:s:vnd.android.cursor.item/photo" >/dev/null
        rowid=$(sq "SELECT _id FROM data WHERE raw_contact_id=$rid AND mimetype_id=$PHOTO_MIME LIMIT 1;")
    fi

    cid=$(sq "SELECT contact_id FROM raw_contacts WHERE _id=$rid;")
    if [ "$photo" = "photo" ]; then
        local hex
        hex=$(python3 -c "import sys;print(open(sys.argv[1],'rb').read().hex())" "$AVATAR_DIR/$num.jpg")
        # Routed through sqlite3: the provider decodes data15 on write and
        # would have to re-encode it, which `content` cannot express.
        sq "UPDATE data SET data15=X'$hex', data14=NULL, data_version=data_version+1
              WHERE _id=$rowid;
            UPDATE contacts SET photo_id=$rowid, photo_file_id=NULL WHERE _id=$cid;
            UPDATE raw_contacts SET version=version+1, metadata_dirty=1, aggregation_needed=1
              WHERE _id=$rid;" >/dev/null
    else
        sq "UPDATE data SET data15=NULL, data14=NULL WHERE _id=$rowid;
            UPDATE contacts SET photo_id=NULL, photo_file_id=NULL WHERE _id=$cid;" >/dev/null
    fi

    # Provider-mediated write so the aggregator and the URI notifier run; the
    # direct SQL above leaves contacts.photo_id set but stale in its caches.
    local ver; ver=$(sq "SELECT version FROM raw_contacts WHERE _id=$rid;")
    adb_ shell "content update --uri content://com.android.contacts/raw_contacts/$rid --bind version:i:$ver" >/dev/null 2>&1 || true

    echo "  ok: $display ($num) rawid=$rid contactid=$cid photo=$photo"
}

info "Seeding contacts"
for entry in "${DEMO_CONTACTS[@]}"; do
    seed_one "$(demo_field "$entry" 1)" "$(demo_field "$entry" 2)" \
             "$(demo_field "$entry" 3)" "$(demo_field "$entry" 4)" \
             "$(demo_field "$entry" 5)"
done

info "Clearing the app's image cache so changed avatars are re-read"
adb_ shell "run-as $PKG rm -rf cache/image_cache cache/coil 2>/dev/null" >/dev/null 2>&1 || true
adb_ shell "am force-stop $PKG" >/dev/null 2>&1 || true

info "=== provider state ==="
sq "SELECT c._id, ifnull(n.data1,'(noname)'), ifnull(p.data1,'(none)'),
           ifnull((SELECT length(d.data15) FROM data d
                    WHERE d.raw_contact_id=rc._id AND d.mimetype_id=$PHOTO_MIME),0)
      FROM raw_contacts rc
      JOIN contacts c ON c._id=rc.contact_id
      LEFT JOIN data n ON n.raw_contact_id=rc._id AND n.mimetype_id=$NAME_MIME
      LEFT JOIN data p ON p.raw_contact_id=rc._id AND p.mimetype_id=$PHONE_MIME
      WHERE rc.sourceid LIKE 'fdroid-%';"
