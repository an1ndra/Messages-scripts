#!/usr/bin/env bash
# New UI, Notifications page: "Notification sound" and "Reply action" must sit
# in the same group, with no card boundary between them.
#
# The two rows are neighbours, but a SettingsGroup boundary used to split them
# into two blocks. A card boundary is visible in a dump as a gap between row
# bounds: rows in one group are spaced by ROW_GAP, and a gap between groups is
# much larger, so the gap directly under the sound row is what this measures.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

open_notifications() {
    # A previous run may have left Android's own notification settings on top.
    adb_ shell am force-stop com.android.settings >/dev/null 2>&1
    adb_ shell am force-stop "$PKG"; sleep 1
    adb_ shell am start -n "$ACT" --activity-clear-task --ez open_settings true >/dev/null 2>&1; sleep 6
    # Settings -> Advanced settings -> Notifications. The first "Notifications"
    # row on the Settings list opens Android's own notification settings, not
    # this screen, so the hop through Advanced settings is required.
    local i
    for i in 1 2 3 4 5 6; do
        layout_center_exact "Advanced settings" >/dev/null 2>&1 && break
        adb_ shell input swipe 540 1800 540 700 400; sleep 1
    done
    tap_layout_exact "Advanced settings" >/dev/null 2>&1 || return 1
    sleep 3
    tap_layout_exact "Notifications" >/dev/null 2>&1 || return 1
    sleep 3
    return 0
}

info "Open Settings -> Notifications (new UI)"
if ! open_notifications; then bad "could not open the Notifications page"; exit 1; fi
dump_ui >/dev/null 2>&1

# bottom y of each row label, by text
y_of() { # $1 = exact label text
    python3 - "$TMP/ui.xml" "$1" <<'PY'
import re, sys
d = open(sys.argv[1], encoding="utf-8", errors="replace").read()
m = re.search(r'text="' + re.escape(sys.argv[2]) + r'"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', d)
print(m.group(4) if m else "")
PY
}

for label in "Send sound" "Receive sound" "Notification sound" "Reply action" "Mark as read" "Delete"; do
    y=$(y_of "$label")
    [ -n "$y" ] && ok "row present: $label (bottom y=$y)" || bad "row missing: $label"
done

info "The gap under 'Notification sound' must match the in-group row gap"
read_ys() {
    SND=$(y_of "Receive sound")
    NS=$(y_of "Notification sound")
    RP=$(y_of "Reply action")
    MR=$(y_of "Mark as read")
    [ -n "$SND" ] && [ -n "$NS" ] && [ -n "$RP" ] && [ -n "$MR" ] || return 1
    echo "$((NS - SND)) $((RP - NS)) $((MR - RP))"
}
GAPS=$(read_ys) || { bad "could not read row positions"; exit 1; }
echo "    gaps: $GAPS"
G1=$(echo "$GAPS" | cut -d' ' -f1)
G2=$(echo "$GAPS" | cut -d' ' -f2)
G3=$(echo "$GAPS" | cut -d' ' -f3)

# A card boundary adds roughly double the row height on top of the row gap.
if [ "$G2" -gt 0 ] && [ "$G1" -gt 0 ]; then
    DIFF=$(( G2 - G1 )); [ "$DIFF" -lt 0 ] && DIFF=$(( -DIFF ))
    if [ "$DIFF" -le 12 ]; then
        ok "'Notification sound' -> 'Reply action' gap ($G2) matches the in-group gap ($G1): same group"
    else
        bad "'Notification sound' -> 'Reply action' gap ($G2) is $DIFFpx larger than in-group ($G1): split across groups"
    fi
fi

echo ""
info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))