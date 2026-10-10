#!/usr/bin/env bash
# Search must only match what the user can see. Two leaks, both from the
# all-history message search:
#   - a locked message's body is masked everywhere in the app, yet searching
#     its text surfaced the thread, proving the secret from the home list;
#   - with "Hide links from messages" on, a URL is removed from every list and
#     chat, yet searching the URL text surfaced the thread.
# Seeds its own threads, drives the home search, and restores the defaults.
source "$(dirname "$0")/env.sh"

KW_LOCK="vaultlock$(date +%s)"
KW_URL="secretpage$(date +%s)"
KW_VIS="visword$(date +%s)"
NAME_LOCK="PrivLockedSearch"
NAME_URL="PrivHiddenLink"
NUM_LOCK="+15559990601"
NUM_URL="+15559990602"
TS=$(( $(date +%s) * 1000 ))
PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

sql() { echo "$1" | adb_ shell "run-as $PKG sqlite3 databases/messages.db"; }

pref_get() {
    adb_ shell "run-as $PKG cat shared_prefs/messages_settings.xml" 2>/dev/null \
        | grep -oE "name=\"hide_links\" value=\"[^\"]*\"" | grep -oE 'value="[^"]*"' | cut -d'"' -f2
}

scroll_to() {
    local i
    for i in 1 2 3 4 5 6 7 8; do
        dump_ui >/dev/null 2>&1 || true
        grep -qF "$1" "$TMP/ui.xml" && return 0
        adb_ shell input swipe 500 1600 500 700 300; sleep 0.8
    done
    return 1
}

open_advanced() {
    # Force-stop first: the settings deep link only opens from a cold start,
    # not from the running instance's current screen.
    adb_ shell am force-stop "$PKG"; sleep 1
    adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null 2>&1
    sleep 3
    scroll_to "Advanced settings" || return 1
    tap_text "Advanced settings" || tap_contains "Advanced settings"
    sleep 2
}

cleanup() {
    sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM_LOCK' OR address='$NUM_URL');"
    sql "DELETE FROM conversations WHERE address='$NUM_LOCK' OR address='$NUM_URL';"
}
restore_settings() {
    if [ "$(pref_get)" = "true" ]; then
        open_advanced && scroll_to "Hide links from messages" && \
            tap_switch_near "Hide links from messages" >/dev/null 2>&1
        sleep 1
    fi
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
}
trap 'restore_settings; cleanup' EXIT

adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1

info "Seed a locked body and a hidden-link body"
cleanup
sql "INSERT INTO conversations(address,name,snippet,timestamp,last_is_me) VALUES('$NUM_LOCK','$NAME_LOCK','tail',$TS,0);" >/dev/null
sql "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,media_type,locked) SELECT id,'the $KW_LOCK code stays here',$TS,0,'received','text',1 FROM conversations WHERE address='$NUM_LOCK';" >/dev/null
sql "INSERT INTO conversations(address,name,snippet,timestamp,last_is_me) VALUES('$NUM_URL','$NAME_URL','tail',$TS,0);" >/dev/null
sql "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,media_type) SELECT id,'docs at https://$KW_URL.example/guide $KW_VIS today',$TS,0,'received','text' FROM conversations WHERE address='$NUM_URL';" >/dev/null

# A cold relaunch puts the app on the home list with an empty search field, so
# every search starts from the same state regardless of what the last one left.
search_for() {
    adb_ shell am force-stop "$PKG"; sleep 1
    adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 5
    if ! tap_text "Search" >/dev/null 2>&1; then bad "no Search button"; exit 1; fi
    sleep 1
    type_text "$1" >/dev/null 2>&1
    sleep 3
}

search_for "$KW_LOCK"
info "A locked message's body must not surface a thread in search"
if ui_has "$NAME_LOCK"; then
    bad "locked body leaked: thread listed by its hidden text"
else
    ok "locked body did not surface its thread"
fi

info "Turn on 'Hide links from messages'"
HIDDEN_ON=0
if open_advanced && scroll_to "Hide links from messages"; then
    tap_switch_near "Hide links from messages" >/dev/null 2>&1
    sleep 1.5
    if [ "$(pref_get)" = "true" ]; then
        ok "Hide links is on (verified in the app's own settings)"
        HIDDEN_ON=1
    else
        bad "Hide links toggle did not stick"
    fi
else
    bad "could not reach the Hide links row"
fi

if [ "$HIDDEN_ON" = "1" ]; then
    search_for "$KW_URL"
    info "While links are hidden, the URL text must not surface a thread"
    if ui_has "$NAME_URL"; then
        bad "hidden link leaked: thread listed by its redacted URL"
    else
        ok "hidden link did not surface its thread"
    fi

    search_for "$KW_VIS"
    info "The same thread is still found by its visible text"
    if ui_has "$NAME_URL"; then
        ok "thread found by a visible word while links are hidden"
    else
        bad "visible word no longer finds the thread (over-filtered)"
    fi
fi

echo ""
info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
