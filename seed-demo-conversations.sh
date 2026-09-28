#!/usr/bin/env bash
# Seeds the demo conversations the store screenshots are taken from.
#
# Not a regression test: this is data, like insert-demo-contacts.sh. The numbers
# are fixed so a screenshot refresh is reproducible - if they change, the shots
# stop matching what is in the listing.
#
# Writes straight to the database, so the app must not be mid-sync. Note that
# wiping conversations is undone on the next launch: syncFromSystem() re-imports
# anything still sitting in the system SMS provider, so clear that too if you
# want a clean inbox.
source "$(dirname "$0")/env.sh"
source "$(dirname "$0")/demo-data.sh"

dbq() { printf '%s' "$1" | adb_ shell "run-as $PKG sqlite3 databases/messages.db" 2>/dev/null | tr -d '\r'; }

# The stock AVD images ship a few hundred sample messages, and syncFromSystem()
# re-imports whatever is still in the telephony provider on the next launch, so
# wiping only the app database is not enough to get a clean inbox. The delete
# has to run as root: the shell uid cannot write to content://sms.
wipe_system_sms() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    adb_ shell "su 0 content delete --uri content://sms --where '1=1'" >/dev/null 2>&1
    adb_ shell "su 0 content delete --uri content://mms --where '1=1'" >/dev/null 2>&1
    adb_ shell "su 0 content delete --uri content://mms/part --where '1=1'" >/dev/null 2>&1
    adb_ shell "su 0 content delete --uri content://mms-sms/segments --where '1=1'" >/dev/null 2>&1
    info "System SMS: $(adb_ shell 'su 0 content query --uri content://sms --projection _id' 2>/dev/null | grep -c Row) rows left"
}

NOW=$(($(date +%s) * 1000))
MIN=$((60 * 1000))
HOUR=$((60 * MIN))
DAY=$((24 * HOUR))

# The fixed demo numbers. These must match DEMO_CONTACTS in demo-data.sh: the
# app looks a contact photo up by the conversation address, so a conversation
# whose number is not in the phone book renders a placeholder avatar.
DAD="+1555771010"
WORK="+1555771020"
ALEX="+1555771030"
BANK="+1555771040"
MOM="+1555771050"
PRIZE="+1555772010"
MYBANK="+1555772020"
REWARDS="+1555772030"
AMAZON="+1555773010"
CLINIC="+1555773020"
SARAH="+1555774010"
WEEKEND="+1555774020"
PRIYA="+1555775010"
CARLOS="+1555775020"
NINA="+1555775030"
EMMA="+1555775040"
JAKE="+1555775050"

CONVERSATION_NUMBERS=("$DAD" "$WORK" "$ALEX" "$BANK" "$MOM" "$PRIZE" "$MYBANK" "$REWARDS" "$AMAZON" "$CLINIC" "$SARAH" "$WEEKEND" "$PRIYA" "$CARLOS" "$NINA" "$EMMA" "$JAKE")

# Every conversation must have a phone-book entry, or its avatar falls back to
# a placeholder. The roster may hold extra contacts that have no conversation
# yet: they are what makes the contact picker in a screenshot look populated.
for n in "${CONVERSATION_NUMBERS[@]}"; do
    if ! printf '%s\n' "${DEMO_CONTACTS[@]}" | cut -d'|' -f1 | grep -qxF "$n"; then
        echo "ERROR: conversation number $n has no contact in demo-data.sh" >&2
        exit 1
    fi
done

if [ "${1:-}" = "--wipe" ]; then
    info "Wiping every conversation and message (destructive, for QA use)"
    dbq "DELETE FROM messages;" >/dev/null
    dbq "DELETE FROM conversations;" >/dev/null
    dbq "DELETE FROM participants;" >/dev/null
    dbq "DELETE FROM blocked_numbers;" >/dev/null
    wipe_system_sms
fi

info "Clearing existing demo data"
for n in "${CONVERSATION_NUMBERS[@]}"; do
    dbq "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$n');" >/dev/null
    dbq "DELETE FROM conversations WHERE address='$n';" >/dev/null
    dbq "DELETE FROM participants WHERE normalized_destination='$n';" >/dev/null
    dbq "DELETE FROM blocked_numbers WHERE number='$n';" >/dev/null
done

# address, display name, seconds-ago, blocked, blocked-ago
seed() {
    dbq "INSERT OR IGNORE INTO participants(normalized_destination,send_destination,display_destination,comparable_destination,country_code,sub_id) VALUES('$1','$1','$2','$1','',-1);" >/dev/null
    dbq "INSERT INTO conversations(address,name,snippet,timestamp,unread_count,last_is_me,archived,blocked,blocked_at,pinned,draft,draft_date,deleted_at,deleted_reason) VALUES('$1','$2','',$((NOW - $3)),0,0,0,$4,$5,0,'',0,0,'manual');" >/dev/null
    dbq "SELECT id FROM conversations WHERE address='$1';" | tr -d '\r\n'
}
# conversation id, body, seconds-ago, is_me, status, deleted_at, blocked_reason
msg() { dbq "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,deleted_at,blocked_reason) VALUES($1,'$2',$3,$4,'$5',$6,'$7');" >/dev/null; }

info "Seeding conversations"
# Dad carries the most traffic, because the "02-chat" shot is taken from it and
# a thread with three bubbles and a screenful of empty space looks unfinished.
D=$(seed "$DAD" "Dad" $((30 * MIN)) 0 0)
msg "$D" "Are you still seeing Dad at the weekend?" $((NOW - 5 * HOUR)) 1 sent 0 ''
msg "$D" "Yes! Leaving after lunch, back by six." $((NOW - 5 * HOUR + MIN)) 0 received 0 ''
msg "$D" "Perfect. I will grab milk on the way." $((NOW - 4 * HOUR)) 1 sent 0 ''
msg "$D" "Good plan. See you soon." $((NOW - 4 * HOUR + MIN)) 0 received 0 ''
msg "$D" "Running late, traffic on the ring road." $((NOW - 2 * HOUR)) 0 received 0 ''
msg "$D" "No rush. I put the kettle on." $((NOW - 90 * MIN)) 1 sent 0 ''
msg "$D" "On my way, ten minutes out." $((NOW - 45 * MIN)) 0 received 0 ''
msg "$D" "Did you remember the parking pass?" $((NOW - 30 * MIN)) 1 sent 0 ''
msg "$D" "It is on the kitchen table." $((NOW - 12 * MIN)) 0 received 0 ''

W=$(seed "$WORK" "Work Group" $((5 * HOUR)) 0 0)
msg "$W" "Standup moved to 10:30 today." $((NOW - 6 * HOUR)) 0 received 0 ''
msg "$W" "Works for me." $((NOW - 6 * HOUR + 2 * MIN)) 1 sent 0 ''
msg "$W" "I will bring the sprint notes." $((NOW - 5 * HOUR)) 1 sent 0 ''
msg "$W" "Thanks Alex." $((NOW - 5 * HOUR + MIN)) 0 received 0 ''
msg "$W" "Deploy is green, rolling out now." $((NOW - 5 * HOUR + 2 * MIN)) 0 received 0 ''

A=$(seed "$ALEX" "Alex" $((1 * DAY)) 0 0)
msg "$A" "Sent over the roof quote." $((NOW - 1 * DAY)) 0 received 0 ''
msg "$A" "Got it, thanks. Friday works." $((NOW - 1 * DAY + 3 * MIN)) 1 sent 0 ''
msg "$A" "See you then." $((NOW - 1 * DAY + 5 * MIN)) 0 received 0 ''

B=$(seed "$BANK" "Bank" $((2 * DAY)) 0 0)
msg "$B" "Your one-time code is 482913. Do not share it with anyone." $((NOW - 2 * DAY)) 0 received 0 ''

M=$(seed "$MOM" "Mom" $((3 * DAY)) 0 0)
msg "$M" "Call me when you land." $((NOW - 3 * DAY)) 0 received 0 ''
msg "$M" "Will do." $((NOW - 3 * DAY + MIN)) 1 sent 0 ''

# The rest of the phone book, so the conversation list fills the screen instead
# of trailing off into empty space, and every one of them is a contact with a
# monogram photo.
E=$(seed "$EMMA" "Emma" $((4 * DAY)) 0 0)
msg "$E" "Are we still on for Saturday?" $((NOW - 4 * DAY)) 0 received 0 ''
msg "$E" "Yes, booked the table for seven." $((NOW - 4 * DAY + 2 * MIN)) 1 sent 0 ''

J=$(seed "$JAKE" "Jake" $((5 * DAY)) 0 0)
msg "$J" "Did the garage call you back?" $((NOW - 5 * DAY)) 1 sent 0 ''
msg "$J" "Not yet, I will chase them tomorrow." $((NOW - 5 * DAY + 40 * MIN)) 0 received 0 ''

P=$(seed "$PRIYA" "Priya Raman" $((6 * DAY)) 0 0)
msg "$P" "Photos from the weekend are on the shared album." $((NOW - 6 * DAY)) 0 received 0 ''
msg "$P" "Found them, thank you!" $((NOW - 6 * DAY + 4 * MIN)) 1 sent 0 ''

C=$(seed "$CARLOS" "Carlos Diaz" $((7 * DAY)) 0 0)
msg "$C" "Flight lands at 6:40, do not pick me up." $((NOW - 7 * DAY)) 0 received 0 ''
msg "$C" "Understood. Welcome back!" $((NOW - 7 * DAY + 6 * MIN)) 1 sent 0 ''

N=$(seed "$NINA" "Nina Okafor" $((9 * DAY)) 0 0)
msg "$N" "Sending over the signed copy now." $((NOW - 9 * DAY)) 0 received 0 ''
msg "$N" "Received, much appreciated." $((NOW - 9 * DAY + 3 * MIN)) 1 sent 0 ''

info "Blocked senders (Spam & Blocked, Conversations)"
S1=$(seed "$PRIZE" "Prize Team" $((2 * HOUR)) 1 $((NOW - 2 * HOUR)))
msg "$S1" "Congratulations! You have won a gift card. Claim yours now." $((NOW - 2 * HOUR)) 0 received 0 ''
dbq "INSERT OR REPLACE INTO blocked_numbers(number,timestamp) VALUES('$PRIZE',$NOW);" >/dev/null
S2=$(seed "$MYBANK" "MY-BANK Alerts" $((1 * DAY)) 1 $((NOW - 30 * DAY)))
msg "$S2" "URGENT: your account will be closed. Call to keep it open." $((NOW - 1 * DAY)) 0 received 0 ''
dbq "INSERT OR REPLACE INTO blocked_numbers(number,timestamp) VALUES('$MYBANK',$NOW);" >/dev/null
S3=$(seed "$REWARDS" "Rewards Dept" $((4 * DAY)) 1 $((NOW - 4 * DAY)))
msg "$S3" "You have been selected for a voucher. Verify your details." $((NOW - 4 * DAY)) 0 received 0 ''
dbq "INSERT OR REPLACE INTO blocked_numbers(number,timestamp) VALUES('$REWARDS',$NOW);" >/dev/null

info "Keyword catches (Spam & Blocked, Messages)"
K1=$(seed "$AMAZON" "Amazon Delivery" $((5 * HOUR)) 0 0)
# An ordinary message first: a thread whose only message was caught by the
# keyword filter has no visible text, so its list row shows a blank preview.
msg "$K1" "Your order has shipped." $((NOW - 6 * HOUR)) 0 received 0 ''
msg "$K1" "Your parcel is on hold. Pay the outstanding customs fee to release it." $((NOW - 5 * HOUR)) 0 received $((NOW - 5 * HOUR)) blocked_keyword
msg "$K1" "Final notice: storage fees increase daily until payment is made." $((NOW - 4 * HOUR)) 0 received $((NOW - 4 * HOUR)) blocked_keyword
K2=$(seed "$CLINIC" "Dr. Patel Clinic" $((2 * DAY)) 0 0)
# An ordinary message first: a thread whose only message was caught by the
# keyword filter has no visible text, so its list row shows a blank preview.
msg "$K2" "Appointment confirmed for Tuesday at 4pm." $((NOW - 3 * DAY)) 0 received 0 ''
msg "$K2" "Reminder: claim your FREE voucher before it expires." $((NOW - 2 * DAY)) 0 received $((NOW - 2 * DAY)) blocked_keyword

info "Deleted chats (Trash)"
T1=$(seed "$SARAH" "Sarah Chen" $((40 * MIN)) 0 0)
dbq "UPDATE conversations SET deleted_at=$((NOW - 1 * HOUR)) WHERE address='$SARAH';" >/dev/null
msg "$T1" "Are we still on for dinner?" $((NOW - 2 * HOUR)) 0 received 0 ''
msg "$T1" "See you at 7" $((NOW - 40 * MIN)) 0 received 0 ''
T2=$(seed "$WEEKEND" "Weekend Plans" $((8 * DAY)) 0 0)
dbq "UPDATE conversations SET deleted_at=$((NOW - 8 * DAY)) WHERE address='$WEEKEND';" >/dev/null
msg "$T2" "Bring the tent, I will bring food" $((NOW - 8 * DAY)) 0 received 0 ''

info "Filling in snippets"
# Inserting messages directly bypasses refreshConversationSnippetFor(), which is
# what normally keeps conversations.snippet and last_is_me in step with the newest
# message. Without this every list row renders with a blank preview under the name.
for n in "${CONVERSATION_NUMBERS[@]}"; do
    dbq "UPDATE conversations SET snippet=(SELECT body FROM messages WHERE conversation_id=conversations.id AND deleted_at=0 ORDER BY timestamp DESC LIMIT 1), last_is_me=(SELECT is_me FROM messages WHERE conversation_id=conversations.id AND deleted_at=0 ORDER BY timestamp DESC LIMIT 1) WHERE address='$n';" >/dev/null
done

adb_ shell am force-stop "$PKG" >/dev/null 2>&1
adb_ shell am start -n "$ACT" >/dev/null 2>&1
sleep 5

info "Seeded"
echo "  conversations: $(dbq "SELECT COUNT(*) FROM conversations;")"
echo "  messages:      $(dbq "SELECT COUNT(*) FROM messages;")"
echo "  blocked msgs:  $(dbq "SELECT COUNT(*) FROM messages WHERE blocked_reason!='' AND deleted_at>0;")"
echo "  trashed convs: $(dbq "SELECT COUNT(*) FROM conversations WHERE deleted_at>0;")"
