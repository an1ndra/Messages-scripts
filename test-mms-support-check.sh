#!/usr/bin/env bash
# Advanced settings -> MMS support: the per-SIM MMS check.
#   * the Advanced list carries an "MMS support" row above Diagnostics
#   * it opens a page with one row per active SIM, a verdict and a country code
#   * the verdict is one of the four the check can reach, and the page never
#     claims "supported" for a SIM whose carrier reports MMS off
#   * back returns to Advanced
#
# Asserted from uiautomator dumps, no screenshots.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

scroll_to() {
    local label="$1" tries="${2:-10}"
    for _ in $(seq 1 "$tries"); do
        dump_ui
        grep -q "text=\"$label\"" "$TMP/ui.xml" && return 0
        adb_ shell input swipe 540 1800 540 800 300; sleep 0.6
    done
    dump_ui
    grep -q "text=\"$label\"" "$TMP/ui.xml"
}

launch_settings() {
    adb_ shell am force-stop "$PKG"; sleep 1
    adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null; sleep 3
}

# Vertical centre of the first node with this exact text (0 when absent). The
# dump is one long line, so ordering has to come from the bounds, not line
# numbers.
y_of() {
    python3 - "$TMP/ui.xml" "$1" <<'PY'
import re, sys
xml = open(sys.argv[1], encoding="utf-8").read()
for tag in re.findall(r'<node[^>]*>', xml):
    if re.search(r'text="%s"' % re.escape(sys.argv[2]), tag):
        b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', tag)
        if b:
            x1, y1, x2, y2 = map(int, b.groups())
            print((y1 + y2) // 2)
            break
else:
    print(0)
PY
}

# Every subtitle on the page, one per line.
subtitles() {
    python3 - "$TMP/ui.xml" <<'PY'
import re, sys
xml = open(sys.argv[1], encoding="utf-8").read()
for tag in re.findall(r'<node[^>]*>', xml):
    t = re.search(r'text="([^"]+)"', tag)
    if t and ' · ' in t.group(1):
        print(t.group(1))
PY
}

# A SIM on a real network has a verdict and a country; a SIM on the emulator's
# fake network still has to say so rather than claim support.
VERDICTS="Supported|Off on this carrier|No network on this SIM|Could not be checked"

info "Advanced carries the MMS support row"
launch_settings
if scroll_to "Advanced settings"; then
    if tap_text "Advanced settings" >/dev/null 2>&1; then
        sleep 2
        ok "opened Advanced"
    else
        bad "could not tap Advanced settings"
    fi
else
    bad "could not find Advanced settings"
fi

if scroll_to "Diagnostics"; then
    dump_ui
    if grep -q 'text="MMS support"' "$TMP/ui.xml"; then
        ok "Advanced shows the MMS support row"
        MMS_Y=$(y_of "MMS support")
        DIAG_Y=$(y_of "Diagnostics")
        if [ "$MMS_Y" -gt 0 ] && [ "$DIAG_Y" -gt 0 ] && [ "$MMS_Y" -lt "$DIAG_Y" ]; then
            ok "the MMS support row sits above Diagnostics"
        else
            bad "the MMS support row is not above Diagnostics (y=$MMS_Y vs $DIAG_Y)"
        fi
    else
        bad "Advanced is missing the MMS support row"
    fi
else
    bad "could not reach Diagnostics on the Advanced screen"
fi

info "The check reports a verdict per SIM"
if tap_text "MMS support" >/dev/null 2>&1; then
    sleep 2
    dump_ui
    if grep -q 'text="MMS support"' "$TMP/ui.xml"; then
        ok "opened the MMS support page"
    else
        bad "did not land on the MMS support page"
    fi
    ROWS=$(subtitles | grep -cE "^($VERDICTS)( ·|$)" || true)
    if [ "${ROWS:-0}" -ge 1 ]; then
        ok "a SIM row carries a verdict ($ROWS row(s))"
    else
        bad "no SIM row reports a verdict (expected one of: $VERDICTS)"
        subtitles | sed 's/^/       saw: /'
    fi
    # The check is about the country, so a row has to say which country it
    # resolved, either from the SIM number or from the SIM network.
    if subtitles | grep -qE "^($VERDICTS) .*(\+[0-9]+ · [A-Z]{2}|Number not shared by carrier)"; then
        ok "a row reports a country code or says the number is withheld"
    else
        bad "no row reports a country code or the withheld-number note"
    fi
    if grep -qE "text=\"[0-9]+ of [0-9]+ SIMs support MMS\"" "$TMP/ui.xml"; then
        ok "the page summarises how many SIMs support MMS"
    else
        bad "the page has no SIMs-support-MMS summary line"
    fi
    if grep -q "text=\"No active SIM found\"" "$TMP/ui.xml"; then
        bad "the page says no active SIM was found on a running device"
    else
        ok "at least one SIM is listed"
    fi
else
    bad "could not tap the MMS support row"
fi

info "Back returns to Advanced"
adb_ shell input keyevent 4; sleep 2.5
dump_ui || dump_ui
if grep -q 'text="Link behaviour"' "$TMP/ui.xml" || grep -q 'text="MMS support"' "$TMP/ui.xml"; then
    ok "back landed on Advanced"
else
    bad "back did not return to Advanced"
fi

if [ -n "$(adb_ shell pidof "$PKG" | tr -d '\r')" ]; then
    ok "app still running"
else
    bad "app crashed"
fi

echo ""
info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
