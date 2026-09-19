#!/usr/bin/env bash
# Accessibility mode regression:
#   - Conversation rows expose a screen-reader description (TalkBack); before
#     the change the list had no content-desc on rows.
#   - Advanced holds an "Accessibility mode" master switch, default OFF. While
#     OFF the "Accessibility options" row is absent and every option is ignored.
#   - Master ON reveals the Accessibility screen with Font size / Bold text /
#     High contrast / Larger touch targets / Reduce motion.
#   - Each option persists to shared_prefs and font size visibly scales text.
#   - All settings are restored to defaults and the master left OFF.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0; SKIP=0
ok()   { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad()  { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
skip() { echo "[SKIP] $1"; SKIP=$((SKIP + 1)); }
info() { echo -e "\n=== $* ==="; }

pref_get() {
    adb_ shell "run-as $PKG cat shared_prefs/messages_settings.xml" 2>/dev/null \
        | grep -oE "name=\"$1\" value=\"[^\"]*\"" | grep -oE 'value="[^"]*"' | cut -d'"' -f2
}
pref_is() { [ "$(pref_get "$1")" = "$2" ]; }

# Swipe up within a settings list until the label is visible (bounded).
scroll_to() {
    local label="$1" tries="${2:-10}"
    for _ in $(seq 1 "$tries"); do
        dump_ui
        grep -q "text=\"$label\"" "$TMP/ui.xml" && return 0
        adb_ shell input swipe 500 1900 500 900 300; sleep 0.5
    done
    dump_ui
    grep -q "text=\"$label\"" "$TMP/ui.xml"
}

ensure_switch() {
    local label="$1" pref="$2" want="$3" cur=off
    pref_is "$pref" true && cur=on
    if [ "$cur" != "$want" ]; then
        tap_switch_near "$label" || return 1
        sleep 0.7
    fi
}

# Height of the first node with the exact text, in px (0 when missing).
node_height() {
    local b y1 y2
    b=$(grep -oE "text=\"$1\"[^>]*bounds=\"\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]\"" "$TMP/ui.xml" \
        | grep -oE '\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]' | head -1)
    [ -z "$b" ] && { echo 0; return; }
    y1=$(sed -E 's/\[[0-9]+,([0-9]+)\].*/\1/' <<< "$b")
    y2=$(sed -E 's/.*\]\[[0-9]+,([0-9]+)\]/\1/' <<< "$b")
    echo $((y2 - y1))
}

launch_settings() {
    adb_ shell am force-stop "$PKG"; sleep 1
    adb_ shell am start -n "$ACT" --ez open_settings true; sleep 3
}
open_advanced() {
    scroll_to "Advanced"
    tap_text "Advanced" || tap_contains "Advanced"
    sleep 1.5
}

info "Phase 1: conversation rows expose screen-reader descriptions"
launch_settings
adb_ shell input keyevent 4; sleep 1.2
if dump_ui; then
    ROWS=$(grep -oE 'content-desc="[^"]+"' "$TMP/ui.xml" \
        | grep -cE '^content-desc="[0-9(]')
    if [ "$ROWS" -gt 0 ]; then
        ok "conversation rows carry a TalkBack description ($ROWS rows)"
    elif grep -qi "no conversations\|start a conversation" "$TMP/ui.xml"; then
        skip "conversation list is empty; cannot check row descriptions"
    else
        bad "conversation rows have no TalkBack description"
    fi
    # The description must live on the same node TalkBack focuses/activates,
    # not on a non-focusable child (regression: row desc was on a split node).
    ROW_NODE=$(ui_tags | grep 'content-desc="[0-9(]' | grep 'clickable="true"' | head -1)
    if [ -n "$ROW_NODE" ]; then
        ok "row description is on the clickable/activatable node"
    else
        bad "row description is not on a clickable node (TalkBack would skip it)"
    fi
else
    bad "could not dump the conversation list"
fi

info "Master switch gates the Accessibility screen"
launch_settings
open_advanced
if scroll_to "Accessibility mode"; then
    ok "Advanced shows the Accessibility mode switch"
else
    bad "Accessibility mode switch not found in Advanced"
fi
ensure_switch "Accessibility mode" a11y_enabled off

dump_ui
if grep -q 'text="Accessibility options"' "$TMP/ui.xml"; then
    bad "Accessibility options visible while master is OFF"
else
    ok "Accessibility options hidden while master is OFF"
fi

ensure_switch "Accessibility mode" a11y_enabled on
dump_ui
if grep -q 'text="Accessibility options"' "$TMP/ui.xml"; then
    ok "master ON reveals Accessibility options"
else
    bad "master ON did not reveal Accessibility options"
fi

tap_text "Accessibility options"; sleep 1.5
dump_ui
for label in "Font size" "Bold text" "High contrast" "Larger touch targets" "Reduce motion"; do
    if grep -q "text=\"$label\"" "$TMP/ui.xml"; then
        ok "Accessibility screen shows '$label'"
    else
        bad "Accessibility screen missing '$label'"
    fi
done

info "Options persist to shared_prefs"
ensure_switch "Bold text" a11y_bold on
ensure_switch "High contrast" a11y_high_contrast on
ensure_switch "Reduce motion" a11y_reduce_motion on
ensure_switch "Larger touch targets" a11y_large_touch on
for p in a11y_bold a11y_high_contrast a11y_reduce_motion a11y_large_touch; do
    if pref_is "$p" true; then ok "$p persisted"; else bad "$p did not persist"; fi
done

info "Font size scales text and persists"
dump_ui
H_BEFORE=$(node_height "Bold text")
tap_text "Font size"; sleep 1
tap_text "Largest (130%)"; sleep 0.6
tap_text "OK"; sleep 1.2
if pref_is a11y_font_scale 130; then ok "font scale persisted as 130"; else bad "font scale not 130"; fi
dump_ui
H_AFTER=$(node_height "Bold text")
if [ "$H_AFTER" -gt "$H_BEFORE" ] && [ "$H_BEFORE" -gt 0 ]; then
    ok "larger font visibly grew text node ($H_BEFORE -> $H_AFTER px)"
else
    bad "font change did not grow text node ($H_BEFORE -> $H_AFTER px)"
fi

info "Restore defaults"
tap_text "Font size"; sleep 1
tap_text "Default (100%)"; sleep 0.5
tap_text "OK"; sleep 1
ensure_switch "Bold text" a11y_bold off
ensure_switch "High contrast" a11y_high_contrast off
ensure_switch "Reduce motion" a11y_reduce_motion off
ensure_switch "Larger touch targets" a11y_large_touch off
adb_ shell input keyevent 4; sleep 1.2
scroll_to "Accessibility mode"
ensure_switch "Accessibility mode" a11y_enabled off
for p in a11y_enabled a11y_bold a11y_high_contrast a11y_reduce_motion a11y_large_touch; do
    if pref_is "$p" false; then ok "$p restored to false"; else bad "$p not restored"; fi
done
if pref_is a11y_font_scale 100; then ok "a11y_font_scale restored to 100"; else bad "font scale not restored"; fi

if [ -n "$(adb_ shell pidof "$PKG" | tr -d '\r')" ]; then
    ok "app still running"
else
    bad "app crashed"
fi

echo ""
info "Results: $PASS passed, $FAIL failed, $SKIP skipped"
exit $((FAIL > 0))
