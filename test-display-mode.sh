#!/usr/bin/env bash
# Guard for issue #192: opening the app must not change the display resolution
# or density. The original code forced the max-refresh display mode, which on
# some panels also carried a different resolution -> the whole UI rescaled.
#
# The AVD exposes a single display mode, so this asserts the observable no-op
# (size + density unchanged). The selection logic (never pick a
# different-resolution mode) is covered by DisplayModeSelectorTest.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

SIZE_BEFORE=$(adb_ shell wm size | tr -d '\r')
DENS_BEFORE=$(adb_ shell wm density | tr -d '\r')
MODE_BEFORE=$(adb_ shell dumpsys display 2>/dev/null | grep -m1 -oE 'mActiveModeId=[0-9]+' | head -1)

info "Launch app"
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 3

SIZE_AFTER=$(adb_ shell wm size | tr -d '\r')
DENS_AFTER=$(adb_ shell wm density | tr -d '\r')
MODE_AFTER=$(adb_ shell dumpsys display 2>/dev/null | grep -m1 -oE 'mActiveModeId=[0-9]+' | head -1)

info "Display unchanged after launch"
if [ "$SIZE_BEFORE" = "$SIZE_AFTER" ]; then
    ok "resolution unchanged ($SIZE_AFTER)"
else
    bad "resolution changed: '$SIZE_BEFORE' -> '$SIZE_AFTER'"
fi
if [ "$DENS_BEFORE" = "$DENS_AFTER" ]; then
    ok "density unchanged ($DENS_AFTER)"
else
    bad "density changed: '$DENS_BEFORE' -> '$DENS_AFTER'"
fi
if [ -z "$MODE_BEFORE" ] || [ "$MODE_BEFORE" = "$MODE_AFTER" ]; then
    ok "active display mode unchanged (${MODE_AFTER:-unknown})"
else
    bad "active display mode changed: '$MODE_BEFORE' -> '$MODE_AFTER'"
fi

echo ""
info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
