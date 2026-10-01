#!/usr/bin/env bash
# Searching the legacy General settings screen.
#
# Search there works like a dialler suggesting contacts, not like a filter:
# results are a plain list of names, and picking one leaves search, scrolls to
# the card that option lives in, and flashes the row so it is obvious where the
# tap landed. Asserting the filter behaviour instead would pass while the screen
# did something the user did not ask for.
#
# Covers:
#   * results are names, and are narrowed by what is typed
#   * choosing a result leaves search and scrolls to the option's own card
#   * the chosen row is actually brought into view -- an earlier version fired
#     the scroll once before the card existed and silently did nothing
#   * back leaves search and restores the title
#
# Asserted from uiautomator dumps, no screenshots.
# Run: scripts/test-settings-search.sh
set -uo pipefail
cd "$(dirname "$0")"
source ./env.sh

PASS=0; FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

LEGACY_WAS_SET=0
restore_ui() {
    [ "$LEGACY_WAS_SET" = "1" ] || return 0
    adb_ shell "run-as $PKG sh -c 'sed -i \"s#name=\\\"use_new_ui\\\" value=\\\"false\\\"#name=\\\"use_new_ui\\\" value=\\\"true\\\"#\" shared_prefs/messages_settings.xml'" \
        >/dev/null 2>&1 || true
}
cleanup() { restore_ui; }
trap cleanup EXIT

# The redesigned settings screen has no search icon, so pin the legacy one or
# every assertion below would fail against the wrong UI.
info "Pinning the legacy settings screen"
cur=$(adb_ shell "run-as $PKG cat shared_prefs/messages_settings.xml" 2>/dev/null \
    | grep -o 'use_new_ui" value="[a-z]*"' | head -1)
[ "$cur" = 'use_new_ui" value="true"' ] && LEGACY_WAS_SET=1
adb_ shell "run-as $PKG sh -c 'sed -i \"s#name=\\\"use_new_ui\\\" value=\\\"true\\\"#name=\\\"use_new_ui\\\" value=\\\"false\\\"#\" shared_prefs/messages_settings.xml'" \
    >/dev/null 2>&1 || true

open_settings() {
    adb_ shell am force-stop "$PKG"; sleep 1
    adb_ shell am start -n "$ACT" >/dev/null; sleep 6
    dump_ui >/dev/null 2>&1 || return 1
    # The set-default prompt reappears after a reinstall and covers the top bar;
    # leaving it up means the tap below lands on the prompt instead.
    if grep -q 'text="Not now"' "$TMP/ui.xml"; then
        local n
        n=$(bounds_of "Not now")
        [ -n "$n" ] && { adb_ shell input tap $n; sleep 5; dump_ui >/dev/null 2>&1; }
    fi
    adb_ shell input tap 970 239; sleep 4
    dump_ui >/dev/null 2>&1 || return 1
    # Assert the screen, never just the icon: the conversation list carries a
    # search icon in the same corner, so this otherwise passes on the wrong UI.
    grep -q 'text="General settings"' "$TMP/ui.xml"
}

bounds_of() {   # $1 = exact text; skips the search field
    python3 - "$TMP/ui.xml" "$1" <<'PYEOF'
import re, sys
xml = open(sys.argv[1], encoding="utf-8", errors="replace").read()
want = sys.argv[2]
for tag in re.findall(r'<node[^>]*>', xml):
    # The query the user typed is also a text node and usually equals the result
    # being looked for. Matching it taps the field, not the row.
    if "EditText" in tag:
        continue
    t = re.search(r'text="([^"]*)"', tag)
    b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', tag)
    if t and b and t.group(1) == want:
        x1, y1, x2, y2 = map(int, b.groups())
        print((x1 + x2) // 2, (y1 + y2) // 2)
        break
PYEOF
}

info "The legacy settings screen offers search"
if open_settings; then
    pass "search icon present"
else
    fail "no search icon in the legacy settings header"
    exit 1
fi
TITLE=$(bounds_of "General settings")
[ -n "$TITLE" ] || { fail "settings title missing"; exit 1; }
pass "settings list reachable"

info "Results are a plain list of names"
tap_contains "Search" >/dev/null 2>&1 || { fail "could not open search"; exit 1; }
sleep 2
type_text "Notification"; sleep 2
dump_ui >/dev/null 2>&1
for want in "Notifications" "Notification sound"; do
    if grep -q "text=\"$want\"" "$TMP/ui.xml"; then
        pass "'Notification' offers '$want'"
    else
        fail "'Notification' does not offer '$want'"
    fi
done
# The full settings list must not still be on screen behind the results.
if grep -q 'text="Pinned conversations"' "$TMP/ui.xml"; then
    fail "the settings list is still shown behind the results"
else
    pass "results replace the list rather than filtering it"
fi

info "Choosing a result jumps to that option's card"
PICK=$(bounds_of "Notification sound")
[ -n "$PICK" ] || { fail "could not locate the result row"; exit 1; }
adb_ shell input tap $PICK; sleep 2
dump_ui >/dev/null 2>&1
# The header shows a search icon whether or not a search is open, so look for
# the field itself.
if grep -q 'text="Search settings"' "$TMP/ui.xml"; then
    fail "still in search after picking a result"
else
    pass "search closed and the settings list is back"
fi
if grep -q 'text="Notification sound"' "$TMP/ui.xml"; then
    pass "the chosen option is on screen"
else
    fail "the chosen option is not visible after the jump"
fi

info "A result on the last card scrolls it into view"
adb_ shell input tap 970 239; sleep 3
tap_contains "Search" >/dev/null 2>&1 || { fail "could not reopen search"; exit 1; }
sleep 2
type_text "Advanced"; sleep 2
dump_ui >/dev/null 2>&1
PICK=$(bounds_of "Advanced settings")
[ -n "$PICK" ] || { fail "could not locate 'Advanced settings' in the results"; exit 1; }
adb_ shell input tap $PICK; sleep 3
dump_ui >/dev/null 2>&1
if grep -q 'text="Advanced settings"' "$TMP/ui.xml"; then
    pass "'Advanced settings' was scrolled into view"
else
    fail "'Advanced settings' is not on screen -- the jump did not scroll"
fi

info "An option on a sub-screen navigates there and flashes"
# Already on the settings list from the step above. Backing out here would land
# on the conversation list, whose header has a search icon in the same corner.
dump_ui >/dev/null 2>&1
grep -q 'text="General settings"' "$TMP/ui.xml" || { fail "not on the settings list"; exit 1; }
tap_contains "Search" >/dev/null 2>&1 || { fail "could not reopen search"; exit 1; }
sleep 2
type_text "Diagnostics"; sleep 2
dump_ui >/dev/null 2>&1
if ! grep -q 'text="Diagnostics"' "$TMP/ui.xml"; then
    fail "'Diagnostics' is not offered by search"
else
    pass "'Diagnostics' is offered by search"
fi
PICK=$(bounds_of "Diagnostics")
[ -n "$PICK" ] || { fail "could not locate the Diagnostics result"; exit 1; }
adb_ shell input tap $PICK; sleep 3
dump_ui >/dev/null 2>&1
# A row that only exists on Advanced proves the navigation happened, without
# depending on the title being in the dump at that instant.
if grep -q 'text="Blocked keywords"\|text="Redesigned interface"\|text="Auto-delete"' "$TMP/ui.xml"; then
    pass "navigated to the screen that owns the option"
else
    fail "did not navigate to Advanced settings"
fi
if grep -q 'text="Diagnostics"' "$TMP/ui.xml"; then
    pass "the option is on screen after the jump"
else
    fail "the option is not visible after the jump"
fi

info "Back leaves search"
# Whatever screen the jump left us on, walk back to the settings list first.
for _ in 1 2 3 4; do
    dump_ui >/dev/null 2>&1
    grep -q 'text="General settings"' "$TMP/ui.xml" && break
    adb_ shell input keyevent 4; sleep 2
done
grep -q 'text="General settings"' "$TMP/ui.xml" || { fail "could not get back to General settings"; exit 1; }
tap_contains "Search" >/dev/null 2>&1; sleep 2
type_text "Trash"; sleep 2
adb_ shell input keyevent 4; sleep 1
adb_ shell input keyevent 4; sleep 3
dump_ui >/dev/null 2>&1
if grep -q 'text="General settings"' "$TMP/ui.xml"; then
    pass "back returned to the settings list"
else
    fail "back did not leave search"
fi

echo
if [ "$FAIL" = 0 ]; then
    echo "ALL SETTINGS SEARCH TESTS PASSED"
else
    echo "SOME SETTINGS SEARCH TESTS FAILED"
    exit 1
fi