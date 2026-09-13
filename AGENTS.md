# AGENTS.md — Messages UI test scripts

## What this repo is

Manual/automated UI test scripts for the **Messages** Android app
(`com.anindra.messages`, a Google-Messages-clone SMS app). They drive the app
on the `emulator-5554` AVD over adb and assert state via **uiautomator dumps**
(never screenshots). This repo ships as a **git submodule** at `scripts/` inside
the Messages app repo (`git@github.com:an1ndra/Messages.git`).

## Environment (defaults, all env-overridable via `env.sh`)

| Var | Default | Notes |
|---|---|---|
| `PKG` | `com.anindra.messages` | target app package |
| `ACT` | `$PKG/.MainActivity` | derived from `PKG` |
| `ADB` | `$HOME/android/platform-tools/adb` | adb binary |
| `ANDROID_SERIAL` | `emulator-5554` | primary test device |
| `SHOTS_DIR` | `screenshots/` (next to the app repo) | screenshot output |
| `TMP` | `/tmp/opencode/messages-tests` | scratch dir (ui.xml dumps) |

Screens assume **1080x2400 @ 420dpi**. Inbound SMS injection:
`adb_ emu sms send <number> "<text>"`; the emulator's own numbers are the
`+15551230004` range; real Google Messages also runs on the AVD as default
SMS handler.

## How to run

```bash
bash run-all-tests.sh            # full end-to-end sweep
bash install.sh                  # gradle build + install debug APK
bash open-app.sh                 # cold launch
bash test-<area>.sh              # single regression script
```

Every script must start with `source "$(dirname "$0")/env.sh"` so it
self-locates — **never** hardcode this repo's or the app repo's absolute path.

## `env.sh` helpers

`adb_` (adb + serial), `shot` (png), `type_text`, `dump_ui`/`ui_tags`
(uiautomator → `/tmp/.../ui.xml`), `re_escape`, `center_of`,
`center_of_contains`, `tap_text`, `tap_switch_near`, `tap_edittext`, `info`.
Full reference in `Development.md`.

## Hard rules for any agent working here

1. **Never hardcode paths/serial.** Always `source "$(dirname "$0")/env.sh"`
   and use `adb_`, `$PKG`, `$ACT`, `$ANDROID_SERIAL`. Overrides are set by
   exporting `PKG`, `ADB`, `ANDROID_SERIAL`, `SHOTS_DIR`.
2. **Assert with uiautomator dumps, not screenshots.** `dump_ui` + grep the
   xml, or `center_of_contains`. Screenshot-based verification is slow — never
   add a script that "verifies" only via saved PNGs, and don't take screenshots
   without the user's permission.
3. **Coordinate taps default to 1080x2400 @ 420dpi**; prefer dump-derived
   centers (`tap_text`, `center_of_contains`) over fixed coordinates.
4. **Keep the PASS/FAIL counter convention** (`pass()/fail()` or `ok()/bad()`
   with `PASS`/`FAIL` counters) and `exit $((FAIL > 0))` so scripts are
   automatable.
5. **Tests are self-contained + idempotent**: they seed their own messages with
   unique markers (timestamp+PID), assert, then clean up their rows and restore
   settings to defaults.
6. **Every app bug fix gets a regression script** `test-<area>.sh` — the
   developer must be able to re-run it at any time. Run it to green before
   declaring done.
7. **Always update `TODO.md`** and check off completed tasks — never skip it.
8. **No comments** unless genuinely non-obvious (repo style).
9. **Split large work across agents** (new agent per task) so implementation/
   bug-fix tracking becomes coherent issues; follow the app repo's issue rules.
10. **The AVD is touchy**: swiftshader/Vulkan segfaults, `uiautomator` can
    segfault intermittently, and the SAF file picker auto-scroll is flaky —
    build 2-3 retries into UI sequences.

## Git workflow (submodule of the Messages app)

This repo is embedded in the app repo as a submodule; the app stores only a
commit pointer. After changing a script here, publish it **and** bump the app
pointer:

```bash
# in the scripts submodule:
git add -A && git commit -m "..." && git push

# in the Messages app repo (superproject):
git add scripts && git commit -m "chore: bump scripts submodule"
```

To pull this repo into a fresh app checkout:

```bash
git submodule update --init scripts     # in the app repo
```