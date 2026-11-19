#!/usr/bin/env bash
# Issue #480: the tray offers a contact, the system contact picker opens, and
# picking one sends that person's card into the chat.
#
# What it asserts, in the order a finger does it:
#   * the tray lists a Contact tile and it opens the system contact picker,
#   * picking someone stores the message as a contact card (a .vcf attachment),
#     not as text with the vCard pasted into the body,
#   * the chat draws it as a card — the name and number, not BEGIN:VCARD.
#
# A vCard pasted into the body is what a text message carries: the receiving
# phone shows the properties, not a contact. Only the attachment form is a card.
#
# Run: scripts/test-contact-card.sh          (add -v to see every dump)
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
PICKED="Alex"                     # a demo contact, from insert-demo-contacts.sh

# Runtime grants first: a permission dialog on top reads as "the tile did
# nothing", and a denied READ_CONTACTS leaves the picker unable to hand back a
# number at all.
adb_su "pm grant $PKG android.permission.READ_CONTACTS" >/dev/null 2>&1 \
    || adb_ shell pm grant "$PKG" android.permission.READ_CONTACTS >/dev/null 2>&1

MAXID=$(local_query "SELECT IFNULL(MAX(id),0) FROM messages;")
cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    local_query "DELETE FROM messages WHERE id > ${MAXID:-0} AND (media_type = 'contact' OR body LIKE 'BEGIN:VCARD%');" >/dev/null 2>&1 || true
}
trap cleanup EXIT

info "Open the first conversation"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1
adb_ shell am start -W -n "$ACT" >/dev/null 2>&1
sleep 3
row=$(first_row || true)
[ -n "$row" ] && adb_ shell input tap ${row% *} ${row#* } && sleep 3 \
    || { bad "no conversation to open"; exit 1; }

info "The tray offers '$contact_label'"
attach=$(center_of "Attach" || true)
[ -n "$attach" ] && adb_ shell input tap ${attach% *} ${attach#* } && sleep 2 \
    || bad "attach button not found"
if dump_ui >/dev/null && grep -q "text=\"$contact_label\"" "$TMP/ui.decoded.xml"; then
    ok "the attach tray lists '$contact_label'"
else
    bad "the tray has no '$contact_label' tile"
fi

info "Tapping it opens the system contact picker"
entry=$(center_of "$contact_label" || true)
[ -n "$entry" ] && adb_ shell input tap ${entry% *} ${entry#* } && sleep 4
focus=$(adb_ shell dumpsys window 2>/dev/null | grep -m1 mCurrentFocus || true)
case "$focus" in
    *com.android.contacts*) ok "the contacts picker came up" ;;
    *) bad "no contacts picker (focus: ${focus##*u0 })" ;;
esac

info "Picking '$PICKED' sends a card"
person=$(center_of "$PICKED" || true)
if [ -z "$person" ]; then
    bad "no '$PICKED' row in the picker (run scripts/insert-demo-contacts.sh)"
    echo; echo "  PASS=$PASS FAIL=$FAIL"; exit 1
fi
adb_ shell input tap ${person% *} ${person#* }; sleep 4

# ── the stored message is a card, not text ──────────────────────────────────
row=$(local_query "SELECT media_type || '|' || media_uri FROM messages WHERE id > ${MAXID:-0} ORDER BY id DESC LIMIT 1;")
kind=${row%%|*}
uri=${row#*|}
if [ "$kind" = "contact" ]; then
    ok "the message is stored as a contact card"
else
    bad "the message is stored as '$kind', not a contact card"
fi
case "$uri" in
    *.vcf) ok "the card travels as a .vcf attachment" ;;
    *) bad "no .vcf attachment behind the card (uri: ${uri:-none})" ;;
esac

# ── the chat draws it as a card ─────────────────────────────────────────────
dump_ui >/dev/null
if python3 - "$TMP/ui.xml" "$PICKED" <<'PY'
import re, sys
from html import unescape
xml = open(sys.argv[1]).read()
picked = sys.argv[2]
texts = [unescape(m.group(1)) for m in re.finditer(r'text="([^"]*)"', xml)]
has_name = any(t.strip() == picked for t in texts)
has_number = any(t.strip().startswith("+") and t.strip()[1:].isdigit() for t in texts)
raw = any(t.strip().startswith("BEGIN:VCARD") for t in texts)
sys.exit(0 if (has_name and has_number and not raw) else 1)
PY
then
    ok "the chat shows a card for $PICKED: name and number, no raw properties"
else
    bad "the chat did not draw a card (raw vCard text, or no number)"
fi

info "Result"
echo "  PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && echo "=== OK ===" || echo "=== FAILED ==="
exit $((FAIL > 0))
