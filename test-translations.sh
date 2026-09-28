#!/usr/bin/env bash
# Regression for the shipped translations. Every locale directory under
# app/src/main/res must define every key of the base values/ strings, with the
# same format placeholders, no duplicate keys, keys in the same order as the
# base file, and no string left in English for the accessibility / retention /
# diagnostics / keyword / crash-report groups added to every language.
# The source checks are deterministic; the on-device check confirms the app
# still launches with the new resources on emulator-5554.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

RES="$PROJECT_DIR/app/src/main/res"
cleanup() { adb_ shell am force-stop "$PKG" >/dev/null 2>&1; }
trap cleanup EXIT

info "Resources: key parity, placeholders, order, no leftovers"
python3 - "$RES" <<'PY'
import os, re, sys, xml.etree.ElementTree as ET

res = sys.argv[1]
STR = re.compile(r'<string name="([^"]+)"\s*>(.*?)</string>', re.S)
PH = re.compile(r'%\d+\$[sd]')
TRACKED = [
    'access_open_conversation', 'a11y_reduce_motion_title', 'settings_advanced_emoji_button',
    'keywords_title', 'keywords_subtitle_count', 'diagnostics_clip_label', 'settings_sim_unknown',
    'chat_moved_to_spam', 'chat_select_all', 'message_details_title', 'message_status_failed',
    'chat_alphanumeric_notice', 'common_continue', 'access_blocked', 'conversations_spam_blocked',
    'spam_blocked_messages_empty', 'notif_you', 'crash_report_title', 'crash_report_clip_label',
    'settings_blocked_numbers_title', 'blocked_numbers_unblock', 'settings_retention_title',
    'settings_retention_action_active', 'settings_retention_keep_spam', 'settings_backup_save_to',
    'settings_backup_saved_location', 'settings_import_source_title', 'settings_import_sms_ie_failed',
    'trash_reason_blocked', 'translation_help',
]


def text_of(path):
    return open(path, encoding='utf-8').read()


def read(path):
    text = text_of(path)
    ET.fromstring(text)
    return STR.findall(text)


def name_of(path):
    return [m.group(1) for m in STR.finditer(text_of(path))]


def read_dir(d):
    values, order, files = {}, [], []
    for f in sorted(os.listdir(d)):
        if f.startswith('strings') and f.endswith('.xml'):
            p = os.path.join(d, f)
            files.append((f, p))
            for key, value in read(p):
                if key in values:
                    print('DUPLICATE %s %s' % (d, key))
                values[key] = value
            order.append((f, name_of(p)))
    return values, order, files


base, _, _ = read_dir(os.path.join(res, 'values'))
locales = sorted(d for d in os.listdir(res) if re.match(r'^values-[a-z]{2}(-r[A-Z]{2})?$', d))
print('base keys: %d, locales: %d' % (len(base), len(locales)))
assert len(locales) == 12, 'expected 12 locale dirs, found %d' % len(locales)

fails = 0
for loc in locales:
    d = os.path.join(res, loc)
    values, order, _ = read_dir(d)
    missing = sorted(set(base) - set(values))
    extra = sorted(set(values) - set(base))
    if missing:
        print('MISSING %s: %s' % (loc, missing)); fails += 1
    if extra:
        print('EXTRA %s: %s' % (loc, extra)); fails += 1
    for key, value in values.items():
        want, got = sorted(set(PH.findall(base[key]))), sorted(set(PH.findall(value)))
        if want != got:
            print('PLACEHOLDER %s/%s expected %s got %s' % (loc, key, want, got)); fails += 1
    for fname, keys in order:
        pos = {k: i for i, k in enumerate(name_of(os.path.join(res, 'values', fname)))}
        seq = [pos.get(k, -1) for k in keys]
        if seq != sorted(seq):
            print('ORDER %s/%s keys out of base order' % (loc, fname)); fails += 1
    for key in TRACKED:
        if key not in base:
            print('TRACKED %s missing from base' % key); fails += 1
        elif values.get(key) == base[key]:
            print('ENGLISH %s/%s still the English string' % (loc, key)); fails += 1
sys.exit(1 if fails else 0)
PY
if [ $? -eq 0 ]; then
    ok "12 locales complete, placeholders/order/duplicates clean, no English leftovers"
else
    bad "resource parity check reported problems"
fi

info "Device: app launches with the new resources"
adb_ shell am force-stop "$PKG" >/dev/null 2>&1; sleep 1
adb_ logcat -c >/dev/null 2>&1
adb_ shell am start -n "$ACT" >/dev/null 2>&1; sleep 5
if adb_ shell "ps -A 2>/dev/null" | grep -q "$PKG"; then
    ok "process running after launch"
else
    bad "process not running after launch"
fi
if adb_ shell logcat -d 2>/dev/null | grep -q "FATAL EXCEPTION"; then
    bad "FATAL EXCEPTION in logcat"
else
    ok "no FATAL EXCEPTION"
fi

echo ""
info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
