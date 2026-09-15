#!/usr/bin/env bash
# Regression: Settings -> Advanced now also holds Privacy mode, App lock,
# Drafts, Send sound and Receive sound (moved out of the main Settings screen),
# plus a Font picker that switches the app font and persists the choice.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

MOVED="Privacy mode|App lock|Drafts|Send sound|Receive sound"

pref_get() {
    adb_ shell "run-as $PKG cat shared_prefs/messages_settings.xml" 2>/dev/null > "$TMP/prefs.xml"
    python3 - "$1" "$TMP/prefs.xml" <<'PY'
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

open_settings() {
    adb_ shell am force-stop "$PKG"; sleep 1
    adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null 2>&1; sleep 3
}

scroll_until() {
    local target="$1" i
    for i in $(seq 1 8); do
        dump_ui || true
        grep -q "text=\"$target\"" "$TMP/ui.xml" && return 0
        adb_ shell input swipe 540 1700 540 900 250 >/dev/null 2>&1; sleep 0.5
    done
    return 1
}

open_advanced() {
    scroll_until "Advanced" || return 1
    tap_text "Advanced" >/dev/null 2>&1 || return 1
    sleep 1.5
}

info "Main Settings no longer shows the moved toggles"
open_settings
FOUND=""
for i in $(seq 1 8); do
    dump_ui || true
    for s in "Privacy mode" "App lock" "Drafts" "Send sound" "Receive sound"; do
        grep -q "text=\"$s\"" "$TMP/ui.xml" && FOUND="$FOUND|$s"
    done
    adb_ shell input swipe 540 1700 540 900 250 >/dev/null 2>&1; sleep 0.4
done
for s in "Privacy mode" "App lock" "Drafts" "Send sound" "Receive sound"; do
    case "$FOUND" in
        *"|$s"*) bad "main Settings still shows '$s'" ;;
        *) ok "main Settings no longer shows '$s'" ;;
    esac
done

info "Advanced shows the moved toggles + Font"
open_settings
open_advanced || bad "could not open Advanced"
FOUND_ADV=""
for i in $(seq 1 8); do
    dump_ui || true
    for s in "Privacy mode" "App lock" "Drafts" "Send sound" "Receive sound" "Font"; do
        grep -q "text=\"$s\"" "$TMP/ui.xml" && FOUND_ADV="$FOUND_ADV|$s"
    done
    adb_ shell input swipe 540 1700 540 900 250 >/dev/null 2>&1; sleep 0.4
done
for s in "Privacy mode" "App lock" "Drafts" "Send sound" "Receive sound" "Font"; do
    case "$FOUND_ADV" in
        *"|$s"*) ok "Advanced shows '$s'" ;;
        *) bad "Advanced missing '$s'" ;;
    esac
done

info "Font picker lists the bundled fonts"
open_settings
open_advanced || bad "could not open Advanced"
scroll_until "Font" >/dev/null 2>&1
tap_text "Font" >/dev/null 2>&1; sleep 1.2
dump_ui
for s in "DM Sans" "Inter" "Figtree" "System default"; do
    grep -q "text=\"$s\"" "$TMP/ui.xml" && ok "font option '$s'" || bad "font option '$s' missing"
done

info "Picking Figtree updates the subtitle and persists"
tap_text "Figtree" >/dev/null 2>&1; sleep 0.5
tap_text "OK" >/dev/null 2>&1; sleep 1
dump_ui
grep -q 'text="Figtree"' "$TMP/ui.xml" && ok "font subtitle -> Figtree" || bad "font subtitle did not change"
[ "$(pref_get font_family)" = "figtree" ] && ok "font_family pref persisted" || bad "font_family pref not persisted"

info "Restore the default font (DM Sans)"
scroll_until "Font" >/dev/null 2>&1
tap_text "Font" >/dev/null 2>&1; sleep 1.2
tap_text "DM Sans" >/dev/null 2>&1; sleep 0.5
tap_text "OK" >/dev/null 2>&1; sleep 1
[ "$(pref_get font_family)" = "dm_sans" ] && ok "font restored to DM Sans" || bad "font not restored"

echo ""
info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
