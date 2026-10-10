#!/usr/bin/env bash
# The :mms facade's send bookkeeping, where it is actually specified: the
# module's own JVM tests drive Mms against scripted transports and a faked
# store. Two guarantees the provider row depends on — a refused send leaves a
# *failed* box rather than an outbox row that still looks in flight, and two
# sends inside one second do not share the MMSC's only deduplication key — are
# pinned by named tests, because the suite staying green after one of them is
# renamed or deleted would guard nothing.
#
# No emulator: the facade, the transport seam and the store are pure Kotlin.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
info() { printf '\n=== %s ===\n' "$*"; }

MODULE="$PROJECT_DIR/mms"
PKG="com.anindra.messages.mms"
RESULTS="$MODULE/build/test-results/testDebugUnitTest"
LOG="$TMP/mms-facade-gradle.log"

# Each guarantee is pinned by a named test. A rename or a delete is a
# regression here even though the suite itself would still be green.
GUARDED="aRefusedSendMovesTheRowToFailed
anUnreadableResponseStatusIsNotTreatedAsDelivered
twoSendsInTheSameSecondGetDifferentTransactionIds"

[[ -d "$MODULE" ]] || { printf 'No :mms module at %s\n' "$MODULE"; exit 1; }
[[ -x "$PROJECT_DIR/gradlew" ]] || { printf 'No gradlew at %s\n' "$PROJECT_DIR"; exit 1; }

for cand in "$HOME/.local/java/"jdk-21.* "$HOME/tools/jdk21" "$JAVA_HOME"; do
  if [ -x "$cand/bin/java" ]; then export JAVA_HOME="$cand"; break; fi
done

info "Run the :mms facade and send-request tests"
rm -rf "$RESULTS"
(cd "$PROJECT_DIR" && ./gradlew :mms:testDebugUnitTest --rerun-tasks \
  --tests "$PKG.MmsFacadeTest" \
  --tests "$PKG.SendReqBuilderTest") >"$LOG" 2>&1 || true
if [ ! -d "$RESULTS" ]; then
  fail "the facade tests produced no results (build or compile failed)"
  grep -E '^e: |error:|FAILURE:|FAILED' "$LOG" | head -20 | sed 's/^/       /'
  printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
  exit $((FAIL > 0))
fi
pass "the facade tests ran"

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
[ "${TOTAL:-0}" -gt 0 ] && pass "$TOTAL facade tests ran" || fail "no facade tests ran"
[ -z "${MISSING// /}" ] || fail "these send guarantees are no longer asserted: $MISSING"
[ "${FAILURES:-1}" -eq 0 ] && pass "0 failures" || fail "$FAILURES failing facade tests"
[ "${ERRORS:-1}" -eq 0 ] && pass "0 errors" || fail "$ERRORS errored facade tests"
if [ "${SKIPPED:-0}" -gt 0 ]; then
  fail "$SKIPPED skipped facade tests — a skipped assertion guards nothing"
else
  pass "0 skipped"
fi
printf '  %s tests, %s skipped, %s failures, %s errors\n' "$TOTAL" "$SKIPPED" "$FAILURES" "$ERRORS"

printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
