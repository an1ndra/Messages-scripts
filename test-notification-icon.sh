#!/usr/bin/env bash
# Regression for issue #211: the status-bar notification icon was too small.
# Root cause: both notification builders used the adaptive launcher foreground
# (108dp canvas, glyph only ~47%) as the small icon, so the status bar drew a
# half-size silhouette. Fix: a second copy of the same artwork
# (drawable/ic_stat_message) whose glyph fills a 24dp canvas; the launcher
# foreground stays untouched for the splash/launcher icon.
#
# This script asserts the POSTED notification's small icon resolves to
# drawable/ic_stat_message (not ic_launcher_foreground) and that the compiled
# drawable is authored on a 24x24 viewport.
#
# Run: scripts/test-notification-icon.sh
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh

NUM=15551230077
PROBE="iconprobe $(date +%s)"
APK_SRC="$PROJECT_DIR/app/build/outputs/apk/debug/app-debug.apk"
AAPT2="${AAPT2:-$HOME/android/build-tools/36.0.0/aapt2}"
PASS=0
FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }

[[ "$ANDROID_SERIAL" == emulator-* ]] || { printf 'Requires a disposable emulator.\n'; exit 1; }
[[ -x "$AAPT2" ]] || { printf 'aapt2 not found (set AAPT2).\n'; exit 1; }
[[ -f "$APK_SRC" ]] || { printf 'Build the debug APK first.\n'; exit 1; }

APK=$($ADB -s "$ANDROID_SERIAL" shell pm path "$PKG" | tr -d '\r' | sed 's/^package://')
[[ -n "$APK" ]] || { printf 'App not installed.\n'; exit 1; }
$ADB -s "$ANDROID_SERIAL" pull "$APK" "$TMP/base.apk" >/dev/null

cleanup() {
    for id in $($ADB -s "$ANDROID_SERIAL" shell cmd notification list 2>/dev/null \
        | grep "$PKG" | sed -E 's/^\S+ \|'"${PKG//./\\.}"' \|([0-9]+).*/\1/'); do
        $ADB -s "$ANDROID_SERIAL" shell cmd notification cancel "$PKG" "$id" >/dev/null 2>&1 || true
    done
}
trap cleanup EXIT

$ADB -s "$ANDROID_SERIAL" shell cmd role add-role-holder android.app.role.SMS "$PKG" >/dev/null 2>&1 || true
bash ./grant-permissions.sh >/dev/null 2>&1 || true
$ADB -s "$ANDROID_SERIAL" shell am force-stop "$PKG"
sleep 1
$ADB -s "$ANDROID_SERIAL" emu sms send "$NUM" "$PROBE"
sleep 4

ICON_ID=$($ADB -s "$ANDROID_SERIAL" shell dumpsys notification --noredact 2>/dev/null \
    | grep -A1 "pkg=$PKG" | grep -oE "id=0x[0-9a-f]+" | head -1 | cut -d= -f2)
if [[ -z "$ICON_ID" ]]; then
    fail 'posted notification exposes a small-icon resource id'
else
    pass 'posted notification exposes a small-icon resource id'
fi

STAT_MESSAGE=$("$AAPT2" dump resources "$TMP/base.apk" 2>/dev/null \
    | grep -E "drawable/ic_stat_message" -B1 | grep -oE "0x[0-9a-f]+" | head -1)
LAUNCHER=$("$AAPT2" dump resources "$TMP/base.apk" 2>/dev/null \
    | grep -E "drawable/ic_launcher_foreground" -B1 | grep -oE "0x[0-9a-f]+" | head -1)
[[ -n "$STAT_MESSAGE" && -n "$LAUNCHER" ]] || { fail 'both drawables present in installed apk'; exit 1; }
pass 'both drawables present in installed apk'

[[ "$ICON_ID" == "$STAT_MESSAGE" ]] && pass 'notification uses ic_stat_message' \
    || fail "notification icon $ICON_ID is not ic_stat_message ($STAT_MESSAGE)"
[[ "$ICON_ID" != "$LAUNCHER" ]] && pass 'notification no longer uses ic_launcher_foreground' \
    || fail 'notification still uses the launcher foreground'

TREE=$("$AAPT2" dump xmltree --file res/drawable/ic_stat_message.xml "$TMP/base.apk" 2>/dev/null)
echo "$TREE" | grep -q "viewportWidth(0x01010402)=24" && pass 'notification icon viewport is 24' \
    || fail 'notification icon viewport is not 24'
echo "$TREE" | grep -q "viewportHeight(0x01010403)=24" && pass 'notification icon viewport height is 24' \
    || fail 'notification icon viewport height is not 24'
echo "$TREE" | grep -q 'M36,12C22.745,12' && pass 'notification icon reuses the launcher artwork' \
    || fail 'notification icon artwork differs from the launcher glyph'

printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
