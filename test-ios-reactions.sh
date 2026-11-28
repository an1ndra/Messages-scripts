#!/usr/bin/env bash
# Issue #533: iOS tapback notices quote their target with curly quotes and
# sometimes name the tapback in words. They must land on the quoted message as
# a reaction chip instead of showing up as a plain bubble.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

sql() { echo "$1" | adb_ shell "run-as $PKG sqlite3 databases/messages.db"; }

NUM="+15550007777"
STAMP=$(date +%s)
T1="ios emoji target $STAMP"
T2="ios question target $STAMP"
T3="ios quoted guard $STAMP"
T4="ios like target $STAMP"
TS=$(( STAMP * 1000 ))

cleanup() {
    sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$NUM');"
    sql "DELETE FROM conversations WHERE address='$NUM';"
}
trap cleanup EXIT

adb_su "cmd role add-role-holder android.app.role.SMS $PKG" >/dev/null 2>&1
for p in READ_SMS RECEIVE_SMS SEND_SMS POST_NOTIFICATIONS; do
    adb_ shell pm grant "$PKG" android.permission."$p" 2>/dev/null
done

INJECT_DIR="$(dirname "$0")/lib/inject-sms"
SDK_ROOT="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [ -z "$SDK_ROOT" ]; then
    for candidate in "$HOME/android" "$HOME/Android/sdk" "$HOME/Android/sdk-secondary"; do
        [ -f "$candidate/platforms/android-33/android.jar" ] && SDK_ROOT="$candidate" && break
    done
fi

build_injector() {
    local dex="$TMP/inject.dex" src="$INJECT_DIR/InjectSms.java"
    if [ -f "$dex" ] && [ "$dex" -nt "$src" ]; then return 0; fi
    local aj="$SDK_ROOT/platforms/android-33/android.jar"
    local d8
    d8=$(ls -d "$SDK_ROOT"/build-tools/*/d8 2>/dev/null | sort -V | tail -1)
    [ -f "$aj" ] && [ -x "$d8" ] || return 1
    local work="$TMP/inject-src"
    rm -rf "$work"; mkdir -p "$work"
    cp "$src" "$work/" || return 1
    ( cd "$work" \
        && javac -source 8 -target 8 -bootclasspath "$aj" -d . InjectSms.java >/dev/null 2>&1 \
        && "$d8" --lib "$aj" --output . InjectSms.class >/dev/null 2>&1 ) || return 1
    cp "$work/classes.dex" "$dex" || return 1
    adb_ push "$dex" /data/local/tmp/inject.dex >/dev/null || return 1
}

inject_sms() {
    build_injector || return 1
    local pdu
    pdu=$(python3 "$INJECT_DIR/pdu.py" "$NUM" "$1" --ucs2) || return 1
    adb_ shell "su -c 'CLASSPATH=/data/local/tmp/inject.dex app_process /system/bin InjectSms $pdu $PKG'" >/dev/null 2>&1
}

reactions_of() { sql "SELECT reactions FROM messages WHERE body='$1';" | tr -d '\r'; }
wait_reactions() { # body, expected
    local i got
    for i in $(seq 1 8); do
        got=$(reactions_of "$1")
        [ "$got" = "$2" ] && return 0
        sleep 1
    done
    echo "  last reactions for '$1': '$got'" >&2
    return 1
}
notice_stored() { sql "SELECT COUNT(*) FROM messages WHERE body='$1';" | tr -d '\r'; }

info "Seed four target messages"
cleanup
sql "INSERT INTO conversations(address,name,snippet,timestamp,last_is_me) VALUES('$NUM','IosReactions','$T1',$TS,0);"
for body in "$T1" "$T2" "$T3" "$T4"; do
    sql "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,media_type) SELECT id,'$body',$TS,0,'received','text' FROM conversations WHERE address='$NUM';"
done

adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 4

info "Reacted <emoji> to <curly-quoted snippet>"
inject_sms "Reacted 😂 to “$T1”" || { bad "could not inject the emoji notice"; exit 1; }
if wait_reactions "$T1" "😂:1"; then ok "😂 applied to the quoted message"; else bad "😂 was not applied"; fi
if [ "$(notice_stored "Reacted 😂 to “$T1”")" = "0" ]; then ok "notice did not become a bubble"; else bad "notice was stored as a bubble"; fi

info "Questioned <curly-quoted snippet>"
inject_sms "Questioned “$T2”" || { bad "could not inject the worded notice"; exit 1; }
if wait_reactions "$T2" "❓:1"; then ok "❓ applied to the quoted message"; else bad "❓ was not applied"; fi
if [ "$(notice_stored "Questioned “$T2”")" = "0" ]; then ok "notice did not become a bubble"; else bad "notice was stored as a bubble"; fi

info "Removed a question mark from <curly-quoted snippet>"
inject_sms "Removed a question mark from “$T2”" || { bad "could not inject the removal"; exit 1; }
if wait_reactions "$T2" ""; then ok "❓ removed from the quoted message"; else bad "❓ was not removed"; fi
if [ "$(notice_stored "Removed a question mark from “$T2”")" = "0" ]; then ok "removal did not become a bubble"; else bad "removal was stored as a bubble"; fi

info "Liked <curly-quoted snippet>, then Removed a like from it"
inject_sms "Liked “$T4”" || { bad "could not inject the like"; exit 1; }
if wait_reactions "$T4" "👍:1"; then ok "👍 applied to the quoted message"; else bad "👍 was not applied"; fi
inject_sms "Removed a like from “$T4”" || { bad "could not inject the like removal"; exit 1; }
if wait_reactions "$T4" ""; then ok "👍 removed from the quoted message"; else bad "👍 was not removed"; fi
if [ "$(notice_stored "Removed a like from “$T4”")" = "0" ]; then ok "like removal did not become a bubble"; else bad "like removal was stored as a bubble"; fi

info "Our own quote-free notice is still an ordinary message"
inject_sms "Reacted 👍 to $T3" || { bad "could not inject our own notice"; exit 1; }
sleep 4
if [ "$(notice_stored "Reacted 👍 to $T3")" = "1" ]; then ok "quote-free notice stored as a message"; else bad "quote-free notice was consumed"; fi
if [ -z "$(reactions_of "$T3")" ]; then ok "quote-free notice changed no reaction"; else bad "quote-free notice applied a reaction"; fi

echo ""
info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
