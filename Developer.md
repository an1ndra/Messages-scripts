# Developer.md — Developer reference

Deep-dive on the test harness internals, environment quirks, and conventions.
For the quick start see [Development.md](Development.md).

---

## 1. Test device facts

- Emulator: **`emulator-5554`** → AVD `Pixel_7_API_35`, 1080x2400 @ 420dpi.
- adb: `$HOME/android/platform-tools/adb` (`$HOME/android` is the Android SDK).
- Own numbers: `+15551230004` range; inject inbound via
  `adb emu sms send <num> "<text>"`.
- Real Google Messages is also installed and is the default SMS handler; it
  mirrors all traffic — our app coexists. Demo conversations are seeded by
  the app only when its DB is empty.

### Emulator launch (host workaround)

The AVD segfaults (SIGSEGV, exit 139) on the AMD radeonsi Vulkan driver. Launch
with software rendering:

```bash
setsid nohup $HOME/android/emulator/emulator \
  -avd Pixel_7_API_35 -no-snapshot-load -no-boot-anim \
  -gpu swiftshader_indirect -feature -Vulkan
```

Ignore a "boot_completed" false-alarm on the first poll before qemu exec; loop
`adb shell getprop sys.boot_completed` until `1`.

### Known flaky spots

- `uiautomator dump` segfaults intermittently — retry dumped-based lookups 2-3x
  (`center_of_contains` already loops 3x).
- The SAF file picker auto-scroll is unreliable — add more swipes / retries.
- `pm revoke READ_SMS` is silently re-granted when the app holds the SMS role.

## 2. Permissions & SMS role

Declared + runtime-requested: `SEND_SMS`, `RECEIVE_SMS`, `READ_CONTACTS`,
`POST_NOTIFICATIONS` (API 33+). Scripts grant silently
(`grant-permissions.sh`), or revoke to see real dialogs
(`reset-permissions.sh`). The SMS role (`android.app.role.SMS`) must often be
re-granted to the app after `pm clear`:

```bash
adb_ shell cmd role add-role-holder android.app.role.SMS "$PKG"
```

## 3. Output conventions

Every `test-*.sh` keeps two counters, prints a results line, and exits
non-zero on failure:

```bash
PASS=0; FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }
# ... end:
echo "Result: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
```

`run-all-tests.sh` runs the stable set and must stay green.

## 4. `env.sh` internals

- `PROJECT_DIR` is derived as the parent of the scripts directory
  (`dirname "${BASH_SOURCE[0]}")/..`), so it works both as a submodule in the
  app and standalone (override `SHOTS_DIR` in the latter case).
- `center_of` matches `text=` or `content-desc=` + `bounds="[x1,y1][x2,y2]"`
  and prints the center; queries are `re_escape`d so `+1-555-333-4444` (dots,
  plus, parens) match literally.
- Grep patterns over the dump split individual `<node>` tags via
  `ui_tags` — some builds pack many nodes onto one line.

## 5. Conventions (enforced)

1. `source "$(dirname "$0")/env.sh"` at the top of every script; `env.sh` is
   already chmod +x.
2. No hardcoded absolute repo paths or adb entitlements — everything through
   `env.sh` vars / `adb_`.
3. Assert by uiautomator dump; screenshots (`shot`) only as evidence output.
4. Comments only when genuinely non-obvious.
5. Update `TODO.md` and check off completed tasks.

## 6. Git workflow (submodule)

This repo is the upstream of the `scripts/` submodule in the Messages app.

- Publish: `git -C scripts add -A && git -C scripts commit && git -C scripts push`
  then in the app repo `git add scripts && git commit -m "chore: bump scripts submodule"`.
- Update an app checkout: `git submodule update --init scripts` (fresh) or
  `git -C scripts pull --ff-only && git add scripts && git commit`.

## 7. Test matrix

| Area | Scripts |
|---|---|
| Build/install/launch | `install.sh`, `open-app.sh`, `logs.sh` |
| Messaging flow | `send-message.sh`, `new-message.sh`, `receive-sms.sh`, `send-dummy-sms.sh` |
| Thread/parsing bugs | `test-issue-179-*.sh`, `test-issue-183-split-threads.sh`, `test-multipart-sms.sh`, `test-parentheses-number.sh`, `test-input-capitalization.sh`, `test-newline-input.sh`, `test-empty-chat-removal.sh`, `test-message-selection.sh` |
| Navigation | `test-back-nav.sh`, `test-back-stack.sh` |
| Chat UI | `test-chat-menu.sh`, `test-chat-render.sh`, `test-sim-menu.sh`, `test-sim-indicator.sh`, `test-sim-inputbar.sh` |
| Links/OTP | `test-links-and-senders.sh`, `test-link-warning.sh`, `test-hide-links.sh`, `test-otp.sh`, `test-otp-link-independence.sh` |
| Notifications | `test-notifications.sh`, `test-notification-sound.sh`, `test-notification-posts.sh`, `test-issue-184-notification-name.sh`, `test-quick-reply.sh`, `test-sms-mirror.sh` |
| Backup/import | `test-backup-restore.sh`, `test-import-loading.sh`, `test-import-mirrors-provider.sh`, `test-merge-import.sh`, `test-initial-sync.sh`, `test-large-provider-startup.sh` |
| Privacy/trash/lock | `test-trash.sh`, `test-permanent-delete-warning.sh`, `test-message-lock.sh`, `test-privacy-features.sh`, `test-security-fixes.sh` |
| Settings/theme | `test-settings-live.sh`, `test-settings-scroll-retention.sh`, `test-advanced-settings.sh`, `theme.sh`, `settings.sh`, `test-splash.sh` |
| List/interaction | `test-archive-undo.sh`, `test-swipe-threshold.sh`, `test-message-delete-undo.sh`, `test-loading-screen.sh`, `test-contacts-limit.sh` |
| Work profile | `test-work-profile-contacts.sh`, `test-work-profile-search.sh` |
| Miscellaneous | `test-p2-p3-p5.sh`, `test-delayed-send.sh`, `test-scheduled-send.sh`, `test-bugfix-trio.sh`, `test-links-and-senders.sh` |
| Release screenshots | `take-fdroid-screenshots.sh`, `insert-demo-contacts.sh`, `seed-google-comparison.sh` |