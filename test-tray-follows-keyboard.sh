#!/usr/bin/env bash
# The tray follows the keyboard's height, not a fixed number.
#
# Changing the display density changes this AVD's AOSP keyboard height in dp
# (it sizes itself as a fraction of the screen), which is a real keyboard
# resize: at 420 dpi the slot is ~295 dp, at 320 dpi it is ~375 dp.
#
# For each density the script types into the field, opens the tray, and asserts
#   * the tray is exactly as tall as the keyboard's slot (from the app's own
#     AttachTrayHeight log),
#   * the composer's field has not moved between the keyboard and the tray,
#   * the two densities really did produce different keyboard heights — the
#     check above would pass vacuously on a build that ignored the keyboard.
#
# Run: scripts/test-tray-follows-keyboard.sh
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
# Everything but the measured number goes to stderr: `measure` is captured by
# the caller, and a stray line would be read as the height.
ok()  { echo "  [PASS] $1" >&2; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1" >&2; FAIL=$((FAIL + 1)); }

ATTACH=$(res_string icon_attach)
SLOT_DEFAULT=""
SLOT_BIGGER=""

# The density is a device-wide setting and must be restored even on a crash.
restore_density() { adb_ shell wm density reset >/dev/null 2>&1; }
trap restore_density EXIT

bounds_of_edittext() {
    dump_ui >/dev/null 2>&1 || return 1
    grep -oE 'class="android.widget.EditText"[^>]*bounds="\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]"' \
        "$TMP/ui.xml" 2>/dev/null | head -1 | grep -oE '\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]'
}

# Types, opens the tray and leaves the slot height in MEASURED (a global: the
# counters and the assertions then stay in one shell).
MEASURED=""
measure() {
    local label="$1" before after moved tray target
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    adb_ shell am start -n "$ACT" >/dev/null 2>&1
    for i in $(seq 1 25); do
        dump_ui >/dev/null 2>&1
        grep -qF "$(res_string access_start_chat)" "$TMP/ui.xml" && break
        sleep 1
    done
    tap_contains "tray probe" >/dev/null
    for i in $(seq 1 25); do
        dump_ui >/dev/null 2>&1
        grep -qF "$ATTACH" "$TMP/ui.xml" && break
        sleep 1
    done

    adb_ shell logcat -c >/dev/null 2>&1
    tap_edittext >/dev/null
    sleep 3
    before=$(bounds_of_edittext)
    tap_text "$ATTACH" >/dev/null
    sleep 2
    after=$(bounds_of_edittext)

    local y1 y2
    y1=$(sed -E 's/^\[([0-9]+),([0-9]+)\].*/\2/' <<< "$before")
    y2=$(sed -E 's/^\[([0-9]+),([0-9]+)\].*/\2/' <<< "$after")
    moved=$(( y2 - y1 )); [ "$moved" -lt 0 ] && moved=$(( -moved ))

    local log
    log=$(adb_ shell logcat -d 2>/dev/null | grep AttachTrayHeight | grep "tray=" | tail -1)
    tray=$(sed -E 's/.*tray=([0-9.]+).*/\1/' <<< "$log" | cut -d. -f1)
    target=$(sed -E 's/.*target=([0-9.]+).*/\1/' <<< "$log" | cut -d. -f1)

    # stdout is the captured number; the human line goes to the log.
    echo "  [$label] field moved ${moved}px, tray ${tray}dp for a ${target}dp slot" >&2
    if [ "$moved" -le 24 ]; then
        ok "$label: the composer holds still while the keyboard and tray swap"
    else
        bad "$label: the composer jumped ${moved}px"
    fi
    if [ -n "$tray" ] && [ "$tray" = "$target" ] && [ "$tray" != "0" ]; then
        ok "$label: the tray is exactly the keyboard's slot (${tray}dp)"
    else
        bad "$label: tray ${tray:-?}dp against a ${target:-?}dp keyboard"
    fi
    MEASURED="$tray"
}

# ── default density ─────────────────────────────────────────────────────────
restore_density
sleep 3
measure "420dpi"
SLOT_DEFAULT="$MEASURED"
echo

# ── a keyboard that is a different size in dp ───────────────────────────────
adb_ shell wm density 320 >/dev/null 2>&1
sleep 4
measure "320dpi"
SLOT_BIGGER="$MEASURED"
echo

restore_density
sleep 2

if [ -n "$SLOT_DEFAULT" ] && [ -n "$SLOT_BIGGER" ] &&
   [ $(( SLOT_BIGGER - SLOT_DEFAULT )) -gt 20 ]; then
    ok "the keyboard really did resize (${SLOT_DEFAULT}dp -> ${SLOT_BIGGER}dp), and the tray followed"
else
    bad "the keyboard height did not change, so the follow-through is unproven"
fi

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
