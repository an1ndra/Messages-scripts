#!/usr/bin/env bash
# Regression: the redesigned UI's "Delay before sending" picker must render
# every delay option inside the dialog.
#
# Bug (#): each option row used Modifier.fillMaxSize(), so every row claimed the
# dialog's whole height and all choices but the first were clipped off-screen —
# the dialog showed only "1s". The rows are now fillMaxWidth().
#
# Run: scripts/test-delay-dialog-options.sh
set -uo pipefail
cd "$(dirname "$0")"
source ./env.sh

PASS=0
FAIL=0
pass() { echo "[PASS] $*"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $*"; FAIL=$((FAIL + 1)); }

PREFS="/data/data/$PKG/shared_prefs/messages_settings.xml"
BACKUP="$TMP/delay-dialog-settings.bak.xml"

# Exact-text variant of layout_has: an option label ("5s") must be a node's own
# text, not a substring of the "5s before sending" subtitle the dialog covers.
layout_has_exact() {
    layout_json && python3 - "$TMP/layout.json" "$1" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
q = sys.argv[2]
def walk(node):
    if isinstance(node, list):
        return any(walk(c) for c in node)
    if isinstance(node, dict):
        for key in ("text", "content-desc", "contentDesc"):
            if node.get(key) == q:
                return True
        return any(walk(c) for key in ("content", "children") for c in (node.get(key) or []))
    return False
sys.exit(0 if walk(data) else 1)
PY
}

info "Backing up current settings"
adb_ shell "run-as $PKG cat $PREFS" > "$BACKUP" 2>/dev/null || true

restore() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    if [ -s "$BACKUP" ]; then
        adb_ shell "run-as $PKG sh -c 'cat > $PREFS'" < "$BACKUP" >/dev/null 2>&1 || true
    fi
}
trap restore EXIT

info "Enable new UI + delayed sending"
adb_ shell am force-stop "$PKG"
cat > "$TMP/delay-dialog-settings.xml" <<XML
<?xml version="1.0" encoding="utf-8" standalone="yes" ?>
<map>
    <boolean name="first_import_done" value="true" />
    <boolean name="use_new_ui" value="true" />
    <boolean name="delayed_sending_enabled" value="true" />
    <int name="delay_seconds" value="5" />
</map>
XML
adb_ shell "run-as $PKG sh -c 'cat > $PREFS'" < "$TMP/delay-dialog-settings.xml"

info "Launch app"
adb_ shell am start -n "$ACT" >/dev/null
sleep 4

# The Settings avatar in the conversation-list top bar exposes no text/content
# description, so it can only be located by position on the reference 1080x2400
# screen.
info "Open Settings (avatar) -> Inbox settings"
adb_ shell input tap 976 164
sleep 2
if tap_layout "Inbox settings"; then
    pass "opened Inbox settings"
else
    fail "could not open Inbox settings"
fi
sleep 2

info "Open the Delay seconds picker"
if scroll_to_layout "Delay seconds" && tap_layout "Delay seconds"; then
    pass "tapped Delay seconds"
else
    fail "could not reach the Delay seconds row"
fi
sleep 2

info "Assert the dialog lists every delay option"
if ! layout_json; then
    fail "could not dump the layout"
else
    if layout_has "Delay before sending"; then
        pass "delay dialog is open"
    else
        fail "delay dialog did not open"
    fi
    if layout_has "Choose how long to wait before sending:"; then
        pass "dialog shows its explanatory hint"
    else
        fail "dialog hint missing"
    fi

    # Every option must be present as its own node; the clipped bug leaves only
    # "1s" on screen.
    for opt in 1s 3s 5s 10s 30s; do
        if layout_has_exact "$opt"; then
            pass "option $opt present"
        else
            fail "option $opt missing (options clipped?)"
        fi
    done
fi

adb_ shell input keyevent KEYCODE_BACK >/dev/null 2>&1 || true

echo
echo "passed=$PASS failed=$FAIL"
exit $(( FAIL > 0 ))
