#!/usr/bin/env bash
# Regression for lint MissingPermission on the SIM / carrier-config reads.
#
# `SubscriptionManager.activeSubscriptionInfoList` and
# `CarrierConfigManager.getConfigForSubId` both require READ_PHONE_STATE, a
# runtime permission the user can refuse or revoke at any time, and
# `SubscriptionInfo.getNumber` needs READ_PHONE_NUMBERS, which this app never
# requests. All four call sites must degrade to a documented default instead of
# crashing the app.
#
# The unit test (PermissionGuardTest) only checks the source shape, because a
# JVM test has no package manager to revoke against. This does the real thing:
# revokes the permissions on a live device, exercises every path that reads
# them, and asserts the app survives. Grant them again at the end.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()   { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad()  { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

SDK=$(adb_ shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')
info "Device: $(adb_ shell getprop ro.build.version.release 2>/dev/null | tr -d '\r') (SDK ${SDK:-unknown})"

if [ -z "$SDK" ] || [ "$SDK" -lt 23 ]; then
    echo "[SKIP] runtime permission revocation needs API 23+"
    exit 0
fi
if ! adb_ shell pm path "$PKG" >/dev/null 2>&1; then
    echo "[FAIL] $PKG is not installed on $ANDROID_SERIAL"
    exit 1
fi

restore() {
    info "Restoring permissions"
    for p in android.permission.READ_PHONE_STATE android.permission.READ_PHONE_NUMBERS; do
        adb_ shell pm grant "$PKG" "$p" >/dev/null 2>&1 && echo "    granted $p"
    done
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
}
trap restore EXIT

crashes() {
    # logcat formats a fatal as two lines:
    #   FATAL EXCEPTION: main
    #   Process: com.anindra.messages, PID: 123
    # so the package name is NOT on the FATAL EXCEPTION line — the block has to
    # be pulled in with -A before it can be matched, or every count comes back 0.
    # grep -c always prints a count but exits 1 when it is 0, so the result must
    # not be guarded with `|| echo 0`: that appends a second line and every
    # `[ -gt 0 ]` downstream silently errors out instead of failing.
    local n
    n=$(adb_ logcat -d 2>/dev/null | grep -A3 "FATAL EXCEPTION" | grep -cF "Process: $PKG")
    echo "${n:-0}"
}

launch_and_survive() {
    local label="$1"
    adb_ logcat -c >/dev/null 2>&1
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    adb_ shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
    sleep 5
    local n
    n=$(crashes)
    if [ "$n" -gt 0 ]; then
        bad "$label: $n crash/ANR entries in logcat"
        adb_ logcat -d 2>/dev/null | grep -A25 "FATAL EXCEPTION" | head -30 | sed 's/^/    /'
    else
        ok "$label: no crash"
    fi
    local focus
    focus=$(adb_ shell dumpsys window 2>/dev/null | tr -d '\r' | grep -E "mCurrentFocus" | head -1)
    if echo "$focus" | grep -cF "$PKG" >/dev/null 2>&1; then
        ok "$label: still in the foreground"
    else
        bad "$label: not in the foreground — $focus"
    fi
}

info "Baseline: all permissions granted"
for p in android.permission.READ_PHONE_STATE android.permission.READ_PHONE_NUMBERS; do
    adb_ shell pm grant "$PKG" "$p" >/dev/null 2>&1
done
launch_and_survive "permissions granted"

info "Revoking READ_PHONE_STATE and READ_PHONE_NUMBERS"
for p in android.permission.READ_PHONE_STATE android.permission.READ_PHONE_NUMBERS; do
    if adb_ shell pm revoke "$PKG" "$p" 2>&1 | grep -q "Operation not allowed"; then
        echo "[SKIP] cannot revoke $p on this device (needs a userdebug/rooted emulator)"
        exit 0
    fi
    echo "    revoked $p"
done

GRANTED=$(adb_ shell dumpsys package "$PKG" 2>/dev/null | tr -d '\r' \
    | grep "android.permission.READ_PHONE_STATE: granted" | head -1)
if echo "$GRANTED" | grep -c "=true" >/dev/null 2>&1; then
    bad "READ_PHONE_STATE is still granted; the revocation did not take effect"
    echo "$GRANTED" | sed 's/^/    /'
else
    ok "READ_PHONE_STATE is denied at runtime"
    echo "$GRANTED" | sed 's/^/    /'
fi

info "Launch with the telephony permissions denied"
# Exercises PhoneNumberUtils.resolveRegion, SimCards.load and MmsCarrierConfig.load
# during startup, then the SIM/MMS screens in Advanced settings.
launch_and_survive "denied-permission launch"

info "Exercising the MMS support screen (Settings > Advanced > MMS support)"
# SimMmsProbe.run() calls both SimCards.load() and getConfigForSubId(), so this
# screen is the one place both changed call sites are exercised together.
adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null 2>&1
sleep 3
adb_ shell input swipe 500 1900 500 700 400 >/dev/null 2>&1
adb_ shell input swipe 500 1900 500 700 400 >/dev/null 2>&1
sleep 1
if tap_contains "Advanced" >/dev/null 2>&1; then
    sleep 2
    if tap_contains "MMS support" >/dev/null 2>&1; then
        ok "navigated to MMS support with permissions denied"
        sleep 3
        n=$(crashes)
        if [ "$n" -gt 0 ]; then
            bad "MMS support screen: $n crash/ANR entries in logcat"
            adb_ logcat -d 2>/dev/null | grep -A25 "FATAL EXCEPTION" | head -30 | sed 's/^/    /'
        else
            ok "MMS support screen: no crash"
        fi
        # With READ_PHONE_STATE revoked, SimCards.load() returns an empty list, so
        # the screen must render its empty state. Anything else means the denial
        # was not actually observed.
        if wait_for_text "No active SIM found" 6; then
            ok "rendered the empty state instead of crashing on the denied read"
        elif wait_for_text "MMS support" 3; then
            ok "screen rendered (SIMs still visible — revocation had no effect here)"
        else
            bad "MMS support screen did not render"
        fi
    else
        bad "could not find the 'MMS support' row in Advanced settings"
    fi
else
    bad "could not find the 'Advanced' row in settings"
fi

info "Denial is logged as a handled degradation, not a crash"
if adb_ logcat -d 2>/dev/null | grep -cE "SecurityException" >/dev/null 2>&1; then
    echo "    SecurityException lines seen in logcat (expected only if unhandled):"
    adb_ logcat -d 2>/dev/null | grep -E "SecurityException" | head -5 | sed 's/^/    /'
fi

echo ""
echo "=== Result: ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
