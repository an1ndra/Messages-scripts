#!/usr/bin/env bash
# Checks the composited Play Store screenshots.
#
# The listing set is generated, not captured, so the things worth asserting are
# geometric: Play rejects a 20:9 raw capture, the headline has to be legible on
# the backdrop, and the phone has to sit inside the frame rather than fill it.
# That can only be judged from pixels, which is why this script reads them
# instead of a uiautomator dump.
#
#   bash test-store-screenshots.sh
#
# Regenerate the set with:
#   bash take-fdroid-screenshots.sh          # raw captures -> screenshots/store-raw
#   python3 make-store-screenshots.py        # frames -> fastlane phoneScreenshots
set -uo pipefail
cd "$(dirname "$0")"
source ./env.sh

SHOTS="$PROJECT_DIR/fastlane/metadata/android/en-US/images/phoneScreenshots"
PASS=0
FAIL=0

ok()   { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad()  { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "\n=== $* ==="; }

info "The curated set is complete"
names=$(cd "$SHOTS" 2>/dev/null && ls -1 *.png 2>/dev/null | tr '\n' ' ')
expected="01-chats.png 01-conversations.png 01-home-dark.png 01-home.png 02-chat-dark.png 02-chat-grouped-bubbles.png 02-replying.png 02-settings.png 03-chat.png 03-chat-work.png 03-home-light.png 03-reactions.png 04-chat-alex.png 04-chat-light.png 04-contact.png 04-new-chat.png 05-chat-otp.png 05-contact.png 05-reaction.png 05-settings-light.png 06-new-chat.png 06-settings-dark.png 06-themes.png 06-typing.png 07-advanced.png 07-reply-dark.png 07-settings.png 07-sim-switcher.png 08-import.png 08-new-chat.png 08-reply-light.png 08-spam-blocked.png 09-settings-scroll-light.png 09-spam-blocked-messages.png 10-auto-delete.png 10-settings-scroll-dark.png 11-notification-grouped.png 11-scheduled-dark.png 12-scheduled-light.png 13-trash-dark.png 14-trash-light.png 15-contact-details-dark.png 16-contact-details-light.png 17-new-chat-dark.png 18-new-chat-light.png 19-archive-dark.png 20-archive-light.png 21-search-dark.png 21-search-light.png 22-starred-dark.png 22-starred-light.png "
[ "$names" = "$expected" ] && ok "51 shots, the full F-Droid name set" || bad "expected [$expected] got [$names]"

info "Every shot is a valid 9:16 listing frame with its text and phone in place"
python3 - "$SHOTS" <<'PY'
import sys, os
from PIL import Image

shots = os.path.join(sys.argv[1])
fails = 0
for name in sorted(os.listdir(shots)):
    if not name.endswith(".png"):
        continue
    path = os.path.join(shots, name)
    im = Image.open(path).convert("RGB")
    w, h = im.size
    top = im.getpixel((6, 6))
    bottom = im.getpixel((6, h - 2))
    outside = im.getpixel((10, 1400))
    inside = im.getpixel((200, 1400))
    last = im.getpixel((w // 2, h - 3))
    band = im.crop((90, 100, w - 90, 330))
    white = sum(1 for p in band.getdata() if min(p) > 232)

    problems = []
    if (w, h) != (1080, 1920):
        problems.append(f"{w}x{h} is not 1080x1920")
    brand = top[2] > top[0] + 40 and top[2] > 150
    slate = sum(top) < 320 and top[2] >= top[0]
    if not (brand or slate):
        problems.append(f"top backdrop {top} is neither the brand blue nor the dark slate")
    if sum(top) <= sum(bottom):
        problems.append("backdrop gradient does not darken downwards")
    margin_ok = (outside[2] > outside[0] + 40 and outside[2] > 100) or (
        sum(outside) < 260 and sum(outside) < sum(top))
    if not margin_ok:
        problems.append(f"left margin {outside} is not backdrop — the phone fills the frame")
    if inside == outside:
        problems.append("no phone at the centre column")
    # On the dark backdrop the screen content at the bottom is itself near
    # black, so "differs from the backdrop" cannot tell a clipped phone from a
    # gap. The dark set asserts the opposite way: the bottom centre must be a
    # dark pixel, which only happens when the phone overruns the canvas.
    low_margin = im.getpixel((10, 1700))
    low_centre = im.getpixel((w // 2, 1700))
    if slate:
        if not (sum(low_margin) < 260 and low_margin != low_centre):
            problems.append(f"lower margin {low_margin} does not show the backdrop beside the phone")
    elif sum(abs(a - b) for a, b in zip(last, bottom)) < 60:
        problems.append("phone does not reach the bottom edge")
    if white < 4000:
        problems.append(f"only {white} white pixels in the headline band — no headline")

    if problems:
        print(f"  [FAIL] {name}: " + "; ".join(problems))
        fails += 1
    else:
        print(f"  [PASS] {name}: 1080x1920, headline {white} white px, framed")
sys.exit(1 if fails else 0)
PY
if [ $? -eq 0 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi

info "Result"
echo "  PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && echo "=== OK ===" || echo "=== FAILED ==="
exit $((FAIL > 0))
