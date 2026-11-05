#!/usr/bin/env bash
# Regression for CodeQL action pinning across .github/workflows/.
#
# github/codeql-action/analyze reads the configuration written by
# github/codeql-action/init and refuses to run when their versions differ.
# Dependabot bumped analyze and upload-sarif to v4.39.1 but left init on
# v4.38.2, so every CodeQL job died at the analyze post-step with
#
#   Loaded a configuration file for version '4.38.2', but running version '4.39.1'
#
# The scheduled scans failed from 2026-10-19 and the v1.0.31 release run too.
#
# The checks are static, but every script bootstraps through env.sh.
# Run: bash scripts/test-security-workflow.sh
source "$(dirname "$0")/env.sh"

WF="$PROJECT_DIR/.github/workflows"
SEC="$WF/security.yml"
DB="$PROJECT_DIR/.github/dependabot.yml"

PASS=0
FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }

info "1. every github/codeql-action step in a workflow uses one commit"
found=0
for f in "$WF"/*.yml "$WF"/*.yaml; do
    [ -f "$f" ] || continue
    pins=$(grep -oE 'github/codeql-action/[A-Za-z-]+@[0-9a-f]{40}' "$f" | sort -u)
    [ -n "$pins" ] || continue
    found=1
    distinct=$(printf '%s\n' "$pins" | sed 's/.*@//' | sort -u | wc -l | tr -d ' ')
    name=$(basename "$f")
    if [ "$distinct" -eq 1 ]; then
        sha=$(printf '%s\n' "$pins" | head -1 | sed 's/.*@//' | cut -c1-7)
        pass "$name: all CodeQL steps share @$sha"
    else
        fail "$name mixes CodeQL action versions:"
        printf '%s\n' "$pins" | sed 's/^/       /'
    fi
done
if [ "$found" -eq 0 ]; then
    fail "no github/codeql-action pins found in $WF"
fi

info "2. security.yml still runs init and analyze"
if grep -qE 'github/codeql-action/init@[0-9a-f]{40}' "$SEC"; then
    pass "security.yml runs codeql-action/init"
else
    fail "security.yml does not run codeql-action/init"
fi
if grep -qE 'github/codeql-action/analyze@[0-9a-f]{40}' "$SEC"; then
    pass "security.yml runs codeql-action/analyze"
else
    fail "security.yml does not run codeql-action/analyze"
fi

info "3. dependabot updates the CodeQL actions together"
if grep -q '"github/codeql-action\*"' "$DB"; then
    pass "dependabot groups github/codeql-action"
else
    fail "dependabot does not group github/codeql-action - a split bump will break analyze again"
fi

info "4. SecurityWorkflowTest agrees"
cd "$PROJECT_DIR" || exit 1
# --rerun: the test reads the workflow file at runtime, which Gradle does not
# know about, so without it the task is UP-TO-DATE and "passes" on stale input.
if ./gradlew --quiet :app:testDebugUnitTest --tests "com.anindra.messages.ci.SecurityWorkflowTest" --rerun; then
    pass "SecurityWorkflowTest passes"
else
    fail "SecurityWorkflowTest fails"
fi

printf '\n[RESULT] %d passed, %d failed\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
