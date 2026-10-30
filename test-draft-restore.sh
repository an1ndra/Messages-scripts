#!/usr/bin/env bash
# Regression: a saved draft comes back when the chat is opened again.
#
# Reported: "one Draft message I open in chat Text field I cant see them it
# disappere". The restore block in ChatScreen was a bare `{ … }` lambda literal
# that never ran, so the draft was silently dropped; the repo had recorded it as
# "found, not fixed (separate bug)" and the bidi script worked around it by
# seeding the composer through a share intent.
#
# Seeds the draft straight into the database (the path that used to fail), opens
# the chat and asserts the composer carries the text.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

NUM="+15559442222"
DRAFT="draftprobe$(date +%s)"

adb_ root >/dev/null 2>&1; sleep 1
sql() { adb_ shell "sqlite3 /data/data/$PKG/databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r'; }

cleanup() {
    sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM');" >/dev/null 2>&1
    sql "DELETE FROM conversations WHERE address='$NUM';" >/dev/null 2>&1
}
trap cleanup EXIT
cleanup

info "Seed a conversation that already has a draft"
sql "INSERT INTO conversations(address,name,snippet,timestamp,unread_count,draft,draft_date) VALUES('$NUM','draftprobe','last message',$(date +%s000),0,'$DRAFT',$(date +%s000));" >/dev/null 2>&1
CID=$(sql "SELECT id FROM conversations WHERE address='$NUM';")
[ -z "$CID" ] && { bad "could not seed a conversation"; exit 1; }
sql "INSERT INTO messages(conversation_id,body,timestamp,status,is_me) VALUES($CID,'last message',$(date +%s000),'sent',1);" >/dev/null 2>&1
STORED=$(sql "SELECT draft FROM conversations WHERE id=$CID;")
[ "$STORED" = "$DRAFT" ] && ok "draft stored in the database" || bad "draft did not store ($STORED)"

info "Opening the chat puts the draft back in the composer"
OPENED=0
for attempt in 1 2 3; do
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
    adb_ shell am start -n "$ACT" --es open_conversation_address "$NUM" >/dev/null 2>&1
    sleep 6
    dump_ui >/dev/null 2>&1 || continue
    if grep -qF -- "$DRAFT" "$TMP/ui.xml"; then OPENED=1; break; fi
    sleep 2
done
if [ "$OPENED" = "1" ]; then
    ok "the composer shows the saved draft"
else
    bad "the saved draft is missing from the composer"
fi

info "The draft survives leaving and re-opening the chat"
if [ "$OPENED" = "1" ]; then
    adb_ shell input keyevent 4 >/dev/null 2>&1; sleep 2
    adb_ shell am start -n "$ACT" --es open_conversation_address "$NUM" >/dev/null 2>&1
    sleep 6
    dump_ui >/dev/null 2>&1 || true
    grep -qF -- "$DRAFT" "$TMP/ui.xml" && ok "the draft is still there after a round trip" \
        || bad "the draft was lost on re-open"
    # And it must have been written back to the database, not just held in memory.
    RESTORED=$(sql "SELECT draft FROM conversations WHERE id=$CID;")
    [ "$RESTORED" = "$DRAFT" ] && ok "the database still holds the draft" \
        || bad "the database lost the draft ($RESTORED)"
else
    bad "cannot check the round trip: the draft never appeared"
    bad "cannot check the stored draft: the draft never appeared"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
exit $((FAIL > 0))
