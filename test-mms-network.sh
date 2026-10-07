#!/usr/bin/env bash
# The :mms network binding's decisions, where they are specified today: the
# module's own JVM tests (no emulator) plus the source-level request contract.
# The request object itself cannot be built under the unit-test stubs —
# NetworkRequest.Builder answers every call with a default — so the conventions
# it must not get wrong (MMS capability, no INTERNET requirement, a
# subscription pinned only when one was named) are pinned against the builder's
# source. Named tests throughout, because a rename or a delete would leave the
# suite itself green.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
info() { printf '\n=== %s ===\n' "$*"; }

MODULE="$PROJECT_DIR/mms"
PKG="com.anindra.messages.mms.net"
RESULTS="$MODULE/build/test-results/testDebugUnitTest"
LOG="$TMP/mms-network-gradle.log"

GUARDED="aNamedSubscriptionPinsTheRequest
theDefaultAndNoSubscriptionDoNotPin
withNoConnectivityManagerTheBindingRefusesRatherThanGuessing
theRequestAsksForMmsAndNotInternet
aNamedSubscriptionIsTheCaseThatPinsOne"

[[ -d "$MODULE" ]] || { printf 'No :mms module at %s\n' "$MODULE"; exit 1; }
[[ -x "$PROJECT_DIR/gradlew" ]] || { printf 'No gradlew at %s\n' "$PROJECT_DIR"; exit 1; }

for cand in "$HOME/.local/java/"jdk-21.* "$HOME/tools/jdk21" "$JAVA_HOME"; do
  if [ -x "$cand/bin/java" ]; then export JAVA_HOME="$cand"; break; fi
done

info "Run the :mms network binding tests"
rm -rf "$RESULTS"
(cd "$PROJECT_DIR" && ./gradlew :mms:testDebugUnitTest --rerun-tasks \
  --tests "$PKG.MmsNetworkBindingTest" \
  --tests "$PKG.MmsNetworkRequestWiringTest") >"$LOG" 2>&1 || true
if [ ! -d "$RESULTS" ]; then
  fail "the network tests produced no results (build or compile failed)"
  grep -E '^e: |error:|FAILURE:|FAILED' "$LOG" | head -20 | sed 's/^/       /'
  printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
  exit $((FAIL > 0))
fi
pass "the network tests ran"

read -r TOTAL SKIPPED FAILURES ERRORS MISSING <<<"$(
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
print(total, skipped, failures, errors, ' '.join(absent))
PY
)"

info "Results"
[ "${TOTAL:-0}" -gt 0 ] && pass "$TOTAL network tests ran" || fail "no network tests ran"
[ -z "${MISSING// /}" ] || fail "these network guarantees are no longer asserted: $MISSING"
[ "${FAILURES:-1}" -eq 0 ] && pass "0 failures" || fail "$FAILURES failing network tests"
[ "${ERRORS:-1}" -eq 0 ] && pass "0 errors" || fail "$ERRORS errored network tests"
if [ "${SKIPPED:-0}" -gt 0 ]; then
  fail "$SKIPPED skipped network tests — a skipped assertion guards nothing"
else
  pass "0 skipped"
fi
printf '  %s tests, %s skipped, %s failures, %s errors\n' "$TOTAL" "$SKIPPED" "$FAILURES" "$ERRORS"

printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
