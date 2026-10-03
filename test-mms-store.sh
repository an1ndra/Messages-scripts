#!/usr/bin/env bash
# Provider persistence for the :mms module.
#
# There is no Diagnostics surface for this yet: DiagnosticsReport's only MMS
# line is "MMS carrier config", a per-SIM dump of CarrierConfigManager keys from
# SimMmsProbe. Nothing in the report reads content://mms, so there is no way to
# seed a message through Diagnostics and read it back, and nothing to assert
# against on the device. This script therefore covers the persistence contract
# where it is actually specified today — the store package's own JVM tests,
# which drive TelephonyMmsStore against a FakeContentResolver.
#
# Replace this when a Diagnostics probe lands: it would then be a uiautomator
# script asserting a provider row count from the report text, which is faster to
# read than a JVM run and covers the real provider rather than the fake.
#
# No emulator and no direct provider-database writes, so this runs on a build
# machine. The named tests are required individually: a store contract that
# stops being asserted still leaves the suite green.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
info() { printf '\n=== %s ===\n' "$*"; }

MODULE="$PROJECT_DIR/mms"
PKG="com.anindra.messages.mms.store"
RESULTS="$MODULE/build/test-results/testDebugUnitTest"
LOG="$TMP/mms-store-gradle.log"

# The persistence guarantees, each pinned by a named test. A rename or a delete
# is a regression here even though the suite would still be green.
GUARDED="boxValuesAreTheProviders
fiveIsFailedAndNotATemporaryBox
onlyTheBoxesWithACollectionHaveAUriPath
eachAddressableBoxPersistsIntoItsOwnUriPath
persistingIntoABoxWithNoCollectionIsRefusedRatherThanGuessed
movingToFailedKeepsTheRowAtItsExistingUri
pendingQueueAsksForDueRetryableRowsOnly
pendingRowsAreOrderedByDueTime
pendingErrorTypeIsWrittenAndTheRowCanBeDropped
partBytesRoundTripThroughTheProviderStream
readingAndDeletingAMessageTouchTheProviderRow
aMessageWithoutAThreadOrSubscriptionIdOmitsThoseColumns
headersRoundTripThroughTheMappedColumns
messageSizeDefaultsToTheSumOfTheParts
loadOfSomethingThatIsNotAMessageIsNull
persistWritesMessagePartsAndAddresses
partsAreWrittenBeforeTheMessageRowAndRepointedAfterwards
textGoesToAColumnAndBinaryIsStreamed
loadRebuildsThePduThatWasPersisted
moveTouchesOnlyTheMessageBox
aProviderFailureBecomesNullOrFalseInsteadOfEscaping
subIdProbeRunsOnceAndItsAnswerIsReused
threadIdExcludesThisDeviceAndUsesThePlatformComparison"

[[ -d "$MODULE" ]] || { printf 'No :mms module at %s\n' "$MODULE"; exit 1; }
[[ -x "$PROJECT_DIR/gradlew" ]] || { printf 'No gradlew at %s\n' "$PROJECT_DIR"; exit 1; }

for cand in "$HOME/.local/java/"jdk-21.* "$HOME/tools/jdk21" "$JAVA_HOME"; do
  if [ -x "$cand/bin/java" ]; then export JAVA_HOME="$cand"; break; fi
done

info "Run the :mms store contract tests"
rm -rf "$RESULTS"
(cd "$PROJECT_DIR" && ./gradlew :mms:testDebugUnitTest --rerun-tasks --tests "$PKG.*") >"$LOG" 2>&1 || true
if [ ! -d "$RESULTS" ]; then
  fail "the store tests produced no results (build or compile failed)"
  grep -E '^e: |error:|FAILURE:|FAILED' "$LOG" | head -20 | sed 's/^/       /'
  printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
  exit $((FAIL > 0))
fi
pass "the store tests ran"

read -r TOTAL SKIPPED FAILURES ERRORS SUITES MISSING <<<"$(
  python3 - "$RESULTS" "$PKG" "$(printf '%s\n' "$GUARDED" | tr '\n' ' ')" <<'PY'
import glob, os, sys, xml.etree.ElementTree as ET
results, pkg, wanted = sys.argv[1], sys.argv[2], sys.argv[3].split()
total = skipped = failures = errors = 0
cases = set()
for path in glob.glob(os.path.join(results, 'TEST-*.xml')):
    suite = ET.parse(path).getroot()
    if suite.tag != 'testsuite' or not suite.get('name', '').startswith(pkg):
        continue
    total += int(suite.get('tests', 0))
    skipped += int(suite.get('skipped', 0))
    failures += int(suite.get('failures', 0))
    errors += int(suite.get('errors', 0))
    cases.update(c.get('name') for c in suite.iter('testcase'))
absent = [n for n in wanted if n not in cases]
print(total, skipped, failures, errors, len(cases), ' '.join(absent))
PY
)"

info "Results"
[ "${TOTAL:-0}" -gt 0 ] && pass "$TOTAL store tests ran" || fail "no store tests ran"
[ "${SUITES:-0}" -ge 2 ] \
  && pass "both store test classes reported results" \
  || fail "only ${SUITES:-0} store test classes reported results (expected the contract and write-path classes)"
[ -z "${MISSING// /}" ] || fail "these provider guarantees are no longer asserted: $MISSING"
[ "${FAILURES:-1}" -eq 0 ] && pass "0 failures" || fail "$FAILURES failing store tests"
[ "${ERRORS:-1}" -eq 0 ] && pass "0 errors" || fail "$ERRORS errored store tests"
if [ "${SKIPPED:-0}" -gt 0 ]; then
  fail "$SKIPPED skipped store tests — a skipped assertion guards nothing"
else
  pass "0 skipped"
fi
printf '  %s tests, %s skipped, %s failures, %s errors\n' "$TOTAL" "$SKIPPED" "$FAILURES" "$ERRORS"

printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
exit $((FAIL > 0))