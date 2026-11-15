#!/usr/bin/env bash
# Issue #480: the attach sheet offers a contact, the system contact picker opens,
# and picking one sends that person's card as a vCard text into the chat.
#
#   bash scripts/test-contact-card.sh
set -uo pipefail
cd "$(dirname "$0")"
source ./env.sh

PASS=0
FAIL=0
ok()   { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad()  { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

center_of() { # text or content-desc, from a fresh dump
    dump_ui >/dev/null
    python3 - "$TMP/ui.xml" "$1" <<'PY'
import re, sys
xml = open(sys.argv[1]).read()
want = sys.argv[2]
for m in re.finditer(r'<node[^>]*>', xml):
    tag = m.group(0)
    if f'text="{want}"' in tag or f'content-desc="{want}"' in tag:
        b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', tag)
        if b:
            x1, y1, x2, y2 = map(int, b.groups())
            print((x1 + x2) // 2, (y1 + y2) // 2)
            sys.exit(0)
sys.exit(1)
PY
}

first_row() {
    dump_ui >/dev/null
    python3 - "$TMP/ui.xml" <<'PY'
import re, sys
xml = open(sys.argv[1]).read()
best = None
for m in re.finditer(r'<node[^>]*content-desc="([^"]+)"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', xml):
    y1 = int(m.group(3))
    if y1 > 300 and (best is None or y1 < best[0]):
        best = (y1, (int(m.group(2)) + int(m.group(4))) // 2, (int(m.group(3)) + int(m.group(5))) // 2)
if not best:
    sys.exit(1)
print(best[1], best[2])
PY
}

local_query() { adb_ shell "run-as '$PKG' sqlite3 databases/messages.db \"$1\"" | tr -d '\r'; }

contact_label=$(res_string chat_media_contact)
PICKED="Alex"                     # a demo contact, from demo-data.sh

MAXID=$(local_query "SELECT IFNULL(MAX(id),0) FROM messages;")
cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    local_query "DELETE FROM messages WHERE body LIKE 'BEGIN:VCARD%' AND id > ${MAXID:-0};" >/dev/null 2>&1 || true
}
trap cleanup EXIT

info "Open the first conversation"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1
adb_ shell am start -n "$ACT" >/dev/null 2>&1
sleep 5
row=$(first_row || true)
[ -n "$row" ] && adb_ shell input tap ${row% *} ${row#* } && sleep 3 \
    || { bad "no conversation to open"; exit 1; }

info "The attach sheet offers '$contact_label'"
attach=$(center_of "Attach" || true)
[ -n "$attach" ] && adb_ shell input tap ${attach% *} ${attach#* } && sleep 2 \
    || bad "attach button not found"
if dump_ui >/dev/null && grep -q "text=\"$contact_label\"" "$TMP/ui.decoded.xml"; then
    ok "attach sheet lists '$contact_label'"
else
    bad "attach sheet has no '$contact_label' entry"
fi

info "Tapping it opens the system contact picker"
entry=$(center_of "$contact_label" || true)
[ -n "$entry" ] && adb_ shell input tap ${entry% *} ${entry#* } && sleep 4
focus=$(adb_ shell dumpsys window 2>/dev/null | grep -m1 mCurrentFocus || true)
case "$focus" in
    *com.android.contacts*) ok "the contacts picker came up" ;;
    *) bad "no contacts picker (focus: ${focus##*u0 })" ;;
esac

info "Picking '$PICKED' sends the card into the chat"
person=$(center_of "$PICKED" || true)
if [ -n "$person" ]; then
    adb_ shell input tap ${person% *} ${person#* }; sleep 4
    # The bubble's text carries real newlines once the dump's entities are
    # expanded, so the card is matched as one node rather than line by line.
    dump_ui >/dev/null
    if python3 - "$TMP/ui.xml" "$PICKED" <<'PY'
import re, sys
from html import unescape
xml = open(sys.argv[1]).read()
picked = sys.argv[2]
for m in re.finditer(r'text="([^"]*)"', xml):
    text = unescape(m.group(1))
    if (text.startswith("BEGIN:VCARD") and f"FN:{picked}" in text
            and "TEL;TYPE=CELL:+" in text and text.rstrip().endswith("END:VCARD")):
        sys.exit(0)
sys.exit(1)
PY
    then
        ok "the chat holds a vCard for $PICKED with its number"
    else
        bad "no vCard for $PICKED reached the chat"
    fi
else
    bad "no '$PICKED' row in the picker (run insert-demo-contacts.sh?)"
fi

info "Result"
echo "  PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && echo "=== OK ===" || echo "=== FAILED ==="
exit $((FAIL > 0))
