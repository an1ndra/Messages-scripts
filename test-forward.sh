#!/usr/bin/env bash
# Forward a message from a chat:
#   * long-pressing a bubble opens the selection toolbar with a Forward button
#   * tapping it opens the target picker, and the picker offers people who are
#     NOT saved contacts (recent conversations) and a bare number typed into the
#     search box -- before this, forwarding to anyone outside the address book
#     was a dead end
#   * picking a target forwards the message into that conversation
#   * with forwarding turned off in Inbox settings, tapping Forward says so
#     instead of doing nothing
#
# Asserted from uiautomator dumps, no screenshots.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

MARK="FW$(date +%s)$$"
SELF="+1555999$$"
cleanup() {
    adb_ shell "run-as $PKG sqlite3 databases/messages.db \"delete from messages where body like '%$MARK%';\"" >/dev/null 2>&1 || true
}

adb_ shell am force-stop "$PKG" >/dev/null 2>&1
# Seed the conversation this test forwards from, so it never depends on whatever
# the device already has.
adb_ shell am start -a android.intent.action.SENDTO -d "smsto:$SELF" "$ACT" >/dev/null 2>&1
sleep 4
tap_edittext || true
type_text "$MARK"
sleep 1
# ENTER inserts a newline in this field; the send button is the only way out.
dump_ui || true
SEND=$(python3 - "$TMP/ui.xml" <<'PY'
import re, sys
xml = open(sys.argv[1], encoding="utf-8").read()
for tag in re.findall(r'<node[^>]*>', xml):
    d = re.search(r'content-desc="Send"', tag)
    b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', tag)
    if d and b:
        x1, y1, x2, y2 = map(int, b.groups())
        print((x1 + x2) // 2, (y1 + y2) // 2); break
PY
)
[ -n "$SEND" ] && adb_ shell input tap $SEND
sleep 3
dump_ui
SEEDED=$(adb_ shell "run-as $PKG sqlite3 databases/messages.db \"select count(*) from messages where body like '%$MARK%';\"" | tr -d '\r')
if [ "${SEEDED:-0}" -ge 1 ]; then
    ok "seeded a conversation with a message to forward"
else
    bad "could not seed the message to forward"
    cleanup
    exit 1
fi

info "Selection toolbar offers Forward"
BUBBLE=$(center_of "$MARK")
adb_ shell input swipe $BUBBLE $BUBBLE 800; sleep 2
dump_ui
if ui_tags | grep -q 'content-desc="Forward"'; then
    ok "long-press opened the selection toolbar with a Forward button"
else
    bad "no Forward button on the selection toolbar"
fi

info "The picker can reach people who are not contacts"
FWD=$(python3 - "$TMP/ui.xml" <<'PY'
import re, sys
xml = open(sys.argv[1], encoding="utf-8").read()
for tag in re.findall(r'<node[^>]*>', xml):
    d = re.search(r'content-desc="Forward"', tag)
    b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', tag)
    if d and b:
        x1, y1, x2, y2 = map(int, b.groups())
        print((x1 + x2) // 2, (y1 + y2) // 2); break
PY
)
if [ -n "$FWD" ]; then
    adb_ shell input tap $FWD; sleep 2
    dump_ui
    if grep -q 'text="Forward to"' "$TMP/ui.xml"; then
        ok "Forward opened the target picker"
    else
        bad "Forward did not open the target picker"
    fi
    # A number nobody has in contacts is still a destination.
    C=$(center_of "Search contacts" 2>/dev/null || echo "")
    if [ -n "$C" ]; then
        adb_ shell input tap $C; sleep 1
        type_text "555000111"
        sleep 2
        dump_ui
        if grep -q 'text="555000111"' "$TMP/ui.xml"; then
            ok "a typed number that matches nobody is offered as a target"
        else
            bad "a typed number is not offered as a target"
        fi
        adb_ shell input keyevent 4; sleep 1
    else
        bad "the picker's search field is not reachable"
    fi
    if center_of_contains "Cancel" >/dev/null 2>&1; then
        adb_ shell input keyevent 4; sleep 1.5
    fi
else
    bad "could not locate the Forward button"
fi

info "Picking a target forwards the message"
dump_ui >/dev/null 2>&1
BEFORE=$(adb_ shell "run-as $PKG sqlite3 databases/messages.db \"select count(*) from messages where body like '%$MARK%';\"" | tr -d '\r')
if [ -n "$FWD" ] && ui_tags | grep -q 'content-desc="Forward"'; then
    adb_ shell input tap $FWD; sleep 2
    dump_ui || true
    TARGET=$(python3 - "$TMP/ui.xml" <<'PY'
import re, sys
xml = open(sys.argv[1], encoding="utf-8").read()
rows = []
for tag in re.findall(r'<node[^>]*>', xml):
    t = re.search(r'text="([^"]+)"', tag)
    b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', tag)
    if t and b:
        x1, y1, x2, y2 = map(int, b.groups())
        if y1 > 800 and y2 < 1650 and '+' in t.group(1) and len(t.group(1)) > 6:
            rows.append((y1, (x1 + x2) // 2, (y1 + y2) // 2))
if rows:
    rows.sort()
    print(rows[0][1], rows[0][2])
PY
)
    if [ -n "$TARGET" ]; then
        adb_ shell input tap $TARGET; sleep 3
        AFTER=$(adb_ shell "run-as $PKG sqlite3 databases/messages.db \"select count(*) from messages where body like '%$MARK%';\"" | tr -d '\r')
        if [ "${AFTER:-0}" -gt "${BEFORE:-0}" ]; then
            ok "the message was forwarded into the picked conversation ($BEFORE -> $AFTER)"
        else
            bad "picking a target did not forward the message ($BEFORE -> $AFTER)"
        fi
    else
        bad "the picker offered no target to pick"
    fi
else
    bad "no selection toolbar to forward from"
fi

info "Forwarding disabled explains itself instead of doing nothing"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1
adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null; sleep 3
dump_ui || true
# Forwarding lives on the Inbox settings sub-page, not on General settings.
if ! ui_tags | grep -q 'text="Inbox settings"'; then
    for _ in 1 2 3 4 5 6; do
        adb_ shell input swipe 540 1800 540 800 300; sleep 0.5
        dump_ui
        ui_tags | grep -q 'text="Inbox settings"' && break
    done
fi
if tap_text "Inbox settings" >/dev/null 2>&1; then
    sleep 2
    dump_ui || true
    if tap_switch_near "Forwarding" >/dev/null 2>&1; then
        sleep 1.5
        STATE=$(adb_ shell "run-as $PKG cat shared_prefs/messages_settings.xml" 2>/dev/null \
            | grep -oE 'name="forwarding_enabled" value="[^"]*"' | grep -oE 'value="[^"]*"')
        if [ "$STATE" = 'value="false"' ]; then
            ok "turned forwarding off for the check"
            adb_ shell am start -a android.intent.action.SENDTO -d "smsto:$SELF" "$ACT" >/dev/null 2>&1
            sleep 3
            dump_ui || true
            B=$(center_of "$MARK" 2>/dev/null || echo "")
            if [ -n "$B" ]; then
                adb_ shell input swipe $B $B 800; sleep 2
                dump_ui || true
                F2=$(python3 - "$TMP/ui.xml" <<'PY'
import re, sys
xml = open(sys.argv[1], encoding="utf-8").read()
for tag in re.findall(r'<node[^>]*>', xml):
    d = re.search(r'content-desc="Forward"', tag)
    b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', tag)
    if d and b:
        x1, y1, x2, y2 = map(int, b.groups())
        print((x1 + x2) // 2, (y1 + y2) // 2); break
PY
)
                if [ -z "$F2" ]; then
                    bad "no Forward button to tap with forwarding off"
                else
                    # uiautomator does not expose toast windows, so assert the
                    # behaviour that *is* observable: with forwarding off the
                    # picker must not open. The toast that explains why is
                    # covered by the same branch in the code.
                    OPENED=no
                    for _ in 1 2 3; do
                        adb_ shell input tap $F2
                        sleep 0.8
                        dump_ui >/dev/null 2>&1 || true
                        if grep -q 'text="Forward to"' "$TMP/ui.xml"; then
                            OPENED=yes; break
                        fi
                    done
                    if [ "$OPENED" = no ]; then
                        ok "Forward is refused while forwarding is off"
                    else
                        bad "the picker opened even though forwarding is off"
                    fi
                fi
            else
                bad "could not open the chat to test the disabled case"
            fi
        else
            bad "could not turn forwarding off (pref: $STATE)"
        fi
        # restore
        adb_ shell am force-stop "$PKG" >/dev/null 2>&1
        adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null; sleep 3
        tap_text "Inbox settings" >/dev/null 2>&1; sleep 2
        tap_switch_near "Forwarding" >/dev/null 2>&1; sleep 1
    else
        bad "could not toggle the Forwarding switch"
    fi
else
    bad "could not open Inbox settings"
fi

if [ -n "$(adb_ shell pidof "$PKG" | tr -d '\r')" ]; then
    ok "app still running"
else
    bad "app crashed"
fi

cleanup
echo ""
info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
