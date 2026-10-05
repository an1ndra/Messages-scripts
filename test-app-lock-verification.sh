#!/usr/bin/env bash
# Regression: changing the App lock setting must require a screen lock
# verification, in both directions, in both UIs.
#
# Two defects are covered. Disabling needed no check at all, and even enabling
# only asked whether a device credential *existed* -- it never actually asked
# for one, so the setting changed with no prompt on screen. Since the lock is
# what stands between a borrowed unlocked phone and the user's messages, turning
# it off is the sensitive direction, so both directions now go through a
# BiometricPrompt and only a verified result is applied.
#
# A device credential is set and cleared by this script, because a device with
# no screen lock cannot show the prompt at all and the toggle is meant to be
# refused there. The original credential state is restored at the end.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

PREFS="/data/data/$PKG/shared_prefs/messages_settings.xml"
TEST_PIN=1234
PROMPT_TITLE_RE="Confirm to change App lock|Confirm to change"   # matches any locale's short form

had_credential=0
if [ "$(adb_ shell locksettings get-disabled 2>/dev/null | tr -d '\r')" = "false" ]; then
    had_credential=1
fi

app_lock_state() {
    adb_ shell "run-as $PKG cat $PREFS" 2>/dev/null \
        | grep -oE 'name="app_lock_enabled" value="[a-z]+"' \
        | grep -oE '(true|false)$' | tr -d '\r'
}

row_centre() {
    python3 - "$TMP/ui.xml" "$1" <<'PY'
import re, sys
xml, needle = open(sys.argv[1], encoding='utf-8', errors='replace').read(), sys.argv[2]
i = xml.find(f'text="{needle}"')
if i < 0:
    raise SystemExit(0)
hits = re.findall(r'clickable="true"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', xml[:i])
if not hits:
    raise SystemExit(0)
x1, y1, x2, y2 = map(int, hits[-1])
print((x1 + x2) // 2, (y1 + y2) // 2)
PY
}

# The checkable switch inside the row owning the given text.
switch_beside() {
    python3 - "$TMP/ui.xml" "$1" <<'PY'
import re, sys
xml, needle = open(sys.argv[1], encoding='utf-8', errors='replace').read(), sys.argv[2]
i = xml.find(f'text="{needle}"')
if i < 0:
    raise SystemExit(0)
for m in re.finditer(r'checkable="true"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', xml[i:i + 1400]):
    x1, y1, x2, y2 = map(int, m.groups())
    if x1 > 700:
        print((x1 + x2) // 2, (y1 + y2) // 2)
        raise SystemExit(0)
raise SystemExit(0)
PY
}

scroll_to_row() {
    local label="$1" c
    for _ in 1 2 3 4 5 6 7 8; do
        dump_ui
        c=$(row_centre "$label")
        [ -n "$c" ] && { echo "$c"; return 0; }
        adb_ shell input swipe 540 1800 540 700 300 >/dev/null 2>&1; sleep 1
    done
    return 1
}

back_out() {
    local n="${1:-1}" _
    for _ in $(seq "$n"); do adb_ shell input keyevent 4 >/dev/null 2>&1; sleep 1; done
}

prompt_is_up() {
    for _ in 1 2 3 4 5 6; do
        dump_ui
        if adb_ shell dumpsys window 2>/dev/null | grep -q "BiometricPrompt"; then
            return 0
        fi
        sleep 1
    done
    return 1
}

dismiss_prompt() {
    # The prompt's own cancel target, so this exercises onAuthenticationError
    # rather than killing the process.
    local c
    dump_ui
    c=$(python3 - "$TMP/ui.xml" <<'PY'
import re, sys
xml = open(sys.argv[1], encoding='utf-8', errors='replace').read()
m = re.search(r'content-desc="[^"]*cancel[^"]*"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', xml)
if not m:
    raise SystemExit(0)
x1, y1, x2, y2 = map(int, m.groups())
print((x1 + x2) // 2, (y1 + y2) // 2)
PY
)
    if [ -n "$c" ]; then
        set -- $c
        adb_ shell input tap "$1" "$2" >/dev/null 2>&1
    else
        adb_ shell input keyevent 4 >/dev/null 2>&1
    fi
    sleep 3
}

# Drives the App lock switch in the currently open advanced settings screen.
try_toggle() {
    local sw
    dump_ui
    sw=$(switch_beside "App lock")
    [ -z "$sw" ] && return 1
    set -- $sw
    adb_ shell input tap "$1" "$2" >/dev/null 2>&1
    sleep 2
    return 0
}

open_advanced() {
    local c
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
    adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null 2>&1; sleep 6
    # With App lock on the app opens behind its own gate; get past it first.
    if prompt_is_up; then
        enter_pin
    fi
    c=$(scroll_to_row "Advanced settings") || return 1
    set -- $c
    adb_ shell input tap "$1" "$2" >/dev/null 2>&1; sleep 4
    return 0
}

# Relaunches and gets past the app's own unlock gate, for the disable direction.
relaunch_and_unlock() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
    adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null 2>&1; sleep 6
    prompt_is_up && { enter_pin; sleep 1; }
    return 0
}

# Completes the device-credential prompt with the temporary PIN. Retries because
# the prompt animates in and a keystroke sent too early lands on the screen
# behind it, which left the setting unchanged and failed the run.
enter_pin() {
    local attempt
    for attempt in 1 2 3; do
        prompt_is_up || return 0
        adb_ shell input text "$TEST_PIN" >/dev/null 2>&1; sleep 1
        adb_ shell input keyevent 66 >/dev/null 2>&1; sleep 3
        prompt_is_up || return 0
        sleep 1
    done
    return 0
}

info "A device credential is required to show the prompt at all"
if [ "$had_credential" = 0 ]; then
    adb_ shell locksettings set-pin "$TEST_PIN" >/dev/null 2>&1
    sleep 2
    ok "set a temporary screen lock"
else
    ok "device already had a screen lock; leaving it alone"
fi

info "With NO screen lock the toggle is refused, not silently applied"
if [ "$had_credential" = 0 ]; then
    adb_ shell locksettings clear --old "$TEST_PIN" >/dev/null 2>&1
    sleep 2
    if open_advanced && scroll_to_row "App lock" >/dev/null && try_toggle; then
        sleep 2
        if prompt_is_up; then
            bad "a prompt appeared on a device with no screen lock"
            dismiss_prompt
        elif [ "$(app_lock_state)" = "true" ]; then
            bad "App lock was enabled with no verification and no credential"
        else
            ok "App lock not enabled without a screen lock to verify against"
        fi
    else
        bad "could not reach the App lock row"
    fi
    adb_ shell locksettings set-pin "$TEST_PIN" >/dev/null 2>&1
    sleep 2
fi

info "ENABLING asks for verification, and cancelling leaves it off"
if open_advanced && scroll_to_row "App lock" >/dev/null && try_toggle; then
    if prompt_is_up; then
        ok "enabling shows a screen lock prompt"
        dismiss_prompt
        if [ "$(app_lock_state)" = "true" ]; then
            bad "App lock was enabled after the prompt was cancelled"
        else
            ok "a cancelled prompt does not enable App lock"
        fi
    else
        bad "enabling App lock showed no verification prompt"
    fi
else
    bad "could not reach the App lock row"
fi

info "A successful verification does apply the change"
# Completing the prompt is what distinguishes a real check from a capability
# probe: the old code never prompted, so nothing here could have passed before.
if open_advanced && scroll_to_row "App lock" >/dev/null && try_toggle; then
    if prompt_is_up; then
        enter_pin
        if [ "$(app_lock_state)" = "true" ]; then
            ok "a verified user does enable App lock"
        else
            bad "the prompt was satisfied but App lock was not enabled"
        fi
    else
        bad "no prompt to satisfy when enabling"
    fi
else
    bad "could not reach the App lock row"
fi

info "DISABLING also asks for verification, and cancelling keeps the lock on"
# App lock is now on, so the app opens behind its own unlock gate first.
if relaunch_and_unlock && scroll_to_row "App lock" >/dev/null && try_toggle; then
    if prompt_is_up; then
        ok "disabling shows a screen lock prompt too"
        dismiss_prompt
        if [ "$(app_lock_state)" = "true" ]; then
            ok "a cancelled prompt does not disable App lock"
        else
            bad "App lock was turned off by a cancelled prompt"
        fi
    else
        bad "disabling App lock showed no verification prompt"
    fi
else
    bad "could not reach the App lock row with App lock on"
fi

info "Restore device state"
# Turn the lock back off through a real verification so the device is left as
# found without editing the prefs behind the app's back.
if [ "$(app_lock_state)" = "true" ]; then
    if relaunch_and_unlock && scroll_to_row "App lock" >/dev/null && try_toggle; then
        prompt_is_up && { enter_pin; sleep 1; }
    fi
fi
if [ "$(app_lock_state)" = "true" ]; then
    bad "could not restore App lock to off"
else
    ok "App lock restored to off"
fi
if [ "$had_credential" = 0 ]; then
    adb_ shell locksettings clear --old "$TEST_PIN" >/dev/null 2>&1
    ok "cleared the temporary screen lock"
else
    ok "left the existing screen lock in place"
fi
adb_ shell am force-stop "$PKG" >/dev/null 2>&1

echo ""
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
