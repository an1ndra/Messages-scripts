#!/usr/bin/env bash
# Regression for the Persian (fa) locale — the app's second right-to-left
# language and the one the #345 reports were written in.
#
# Three things are checked, because a language can fail at each of them:
#   source   values-fa/ must define every base key, in base order, with the
#            same format placeholders, and must not be English left in place.
#            crowdin.yml must pin fa -> fa, or Crowdin exports values-fa-rIR
#            and every scheduled sync misses the shipped directory.
#   artifact the built APK must carry a (fa) config for the real strings, not
#            just a values-fa/ directory Gradle ignored.
#   device   Android has no per-app locale before API 33, so the only way to
#            see Persian on the AOSP-12 target is the system locale. The
#            script sets persist.sys.locale, restarts zygote, and asserts the
#            running configuration is fa + ldrtl and that the app paints
#            Persian. The original locale is restored on exit, interrupted or
#            not — leaving the comparison AVD in Persian breaks every other
#            script on it.
#
# Root is required for the locale switch (Magisk su on both standing AVDs).
# Run: scripts/test-persian-locale.sh
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

RES="$PROJECT_DIR/app/src/main/res"
APK="$PROJECT_DIR/app/build/outputs/apk/debug/app-debug.apk"
ORIG_LOCALE=$(adb_ shell getprop persist.sys.locale 2>/dev/null | tr -d '\r')
[ -z "$ORIG_LOCALE" ] && ORIG_LOCALE="en-US"

set_locale() {
    adb_ shell "su -c 'setprop persist.sys.locale $1'" >/dev/null 2>&1
    adb_ shell "su -c 'setprop ctl.restart zygote'" >/dev/null 2>&1
    local i
    for i in $(seq 1 60); do
        sleep 2
        if adb_ shell am get-config 2>/dev/null | grep -q "${2:-$1}"; then
            sleep 2
            return 0
        fi
    done
    return 1
}

restore() {
    if [ "$ORIG_LOCALE" != "fa-IR" ] && [ -n "$ORIG_LOCALE" ]; then
        adb_ shell "su -c 'setprop persist.sys.locale $ORIG_LOCALE'" >/dev/null 2>&1
        adb_ shell "su -c 'setprop ctl.restart zygote'" >/dev/null 2>&1
        local i
        for i in $(seq 1 60); do
            sleep 2
            if adb_ shell am get-config 2>/dev/null | grep -q "$ORIG_LOCALE"; then break; fi
        done
    fi
    # The role is documented as Google Messages' on both standing AVDs, and
    # `cmd role` on API 31 has no read command to record who held it before.
    if adb_ shell pm path com.google.android.apps.messaging >/dev/null 2>&1; then
        adb_ shell "su -c 'cmd role add-role-holder android.app.role.SMS com.google.android.apps.messaging'" >/dev/null 2>&1
    fi
}
trap restore EXIT

info "Source: declared, complete, in base order, actually Persian"
python3 - "$RES" "$PROJECT_DIR" <<'PY'
import os, re, sys

res, root = sys.argv[1], sys.argv[2]
STR = re.compile(r'<string name="([^"]+)"\s*>(.*?)</string>', re.S)
PH = re.compile(r'%\d+\$[sd]|%[sd]')
ARABIC = re.compile(r'[\u0600-\u06FF]')
WORD = re.compile(r'[A-Za-z]{3,}')

# Kept in Latin script on purpose: typefaces, product names, the SMS label,
# the two CLDR-resolved date patterns and the licence list.
LATIN_BY_DESIGN = {
    'font_dm_sans', 'font_inter', 'font_figtree', 'font_poppins',
    'time_format_date', 'time_format_divider', 'time_format_hour',
    'status_sms', 'settings_theme_amoled', 'settings_sound_dragon',
    'about_licences_subtitle', 'settings_import_source_sms_ie_title',
}

fails = 0


def read_dir(d):
    values, order, files = {}, [], []
    for f in sorted(os.listdir(d)):
        if f.startswith('strings') and f.endswith('.xml'):
            p = os.path.join(d, f)
            files.append(f)
            keys = []
            for key, value in STR.findall(open(p, encoding='utf-8').read()):
                if key in values:
                    print('DUPLICATE %s %s' % (d, key)); fails += 1
                values[key] = value
                keys.append(key)
            order.append((f, keys))
    return values, order, files


base, base_order, base_files = read_dir(os.path.join(res, 'values'))
cfg = os.path.join(res, 'xml', 'locales_config.xml')
declared = set(re.findall(r'android:name="([^"]+)"', open(cfg, encoding='utf-8').read()))
if 'fa' not in declared:
    print('DECLARED fa missing from locales_config.xml, so no app can ever select Persian')
    fails += 1

fa_dir = os.path.join(res, 'values-fa')
if not os.path.isdir(fa_dir):
    print('MISSING values-fa/ - Persian is not shipped')
    sys.exit(1)

fa, fa_order, fa_files = read_dir(fa_dir)
if fa_files != base_files:
    print('FILES values-fa/ carries %s, base has %s' % (fa_files, base_files)); fails += 1

missing = sorted(set(base) - set(fa))
extra = sorted(set(fa) - set(base))
if missing:
    print('MISSING VALUES %d keys, first: %s' % (len(missing), missing[:10])); fails += 1
if extra:
    print('EXTRA VALUES %s' % extra[:10]); fails += 1

for key, value in fa.items():
    if key not in base:
        continue
    want = sorted(set(PH.findall(base[key])))
    got = sorted(set(PH.findall(value)))
    if want != got:
        print('PLACEHOLDER %s expected %s got %s' % (key, want, got)); fails += 1

for fname, keys in fa_order:
    pos = {k: i for i, k in enumerate(dict(base_order)[fname])}
    seq = [pos.get(k, -1) for k in keys]
    if seq != sorted(seq):
        print('ORDER values-fa/%s is not in base key order' % fname); fails += 1

english, empty = [], []
for key, value in fa.items():
    if key in base and key not in LATIN_BY_DESIGN and WORD.search(base[key]) and not ARABIC.search(value):
        english.append(key)
    if key in base and base[key].strip() and not value.strip():
        empty.append(key)
if english:
    print('ENGLISH %d strings are still English: %s' % (len(english), sorted(english)[:10])); fails += 1
if empty:
    print('EMPTY %s' % sorted(empty)[:10]); fails += 1

text = open(os.path.join(root, 'crowdin.yml'), encoding='utf-8').read()
if re.search(r'(?m)^\s+fa:\s*fa\s*$', text) is None:
    print('CROWDIN crowdin.yml does not pin fa -> fa, so exports land in values-fa-rIR')
    fails += 1

print('values-fa: %d keys, base: %d keys' % (len(fa), len(base)))
# Every locale is reported, so "100%% translated" is a number and not a claim.
for d in sorted(x for x in os.listdir(res) if re.match(r'^values-[a-z]{2}(-r[A-Z]{2})?$', x)):
    values, _, _ = read_dir(os.path.join(res, d))
    gap = len(set(base) - set(values))
    print('%-14s %d/%d keys%s' % (d, len(values), len(base), '' if not gap else ' MISSING %d' % gap))
    if gap:
        fails += 1
sys.exit(1 if fails else 0)
PY
if [ $? -eq 0 ]; then
    ok "values-fa matches the base key-for-key, in order, and is Persian"
else
    bad "values-fa is incomplete, out of order or still English"
fi

info "Artifact: the APK carries the Persian resource configuration"
AAPT2=$(ls -1 "${ANDROID_HOME:-$HOME/android}"/build-tools/*/aapt2 2>/dev/null | sort -V | tail -1)
if [ ! -f "$APK" ]; then
    bad "no APK at app/build/outputs/apk/debug/app-debug.apk - run ./gradlew assembleDebug"
elif [ -z "$AAPT2" ]; then
    bad "no aapt2 under build-tools - cannot inspect the APK"
else
    "$AAPT2" dump resources "$APK" 2>/dev/null | python3 -c '
import re, sys
text = sys.stdin.read()
checks = {
    "settings_about_title": "درباره",
    "settings_calendar_title": "تقویم",
    "trash_title": "سطل زباله",
    "chat_draft_prefix": "پیش‌نویس",
}
fails = 0
for key, needle in checks.items():
    block = re.search(r"string/%s\b(.*?)(?=\n    resource |\n  type )" % key, text, re.S)
    if not block:
        print("APK string/%s missing from the resource table" % key); fails += 1; continue
    fa = re.search(r"\(fa\) \"([^\"]*)\"", block.group(1))
    if not fa:
        print("APK string/%s has no (fa) configuration" % key); fails += 1; continue
    if not re.search("[\u0600-\u06FF]", fa.group(1)):
        print("APK string/%s (fa) is not Persian: %r" % (key, fa.group(1))); fails += 1
print("checked %d strings" % len(checks))
sys.exit(1 if fails else 0)
'
    if [ $? -eq 0 ]; then
        ok "APK ships (fa) values for the app titles and labels"
    else
        bad "APK does not carry the Persian strings - rebuild before testing"
    fi
fi

info "Device: the system locale switches to Persian and the app paints it"
if ! adb_ shell "su -c id" 2>/dev/null | grep -q "uid=0"; then
    bad "no root on $ANDROID_SERIAL - the locale switch needs Magisk su"
else
    if set_locale "fa-IR" "fa-rIR"; then
        ok "device configuration is now fa-rIR"
    else
        bad "device did not come back with a fa-RIR configuration"
    fi
    if adb_ shell am get-config 2>/dev/null | grep -q "ldrtl"; then
        ok "Persian configuration is right-to-left (ldrtl)"
    else
        bad "Persian configuration is not ldrtl"
    fi

    for p in READ_SMS RECEIVE_SMS READ_CONTACTS; do
        adb_ shell pm grant "$PKG" "android.permission.$p" >/dev/null 2>&1
    done
    adb_ shell "su -c 'cmd role add-role-holder android.app.role.SMS $PKG'" >/dev/null 2>&1

    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
    adb_ logcat -c >/dev/null 2>&1
    adb_ shell am start -n "$ACT" >/dev/null 2>&1
    sleep 8
    dump_ui >/dev/null 2>&1
    UI="$TMP/ui.decoded.xml"

    if adb_ shell "dumpsys activity activities" 2>/dev/null | grep -q "mResumedActivity.*$PKG"; then
        ok "app came to the foreground under the Persian configuration"
    else
        bad "app did not come to the foreground (locale switch left it unlaunchable)"
        adb_ logcat -d 2>/dev/null | grep -A3 "FATAL EXCEPTION" | head -8
    fi

    if grep -q 'text="پیام‌ها"' "$UI" 2>/dev/null; then
        ok "the list title paints Persian (پیام‌ها)"
    else
        bad "the list title is not Persian"
    fi
    if grep -q 'content-desc="جستجو"' "$UI" 2>/dev/null; then
        ok "the search action paints Persian (جستجو)"
    else
        bad "the search action is not Persian"
    fi
    if grep -q 'text="بایگانی‌شده"\|content-desc="بایگانی‌شده"' "$UI" 2>/dev/null; then
        ok "the archived row paints Persian (بایگانی‌شده)"
    else
        bad "the archived row is not Persian"
    fi
    if adb_ logcat -d 2>/dev/null | grep -q "FATAL EXCEPTION"; then
        bad "FATAL EXCEPTION in logcat"
    else
        ok "no FATAL EXCEPTION"
    fi
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
fi

echo ""
info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
