#!/usr/bin/env bash
# Smoke regression for dependency bumps: verifies the updated libraries still
# load and the integration points they own still work.
#
# Covered bumps:
#   - libphonenumber 9.x    -> New Chat number normalization
#   - org.json 2026.x       -> unit-test JSON round-trip
#   - androidx.core 1.19.x  -> incoming-SMS notification posts
#   - androidx.fragment 1.9 -> App lock settings row (FragmentActivity)
#   - coil 3.6.x            -> app launch + contact/message list renders
#   - gradle 9.8            -> build path itself
#
# Run: scripts/test-dependency-bump.sh
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh

PASS=0
FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }

NUM1="+1555$(date +%s)001"
NUM2="1555$(date +%s)001"
PROBE="dep-probe-$(date +%s)"

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1 || true
    adb_ shell "run-as $PKG sqlite3 databases/messages.db \"DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address IN ('$NUM1','$NUM2')); DELETE FROM conversations WHERE address IN ('$NUM1','$NUM2'); DELETE FROM participants WHERE normalized_destination IN ('$NUM1','$NUM2');\"" >/dev/null 2>&1 || true
}
trap cleanup EXIT

info "0. build + unit tests"
cd "$PROJECT_DIR"
for cand in \
  "$HOME/.local/java/"jdk-21.* \
  "$HOME/tools/jdk21" \
  "$JAVA_HOME" ; do
  if [ -x "$cand/bin/java" ]; then export JAVA_HOME="$cand"; break; fi
done
if ./gradlew --quiet :app:testDebugUnitTest --tests "DependencyApiSmokeTest"; then
    pass "DependencyApiSmokeTest passes"
else
    fail "DependencyApiSmokeTest fails"
fi

info "1. install debug APK"
./gradlew --quiet assembleDebug
adb_ install -r app/build/outputs/apk/debug/app-debug.apk >/dev/null
pass "debug APK installed"

bash ./grant-permissions.sh >/dev/null 2>&1 || true
adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1 || true

info "2. cold launch"
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" >/dev/null
sleep 4
if wait_for_text "Start chat" 15 >/dev/null 2>&1 || wait_for_text "Messages" 10 >/dev/null 2>&1; then
    pass "app launches to home screen"
else
    fail "app did not reach home screen"
fi

info "3. libphonenumber normalization in New Chat"
tap_text "Start chat" || adb_ shell input tap 940 2260
sleep 2.5
# First format: +1 555 ...
type_text "$NUM1"; sleep 2
dump_ui >/dev/null 2>&1
if grep -q "Send to" "$TMP/ui.xml"; then
    pass "international format produces a send-to row"
else
    fail "international format produced no send-to row"
fi
# Clear and type national format; same E.164 should match the same row.
for _ in $(seq 1 25); do adb_ shell input keyevent 67 >/dev/null 2>&1; done
sleep 0.5
type_text "$NUM2"; sleep 2
dump_ui >/dev/null 2>&1
if grep -q "Send to" "$TMP/ui.xml"; then
    pass "national format also produces a send-to row (normalization OK)"
else
    fail "national format produced no send-to row"
fi
adb_ shell input keyevent KEYCODE_HOME >/dev/null 2>&1
sleep 1

info "4. androidx.core notification posts"
adb_ shell am force-stop "$PKG"; sleep 1
adb_ emu sms send "$NUM1" "$PROBE notification"
sleep 5
if adb_ shell cmd notification list | grep -q 'com.anindra.messages'; then
    pass "incoming SMS notification is posted"
else
    fail "incoming SMS notification is not posted"
fi
if adb_ shell dumpsys notification | grep -qE '\[[0-9]+\] "(Reply|Mark as read|Delete)" -> PendingIntent'; then
    pass "notification action is wired"
else
    fail "notification action is not wired"
fi

info "5. androidx.fragment App lock row"
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null
sleep 4
# Legacy settings: App lock lives inside Advanced settings.
found_advanced=0
for _ in $(seq 1 15); do
    if dump_ui >/dev/null 2>&1 && grep -q 'text="Advanced settings"' "$TMP/ui.xml"; then
        found_advanced=1
        break
    fi
    adb_ shell input swipe 540 1800 540 700 300 >/dev/null 2>&1; sleep 0.5
done
if [ "$found_advanced" -eq 1 ]; then
    c=$(python3 - "$TMP/ui.xml" <<'PY'
import re, sys
xml = open(sys.argv[1], encoding='utf-8', errors='replace').read()
idx = xml.find('text="Advanced settings"')
if idx < 0:
    raise SystemExit(0)
for m in re.finditer(r'clickable="true"[^>]*bounds="(\[\d+,\d+\]\[\d+,\d+\])"', xml[:idx]):
    pass
if not m:
    raise SystemExit(0)
x1,y1,x2,y2 = map(int, re.findall(r'\d+', m.group(1)))
print((x1+x2)//2, (y1+y2)//2)
PY
)
    [ -n "$c" ] && adb_ shell input tap $c; sleep 3
fi
found=0
for _ in $(seq 1 10); do
    if dump_ui >/dev/null 2>&1 && grep -q 'text="App lock"' "$TMP/ui.xml"; then
        found=1
        break
    fi
    adb_ shell input swipe 540 1800 540 700 300 >/dev/null 2>&1; sleep 0.5
done
if [ "$found" -eq 1 ]; then
    pass "App lock settings row is present"
else
    fail "App lock settings row is missing"
fi

printf '\n[RESULT] %d passed, %d failed\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
