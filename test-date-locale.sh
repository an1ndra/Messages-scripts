#!/usr/bin/env bash
# Regression for locale-aware date formatting.
#
# The app formatted dates with literal patterns ("MMM d", "EEE, MMM d",
# "EEEE, MMM d, yyyy"). Field order is CLDR data, not formatting trivia: those
# patterns rendered "Mar 3" in French where French reads "3 mars". The list
# timestamp and the chat date divider are the two places a user sees it.
#
# Unit tests (DatePatternsTest) cover the skeleton/plumbing logic off-device.
# This script covers what only a device can answer: whether the platform's real
# CLDR data actually reaches the screen, in a language other than English.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

ORIG_LOCALE=""
CONV_ID=""
ORIG_TS=""

db() { adb_ shell "run-as $PKG sqlite3 databases/messages.db \"$1\"" | tr -d '\r'; }

restore() {
    [ -n "$ORIG_LOCALE" ] && adb_ shell "cmd locale set-app-locales $PKG --locales $ORIG_LOCALE" >/dev/null 2>&1
    if [ -n "$CONV_ID" ] && [ -n "$ORIG_TS" ]; then
        db "update conversations set timestamp=$ORIG_TS where id=$CONV_ID;" >/dev/null 2>&1
    fi
    adb_ shell "cmd locale set-app-locales $PKG --user 0 --locales ''" >/dev/null 2>&1
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
}
trap restore EXIT

info "Saving state"
ORIG_LOCALE=$(adb_ shell "cmd locale get-app-locales $PKG" 2>/dev/null | tr -d '\r' | sed -n 's/.*\[\(.*\)\].*/\1/p')
[ -z "$ORIG_LOCALE" ] && ORIG_LOCALE="en"
info "Original per-app locale: ${ORIG_LOCALE:-<system>}"

# Backdate the newest conversation so the list row falls through to the date
# branch instead of "Now"/time-only. Its real timestamp is restored on exit.
CONV_ID=$(db "select id from conversations where deleted_at=0 order by timestamp desc limit 1;" | head -1)
if [ -z "$CONV_ID" ]; then
    bad "no conversation available to date-label"
    echo; echo "=== Results: $PASS passed, $FAIL failed ==="
    exit 1
fi
ORIG_TS=$(db "select timestamp from conversations where id=$CONV_ID;")
BACKDATED=$(( $(date +%s000) - 8 * 86400000 ))
db "update conversations set timestamp=$BACKDATED where id=$CONV_ID;" >/dev/null 2>&1
ok "conversation $CONV_ID backdated 8 days (ts $ORIG_TS -> $BACKDATED)"

list_label() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    adb_ shell am start -n "$ACT" >/dev/null 2>&1
    sleep 6
    dump_ui >/dev/null 2>&1
    # Conversation rows expose their whole summary through content-desc (the row
    # merges sender, snippet and timestamp into one a11y node), so text= alone
    # only ever yields the screen title.
    grep -oE '(text|content-desc)="[^"]+"' "$TMP/ui.xml" 2>/dev/null \
        | sed -E 's/^(text|content-desc)="//; s/"$//' | grep -vE '^[[:space:]]*$'
}

# English is the control: it must show a month abbreviation, which proves the
# row is genuinely on the date branch before any locale is switched.
info "English renders an abbreviated month"
adb_ shell "cmd locale set-app-locales $PKG --locales en" >/dev/null 2>&1
EN_LABELS=$(list_label)
if echo "$EN_LABELS" | grep -qE '\b(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\b'; then
    ok "English list shows an abbreviated month"
else
    bad "English list showed no month abbreviation; the date branch was not reached"
    echo "$EN_LABELS" | head -20
fi

info "French renders its own field order"
adb_ shell "cmd locale set-app-locales $PKG --locales fr" >/dev/null 2>&1
FR_LABELS=$(list_label)

# French writes the day first ("26 sept."). The regression rendered "sept. 26",
# so matching a month name alone proves nothing -- the order is the assertion.
if echo "$FR_LABELS" | grep -qE '[0-9]{1,2} (janv|f[eé]vr|mars|avr|mai|juin|juil|ao[uû]t|sept|oct|nov|d[eé]c)'; then
    ok "French list puts the day before the month"
else
    bad "French list did not put the day before the month"
    echo "$FR_LABELS" | grep '\.\.' | head -5
fi

if echo "$FR_LABELS" | grep -qE '(janv|f[eé]vr|mars|avr|mai|juin|juil|ao[uû]t|sept|oct|nov|d[eé]c)\.? [0-9]{1,2}\b'; then
    bad "French still renders month-first (English field order)"
else
    ok "French does not reuse the English field order"
fi

info "German renders its own field order"
adb_ shell "cmd locale set-app-locales $PKG --locales de" >/dev/null 2>&1
DE_LABELS=$(list_label)

# German is day-first with a period: "26. Sept." The regression gave "Sept. 26".
# No trailing \b: these tokens end in '.', and a word boundary after a
# non-word character never matches at end of line.
# 'M.rz' rather than 'M[aä]rz' because grep bracket expressions are unreliable
# on the non-ASCII character in this locale.
if echo "$DE_LABELS" | grep -qE '[0-9]{1,2}\. (Jan|Feb|M.rz|Apr|Mai|Jun|Jul|Aug|Sept|Okt|Nov|Dez)'; then
    ok "German list puts the day before the month"
else
    bad "German list did not put the day before the month"
    echo "$DE_LABELS" | grep '\.\.' | head -5
fi

if echo "$DE_LABELS" | grep -qE '(Jan|Feb|M.rz|Apr|Mai|Jun|Jul|Aug|Sept|Okt|Nov|Dez)\.? [0-9]{1,2}\b'; then
    bad "German still renders month-first (English field order)"
else
    ok "German does not reuse the English field order"
fi

info "Japanese renders its own order and characters"
adb_ shell "cmd locale set-app-locales $PKG --locales ja" >/dev/null 2>&1
JA_LABELS=$(list_label)
if echo "$JA_LABELS" | grep -qE '[0-9]+月[0-9]+日'; then
    ok "Japanese list shows a M月D日 date"
else
    bad "Japanese list showed no M月D日 date"
    echo "$JA_LABELS" | grep '\.\.' | head -5
fi

info "Restoring"
restore
trap - EXIT
ORIG_LOCALE=""; CONV_ID=""; ORIG_TS=""
if db "select timestamp from conversations where id=(select id from conversations where deleted_at=0 order by timestamp desc limit 1);" >/dev/null 2>&1; then
    ok "app reachable and database restored"
else
    bad "database not reachable after restore"
fi

echo; echo "=== Results: $PASS passed, $FAIL failed ==="
exit $((FAIL > 0))