#!/usr/bin/env bash
# Regression: "Unread at top" is OFF by default, so the inbox is strictly
# newest-first (matching QUIK). With it on, an older unread thread can sit above
# a newer read one, hiding the actual latest message behind an unnecessary
# scroll. The toggle must still work when the user opts in.
#
# On a fresh install the preference is absent, so the switch's own state is what
# proves the default — not the absence of a "true" entry.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

PREFS="/data/data/$PKG/shared_prefs/messages_settings.xml"
LABEL="Unread at top"

pref_unread() {
    adb_ shell "grep -oE 'name=\"unread_at_top_enabled\" value=\"[^\"]*\"' $PREFS" 2>/dev/null | tr -d '\r'
}

# "checked" | "unchecked" for the switch on the row titled $1, read from the
# `android` CLI layout (uiautomator is unreliable against this Compose screen).
switch_state() {
    layout_json || return 1
    python3 - "$TMP/layout.json" "$1" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
label = sys.argv[2]
label_y = [None]
switches = []
def walk(node):
    if isinstance(node, list):
        for child in node: walk(child)
    elif isinstance(node, dict):
        center = node.get("center")
        if center:
            y = int(center.strip("[]").split(",")[1])
            text = node.get("text")
            if isinstance(text, str) and text == label:
                label_y[0] = y
            if "CHECKABLE" in (node.get("interactions") or []):
                switches.append((y, node.get("state") or []))
        for key in ("content", "children"):
            for child in (node.get(key) or []): walk(child)
walk(data)
if label_y[0] is None:
    sys.exit(2)
best = min(switches, key=lambda s: abs(s[0] - label_y[0]), default=None)
if best is None or abs(best[0] - label_y[0]) > 120:
    sys.exit(3)
print("checked" if any(str(s).upper() == "CHECKED" for s in best[1]) else "unchecked")
PY
}

# Flip the switch only when it is not already in the wanted state.
set_switch() {
    local want="$1" state
    state=$(switch_state "$LABEL") || return 1
    [ "$state" = "$want" ] && return 0
    local c; c=$(layout_center "$LABEL") || return 1
    adb_ shell input tap 937 "${c#* }"
    sleep 1
}

close_documents_ui

info "Fresh install: unread-at-top defaults off"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1
adb_ shell pm clear "$PKG" >/dev/null 2>&1
adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1
for p in READ_SMS RECEIVE_SMS SEND_SMS POST_NOTIFICATIONS; do
    adb_ shell pm grant "$PKG" android.permission.$p 2>/dev/null
done
adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null 2>&1; sleep 6
scroll_to_layout "$LABEL" || { bad "Unread at top row not found"; exit 1; }

STATE=$(switch_state "$LABEL")
if [ "$STATE" = "unchecked" ]; then ok "switch is off by default"; else bad "switch default is '$STATE', expected unchecked"; fi
[ "$(pref_unread)" != 'name="unread_at_top_enabled" value="true"' ] \
    && ok "no stored 'true' default" || bad "default preference is true"

info "Opting in still works"
set_switch checked
[ "$(switch_state "$LABEL")" = "checked" ] && ok "switch turns on" || bad "switch did not turn on"
[ "$(pref_unread)" = 'name="unread_at_top_enabled" value="true"' ] && ok "preference stored true" || bad "preference not stored true"
set_switch unchecked
[ "$(switch_state "$LABEL")" = "unchecked" ] && ok "switch turns off" || bad "switch did not turn off"
[ "$(pref_unread)" = 'name="unread_at_top_enabled" value="false"' ] && ok "preference stored false" || bad "preference not stored false"

echo ""
info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
