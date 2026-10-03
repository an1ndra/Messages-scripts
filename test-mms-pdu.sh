#!/usr/bin/env bash
# The :mms module's pure-JVM PDU and SMIL unit tests, run through Gradle and
# read back from the JUnit XML. Counts come from the XML rather than Gradle's
# console output so the numbers in the [PASS]/[FAIL] lines are the ones the
# test task actually recorded.
#
# No emulator: these tests touch no Android framework, so this is the one MMS
# script that runs on a build machine. It is the gate the other :mms scripts
# assume is green.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
info() { printf '\n=== %s ===\n' "$*"; }

MODULE="$PROJECT_DIR/mms"
RESULTS="$MODULE/build/test-results/testDebugUnitTest"
LOG="$TMP/mms-pdu-gradle.log"
read -r CLASSES <<'EOF'
com.anindra.messages.mms.pdu.PduComposerTest com.anindra.messages.mms.pdu.PduParserTest com.anindra.messages.mms.pdu.PduHeadersTest com.anindra.messages.mms.pdu.WspTest com.anindra.messages.mms.pdu.EncodedStringValueTest com.anindra.messages.mms.pdu.ContentTypesTest com.anindra.messages.mms.smil.SmilBuilderTest com.anindra.messages.mms.smil.SmilParserTest com.anindra.messages.mms.smil.SmilSerializerTest
EOF
read -r -a CLASS_ARR <<<"$CLASSES"

[[ -d "$MODULE" ]] || { printf 'No :mms module at %s\n' "$MODULE"; exit 1; }
[[ -x "$PROJECT_DIR/gradlew" ]] || { printf 'No gradlew at %s\n' "$PROJECT_DIR"; exit 1; }

# Same fallback chain as install.sh: the caller's JAVA_HOME may point at a JDK
# the wrapper cannot use.
for cand in "$HOME/.local/java/"jdk-21.* "$HOME/tools/jdk21" "$JAVA_HOME"; do
  if [ -x "$cand/bin/java" ]; then export JAVA_HOME="$cand"; break; fi
done

info "Run the :mms PDU and SMIL unit tests"
# Stale XML from a previous run would otherwise be counted as this run's result.
rm -rf "$RESULTS"
(cd "$PROJECT_DIR" && ./gradlew :mms:testDebugUnitTest --rerun-tasks \
  --tests 'com.anindra.messages.mms.pdu.*' \
  --tests 'com.anindra.messages.mms.smil.*') >"$LOG" 2>&1 || true
if [ ! -d "$RESULTS" ]; then
  fail "the :mms test task produced no results (build or compile failed)"
  grep -E '^e: |error:|FAILURE:|FAILED' "$LOG" | head -20 | sed 's/^/       /'
  printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
  exit $((FAIL > 0))
fi
pass "the :mms test task produced results"

info "Results"
read -r TOTAL SKIPPED FAILURES ERRORS PRESENT MISSING <<<"$(
  python3 - "$RESULTS" "$CLASSES" <<'PY'
import glob, os, sys, xml.etree.ElementTree as ET
results, wanted = sys.argv[1], sys.argv[2].split()
total = skipped = failures = errors = 0
seen = set()
for path in glob.glob(os.path.join(results, 'TEST-*.xml')):
    suite = ET.parse(path).getroot()
    if suite.tag != 'testsuite':
        continue
    seen.add(suite.get('name'))
    total += int(suite.get('tests', 0))
    skipped += int(suite.get('skipped', 0))
    failures += int(suite.get('failures', 0))
    errors += int(suite.get('errors', 0))
absent = [c for c in wanted if c not in seen]
print(total, skipped, failures, errors, len(seen) - len(absent), ' '.join(absent))
PY
)"

[ "${TOTAL:-0}" -gt 0 ] && pass "$TOTAL PDU/SMIL tests ran" || fail "no PDU/SMIL tests ran"
[ "${PRESENT:-0}" -eq "${#CLASS_ARR[@]}" ] \
  && pass "all ${#CLASS_ARR[@]} expected test classes reported results" \
  || fail "only ${PRESENT:-0} of ${#CLASS_ARR[@]} expected test classes reported results"
[ -z "${MISSING// /}" ] \
  || fail "no result file for: ${MISSING}"
[ "${FAILURES:-1}" -eq 0 ] && pass "0 failures" || fail "$FAILURES failing PDU/SMIL tests"
[ "${ERRORS:-1}" -eq 0 ] && pass "0 errors" || fail "$ERRORS errored PDU/SMIL tests"
if [ "${SKIPPED:-0}" -gt 0 ]; then
  fail "$SKIPPED skipped tests — a skipped assertion guards nothing"
else
  pass "0 skipped"
fi
printf '  %s tests, %s skipped, %s failures, %s errors\n' "$TOTAL" "$SKIPPED" "$FAILURES" "$ERRORS"

printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
exit $((FAIL > 0))