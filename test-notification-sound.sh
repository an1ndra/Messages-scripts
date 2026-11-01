#!/usr/bin/env bash
# Regression for #339's sound ownership: the app no longer keeps its own tone
# list, and a channel's sound belongs to whoever owns that channel.
#
#   - Settings -> Advanced -> Notifications has no "Notification sound" row and
#     no Default / Classic / Dragon Studio / Chime / Bubble options. The tone
#     used to be stored per category and applied by minting a channel id per
#     selection, which deleted the user's importance/vibration tuning on every
#     change and could disagree with what Android actually played.
#   - The row that replaced it, "Manage in system settings", opens Android's
#     own channel page.
#   - Category channel ids carry no tone: messages_<category>_default while
#     receive sound is on, messages_<category>_silent while it is off. The ids
#     the old picker minted (_app, _dragon, _uf09, _uf062) are swept at launch.
#   - A category channel plays the SYSTEM default tone, i.e. the app no longer
#     seeds a bundled clip of its own.
#   - Receive sound OFF still posts, stays silent (bundled silent clip, not a
#     null sound, which would demote the channel below IMPORTANCE_HIGH), and
#     still shows the heads-up popup.
#
# Precondition: emulator booted, app installed. Uses layout dumps and dumpsys,
# never screenshots. Requires the app to hold the SMS role so injected SMS reach
# it.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
info() { echo -e "\n=== $* ==="; }
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

pref_get() {
    adb_ shell "run-as $PKG cat shared_prefs/messages_settings.xml" 2>/dev/null > "$TMP/pref_get.xml"
    python3 - "$1" "$TMP/pref_get.xml" <<'PY'
import re, sys
key, path = sys.argv[1], sys.argv[2]
try:
    s = open(path).read()
except OSError:
    s = ""
m = re.search(r'<(?:boolean|string|int) name="%s" value="([^"]*)"\s*/>' % re.escape(key), s)
if m:
    print(m.group(1))
else:
    m = re.search(r'<string name="%s">([^<]*)</string>' % re.escape(key), s)
    if m:
        print(m.group(1))
PY
}
pref_on() { [ "$(pref_get "$1")" = "true" ]; }

# Rewrite a pref directly (app must be stopped) to set a reliable baseline.
set_prefs() {
    adb_ shell am force-stop "$PKG"; sleep 1
    adb_ shell "run-as $PKG cat shared_prefs/messages_settings.xml" > "$TMP/prefs.xml" 2>/dev/null
    python3 - "$1" "$2" "$TMP/prefs.xml" <<'PY'
import re, sys
key, val, path = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
if val in ("true", "false"):
    tag = f'<boolean name="{key}" value="{val}" />'
    s = re.sub(r'<boolean name="%(k)s" value="(true|false)"\s*/>' % {"k": re.escape(key)}, tag, s)
else:
    tag = f'<string name="{key}">{val}</string>'
    s = re.sub(r'<string name="%(k)s">[^<]*</string>' % {"k": re.escape(key)}, tag, s)
if f'name="{key}"' not in s:
    s = s.replace('</map>', f'    {tag}\n</map>')
open(path, 'w').write(s)
PY
    adb_ push "$TMP/prefs.xml" /data/local/tmp/prefs.xml >/dev/null 2>&1
    adb_ shell "run-as $PKG cp /data/local/tmp/prefs.xml shared_prefs/messages_settings.xml"
    echo "  pref $1 -> $2"
}

launch_settings() {
    adb_ shell am force-stop "$PKG"; sleep 1
    adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null 2>&1; sleep 3
}

scroll_settings_top() {
    local i
    for i in 1 2 3; do
        adb_ shell input swipe 540 700 540 2000 300 >/dev/null 2>&1
        sleep 0.3
    done
}

open_advanced() {
    local i
    wait_layout_has "Link behaviour" 1 && return 0
    scroll_settings_top
    for i in 1 2 3 4 5 6; do
        if layout_center "Advanced settings" >/dev/null 2>&1; then
            tap_layout "Advanced settings" >/dev/null 2>&1
            sleep 1.5
            wait_layout_has "Link behaviour" 3 && return 0
        fi
        adb_ shell input swipe 540 1700 540 900 300 >/dev/null 2>&1
        sleep 0.8
    done
    return 1
}

# The Notifications page is identified by a row that survived the change, not by
# the sound row that was removed.
open_notifications() {
    local i
    wait_layout_has "Receive sound" 1 && return 0
    for i in 1 2 3; do
        if open_advanced; then
            tap_layout "Notifications" >/dev/null 2>&1
            sleep 1.5
            wait_layout_has "Receive sound" 3 && return 0
            adb_ shell input keyevent 4 >/dev/null 2>&1
            sleep 1
        fi
        sleep 1
    done
    fail "could not open Notifications settings"
    return 1
}

tap_switch_for() {
    local c
    c=$(layout_center "$1") || { echo "[tap] '$1' not found"; return 1; }
    adb_ shell input tap 937 "${c#* }"
    echo "[tap] switch near '$1' at (937 ${c#* })"
}

# Live channel ids, without the deleted tombstones the framework keeps.
live_channels() {
    adb_ shell dumpsys notification --noredact 2>/dev/null | tr -d '\r' \
        | grep -oE "NotificationChannel\{mId='messages[^']*'.*mDeleted=(true|false)" \
        | grep "mDeleted=false" | sed -E "s/.*mId='([^']*)'.*/\1/" | sort -u
}

# Sound a channel carries. A channel's tone is immutable, so this is what
# Android plays for every notification posted on it.
channel_sound() {
    adb_ shell dumpsys notification --noredact 2>/dev/null | tr -d '\r' \
        | grep -F "NotificationChannel{mId='$1'" \
        | grep -v "mDeleted=true" | head -1 \
        | grep -oE "mSound=[^,]*" | head -1 | cut -d= -f2-
}

# Channel the notification containing [body] was posted on.
notif_channel() {
    local body="$1"
    adb_ shell dumpsys notification --noredact 2>/dev/null | awk -v b="$body" '
        /NotificationRecord\(/ { line = $0 }
        index($0, b) {
            m = line
            sub(/^.*channel=/, "", m)
            sub(/ .*$/, "", m)
            print m
            exit
        }'
}

adb_ shell cmd role add-role-holder android.app.role.SMS com.anindra.messages >/dev/null 2>&1 || true
adb_ shell pm grant com.anindra.messages android.permission.POST_NOTIFICATIONS >/dev/null 2>&1 || true

info "Baseline (Receive sound ON)"
set_prefs receive_sound_enabled true
launch_settings
open_notifications || fail "could not open Notifications settings"

info "The app offers no tone of its own"
layout_has "Receive sound" &&
    pass "'Receive sound' row present" || fail "'Receive sound' row missing"
# These are the rows/options the picker added. Their presence means the app is
# keeping a second sound list again.
if layout_has "Notification sound"; then
    fail "'Notification sound' picker row is back in the app"
else
    pass "no 'Notification sound' picker row"
fi
for label in "Classic" "Dragon Studio" "Chime" "Bubble"; do
    if layout_has "$label"; then
        fail "bundled tone '$label' is offered in the app again"
    else
        pass "bundled tone '$label' is not offered"
    fi
done
layout_has "Manage in system settings" &&
    pass "'Manage in system settings' row present" ||
    fail "'Manage in system settings' row missing"

info "That row hands sound to Android"
tap_layout "Manage in system settings" >/dev/null 2>&1 || fail "could not tap the channel row"
sleep 2.5
resumed=$(adb_ shell dumpsys activity activities 2>/dev/null | tr -d '\r' \
    | grep -m1 -E "mResumedActivity|topResumedActivity" | sed -E 's/.*u0 ([^ ]+).*/\1/')
echo "  resumed: $resumed"
case "$resumed" in
    com.android.settings*)
        pass "the row opens Android's notification-channel settings" ;;
    *)
        fail "the row did not open system channel settings ($resumed)" ;;
esac
adb_ shell input keyevent 4 >/dev/null 2>&1; sleep 1

info "Category channel ids carry no tone"
launch_settings >/dev/null 2>&1
sleep 2
channels=$(live_channels)
echo "$channels" | sed 's/^/  /'
for c in direct group unknown; do
    echo "$channels" | grep -qx "messages_${c}_default" &&
        pass "messages_${c}_default exists" ||
        fail "messages_${c}_default missing"
done
stale=$(echo "$channels" | grep -E "^messages_(direct|group|unknown)_(app|dragon|uf09|uf062)$" || true)
if [ -z "$stale" ]; then
    pass "no per-tone channel ids survive the migration"
else
    fail "per-tone channel ids were not swept: $(echo $stale)"
fi
snd=$(channel_sound messages_direct_default)
echo "  messages_direct_default sound: $snd"
case "$snd" in
    content://settings/system/*)
        pass "the category channel plays the system tone" ;;
    android.resource://*)
        fail "the category channel still plays an app-owned tone ($snd)" ;;
    *)
        fail "unexpected category channel tone ($snd)" ;;
esac

info "A stored tone from an older build no longer moves the channel"
# This is the migration itself: the old build kept the choice in
# `notification_sound` and minted messages_<category>_<tone> from it. The pref is
# ignored now, so the id must not move and the tone must stay the system's.
set_prefs notification_sound dragon_studio
launch_settings >/dev/null 2>&1
sleep 2
channels=$(live_channels)
echo "$channels" | grep -qx "messages_direct_dragon" &&
    fail "the stored tone still mints a per-tone channel" ||
    pass "no channel is minted from the stored tone"
echo "$channels" | grep -qx "messages_direct_default" &&
    pass "the category keeps its stable id" ||
    fail "the category channel disappeared when the tone pref changed"
snd=$(channel_sound messages_direct_default)
case "$snd" in
    content://settings/system/*) pass "the stored tone did not replace the system tone" ;;
    *) fail "the stored tone changed the channel sound ($snd)" ;;
esac

info "Receive sound OFF -> silent id"
open_notifications || fail "could not open Notifications settings"
tap_switch_for "Receive sound" || fail "could not toggle Receive sound"
wait_pref_false=0
for i in $(seq 1 20); do
    if [ "$(pref_get receive_sound_enabled)" = "false" ]; then wait_pref_false=1; break; fi
    sleep 0.5
done
[ "$wait_pref_false" = "1" ] &&
    pass "receive sound turned off" || fail "receive sound not turned off"
sleep 1
channels=$(live_channels)
echo "$channels" | grep -qx "messages_direct_silent" &&
    pass "messages_direct_silent created" || fail "messages_direct_silent missing"
echo "$channels" | grep -qx "messages_direct_default" &&
    fail "the audible channel was not switched away from" ||
    pass "the audible channel is gone"
snd=$(channel_sound messages_direct_silent)
echo "  messages_direct_silent sound: $snd"
case "$snd" in
    android.resource://*silent*|android.resource://*/silent)
        pass "the silent channel carries the bundled silent clip" ;;
    android.resource://*)
        pass "the silent channel carries a bundled clip ($snd)" ;;
    *)
        fail "the silent channel does not use the silent clip ($snd)" ;;
esac

# The heads-up assertion needs a real inbound SMS. The emulator's modem is a
# separate process (it fails with "Unable to connect character device modem"
# when ::1 does not resolve), so the check is skipped — loudly — rather than
# reported as a pass, and a message that does not land is a failure only when
# the SIM was up.
sim_ready() { [ "$(adb_ shell getprop gsm.sim.state | tr -d '\r')" = "READY" ]; }
if sim_ready; then
POPUP_SENDER="+1555$(( 1000 + RANDOM % 9000 ))$RANDOM"
adb_ emu sms send "$POPUP_SENDER" "silent popup check" >/dev/null 2>&1; sleep 1.5
rec=$(adb_ shell dumpsys notification --noredact 2>/dev/null | awk '
    /NotificationRecord\(/ { r=$0 }
    /silent popup check/ { print r; exit }')
stats=$(adb_ shell dumpsys notification --noredact 2>/dev/null | awk '
    /NotificationRecord\(/ { r=$0; hit=0 }
    /silent popup check/ { hit=1 }
    hit && /stats=/ { split($0,a,"airtimeCount="); split(a[2],b,","); print b[1]; exit }')
echo "  record: $rec"
echo "  airtimeCount=$stats"
case "$rec" in
    *channel=messages_*_silent*) pass "the notification posted on a silent category channel" ;;
    *) fail "notification did not post on the silent channel ($rec)" ;;
esac
case "$rec" in
    *groupKey=silent*) fail "setSilent() grouped the popup — heads-up suppressed" ;;
    *) pass "no silent group key (heads-up not suppressed)" ;;
esac
if [ -n "$stats" ] && [ "$stats" -ge 1 ]; then
    pass "heads-up popup displayed (airtimeCount=$stats)"
else
    fail "heads-up popup was NOT displayed (airtimeCount=$stats)"
fi
else
    echo "[SKIP] heads-up check: the emulator's SIM is $(adb_ shell getprop gsm.sim.state | tr -d '\r')"
    echo "       (modem not connected — restart the AVD without a broken modem device)"
fi

info "Restoring defaults"
set_prefs notification_sound default
if pref_on receive_sound_enabled; then
    pass "receive sound already on"
else
    set_prefs receive_sound_enabled true
    adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 3
    channels=$(live_channels)
    echo "$channels" | grep -qx "messages_direct_default" &&
        pass "the audible channel came back" ||
        fail "the audible channel did not come back"
    echo "$channels" | grep -qx "messages_direct_silent" &&
        fail "the silent channel was not cleaned up" ||
        pass "the silent channel was cleaned up"
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
