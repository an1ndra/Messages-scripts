#!/usr/bin/env bash
# Home-search scope selector: the five scopes are pills in one row (the selected
# scope is the fully rounded, primary-filled one; the rest keep the row's
# connected ends, no tick icon). Roundness and fill are pixel properties a
# uiautomator dump cannot see — those are pinned by SearchScopePillTest — so this
# script covers what a dump can: the five scopes exist, the row adapts to the
# window (stretched equal segments on a wide window, a scrolling strip on a
# phone), the options stay compact, and exactly one scope is selected as it is
# switched.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

DENSITY=$(adb_ shell wm density | tr -dc '0-9')
[ -n "$DENSITY" ] || DENSITY=440
px() { echo $(( DENSITY * $1 / 160 )); }

# Print "<x1> <y1> <x2> <y2>" of the clickable scope pill labelled $1.
pill_bounds() {
    python3 - "$TMP/ui.xml" "$1" <<'PY'
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
label = sys.argv[2]

def box(n):
    try:
        a, c = (n.get("bounds") or "").split("][")
        x1, y1 = (int(v) for v in a.strip("[").split(","))
        x2, y2 = (int(v) for v in c.strip("]").split(","))
        return x1, y1, x2, y2
    except ValueError:
        return None

for n in root.iter("node"):
    if n.get("clickable") != "true" and n.get("selected") != "true":
        continue
    if label not in [(m.get("text") or "").strip() for m in n.iter("node")]:
        continue
    b = box(n)
    if b:
        print(*b)
        break
PY
}

# "left right height count" of the pill row: the outer margins, the row's
# vertical extent and how many pills it holds. Works for both layouts.
row_metrics() {
    python3 - "$TMP/ui.xml" <<'PY'
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
labels = ["All", "Contacts", "Messages", "Unread", "Starred"]

def box(n):
    try:
        a, c = (n.get("bounds") or "").split("][")
        x1, y1 = (int(v) for v in a.strip("[").split(","))
        x2, y2 = (int(v) for v in c.strip("]").split(","))
        return x1, y1, x2, y2
    except ValueError:
        return None

screen_w = 0
pills = {}
for n in root.iter("node"):
    if n.get("clickable") != "true" and n.get("selected") != "true":
        continue
    texts = [(m.get("text") or "").strip() for m in n.iter("node")]
    b = box(n)
    if not b:
        continue
    screen_w = max(screen_w, b[2])
    for label in labels:
        if label in texts and label not in pills:
            pills[label] = b
if not pills:
    sys.exit(0)
left = min(b[0] for b in pills.values())
right = max(b[2] for b in pills.values())
top = min(b[1] for b in pills.values())
bottom = max(b[3] for b in pills.values())
print(left, screen_w - right, bottom - top, len(pills))
PY
}

selected_label() {
    python3 - "$TMP/ui.xml" <<'PY'
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
for n in root.iter("node"):
    if n.get("selected") == "true":
        print(" ".join(t for t in ((m.get("text") or "").strip() for m in n.iter("node")) if t))
        break
PY
}

tap_scope() {
    local label="$1" c
    c=$(center_of "$label") || { bad "scope '$label' not on screen"; return 1; }
    adb_ shell input tap $c
    sleep 1; dump_ui >/dev/null 2>&1 || true
}

info "Open the home search"
adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 5
if ! tap_text "Search" >/dev/null 2>&1; then bad "no Search button"; exit 1; fi
sleep 2
dump_ui >/dev/null 2>&1 || { bad "uiautomator dump failed"; exit 1; }

info "Every scope is a pill in the one row"
METRICS=$(row_metrics)
if [ -z "$METRICS" ]; then bad "no scope pills on the search screen"; exit 1; fi
COUNT_PILLS=$(echo "$METRICS" | awk '{print $4}')
if [ "$COUNT_PILLS" = "5" ]; then ok "all five scopes are rendered"; else bad "expected 5 pills, saw $COUNT_PILLS"; fi

info "The row adapts to the window: equal side margins either way"
ROW_LEFT=$(echo "$METRICS" | awk '{print $1}')
ROW_RIGHT=$(echo "$METRICS" | awk '{print $2}')
DELTA=$(( ROW_LEFT - ROW_RIGHT ))
DELTA=${DELTA#-}
# The nodes report touch bounds, which pad the paint by a few px on one side.
if [ "$DELTA" -le "$(px 8)" ]; then
    ok "outer margins match (left ${ROW_LEFT}px, right ${ROW_RIGHT}px)"
else
    bad "outer margins differ by ${DELTA}px (left ${ROW_LEFT}px, right ${ROW_RIGHT}px)"
fi

info "The options stay a compact single row: at most 62dp tall"
HEIGHT=$(echo "$METRICS" | awk '{print $3}')
if [ -n "$HEIGHT" ] && [ "$HEIGHT" -le "$(px 62)" ]; then
    ok "scope row is ${HEIGHT}px tall (<= $(px 62)px)"
else
    bad "scope row is ${HEIGHT:-unknown}px tall, wanted <= $(px 62)px"
fi

info "Every scope stays reachable"
SAMPLE=$(pill_bounds Contacts)
ROW_Y=$(( ($(echo "$SAMPLE" | awk '{print $2}') + $(echo "$SAMPLE" | awk '{print $4}')) / 2 ))
adb_ shell input swipe 950 "$ROW_Y" 150 "$ROW_Y" 300
sleep 1; dump_ui >/dev/null 2>&1 || true
for label in Messages Unread Starred; do
    if [ -n "$(pill_bounds "$label")" ]; then ok "pill '$label' reachable"; else bad "pill '$label' not reachable"; fi
done
adb_ shell input swipe 150 "$ROW_Y" 950 "$ROW_Y" 300
sleep 1; dump_ui >/dev/null 2>&1 || true

info "Exactly one scope is selected, and All starts that way"
COUNT=$(grep -c 'selected="true"' "$TMP/ui.decoded.xml")
if [ "$COUNT" = "1" ]; then ok "exactly one selected node ($COUNT)"; else bad "expected 1 selected node, got $COUNT"; fi
SEL=$(selected_label)
if [ "$SEL" = "All" ]; then ok "All starts selected"; else bad "expected 'All' selected, got '$SEL'"; fi

info "Selecting a scope moves the selection"
for label in Unread Contacts All; do
    tap_scope "$label" || continue
    SEL=$(selected_label)
    if [ "$SEL" = "$label" ]; then ok "'$label' is selected"; else bad "expected '$label' selected, got '$SEL'"; fi
    COUNT=$(grep -c 'selected="true"' "$TMP/ui.decoded.xml")
    if [ "$COUNT" = "1" ]; then ok "still exactly one selected"; else bad "selected count is $COUNT"; fi
    if [ -z "$(pill_bounds "$label")" ]; then bad "'$label' lost its pill when selected"; fi
done

echo ""
info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
