#!/usr/bin/env bash
# Issue #266 regression: "Unread at top" must default to off.
#
# With it on the conversation list re-sorts as messages arrive and jumps out
# from under the user. The default was hardcoded to true in the SettingsStore
# getter, so every fresh install got the jumpy list.
#
# Precondition: emulator booted and the app installed.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
info() { echo -e "\n=== $* ==="; }
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

local_query(){ adb_ shell "run-as '$PKG' sqlite3 databases/messages.db \"$1\"" 2>/dev/null | tr -d '\r'; }
prefs_file(){ adb_ shell "run-as '$PKG' cat shared_prefs/${PKG}_preferences.xml" 2>/dev/null | tr -d '\r'; }

saved=""
cleanup(){
  # Leave the setting exactly as we found it.
  if [ -n "$saved" ]; then
    if [ "$saved" = "absent" ]; then
      adb_ shell "run-as '$PKG' sed -i '/unread_at_top_enabled/d' shared_prefs/${PKG}_preferences.xml" >/dev/null 2>&1 || true
    else
      adb_ shell "run-as '$PKG' sed -i 's|<boolean name=\"unread_at_top_enabled\"[^/]*/>|<boolean name=\"unread_at_top_enabled\" value=\"$saved\" />|' shared_prefs/${PKG}_preferences.xml" >/dev/null 2>&1 || true
    fi
  fi
  adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
}
trap cleanup EXIT

info "Recording the current unread_at_top_enabled value"
line=$(prefs_file | grep -o 'unread_at_top_enabled[^/]*' | head -1 || true)
if [ -z "$line" ]; then
  saved="absent"
  info "key absent (never written) — the getter default is what applies"
else
  saved=$(printf '%s' "$line" | grep -o 'value="[^"]*"' | sed 's/value="//; s/"//')
  info "existing value: $saved"
fi

info "Resetting to a fresh-install state (key removed)"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
adb_ shell "run-as '$PKG' sed -i '/unread_at_top_enabled/d' shared_prefs/${PKG}_preferences.xml" >/dev/null 2>&1 || true
if prefs_file | grep -q unread_at_top_enabled; then
  fail "could not clear unread_at_top_enabled from the prefs"
else
  pass "unread_at_top_enabled cleared from prefs"
fi

info "Opening Settings and reading the 'Unread at top' switch"
adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null; sleep 4
# The row sits near the bottom of the first Settings group, off screen on open.
for _ in $(seq 1 6); do
  dump_ui || break
  grep -q "Unread at top" "$TMP/ui.xml" && break
  adb_ shell input swipe 500 2000 500 1400 300; sleep 0.6
done
dump_ui || fail "settings dump failed"

if grep -q "Unread at top" "$TMP/ui.xml"; then
  pass "'Unread at top' row is present"
else
  fail "'Unread at top' row not found in Settings"
fi

# The switch node is the one immediately after the row's bounds; find the
# Checkable node nearest the row and read its checked state.
state=$(python3 - "$TMP/ui.xml" <<'PY'
import re, sys
xml = open(sys.argv[1]).read()
nodes = re.findall(r'<node[^>]*>', xml)
row_y = None
for n in nodes:
    if 'text="Unread at top"' in n:
        b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', n)
        if b:
            row_y = (int(b.group(2)) + int(b.group(4))) // 2
            break
if row_y is None:
    print("norow"); raise SystemExit
best, best_d = None, 10**9
for n in nodes:
    if 'class="android.widget.Switch"' in n or 'checkable="true"' in n:
        b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', n)
        if not b:
            continue
        y = (int(b.group(2)) + int(b.group(4))) // 2
        d = abs(y - row_y)
        if d < best_d:
            best, best_d = n, d
if best is None:
    print("noswitch")
else:
    c = re.search(r'checked="([^"]*)"', best)
    print(c.group(1) if c else "unknown")
PY
)
echo "   switch checked = $state"
case "$state" in
  false) pass "'Unread at top' defaults to off" ;;
  true)  fail "'Unread at top' defaults to ON (expected off)" ;;
  *)     fail "could not read the 'Unread at top' switch state (got '$state')" ;;
esac

info "Asserting the default is what the list uses, not a leftover write"
after=$(prefs_file | grep -c unread_at_top_enabled || true)
if [ "${after:-0}" -eq 0 ]; then
  pass "no implicit write of unread_at_top_enabled on a fresh install"
else
  fail "unread_at_top_enabled was written without the user asking"
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
