# Development.md — Script development reference

How the test harness works, how to run tests, and how to add a new regression
script. For deep internals see [Developer.md](Developer.md); for agent rules see
[AGENTS.md](AGENTS.md); for task status see [TODO.md](TODO.md).

---

## 1. Quick reference

| Action | Command |
|---|---|
| Full sweep | `bash run-all-tests.sh` |
| Build + install app | `bash install.sh` (`./gradlew assembleDebug` in the app) |
| Cold launch app | `bash open-app.sh` |
| One regression | `bash test-<area>.sh` |
| Inject inbound SMS | `bash receive-sms.sh <number> [text]` |
| Permissions | `bash grant-permissions.sh` / `bash reset-permissions.sh` |

Scripts self-locate via `dirname "$0"` — run them from anywhere; no `cd` into
the app repo needed. They need `env.sh` on the same directory and an emulator
(`emulator-5554`).

## 2. Architecture

```
env.sh                  shared helpers: adb_, shot, tap_text, center_of, dump_ui, ...
install*.sh             build/install helper
open-app.sh             cold launch
receive-sms.sh          adb emu sms send injection
theme.sh / settings.sh  deep-link navigation (set_theme / open_settings)
insert-demo-contacts.sh seeds F-Droid demo contacts into the Contacts provider
seed-google-comparison.sh seeds data for comparing against real Google Messages
test-*.sh               one regression/verification script per feature
take-fdroid-screenshots.sh  F-Droid screenshot pipeline
```

All scripts use `env.sh` (`source "$(dirname "$0")/env.sh"`). It exports the
device/package defaults (`ADB`, `ANDROID_SERIAL`, `PKG`, `ACT`, `SHOTS_DIR`,
`TMP`) and the assert/drive helpers.

## 3. Core helpers (`env.sh`)

| Helper | Purpose |
|---|---|
| `adb_ <cmd>` | `$ADB -s $ANDROID_SERIAL` wrapper |
| `shot <name>` | `screencap` → `$SHOTS_DIR/<name>.png` |
| `type_text <t>` | `input text` with `%s`→space encoding |
| `dump_ui` / `ui_tags` | uiautomator dump → `$TMP/ui.xml`; `ui_tags` splits nodes |
| `re_escape <t>` | escape ERE metachars (`+`, `.`, `()`) for greps |
| `center_of <text>` | `"X Y"` center of node matching text/content-desc |
| `center_of_contains <sub>` | center of first node whose text contains `<sub>` (3x retry) |
| `tap_text <text>` | tap center of matching node |
| `tap_switch_near <label>` | tap the M3 toggle on the right of a label row (`937, y`) |
| `tap_edittext` | tap the focused chat input field |
| `info <msg>` | `=== msg ===` section header |

## 4. Adding a regression test

1. Copy the style of an existing `test-*.sh` (same `env.sh` sourcing, counters,
   `exit $((FAIL > 0))`).
2. Use unique markers (`MARK="TT$(date +%s)$$"`) and only your own phone
   numbers so re-runs never collide; remove your rows in a `cleanup` step.
3. Assert with `dump_ui`/grep (do **not** verify via screenshots).
4. Prefer `tap_text`/`center_of_contains` over fixed coordinates; fall back to
   coordinates (1080x2400 @ 420dpi) only when the dump has no text node.
5. Retry slow UIs 2-3x (uiautomator segfaults on the swiftshader AVD;
   SAF pickers scroll lazily).
6. Run it to green before committing, then publish:
   `git add -A && git commit && git push` (and bump the pointer in the app
   repo: `git add scripts && git commit`).

## 5. Settings rows & navigation

- Settings rows can sit below the fold — scroll before tapping.
- Deep links used by scripts (implemented in `MainActivity`):
  - `adb_ shell am start -n "$ACT" --es set_theme dark|light|system`
  - `adb_ shell am start -n "$ACT" --ez open_settings true`
- With the IME open the first BACK closes the keyboard — send BACK twice.
- `pm clear` wipes permissions → grant again via `grant-permissions.sh`.

## 6. Regression guardrails

After an app change: run the affected `test-*.sh` plus `test-back-nav.sh` and
`test-back-stack.sh` when navigation or screens changed; make sure
`run-all-tests.sh` stays green before claiming done.