# Messages — UI test scripts

Manual test drivers for the Messages app on `emulator-5554`.
Tests assert state from **uiautomator dumps**; `shot` saves PNGs to
`screenshots/` only as visual evidence.

## Quick start

```bash
scripts/run-all-tests.sh          # full end-to-end sweep (~2 min)
```

Scripts self-locate via `dirname "$0"` — run them from anywhere; no need to
`cd` into the app repo first.

Or run individually:

| Script | What it does |
|---|---|
| `install.sh` | Gradle build + install debug APK |
| `install-release.sh [tag]` | Download latest GitHub release APK + install (uninstalls old app on signature mismatch) |
| `logs.sh [filter]` | Stream logcat for the app, auto-re-attaching across restarts |
| `grant-permissions.sh` | Silently grant all runtime permissions |
| `reset-permissions.sh` | Revoke permissions → relaunch → **you see real permission dialogs** |
| `open-app.sh` | Cold-launch app + home screenshot |
| `send-message.sh [row=1] [text]` | Open conversation #row from top of list, type, send |
| `new-message.sh <number> [text]` | Start chat FAB → enter number → send first message |
| `receive-sms.sh <number> [text]` | Inject a real inbound SMS via emulator radio (`adb emu sms send`) |
| `settings.sh` | Open Settings screen + theme dialog screenshots |
| `theme.sh dark\|light\|system` | Switch theme instantly (deep link) |
| `run-all-tests.sh` | Everything above in sequence |

## Notes

- Coordinate taps assume the default emulator **1080x2400 @ 420dpi**.
- Text entry uses `input text` with `%s` for spaces; sending uses the IME Send action (`keyevent 66`).
- To watch permission prompts yourself:
  ```bash
  scripts/reset-permissions.sh && scripts/open-app.sh
  ```
- Deep links used by scripts (implemented in MainActivity):
  - `am start -n com.anindra.messages/.MainActivity --es set_theme dark`
  - `am start -n com.anindra.messages/.MainActivity --ez open_settings true`

## Environment overrides

All values default to the Messages-app setup; override via env:

| Var | Default | Override for |
|---|---|---|
| `PKG` | `com.anindra.messages` | a different app package |
| `ADB` | `$HOME/android/platform-tools/adb` | a custom adb path |
| `ANDROID_SERIAL` | `emulator-5554` | a different emulator/device |
| `SHOTS_DIR` | `<app>/screenshots` | custom screenshot output dir |

## Usage in the Messages app

This repo is attached to the Messages app as a **git submodule** at `scripts/`.
The app repo stores only a commit pointer — no script files are checked out
until you pull them during local setup:

```bash
git submodule update --init scripts      # from the app repo root
# or clone the app fresh with scripts included:
git clone --recurse-submodules <app-url>
```

Fetch newer scripts into an existing checkout (from the app repo root):

```bash
git -C scripts pull --ff-only            # fast-forward the submodule
git add scripts && git commit            # bump the pointer in the app repo
```

Publish edits you make inside `scripts/`:

```bash
cd scripts                               # this repo
git add . && git commit && git push
# back in the app repo:
git add scripts && git commit            # bump the pointer
```

If you work in this repo standalone, point `PROJECT_DIR` at the app repo
(e.g. `SHOTS_DIR=~/Develop/Messages/screenshots`) for screenshot output.
