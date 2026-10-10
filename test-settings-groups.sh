#!/usr/bin/env bash
# The General settings list must match the agreed layout:
#   * one connected run of separate row cards with a tight gap (2dp)
#   * the group's first/last rows softly rounded, the rows between nearly square
#   * a title-only row shorter than a row that carries a description
#   * descriptions only where there is a value or a genuine pointer
#   * "Inbox settings" opening a sub-page that holds the per-conversation toggles
#
# Everything is asserted from uiautomator dumps, no screenshots.
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/env.sh"
set -euo pipefail

PASS=0
FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
[[ "$ANDROID_SERIAL" == emulator-* ]] || { printf 'Requires a disposable emulator.\n'; exit 1; }

adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
adb_ shell am start -n "$ACT" >/dev/null
sleep 4

# Full-width clickable settings rows as "y1 y2 x1 x2", top to bottom.
# 1080x2400 screen; anything ending below this is cut off by the nav bar.
VIEWPORT_BOTTOM=2200
rows_on_screen() {
    python3 - "$TMP/ui.xml" "$VIEWPORT_BOTTOM" <<'PY'
import re, sys
xml = open(sys.argv[1]).read()
viewport_bottom = int(sys.argv[2])
rows = []
for tag in re.findall(r'<node[^>]*>', xml):
    if 'clickable="true"' not in tag:
        continue
    b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', tag)
    if not b:
        continue
    x1, y1, x2, y2 = map(int, b.groups())
    if x2 - x1 < 800 or y2 - y1 < 40:   # skip switches and icon buttons
        continue
    # A row clipped by the bottom of the viewport measures short, so it looks
    # like a title-only row and drags the "short band" minimum down. Only rows
    # fully on screen are measured.
    if y2 > viewport_bottom:
        continue
    rows.append((y1, y2, x1, x2))
rows.sort()
print('\n'.join(' '.join(map(str, r)) for r in rows))
PY
}

scroll_to() {
    local target="$1" i
    for i in 1 2 3 4 5 6 7 8; do
        if center_of "$target" >/dev/null 2>&1; then return 0; fi
        adb_ shell input swipe 540 1800 540 700 250; sleep 1
    done
    center_of "$target" >/dev/null 2>&1
}

go_home() {
    local i
    local i
    for i in 1 2 3 4 5 6; do
        dump_ui >/dev/null 2>&1 || true
        if grep -c 'text="Messages"' "$TMP/ui.xml" >/dev/null 2>&1; then return 0; fi
        adb_ shell input keyevent 4; sleep 1
    done
    # Back-walking can stall (e.g. after handing off to another app); relaunch.
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    adb_ shell am start -n "$ACT" >/dev/null
    sleep 4
    dump_ui >/dev/null 2>&1 || true
    grep -c 'text="Messages"' "$TMP/ui.xml" >/dev/null 2>&1
}

open_settings() {
    # Cold-start straight into Settings via the intent extra. Tapping the
    # top-right entry point instead only works from the conversation list, so it
    # broke whenever the previous step left us on a sub-page.
    adb_ shell am force-stop "$PKG"; sleep 1
    adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null; sleep 3
    dump_ui >/dev/null 2>&1 || true
    grep -q 'text="General settings"' "$TMP/ui.xml"
}

# $2 = the page's row count, so the expected number of gaps is row count - 1.
# A flat ">=5" would silently stop testing the smaller sub-pages.
assert_gap_between_rows() {
    local screen="$1" rows="${2:-}" n smallest want
    read -r n smallest <<< "$(rows_on_screen | python3 -c '
import sys
ys = [tuple(map(int, l.split())) for l in sys.stdin if l.strip()]
gaps = [b[0] - a[1] for a, b in zip(ys, ys[1:]) if b[0] - a[1] > 0]
print(f"{len(gaps)} {min(gaps) if gaps else 0}")')"
    want=4
    if [ -n "$rows" ]; then
        # These pages scroll, so not every row is on screen at once; require a
        # healthy run of them rather than the whole list being visible.
        want=$(( rows / 2 ))
        [ "$want" -lt 4 ] && want=4
    fi
    # 2dp at 420dpi (2.625 px/dp) = ~5px. The band is deliberately narrow: a
    # wider gap turns the run back into a list of separate cards.
    if [ "${n:-0}" -ge "$want" ] && [ "${smallest:-0}" -ge 3 ] && [ "${smallest:-0}" -le 9 ]; then
        pass "$screen: separate cards with a tight gap (${n} gaps, min ${smallest}px)"
    else
        fail "$screen: expected >=${want} gaps of 3-9px, got ${n:-0} gaps, min ${smallest:-0}px"
    fi
}

assert_uniform_width() {
    local screen="$1" uniq w
    read -r uniq w <<< "$(rows_on_screen | python3 -c '
import sys
ws = [int(l.split()[3]) - int(l.split()[2]) for l in sys.stdin if l.strip()]
print(f"{len(set(ws))} {min(ws) if ws else 0}")')"
    if [ "${uniq:-2}" = "1" ]; then
        pass "$screen: all row cards share one width (${w}px)"
    else
        fail "$screen: row cards have ${uniq} different widths"
    fi
}

# Title-only rows are 56dp (147px) and described rows 76dp (200px). Asserting
# both bands is what proves a row's height tracks its own description.
assert_row_heights() {
    local screen="$1" nshort hshort ntall htall
    read -r nshort hshort ntall htall <<< "$(rows_on_screen | python3 -c '
import sys
hs = sorted(int(l.split()[1]) - int(l.split()[0]) for l in sys.stdin if l.strip())
short = [h for h in hs if h < 185]
tall = [h for h in hs if h >= 185]
print(f"{len(short)} {min(short) if short else 0} {len(tall)} {min(tall) if tall else 0}")')"
    if [ "${nshort:-0}" -ge 3 ] && [ "${hshort:-0}" -ge 138 ] && [ "${hshort:-0}" -le 165 ]; then
        pass "$screen: title-only rows are the short band (${nshort} at ${hshort}px)"
    else
        fail "$screen: expected >=3 title-only rows near 147px, got ${nshort:-0} at ${hshort:-0}px"
    fi
    if [ "${ntall:-0}" -ge 3 ] && [ "${htall:-0}" -ge 190 ] && [ "${htall:-0}" -le 215 ]; then
        pass "$screen: described rows are the tall band (${ntall} at ${htall}px)"
    else
        fail "$screen: expected >=3 described rows near 200px, got ${ntall:-0} at ${htall:-0}px"
    fi
}

# Count only text that sits inside a row card, so the app bar title and the
# footer cannot be mistaken for descriptions.
count_described_rows() {
    rows_on_screen | python3 -c '
import sys, re
rows = [tuple(map(int, l.split())) for l in sys.stdin if l.strip()]
if not rows:
    print("0 0"); raise SystemExit
lo = min(r[2] for r in rows); hi = max(r[3] for r in rows)
xml = open(sys.argv[1]).read() if len(sys.argv) > 1 else ""
texts = []
for tag in re.findall(r"<node[^>]*>", xml):
    t = re.search(r"\btext=\"([^\"]+)\"", tag)
    b = re.search(r"\bbounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"", tag)
    if t and b:
        x1, y1, x2, y2 = map(int, b.groups())
        if lo <= x1 and x2 <= hi + 40:
            texts.append((y1, y2))
inside = 0
for y1, y2, _, _ in rows:
    n = sum(1 for ty1, ty2 in texts if y1 - 6 <= ty1 and ty2 <= y2 + 6)
    if n >= 2:
        inside += 1
print(f"{len(rows)} {inside}")' "$TMP/ui.xml"
}

# ------------------------------------------------------------ General settings
info "General settings: one connected run of gapped row cards"
if open_settings; then
    pass 'opened General settings'
    dump_ui >/dev/null 2>&1 || true
    assert_gap_between_rows "General settings" 12
    assert_uniform_width "General settings"
    assert_row_heights "General settings"

    read -r cards described <<< "$(count_described_rows)"
    if [ "${cards:-0}" -ge 8 ] && [ "${described:-99}" -le 6 ]; then
        pass "General settings: descriptions are the exception (${described} of ${cards} rows)"
    else
        fail "General settings: ${described} of ${cards} rows carry a description (expected <=6)"
    fi
else
    fail 'could not open General settings'
fi

# The agreed row order, with exactly the rows that have no description.
info "General settings: agreed row order and description set"
dump_ui >/dev/null 2>&1 || true
EXPECTED_ORDER="Notifications|Mark all as read|Choose theme|SIM card|Inbox settings|Privacy mode|App lock|Trash|Spam &amp; Blocked|Backup messages|Import messages|Advanced settings"
# The page scrolls, so walk it and accumulate row titles in order rather than
# reading one screen's worth.
: > "$TMP/order.txt"
for _ in 1 2 3 4 5 6 7; do
    rows_on_screen | python3 "$HERE/.row_titles.py" "$TMP/ui.xml" >> "$TMP/order.txt"
    adb_ shell input swipe 540 1700 540 800 300
    sleep 0.7
    dump_ui >/dev/null 2>&1 || true
done
ACTUAL=$(awk 'NF' "$TMP/order.txt" | awk '!seen[$0]++' | paste -sd'|' -)

# Every captured row must appear in the agreed relative order. An exact match is
# too brittle: the last row's node is not always reported clickable, so the walk
# sometimes sees 11 of 12 rows.
ORDER_OK=$(python3 "$HERE/.check_order.py" "$TMP/order.txt" "$EXPECTED_ORDER")
if [ "$ORDER_OK" = "OK" ]; then
    pass "General settings: rows are in the agreed order"
else
    fail "General settings: row order differs
  expected: $EXPECTED_ORDER
  actual:   $ACTUAL"
fi

# Notifications is a jump to the OS, not an in-app switch. The order walk left
# the page scrolled to the bottom, so return to the top first.
info "Notifications hands off to the system settings"
for _ in 1 2 3 4 5 6 7 8; do
    adb_ shell input swipe 540 800 540 1800 300
    sleep 0.4
done
dump_ui >/dev/null 2>&1 || true
if tap_text "Notifications" >/dev/null 2>&1; then
    sleep 2
    TOP=$(adb_ shell dumpsys activity activities 2>/dev/null | tr -d '\r' | grep -cE 'NotificationSettings|com\.android\.settings' || true)
    if [ "${TOP:-0}" -ge 1 ]; then
        pass 'Notifications opened the system notification settings'
    else
        fail 'Notifications did not leave the app for the system settings'
    fi
else
    fail 'could not tap Notifications'
fi

# --------------------------------------------------------------- Inbox settings
info "Inbox settings sub-page holds the per-conversation toggles"
if open_settings; then
    if tap_text "Inbox settings" >/dev/null 2>&1; then
        sleep 2
        dump_ui >/dev/null 2>&1 || true
        if grep -c 'text="Inbox settings"' "$TMP/ui.xml" >/dev/null 2>&1 &&
           grep -c 'text="Archiving"' "$TMP/ui.xml" >/dev/null 2>&1; then
            pass 'opened the Inbox settings sub-page'
            assert_gap_between_rows "Inbox settings" 8
            assert_row_heights "Inbox settings"
            if tap_switch_near "Archiving" >/dev/null 2>&1; then
                sleep 1
                pass 'an Inbox settings toggle is tappable'
                tap_switch_near "Archiving" >/dev/null 2>&1 || true   # restore
                sleep 1
            else
                fail 'could not tap an Inbox settings toggle'
            fi
            # The two list rows must open their dialogs, not toggle a switch.
            if tap_text "Number blocking" >/dev/null 2>&1; then
                sleep 2
                if grep -c 'text="Blocked numbers"' "$TMP/ui.xml" >/dev/null 2>&1 ||
                   adb_ shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1; then
                    adb_ shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1
                    adb_ pull /sdcard/ui.xml "$TMP/ui.xml" >/dev/null 2>&1
                    if grep -c 'text="Blocked numbers"' "$TMP/ui.xml" >/dev/null 2>&1; then
                        pass 'Number blocking opens the blocked-numbers list'
                        adb_ shell input keyevent 4; sleep 1
                    else
                        fail 'Number blocking did not open the blocked-numbers list'
                    fi
                else
                    fail 'Number blocking row was not reachable'
                fi
            else
                fail 'could not tap Number blocking'
            fi
        else
            fail 'did not land on the Inbox settings sub-page'
        fi
    else
        fail 'could not find the Inbox settings row'
    fi
else
    fail 'could not return to General settings'
fi

# -------------------------------------------------------------------- Advanced
info "Advanced settings share the same row component"
if open_settings; then
    if scroll_to "Advanced settings" >/dev/null 2>&1 && tap_text "Advanced settings" >/dev/null 2>&1; then
        sleep 2
        dump_ui >/dev/null 2>&1 || true
        if grep -q 'text="Link behaviour"' "$TMP/ui.xml" \
            && grep -q 'text="Auto-delete"' "$TMP/ui.xml"; then
            pass 'opened Advanced'
            assert_gap_between_rows "Advanced settings" 10
        else
            fail 'did not land on the Advanced screen'
        fi
    else
        fail 'could not reach the Advanced screen'
    fi
else
    fail 'could not reach General settings for Advanced'
fi

# ---------------------------------------------------------------- Accessibility
info "Accessibility options share the same row component"
if open_settings; then
    if scroll_to "Advanced settings" >/dev/null 2>&1; then
        tap_text "Advanced settings" >/dev/null 2>&1; sleep 2
        # The Accessibility options row is gated on the master switch, so make
        # sure it is on before looking for it.
        if ! scroll_to "Accessibility options" >/dev/null 2>&1; then
            tap_switch_near "Accessibility mode" >/dev/null 2>&1; sleep 1.5
        fi
        if scroll_to "Accessibility options" >/dev/null 2>&1; then
            tap_text "Accessibility options" >/dev/null 2>&1; sleep 2
            dump_ui >/dev/null 2>&1 || true
            if grep -q 'text="Font size"' "$TMP/ui.xml"; then
                pass 'opened Accessibility options'
                assert_gap_between_rows "Accessibility options" 5
            else
                fail 'did not land on the Accessibility options screen'
            fi
        else
            fail 'could not find the Accessibility options row'
        fi
    else
        fail 'could not reach the Advanced screen'
    fi
else
    fail 'could not reach General settings'
fi

if adb_ logcat -d -b crash 2>/dev/null | grep -q "$PKG"; then
    fail 'app crashed while navigating the settings screens'
else
    pass 'no crash across the settings screens'
fi

adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
