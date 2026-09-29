#!/usr/bin/env bash
# Issue #265 regression: Advanced must come back from the Accessibility screen
# at the scroll position it was left at.
#
# Navigation swaps a route string through AnimatedContent, so the outgoing
# screen's composable is disposed and rebuilt on the way back. Advanced created
# its ScrollState inline, so it always restarted at the top and the row you had
# just left scrolled off screen again.
#
# The navigable row is "Accessibility options", which only exists once
# "Accessibility mode" is on — so this enables it, and restores it afterwards.
#
# Precondition: emulator booted and the app installed, system locale English.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
info() { echo -e "\n=== $* ==="; }
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

ROW="Accessibility options"
# "Drafts" is the first row of Advanced, so it proves the screen is open even
# before any scrolling. "Auto-delete" sits lower and doubles as the anchor.
SENTINEL="Drafts"
ANCHOR="Auto-delete"
A11Y_LABEL="Accessibility mode"
A11Y_ON="absent"

# Topmost y of a label in the current dump; -1 when it is off screen.
y_of() {
    python3 - "$1" "$TMP/ui.xml" <<'PY'
import re, sys
label, path = sys.argv[1], sys.argv[2]
xml = open(path).read()
ys = []
for t in re.findall(r'<node[^>]*>', xml):
    if f'text="{label}"' in t:
        b = re.search(r'bounds="\[\d+,(\d+)\]', t)
        if b:
            ys.append(int(b.group(1)))
print(min(ys) if ys else -1)
PY
}
center_of_text() {
    python3 - "$1" "$TMP/ui.xml" <<'PY'
import re, sys
label, path = sys.argv[1], sys.argv[2]
xml = open(path).read()
for t in re.findall(r'<node[^>]*>', xml):
    if f'text="{label}"' in t:
        b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', t)
        if b:
            print((int(b.group(1)) + int(b.group(3))) // 2,
                  (int(b.group(2)) + int(b.group(4))) // 2)
            break
PY
}
# checked state of the switch on the row carrying $1
switch_state() {
    python3 - "$1" "$TMP/ui.xml" <<'PY'
import re, sys
label, xml_path = sys.argv[1], sys.argv[2]
xml = open(xml_path).read()
nodes = re.findall(r'<node[^>]*>', xml)
row_y = None
for n in nodes:
    if f'text="{label}"' in n:
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
        d = abs((int(b.group(2)) + int(b.group(4))) // 2 - row_y)
        if d < best_d:
            best, best_d = n, d
c = re.search(r'checked="([^"]*)"', best) if best else None
print(c.group(1) if c else "unknown")
PY
}

restore_a11y() {
  [ "$A11Y_ON" = "true" ] && return 0
  adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
  adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null 2>&1 || true
  sleep 3
  for _ in $(seq 1 10); do
    dump_ui >/dev/null 2>&1 || true
    c=$(center_of_text "$A11Y_LABEL")
    [ -n "$c" ] && break
    adb_ shell input swipe 500 2000 500 500 300; sleep 0.7
  done
  dump_ui >/dev/null 2>&1 || true
  [ "$(switch_state "$A11Y_LABEL")" = "true" ] && tap_switch_near "$A11Y_LABEL" >/dev/null 2>&1
  adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
}
trap restore_a11y EXIT

open_advanced() {
  adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
  adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null; sleep 3
  local c=""
  for _ in $(seq 1 10); do
    dump_ui || return 1
    c=$(center_of_text "Advanced")
    [ -n "$c" ] && break
    adb_ shell input swipe 500 2000 500 500 300; sleep 0.7
  done
  [ -z "$c" ] && return 1
  adb_ shell input tap $c; sleep 1.5
  wait_for_text "$SENTINEL" 10 || return 1
  return 0
}

info "Opening Advanced"
open_advanced || { fail "could not open Advanced from Settings"; echo "Results: $PASS passed, $FAIL failed"; exit 1; }
dump_ui
if grep -q "$SENTINEL" "$TMP/ui.xml"; then
  pass "Advanced settings opened"
else
  fail "Advanced settings did not open"
fi

info "Enabling Accessibility mode so the options row is reachable"
for _ in 1 2 3 4 5 6; do
  dump_ui
  [ "$(y_of "$A11Y_LABEL")" -gt 0 ] && break
  adb_ shell input swipe 500 1900 500 600 350; sleep 0.5
done
dump_ui
A11Y_ON=$(switch_state "$A11Y_LABEL")
if [ "$A11Y_ON" != "true" ]; then
  tap_switch_near "$A11Y_LABEL" >/dev/null 2>&1
  sleep 2
  dump_ui
  if [ "$(switch_state "$A11Y_LABEL")" = "true" ]; then
    pass "Accessibility mode enabled (was off; will be restored)"
  else
    fail "could not enable Accessibility mode (state=$(switch_state "$A11Y_LABEL"))"
  fi
else
  pass "Accessibility mode already on; left as found"
fi

info "Scrolling down to the '$ROW' row"
for _ in 1 2 3 4 5 6; do
  dump_ui
  [ "$(y_of "$ROW")" -gt 0 ] && break
  adb_ shell input swipe 500 1900 500 600 350; sleep 0.5
done
dump_ui
row_before=$(y_of "$ROW")
anchor_before=$(y_of "$ANCHOR")
echo "before: '$ROW' y=$row_before, '$ANCHOR' y=$anchor_before"
if [ "$row_before" -gt 0 ]; then
  pass "'$ROW' is visible after scrolling"
else
  fail "'$ROW' not visible after scrolling (y=$row_before)"
fi

info "Opening the Accessibility screen, then pressing back"
dump_ui
ct=$(center_of_text "$ROW")
[ -n "$ct" ] && adb_ shell input tap $ct
# "Font size" is the first control on the Accessibility screen; the row's own
# subtitle only exists on Advanced, so it cannot be used as a sentinel here.
if wait_for_text "Font size" 10; then
  pass "Accessibility screen opened"
else
  fail "Accessibility screen did not open"
fi
adb_ shell input keyevent 4; sleep 1.5
# Coming back at the *restored* offset means "Drafts" is off screen again, so
# wait on a row that is on screen at that offset.
wait_for_text "$ANCHOR" 10 || fail "did not return to Advanced after back"

info "Asserting Advanced kept its scroll position"
dump_ui || fail "dump after back failed"
row_after=$(y_of "$ROW")
anchor_after=$(y_of "$ANCHOR")
echo "after:  '$ROW' y=$row_after, '$ANCHOR' y=$anchor_after"

if grep -q "$ANCHOR" "$TMP/ui.xml"; then
  pass "returned to Advanced"
else
  fail "did not return to Advanced"
fi

# The regression: Advanced used to rebuild at offset 0, so the row just left
# scrolled off the top again.
if [ "$row_before" = "$row_after" ] && [ "$row_after" -gt 0 ]; then
  pass "'$ROW' kept the same position ($row_before -> $row_after)"
else
  fail "'$ROW' moved ($row_before -> $row_after) — scroll was reset"
fi
if [ "$anchor_before" = "$anchor_after" ]; then
  pass "scroll offset retained (anchor '$ANCHOR' y=$anchor_after)"
else
  fail "scroll offset changed ($anchor_before -> $anchor_after)"
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
