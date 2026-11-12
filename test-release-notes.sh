#!/usr/bin/env bash
# Regression for the release body: it must be the store changelog.
#
# v1.0.31 published GitHub's generated "What's Changed" list — a wall of
# Crowdin and dependabot pull requests that says nothing about what a user
# gets. From 1.0.32 the body is seeded from the same file F-Droid reads,
# `fastlane/metadata/android/en-US/changelogs/<versionCode>.txt`, with the
# toolchain block under it and a compare link, and GitHub's own list is turned
# off.
#
# Static: it reads the workflow and the changelog, so it runs on any machine
# with the repo checked out — no emulator, no device.
#
# Fails on the pre-fix tree: the workflow writes only the toolchain block and
# sets generate_release_notes: true.
#
# Run: scripts/test-release-notes.sh
set -uo pipefail
cd "$(dirname "$0")/.."

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

WF=.github/workflows/release.yml
GRADLE=app/build.gradle.kts

[ -f "$WF" ] || { bad "no $WF"; echo "PASS=0 FAIL=1"; exit 1; }

CODE=$(sed -n 's/.*versionCode = \([0-9]*\).*/\1/p' "$GRADLE" | head -1)
NAME=$(sed -n 's/.*versionName = "\(.*\)"/\1/p' "$GRADLE" | head -1)
NOTE="fastlane/metadata/android/en-US/changelogs/${CODE}.txt"
info "Releasing $NAME ($CODE)"

info "The changelog exists and fits the store limit"
if [ -s "$NOTE" ]; then
    ok "$NOTE exists"
else
    bad "$NOTE is missing; F-Droid would have no note for $CODE"
    echo "PASS=$PASS FAIL=$FAIL"
    exit 1
fi
CHARS=$(wc -m < "$NOTE" | tr -d ' ')
if [ "$CHARS" -le 500 ]; then
    ok "the note is $CHARS characters (limit 500)"
else
    bad "the note is $CHARS characters, over the 500 limit"
fi
HEAD=$(head -1 "$NOTE")
case "$HEAD" in
    "New in $NAME:"|"Fixes since "*":") ok "the note opens with '$HEAD'" ;;
    *) bad "the first line '$HEAD' does not name $NAME" ;;
esac
if grep -q '^• ' "$NOTE"; then
    ok "bullets use the • marker"
else
    bad "no • bullets found"
fi

info "The workflow seeds the body from that file"
if grep -q 'fastlane/metadata/android/en-US/changelogs/' "$WF"; then
    ok "release.yml reads the fastlane changelog"
else
    bad "release.yml does not read the fastlane changelog"
fi
if grep -q 'changelogs/${CODE}.txt' "$WF"; then
    ok "the changelog is selected by versionCode"
else
    bad "the changelog is not selected by versionCode"
fi
if grep -qE 'generate_release_notes:\s*false' "$WF"; then
    ok "GitHub's own PR list is not appended"
else
    bad "generate_release_notes is not false; the PR list would follow the note"
fi
if grep -q 'Toolchain used for this build' "$WF" && grep -q 'APK SHA-256' "$WF"; then
    ok "the toolchain block and APK digest are kept"
else
    bad "the toolchain block or APK digest is missing"
fi

P1=$(grep -n 'Append the store changelog' "$WF" | cut -d: -f1 | head -1)
P2=$(grep -n 'Publish GitHub Release' "$WF" | cut -d: -f1 | head -1)
if [ -n "$P1" ] && [ -n "$P2" ] && [ "$P1" -lt "$P2" ]; then
    ok "the note is composed before the release is published"
else
    bad "the changelog step is missing or runs after publish ($P1/$P2)"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
