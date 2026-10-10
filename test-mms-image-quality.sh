#!/usr/bin/env bash
# Regression for the MMS image-quality rules (Phase B).
#
# A carrier that declares no image bounds still hands the app a 640x480
# default. Enforcing that guess cut every photo down to it, which is why a
# picture sent from another app arrived sharp and this one did not. The rule is
# now: enforce the dimension cap only when the carrier declared it, and spend
# the byte budget on quality before resolution.
#
# Sending a real MMS needs a carrier, which the AVD does not have, so this
# asserts what is observable without one: the verdict the report prints, and
# the search order the encoder walks (which is what decides sharpness).
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

cleanup() {
    adb_ shell am force-stop "$PKG" >/dev/null 2>&1
}
trap cleanup EXIT

MODULE="$PROJECT_DIR/mms/src/main/java/com/anindra/messages/mms"

info "The carrier verdict is read from the platform layer only"
# The app-defaults layer always carries 640x480, so a merged check would answer
# "declared" for every carrier and the cap would be enforced everywhere.
if grep -A 6 "fun imageLimitsReported" "$MODULE/net/CarrierProfile.kt" | \
   grep -q "fromPlatform"; then
    ok "imageLimitsReported consults the platform layer"
else
    bad "imageLimitsReported does not consult the platform layer"
fi

info "The fitter only enforces the cap when it was declared"
if grep -A 3 "dimensionLimitsReported" "$MODULE/fit/ImageAttachmentFitter.kt" | \
   grep -q "request.maxImageWidth"; then
    ok "the declared cap is applied"
else
    bad "the declared cap is not applied"
fi
if grep -q "MAX_UNREPORTED_EDGE" "$MODULE/fit/ImageAttachmentFitter.kt"; then
    ok "an undeclared cap falls back to the unreported edge, not to 640x480"
else
    bad "no fallback for an undeclared image cap"
fi

info "Quality is spent before resolution"
if grep -A 16 "fun searchPlan" "$MODULE/fit/ImageAttachmentFitter.kt" | \
   grep -q "index == sizeSteps.lastIndex"; then
    ok "the full quality ladder is kept for the smallest size only"
else
    bad "search plan does not reserve the full ladder for the last step"
fi

info "The send path passes the verdict through"
if grep -q "dimensionLimitsReported = profile.imageLimitsReported()" \
   "$MODULE/Mms.kt"; then
    ok "Mms.fit tells the fitter whether the cap is real"
else
    bad "Mms.fit does not pass imageLimitsReported to the fitter"
fi

info "Report states the verdict for the SIM"
cleanup
adb_ shell am start -n "$ACT" --ez open_settings true >/dev/null 2>&1; sleep 3
adb_ shell input swipe 500 1900 500 700 400 >/dev/null 2>&1; sleep 0.5
adb_ shell input swipe 500 1900 500 700 400 >/dev/null 2>&1; sleep 1
tap_text "Advanced settings" >/dev/null 2>&1 || center_of_contains "Advanced" >/dev/null 2>&1
sleep 1.5
for i in 1 2 3 4 5; do
    dump_ui || true
    grep -q 'text="Diagnostics"' "$TMP/ui.xml" && break
    adb_ shell input swipe 540 1700 540 900 250 >/dev/null 2>&1; sleep 0.4
done
if tap_text "Diagnostics" >/dev/null 2>&1; then
    sleep 2
    dump_ui || true
    if grep -q "imageLimitsReported:" "$TMP/ui.xml"; then
        ok "Diagnostics prints the image-cap verdict"
    else
        bad "Diagnostics does not print imageLimitsReported"
    fi
else
    bad "could not open Diagnostics"
fi

echo -e "\n=== $PASS passed, $FAIL failed ==="
exit $((FAIL > 0))