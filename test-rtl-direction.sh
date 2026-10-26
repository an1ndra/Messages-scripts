#!/usr/bin/env bash
# Regression for #362 — per-message text direction.
#
# Two rules, both pure functions in BidiText (unit-tested in
# BidiTextDirectionTest), here checked against the real UI:
#
#   bubble     first and last strong characters decide; digits, punctuation and
#              links never vote; when the two ends disagree the last one wins.
#   lines      a line that is only numbers or links is pinned LTR inside an RTL
#              message, so it is neither reordered nor pushed to the wrong edge.
#   composer   first strong character alone decides, so the field flips as soon
#              as a Persian/Arabic word is typed and does not flip back when an
#              English word follows.
#
# A layout direction cannot be seen in a `uiautomator` dump (it carries the
# string and its bounds, not the text direction), and a screenshot would show
# the same pixels for a single-line bubble either way — so the app reports the
# direction it actually painted with, the way BubbleShape reports corner radii:
#
#   BubbleDirection:   id=<id> dir=Rtl|Ltr     (per composed bubble)
#   BubbleBidi:        dir=Rtl|Ltr ltrLines=<n> (the transformed bubble body)
#   ComposerDirection: dir=Rtl|Ltr             (per composer direction change)
#
# The chat is opened through the real `sms:`/SENDTO share path rather than a
# seeded draft: `adb shell input text` is ASCII-only, and the `?body=` query is
# the one way to get Persian into the composer from a script.
#
# Run: scripts/test-rtl-direction.sh
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

MARK="rtl$(date +%s)$$"
NUM="+1555985${MARK: -4}"

adb_ root >/dev/null 2>&1; adb_ wait-for-device; sleep 1
sql() { adb_ shell "sqlite3 /data/data/$PKG/databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r'; }
urlenc() { python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$1"; }

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM');" >/dev/null 2>&1
    sql "DELETE FROM conversations WHERE address='$NUM';" >/dev/null 2>&1
}
trap cleanup EXIT

for p in READ_SMS RECEIVE_SMS READ_CONTACTS POST_NOTIFICATIONS; do
    adb_ shell pm grant "$PKG" "android.permission.$p" >/dev/null 2>&1
done
# Without the SMS role the first launch stops on a "Set as default SMS app?"
# dialog and the chat never opens; the phone-call permissions are the other
# first-run dialog.
adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1 || true
for p in READ_PHONE_STATE CALL_PHONE READ_PHONE_NUMBERS; do
    adb_ shell pm grant "$PKG" "android.permission.$p" >/dev/null 2>&1
done

TS=$(date +%s000)
sql "INSERT INTO conversations(address,name,snippet,timestamp,unread_count) VALUES('$NUM','$MARK','$MARK',$TS,0);" >/dev/null 2>&1
CID=$(sql "SELECT id FROM conversations WHERE address='$NUM';")
[ -z "$CID" ] && { bad "could not seed a conversation"; exit 1; }

# The AVD boots with the screen asleep, and a sleeping device renders no
# bubbles — every case would silently read an empty log.
wake() {
    adb_ shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1
    adb_ shell wm dismiss-keyguard >/dev/null 2>&1
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    sleep 1
    adb_ shell logcat -c >/dev/null 2>&1
    # API 30 empties the buffer lazily: without a settle the previous case's
    # direction lines are still readable and get counted as this case's.
    sleep 1
}

# A cold launch on a freshly booted AVD can take well over the 6s a warm one
# needs, so wait for the marker instead of guessing: an empty log is
# indistinguishable from "the app never painted".
await_marker() {
    local tag="$1" want="$2" i
    for i in $(seq 1 10); do
        adb_ logcat -d -s "$tag":D 2>/dev/null | grep -q "dir=$want" && { sleep 1; return 0; }
        sleep 1.5
    done
    return 1
}

# SQLite string literal for a possibly multi-line body: what the issue's own
# examples are, and a literal newline on the adb command line does not survive
# the trip. char(10) keeps each line a line.
sqltext() {
    python3 - "$1" <<'PY'
import sys
print("||char(10)||".join("'%s'" % line.replace("'", "''")
      for line in sys.argv[1].split("\n")), end="")
PY
}

# The seeded body is the only bubble on screen, so the direction lines in a
# freshly cleared log are unambiguous.
bubble_case() {
    local desc="$1" body="$2" want="$3"
    wake
    sql "DELETE FROM messages WHERE conversation_id=$CID;" >/dev/null 2>&1
    sql "INSERT INTO messages(conversation_id,body,timestamp,status) VALUES($CID,$(sqltext "$body"),$TS,'received');" >/dev/null 2>&1
    adb_ shell am start -n "$ACT" --es open_conversation_address "$NUM" >/dev/null 2>&1
    await_marker BubbleDirection "$want"
    local seen
    seen=$(adb_ logcat -d -s BubbleDirection:D 2>/dev/null | grep -o 'dir=.*' | tr -d '\r' | sort -u | tr '\n' ' ')
    if [ "$seen" = "dir=$want " ]; then
        ok "$desc -> $want"
    else
        bad "$desc -> expected dir=$want, got '${seen:-nothing}'"
    fi
}

# A line pinned LTR is invisible in a dump and in a screenshot of a single
# line, so the count comes from the transform that actually painted.
bidi_case() {
    local desc="$1" body="$2" want="$3" want_lines="$4"
    wake
    sql "DELETE FROM messages WHERE conversation_id=$CID;" >/dev/null 2>&1
    sql "INSERT INTO messages(conversation_id,body,timestamp,status) VALUES($CID,$(sqltext "$body"),$TS,'received');" >/dev/null 2>&1
    adb_ shell am start -n "$ACT" --es open_conversation_address "$NUM" >/dev/null 2>&1
    local i
    for i in $(seq 1 10); do
        adb_ logcat -d -s BubbleBidi:D 2>/dev/null | grep -q "ltrLines=$want_lines" && break
        sleep 1.5
    done
    local seen
    seen=$(adb_ logcat -d -s BubbleBidi:D 2>/dev/null | grep -o 'dir=.*' | tr -d '\r' | tail -1)
    if [ "$seen" = "dir=$want ltrLines=$want_lines" ]; then
        ok "$desc -> $want, $want_lines LTR line(s)"
    else
        bad "$desc -> expected dir=$want ltrLines=$want_lines, got '${seen:-nothing}'"
    fi
}

# The composer starts on LTR (empty draft) and flips when the shared body
# lands, so only the last line is the settled direction. An English draft logs
# no second line, so the wait has to accept the first marker either way.
composer_case() {
    local desc="$1" draft="$2" want="$3"
    wake
    sql "DELETE FROM messages WHERE conversation_id=$CID;" >/dev/null 2>&1
    adb_ shell am start -a android.intent.action.SENDTO \
        -d "sms:$NUM?body=$(urlenc "$draft")" >/dev/null 2>&1
    await_marker ComposerDirection "$want"
    local seen
    seen=$(adb_ logcat -d -s ComposerDirection:D 2>/dev/null | grep -o 'dir=.*' | tr -d '\r' | tail -1)
    if [ "$seen" = "dir=$want" ]; then
        ok "$desc -> $want"
    else
        bad "$desc -> expected dir=$want, got '${seen:-nothing}'"
    fi
}

info "Message text: first and last strong characters decide"
bubble_case "Persian message"                     "سلام خوبی"                          Rtl
bubble_case "English message"                     "see you at 8"                       Ltr
bubble_case "Persian ending a message opened in English" "Order 48291 تکمیل شد"         Rtl
bubble_case "English ending a message opened in Persian" "سلام OK"                      Ltr

info "Trailing punctuation and digits do not vote"
bubble_case "Persian with a trailing bang"        "سلام!"                              Rtl
bubble_case "English with a trailing bang"        "hello!"                             Ltr
bubble_case "Persian ending on a phone number"    "شماره من 09123456789"               Rtl

info "Links do not vote for the message"
bubble_case "Persian broadcast ending on a bare link" "ارسال رایگان شد
l.tpshp.co/3lDXoA"                                                                  Rtl
bubble_case "Persian line then an https link"        "تخفیف ویژه
https://zbl.io/RogeAbne"                                                            Rtl
bubble_case "a message that is only a link"          "https://zbl.io/RogeAbne"        Ltr

info "Emoji never vote"
bubble_case "Persian message ending on an emoji"     "ارسال رایگان شد 📣"             Rtl
bubble_case "Persian message opening on an emoji"    "📣 ارسال رایگان شد"             Rtl
bubble_case "English message ending on an emoji"     "hello 📣"                       Ltr

info "A line of only numbers or links is pinned LTR"
bidi_case "OTP code line in a Persian message"       "کد ورود به صرافی تبدیل:
85904
@tabdeal.org #85904
لغو11"                                                                              Rtl 2
bidi_case "Persian broadcast with a bare link line"  "ارسال رایگان شد
l.tpshp.co/3lDXoA
لغو 11r.eu/t"                                                                       Rtl 1
bidi_case "an emoji-only line in a Persian message"  "کد تخفیف را ثبت کن
🎁🎁"                                                                                Rtl 1
bidi_case "no weak-only line, nothing pinned"        "بانک سامان
برداشت مبلغ
مانده 78,556,010"                                                                   Rtl 0

info "Composer: the first strong character typed decides"
composer_case "draft opening in Persian"           "سلام hello"                         Rtl
composer_case "draft opening in English"           "hello سلام"                         Ltr
composer_case "digits are weak, the Persian word still decides" "123 سلام"             Rtl

echo ""
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
