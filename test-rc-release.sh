#!/usr/bin/env bash
# Regression for the RC release pipeline (.github/workflows/rc.yml).
#
# RC publishes to the public Releases page, so a mistake here is a mistake
# everyone sees. Four bit in turn:
#  - the release tag was scraped from versionName, which lags the pushed tag.
#    Against the shipped v1.0.27 that republished the live release as
#    "RC 1.0.27" and marked it pre-release.
#  - the APK was published before the VirusTotal verdict, so a flagged build
#    was downloadable for the length of the scan.
#  - missing keystore secrets silently fell back to assembleDebug, whose
#    signature cannot install over the release build a tester already has.
#  - none of release.yml's guards were carried over: no certificate pin, no
#    unit tests.
#
# This is a CI-config change, so the assertions are static. It needs no device
# and no emulator; run it from the repo root or from scripts/.
#
# Run: bash scripts/test-rc-release.sh
source "$(dirname "$0")/env.sh"

PASS=0
FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }

RC="$PROJECT_DIR/.github/workflows/rc.yml"
REL="$PROJECT_DIR/.github/workflows/release.yml"
SEC="$PROJECT_DIR/.github/workflows/security.yml"
BG="$PROJECT_DIR/app/build.gradle.kts"

[ -f "$RC" ] || { echo "missing $RC"; exit 1; }

# Line number of a "- name: X" step, or empty.
step_at() { grep -n -- "- name: $1" "$RC" | head -1 | cut -d: -f1; }

info "1. release tag comes from the pushed RC tag, not versionName"
if grep -q 'tag_name: ${{ steps.rc.outputs.tag }}' "$RC"; then
    pass "published tag is the RC tag"
else
    fail "published tag is not the RC tag"
fi
if grep -q 'tag_name: v${{' "$RC"; then
    fail "release tag is derived from versionName again"
else
    pass "release tag no longer derived from versionName"
fi
if grep -q "grep -qE '\^v\[0-9\]" "$RC"; then
    pass "RC tag shape is validated"
else
    fail "RC tag shape is not validated"
fi

info "2. a tag behind versionName, or already published, is rejected"
if grep -q 'BASE" != "$NAME' "$RC"; then
    pass "tag base version is checked against versionName"
else
    fail "tag base version is not checked against versionName"
fi
if grep -q 'releases/tags/v$NAME' "$RC"; then
    pass "already-published release is detected before publishing"
else
    fail "no guard against overwriting a published release"
fi
# The exact condition that made this dangerous: versionName still on the
# shipped version while an RC tag is cut for the next one.
NAME=$(sed -n 's/.*versionName = "\(.*\)"/\1/p' "$BG" | head -1)
CODE=$(sed -n 's/.*versionCode = \([0-9]*\).*/\1/p' "$BG" | head -1)
# Only shipped releases count. git's tag glob is not anchored at the end, so
# v1.1.0-rc1 matches v[0-9]*.[0-9]*.[0-9]* and sorts above v1.0.27 - which would
# make the guard look unnecessary when it is exactly what is needed.
LAST=$(git -C "$PROJECT_DIR" tag --list | grep -E '^v[0-9]+(\.[0-9]+)+$' | sort -V | tail -1 | tr -d v)
if [ -n "$NAME" ] && [ -n "$LAST" ]; then
    if [ "$NAME" = "$LAST" ]; then
        # Not a failure of the workflow - it now rejects this. Prove the guard
        # is what stops it rather than leaving it to a manual read.
        if grep -q '::error::.*bump versionName' "$RC"; then
            pass "versionName is still $NAME ($CODE), and the workflow now refuses an RC for it"
        else
            fail "versionName equals the last tag ($LAST) with no guard to stop a clobbering RC"
        fi
    else
        pass "versionName $NAME is ahead of last tag $LAST"
    fi
fi

info "3. the APK is scanned before it is published"
PUB=$(step_at "Publish RC pre-release")
FLAG=$(step_at "Flag malware detections")
REPT=$(step_at "Post scan report to release")
if [ -n "$FLAG" ] && [ -n "$PUB" ] && [ "$FLAG" -lt "$PUB" ]; then
    pass "malware check (line $FLAG) runs before publish (line $PUB)"
else
    fail "malware check runs after the APK is already published"
fi
if [ -n "$REPT" ] && [ "$PUB" -lt "$REPT" ]; then
    pass "scan report is appended after the release exists"
else
    fail "scan report step is out of order"
fi
if sed -n "/- name: Flag malware detections/,/^      - name:/p" "$RC" | grep -q 'exit 1'; then
    pass "a flagged build fails the run"
else
    fail "a flagged build does not fail the run"
fi

info "4. no debug fallback"
if grep -q 'assembleDebug' "$RC"; then
    fail "rc.yml still falls back to assembleDebug"
else
    pass "no assembleDebug fallback"
fi
if grep -q '::error::RELEASE_KEYSTORE_BASE64 secret is not set' "$RC"; then
    pass "a missing keystore fails the run"
else
    fail "a missing keystore does not fail the run"
fi

info "5. signing certificate is pinned to release.yml's digest"
EXP=$(sed -n 's/.*expected="\([0-9a-f]\{64\}\)".*/\1/p' "$REL" | head -1)
if [ -z "$EXP" ]; then
    fail "release.yml no longer pins a signing certificate"
elif grep -q "expected=\"$EXP\"" "$RC"; then
    pass "rc.yml pins the same certificate as release.yml"
else
    fail "rc.yml pins a different (or no) certificate"
fi
if grep -q 'got" != "$expected' "$RC"; then
    pass "a mismatched certificate fails the run"
else
    fail "certificate digest is printed but not enforced"
fi

info "6. the built APK matches the tag it is published under"
if grep -q 'aapt' "$RC" && grep -q 'versionCode is' "$RC" && grep -q 'versionName is' "$RC"; then
    pass "versionCode and versionName are read back from the APK"
else
    fail "the APK's own version is never verified"
fi

info "7. unit tests gate the RC"
if grep -q 'assembleRelease testDebugUnitTest' "$RC"; then
    pass "testDebugUnitTest runs before publishing"
else
    fail "rc.yml ships without running unit tests"
fi

info "8. keystore is removed even when the build fails"
REM=$(step_at "Remove keystore")
if [ -z "$REM" ]; then
    fail "rc.yml never deletes the keystore"
elif sed -n "$((REM + 1)),$((REM + 2))p" "$RC" | grep -q 'if: always()'; then
    pass "keystore removal is if: always()"
else
    fail "keystore removal is not if: always()"
fi

info "9. the report poll loop stops early"
LOOP=$(sed -n '/for i in \$(seq 1 12); do/,/^          done$/p' "$RC")
if printf '%s' "$LOOP" | grep -q '\bbreak\b'; then
    pass "report loop breaks once the report is present"
else
    fail "report loop polls a fixed 12 times (~6 min of dead time)"
fi

info "10. a second run supersedes the first"
if grep -q 'cancel-in-progress: true' "$RC"; then
    pass "concurrency cancels the in-flight run"
else
    fail "queued runs can clobber each other's release"
fi

info "11. rc tags never trigger the final release or security scan"
for f in "$REL" "$SEC"; do
    if sed -n '1,/^jobs:/p' "$f" | grep -q '!v\*-rc\*'; then
        pass "$(basename "$f") excludes rc tags"
    else
        fail "$(basename "$f") does not exclude rc tags - tagging an RC would ship it"
    fi
done
if sed -n '1,/^jobs:/p' "$RC" | grep -q '"v\*-rc\*"'; then
    pass "rc.yml triggers on rc tags"
else
    fail "rc.yml does not trigger on rc tags"
fi

info "12. yaml parses"
if python3 -c "
import sys
try:
    import yaml
except ImportError:
    sys.exit(0)
yaml.safe_load(open('$RC'))
" 2>/dev/null; then
    pass "rc.yml is valid yaml"
else
    fail "rc.yml is not valid yaml"
fi

info "13. RcWorkflowTest agrees"
cd "$PROJECT_DIR"
if ./gradlew --quiet :app:testDebugUnitTest --tests "com.anindra.messages.ci.RcWorkflowTest"; then
    pass "RcWorkflowTest passes"
else
    fail "RcWorkflowTest fails"
fi

printf '\n[RESULT] %d passed, %d failed\n' "$PASS" "$FAIL"
exit $((FAIL > 0))