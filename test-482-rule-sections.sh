#!/usr/bin/env bash
# Categories & rules: one section per tab, and "+" opening the rule sheet.
#
# The page used to be a flat list with a "Keyword · Spam" subtitle — one pile of
# rows that had to be decoded per line. Every tab now owns a group of settings
# rows (the same cards every other settings page draws), and the add form is a
# Material bottom sheet: how to match at the top, the word in the field, the
# four tabs at the bottom, so it all clears the keyboard.
#
# Run: scripts/test-482-rule-sections.sh
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

APP_USER="${APP_USER:-0}"

dump() { adb_ shell 'uiautomator dump /sdcard/rules.xml >/dev/null 2>&1; cat /sdcard/rules.xml'; }

xy_of() { # $1 = exact text; prints "x y" for its centre, or nothing
    python3 -c '
import html, re, sys
x = sys.stdin.read()
for n in re.findall(r"<node[^>]*/>", x):
    t = re.search(r"text=\"([^\"]*)\"", n)
    b = re.search(r"bounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"", n)
    if t and b and html.unescape(t.group(1)) == sys.argv[1]:
        x1, y1, x2, y2 = map(int, b.groups())
        print((x1 + x2) // 2, (y1 + y2) // 2)
        break
' "$1"
}

adb_ shell am force-stop "$PKG" >/dev/null 2>&1
adb_ shell am start --user "$APP_USER" -n "$ACT" --ez open_settings true >/dev/null 2>&1
if ! wait_for_text "Inbox settings" 12; then
    bad "settings never opened"
    exit 1
fi
ok "settings opened"

UI=$(dump)
XY=$(printf '%s' "$UI" | xy_of "Inbox settings")
[ -n "$XY" ] || { bad "no Inbox settings row"; exit 1; }
adb_ shell input tap $XY
sleep 2

UI=$(dump)
# The dump escapes "&" as &amp;, so the row is located on the decoded text.
XY=$(printf '%s' "$UI" | xy_of "Categories & rules")
if [ -z "$XY" ]; then
    bad "the rules row is not on Inbox settings (below the fold?)"
    exit 1
fi
ok "Categories & rules is the first row"
adb_ shell input tap $XY
sleep 2

UI=$(dump)
for section in Personal Transactions OTP Spam; do
    if printf '%s' "$UI" | grep -qF "text=\"$section\""; then
        ok "the $section section heading is on the page"
    else
        bad "no $section section heading"
    fi
done
if printf '%s' "$UI" | grep -qF "text=\"Keyword\""; then
    ok "a saved rule shows its match kind"
else
    bad "rule rows lost their match kind"
fi

adb_ shell input tap 982 160
sleep 2
UI=$(dump)
for want in "Keyword" "Sender" "Word or sender" "Personal" "Transactions" "OTP" "Spam" "Add" "Cancel"; do
    if printf '%s' "$UI" | grep -qF "text=\"$want\""; then
        ok "the rule sheet has '$want'"
    else
        bad "the rule sheet is missing '$want'"
    fi
done

# The picture the user asked for: match kind above the field, tabs underneath.
if printf '%s' "$UI" | python3 -c '
import re, sys
raw = sys.stdin.read()
rows = {}
for label in ("Keyword", "Sender", "Word or sender", "Personal", "Spam", "Add"):
    for n in re.findall(r"<node[^>]*/>", raw):
        m = re.search(r"text=\"([^\"]*)\"", n)
        b = re.search(r"bounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"", n)
        if m and b and m.group(1) == label:
            rows[label] = int(b.group(2))
            break
ok = rows.get("Keyword", 0) < rows.get("Word or sender", 10 ** 6) < rows.get("Spam", 0)
print("  [PASS] match kind on top, tabs below the field" if ok
      else "  [FAIL] the sheet order is wrong: %s" % rows)
sys.exit(0 if ok else 1)
'; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi

echo ""
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
