#!/usr/bin/env bash
# Canonical demo roster for the F-Droid screenshots. Single source of truth:
# insert-demo-contacts.sh (phone book) and seed-demo-conversations.sh (inbox)
# both read it, so a conversation address always matches a phone-book contact.
#
# This alignment matters: the app resolves a contact photo with
# ContactsContract phone_lookup/<conversation address>, so a conversation whose
# address is not in the phone book always renders a placeholder avatar.
#
# Format: number|display name|given|family|photo
#   photo = photo   -> a person; a monogram avatar is generated for them
#   photo = none    -> a brand/spam sender; keeps the app's letter-tile avatar
#
# The numbers are fixed: test-*.sh scripts and the committed screenshots refer
# to them, so changing one invalidates both.

# shellcheck disable=SC2034
DEMO_CONTACTS=(
  "+1555771010|Dad|Dad||photo"
  "+1555771020|Work Group|Work|Group|photo"
  "+1555771030|Alex|Alex||photo"
  "+1555771040|Bank|Bank||none"
  "+1555771050|Mom|Mom||photo"
  "+1555772010|Prize Team|Prize Team||none"
  "+1555772020|MY-BANK Alerts|MY-BANK Alerts||none"
  "+1555772030|Rewards Dept|Rewards Dept||none"
  "+1555773010|Amazon Delivery|Amazon Delivery||none"
  "+1555773020|Dr. Patel Clinic|Dr. Patel Clinic||none"
  "+1555774010|Sarah Chen|Sarah|Chen|photo"
  "+1555774020|Weekend Plans|Weekend|Plans|photo"
  "+1555775010|Priya Raman|Priya|Raman|photo"
  "+1555775020|Carlos Diaz|Carlos|Diaz|photo"
  "+1555775030|Nina Okafor|Nina|Okafor|photo"
  "+1555775040|Emma|Emma||photo"
  "+1555775050|Jake|Jake||photo"
)

demo_field() { # $1 = "a|b|c", $2 = 1-based field index
  echo "${1}" | cut -d'|' -f"$2"
}
