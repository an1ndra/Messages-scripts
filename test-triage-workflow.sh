#!/usr/bin/env bash
# Regression for #325: the Triage workflow failed on every comment with
# "invalid assessment (ArgumentError in reasoning_flag at assessment.rb:834)".
#
# copilot-triage validates its reasoning effort against none/low/default. The
# workflow forwarded `vars.TRIAGE_REASONING_EFFORT` bare; an unset repository
# variable renders as an empty string, which is a *present* input rather than a
# missing one, so it overrode the action's own default and tripped the guard.
# Each input now carries a valid fallback.
#
# This is a workflow change, so the check is static — there is no runtime path
# on the emulator to exercise.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

WF="$PROJECT_DIR/.github/workflows/triage.yml"

info "The workflow is present"
if [ ! -f "$WF" ]; then
    bad "triage.yml is missing at $WF"
    echo; echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi
ok "triage.yml present"

info "Each triage input has a fallback"
if grep -qF "reasoning-effort: \${{ vars.TRIAGE_REASONING_EFFORT || 'low' }}" "$WF"; then
    ok "reasoning-effort falls back to 'low'"
else
    bad "reasoning-effort has no fallback — an unset var sends '' and fails reasoning_flag"
fi
if grep -qF "model: \${{ vars.TRIAGE_MODEL || 'gpt-5.6-luna' }}" "$WF"; then
    ok "model falls back to the action default"
else
    bad "model has no fallback"
fi
if grep -qF "dry-run: \${{ vars.TRIAGE_DRY_RUN || false }}" "$WF"; then
    ok "dry-run falls back to false"
else
    bad "dry-run has no fallback"
fi

info "No input forwards a bare, possibly-empty variable"
if grep -qE '^[[:space:]]*(model|reasoning-effort|dry-run):[[:space:]]*\$\{\{[[:space:]]*vars\.[A-Za-z0-9_]+[[:space:]]*\}\}[[:space:]]*$' "$WF"; then
    bad "an input still forwards \${{ vars.X }} with no fallback"
else
    ok "no bare variable is forwarded"
fi

info "The action step survives"
if grep -qF "uses: crmne/copilot-triage@v0" "$WF"; then
    ok "copilot-triage step is intact"
else
    bad "copilot-triage step is missing"
fi
if python3 -c "import yaml, sys; yaml.safe_load(open(sys.argv[1]))" "$WF" 2>/dev/null; then
    ok "triage.yml parses as YAML"
elif python3 -c "import yaml" 2>/dev/null; then
    bad "triage.yml is not valid YAML"
else
    echo "  (PyYAML unavailable; skipped the strict parse)"
fi

echo
info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
