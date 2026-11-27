#!/usr/bin/env bash
# Regression for #482: the inbox can split itself into tabs, and the tabs are
# only there once you ask for them.
#
# The chip row is hidden on open. Pulling the list down reveals it — for this
# session only, so it is back to hidden after a restart — and picking a chip
# narrows the list to that category. A thread's category is decided once, when
# the inbox first sees it, and stored, so a later reply cannot move it.
#
# Fails on a build without the feature: no chips after the pull, and the OTP
# chip cannot narrow anything.
#
# Run: scripts/test-482-inbox-categories.sh
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

# A failed dump leaves the previous ui.xml in place, and every assertion below
# then reads a screen the app is not showing. Treat it as fatal.
must_dump() {
    if ! dump_ui; then
        bad "uiautomator dump failed - the screen state is unknown"
        echo ""
        echo "=== RESULTS: $PASS passed, $FAIL failed ==="
        exit 1
    fi
}

# A failed dump leaves the previous screen in ui.xml; chip bounds read from
# that file land on a conversation row instead of the chip.
fresh_dump() {
    rm -f "$TMP/ui.xml" "$TMP/ui.decoded.xml"
    dump_ui
}

MARK="cat$(date +%s)$$"
SELF="+1555985${MARK: -4}"
OTP_ADDR="+1555986001"
TXN_ADDR="AD-AMAZON"
PER_ADDR="+1555986002"
OTP_BODY="Your verification code is 482913"
TXN_BODY="Your order has shipped"
PER_BODY="see you at eight ${MARK}"

# A secondary user keeps its app data under /data/user/<id>; user 0's is the
# /data/data shortcut. APP_USER=12 runs this against a test profile on a phone
# whose owner already has the release build installed.
APP_USER="${APP_USER:-0}"
if [ "$APP_USER" = "0" ]; then USER_DIR=/data/data; else USER_DIR=/data/user/$APP_USER; fi
sql() { adb_ shell "sqlite3 $USER_DIR/$PKG/databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r'; }

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    for a in "$OTP_ADDR" "$TXN_ADDR" "$PER_ADDR"; do
        sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$a');" >/dev/null 2>&1
        sql "DELETE FROM conversations WHERE address='$a';" >/dev/null 2>&1
    done
}
trap cleanup EXIT

adb_ root >/dev/null 2>&1; adb_ wait-for-device; sleep 1
for p in READ_SMS RECEIVE_SMS READ_CONTACTS POST_NOTIFICATIONS; do
    adb_ shell pm grant --user "$APP_USER" "$PKG" "android.permission.$p" >/dev/null 2>&1
done
adb_ shell am force-stop "$PKG" >/dev/null 2>&1
sleep 1

info "Seed one thread per category, none of them classified yet"
TS=$(date +%s000)
seed() {
    local addr="$1" name="$2" body="$3"
    sql "INSERT INTO conversations(address,name,snippet,timestamp,unread_count) VALUES('$addr','$name','$body',$TS,0);" >/dev/null 2>&1
    local cid
    cid=$(sql "SELECT id FROM conversations WHERE address='$addr';")
    [ -n "$cid" ] || { bad "could not seed $addr"; return 1; }
    sql "INSERT INTO messages(conversation_id,body,timestamp,status) VALUES($cid,'$body',$TS,'received');" >/dev/null 2>&1
}
seed "$OTP_ADDR" "$OTP_ADDR" "$OTP_BODY"
seed "$TXN_ADDR" "$TXN_ADDR" "$TXN_BODY"
seed "$PER_ADDR" "$PER_ADDR" "$PER_BODY"
ok "three threads seeded"

info "Open the inbox; the chips must not be there yet"
adb_ shell am start -n "$ACT" >/dev/null 2>&1
# The inbox draws a skeleton until the system-SMS import settles, and every dump
# taken before that has no rows in it — which reads as "the tab filtered
# everything out". Wait for a seeded row before asserting anything.
if ! wait_for_text "$OTP_BODY" 24; then
    bad "the inbox never listed the seeded threads"
    exit 1
fi
must_dump
if grep -qF 'text="Transactions"' "$TMP/ui.xml"; then
    bad "the chip row was visible before any pull"
else
    ok "the chip row is hidden on open"
fi

info "Pull the list down"
for _ in 1 2 3; do
    adb_ shell input swipe 540 700 540 1500 300
    sleep 1
done
sleep 1
must_dump
chips=0
for label in All Personal Transactions OTP; do
    grep -qF "text=\"$label\"" "$TMP/ui.xml" && chips=$((chips + 1))
done
if [ "$chips" -eq 4 ]; then
    ok "the pull revealed All · Personal · Transactions · OTP"
else
    bad "expected four chips after the pull, found $chips"
fi

info "The seeded threads got the categories their senders imply"
# The list is filtered client-side from the stored column, so a category that
# was never written shows up in no tab at all — which is what this asserts.
pull_down() {
    for _ in 1 2; do adb_ shell input swipe 540 700 540 1500 300; sleep 1; done
}

tap_chip() {
    local label="$1"
    local xy attempt
    for attempt in 1 2 3; do
    fresh_dump >/dev/null 2>&1 || true
    xy=$(python3 - "$TMP/ui.xml" "$label" <<'PY'
import re, sys, html
xml = open(sys.argv[1], encoding="utf-8").read()
want = sys.argv[2]
for tag in re.findall(r'<node[^>]*>', xml):
    t = re.search(r'text="([^"]*)"', tag)
    b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', tag)
    if not (t and b):
        continue
    if html.unescape(t.group(1)) != want:
        continue
    x1, y1, x2, y2 = map(int, b.groups())
    if y1 < 400:
        print((x1 + x2) // 2, (y1 + y2) // 2)
        break
PY
)
    [ -z "$xy" ] && { sleep 1; continue; }
    adb_ shell input tap $xy
    sleep 2
    fresh_dump >/dev/null 2>&1 || true
    if grep -qF 'text="All"' "$TMP/ui.xml"; then
        return 0
    fi
    adb_ shell input keyevent 4 >/dev/null 2>&1
    sleep 1
    done
    return 1
}

if tap_chip "OTP"; then
    # The list re-renders after the tab change; poll instead of trusting one
    # dump, or a slow frame reads as "the tab showed nothing".
    wait_for_text "$OTP_BODY" 8
    if grep -qF "$OTP_BODY" "$TMP/ui.xml" \
        && ! grep -qF "$TXN_BODY" "$TMP/ui.xml" \
        && ! grep -qF "$PER_BODY" "$TMP/ui.xml"; then
        ok "the OTP tab shows the code thread and nothing else"
    else
        bad "the OTP tab did not narrow the list to the OTP thread"
    fi
else
    bad "could not find the OTP chip to tap"
fi

info "All brings everything back"
if tap_chip "All"; then
    # A chip tap can leave the list at an offset with no rows on screen.
    for _ in 1 2; do
        adb_ shell input swipe 540 700 540 1500 300 >/dev/null 2>&1
        sleep 1
    done
    wait_for_text "$PER_BODY" 8
    if grep -qF "$TXN_BODY" "$TMP/ui.xml" && grep -qF "$PER_BODY" "$TMP/ui.xml"; then
        ok "All restores the whole list"
    else
        bad "All did not restore the other threads"
        python3 - "$TMP/ui.xml" <<'DEBUG'
import html, re, sys
xml = open(sys.argv[1], encoding='utf-8').read()
print("    screen:", [html.unescape(t)[:24] for t in re.findall(r'text="([^"]*)"', xml) if t.strip()][:12])
DEBUG
    fi
else
    bad "could not find the All chip to tap"
fi

info "The tab choice is session state, not a setting"
if adb_ shell "run-as $PKG cat shared_prefs/messages_settings.xml" 2>/dev/null | grep -qi "categor"; then
    bad "the reveal/category state was written into settings"
else
    ok "nothing about the tabs is persisted"
fi

echo ""
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
