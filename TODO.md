# TODO

> Moved from the Messages app repo (2026-09-13). This is the project's
> task/tracking history — issues, verification notes, and the regression
> scripts that test them (all in this repo). Hand this file + `AGENTS.md`
> (same folder) to any AI agent working on the scripts.

## Trash · blocked keywords kept + delete-reason tag (2026-09-22)

✅ USER REQUEST: keyword-blocked messages are no longer dropped — they are
stored and their conversation is moved to Trash (recoverable via Restore) with
no notification. Trash rows now carry a reason tag under the number: "Manually"
(user deleted) or "Keyword" (blocked).

- `Repository.receiveBlockedMessage` inserts the message and sets
  `conversations.deleted_at` + `deleted_reason`; `SmsReceiver` routes blocked
  bodies through `KeywordFilter.route` → TRASH. New `TrashReason` constants; DB
  v18 adds `conversations.deleted_reason` (default `manual`); every manual trash
  path records `manual`. `TrashScreen` renders a small reason tag.
- `keywords_hint` now says matching messages go to Trash.

Tests: `KeywordFilterTest` route cases + new `TrashReasonTest`; `test-keywords.sh`
asserts the message is kept, the conversation trashed with reason
`blocked_keyword`, no notification, and the Trash screen shows the "Keyword" tag;
`test-trash.sh` asserts the "Manually" tag.

## Chat · emoji button setting + composer tweaks (2026-09-22)

✅ USER REQUEST: add an Advanced option to show the emoji button in the message
field (default off), move the attach button inside the field, and rename the
field hint "Text message" → "Message". New `SettingsStore.emojiButtonEnabled`
(`KEY_EMOJI_BUTTON`, default false) surfaced as Advanced → Appearance → "Emoji
button"; `InputBar` takes `showEmojiButton` and only renders the emoji
`IconButton` when set. The attach `AddCircleOutline` moved to the TextField
`leadingIcon`; `text_placeholder` is now "Message".

Tests: new `EmojiButtonSettingTest` (key + default contract) and
`scripts/test-emoji-toggle.sh` run on dual-SIM (`--ez fake_dual_sim true`): 9/9 —
SIM switcher present with the emoji off, both present when on, restored off.

## Chat · SIM switcher icon redesign (2026-09-22)

✅ USER REQUEST: the in-field SIM glyph now matches the supplied artwork — a
solid rounded SIM card (angled cut at the top-right) with a negative numeral.
Rebuilt `ic_sim_1`/`ic_sim_2` as single `evenOdd`-filled 24dp paths (tint
`onSurfaceVariant`): the card outline is taken from the provided
`g483*.svg` path, the "1" reuses that path's digit and the "2" is the Ubuntu-Bold
glyph fitted to the same box. Input-bar trailing row: 40dp icon buttons, SIM
glyph at the emoji's 24dp and placed left of it, staying visible while the soft
keyboard is open (hidden only while a draft exists).

Tests: new `SimIconDrawableTest` (tint-only colour, 24dp, card + number
subpaths, top-right cut, card shared / digit differs) kept green with
`test-sim-inputbar.sh` (8/8, incl. visible with the keyboard open and hidden
while typing).

## App · clock follows the device 12/24-hour setting (2026-09-22)

✅ USER REQUEST: message times read "12:30 AM" even when the phone is set to a
24-hour clock. Every in-app time now derives its pattern from the device via
`android.text.format.DateFormat.is24HourFormat(context)` — 24-hour shows
`00:30`, 12-hour shows `12:30 AM`, matching the phone.

New pure `ui/TimeFormat.kt` (`is24HourFormat`, `timePattern`,
`timeOnlyFormatter`, `dateTimeFormatter`, `formatDateTime`). Wired through
`Components.formatTimeOnly`/`formatListTime`, `MessageGrouping.formatGroupLabel`,
the chat bubble + group header, the message-details dialog, the schedule toast,
the settings scheduled-message list, and `rememberTimePickerState(is24Hour=…)`.
Removed the hard-coded `h:mm a` `SimpleDateFormat` sites in `ChatScreen`/
`SettingsScreen`.

Tests: `testDebugUnitTest` 138/138 (new `TimeFormatTest` 6/6: pattern switch,
`00:30`/`12:30 AM`, date+time prefix, AM/PM absent from bubbles/group labels in
24-hour mode). New `scripts/test-24h-time.sh` (flips `settings put system
time_12_24 24|12`, relaunches, asserts HH:mm vs AM/PM in the chat dump, restores
the original value) wired into `run-all-tests.sh`.

## Issue #227 · in-field SIM switcher + Persian number bidi (2026-09-21)

✅ USER REQUEST (two parts):

1. **SIM button beside send.** Restored the in-field SIM switcher in the chat
   input bar (the prototype removed in `5ba7a29`). New pure `data/SimSwitcher.kt`
   (`iconFor`, `next`) backs it; `InputBar` takes `sims`/`currentSimId`/
   `onCycleSim` and paints `ic_sim_1`/`ic_sim_2`/`ic_dual_sim` (tinted
   `colorScheme.primary`, content-desc "Switch SIM") only for `sims.size > 1`
   and an empty draft. `cycleSim()` now delegates to `SimSwitcher.next`. The
   chat 3-dot menu SIM rows remain.
2. **Persian number reversal.** Root cause reproduced on emulator: in an RTL
   paragraph the space/`-`/`+`-separated number groups are laid out right-to-
   left, so `+98 999 862 0453` painted as `0453 862 999 98+` (list titles,
   message bodies, details). Fix is render-layer only (DB/identity untouched):
   new pure `ui/BidiText.kt` wraps number runs in Unicode LRI/PDI
   (`ltr()` for standalone numbers, `isolateNumberRuns()` + offset `remap()`
   for bodies). `isolateNumberRuns` is a no-op unless the text's first strong
   character is RTL — isolating an otherwise-LTR run would itself reorder it in
   an RTL layout. Applied in `rememberLinkedText`/`styledBody` (preserving link
   + OTP styling offsets) and to every number display (`formatPhoneNumber`,
   which now isolates, plus `convo.display` sites in conversations/chat/contact
   details/trash).

Tests: `testDebugUnitTest` 132/132 (new `BidiTextTest` 7/7, `SimSwitcherTest`
4/4). New `scripts/test-persian-numbers.sh` (4/4: RTL title + body isolated,
LTR body untouched) and rewritten `scripts/test-sim-inputbar.sh` (6/6: dual-SIM
button present, cycles the pref, hidden while typing, absent on single-SIM)
using the `--ez fake_dual_sim true` hook. Both wired into `run-all-tests.sh`.

## CI · pin GitHub Actions runners to ubuntu-24.04 (2026-09-21)

✅ GitHub will migrate the `ubuntu-latest` label from Ubuntu 24.04 to Ubuntu
26.04 between Oct 19 and Nov 19, 2026. Pinned every `runs-on` (11 across
`develop-build.yml`, `rc.yml`, `security.yml`, `virustotal.yml`,
`release.yml`) to `ubuntu-24.04` so CI stays deterministic. `ubuntu-26.04` is
available for an explicit test run when we want to validate the new image.

## Screenshots · dummy-chat set with profile photos (2026-09-21)

✅ USER REQUEST: refresh the app screenshots with useful dummy chats and real
contact profile pictures, dropping the old numbered dark/light pair set.
Replaced the F-Droid/README set (`fastlane/.../en-US/images/phoneScreenshots/`)
with 7 dark-mode captures — `01-conversations`, `02-chat-grouped-bubbles`,
`03-chat-work`, `04-chat-alex`, `05-chat-otp`, `06-new-chat`, `07-settings` —
and updated the README table to match.
Procedure used: `insert-demo-contacts.sh` (then fix the duplicated display names
by clearing the family-name field), seed conversations/messages directly into
`messages.db` (sqlite via `run-as`), inject avatars into the Contacts provider
(256px JPEG as the `data15` blob, with `photo_file_id` left NULL so `PHOTO_URI`
falls back to the thumbnail URI served straight from the blob), then `screencap`.
NOTE: `take-fdroid-screenshots.sh` still targets the old 20-image set, and its
demo-data seeding disappeared with `DemoData.kt` — it must be rewritten (or
replaced with the procedure above) before it can regenerate this set.

## Run-aware chat bubble corners (2026-09-20)

✅ USER REQUEST: bubbles are shaped by their position in a run of consecutive
messages from the same sender (a run also breaks on the existing day / >1h group
boundary, and on a sender change):
- **lone / first of run** — flat tail on the sender's bottom side (outgoing
  bottom-right, incoming bottom-left);
- **middle of run** — all four corners rounded;
- **last of run** — flat tail on the sender's top side (outgoing top-right,
  incoming top-left).
Implementation: new pure `BubblePosition` / `BubbleCorners` + `bubblePosition()`
/ `bubbleCorners()` / `toShape()` in `ui/MessageGrouping.kt`; `ChatBubble` gains a
`position` arg (default `SINGLE`), driven from the live list via
`bubblePosition(messages, idx)`, replacing the old per-bubble `isMe`-only shape.
`ChatBubble` emits a `BubbleShape` logcat marker (`id position mine` + the four
radii) so the script can assert the rendering.
Tests: `testDebugUnitTest` `MessageGroupingTest` 9/9; new
`scripts/test-bubble-corners.sh` drives lone + 3-message runs for outgoing and
incoming and asserts each corner set via the marker. Wired into
`run-all-tests.sh`.

## Documentation refresh · fix stale project docs (2026-09-20)

✅ Audited every doc against the code and corrected outdated facts:
- `docs/Developer.md` (app): fixed the clone URL (`anindra` → `an1ndra`),
  bumped the DB version in the migrations section (v14 → v17), replaced the
  "Compose Navigation" claim with the manual `navRoute` routing, refreshed the
  project tree (added `crash/`, `diagnostics/`, MMS/SIM/backup data helpers,
  `AccessibilityScreen.kt`, `MarkReadReceiver.kt`; dropped the deleted
  `DemoData.kt` and `screenshots/` entries), and dropped the stale Coil
  "(if added)" note.
- `docs/Development.md` (app): DB v14 → v17, nav model/back table now include
  `advanced` and `accessibility`, replaced the `DemoData.kt` demo-seed claim
  with the real first-launch provider sync, and documented the
  `open_conversation_address` intent hook.
- `README.md` (app): accurate permission list (SMS/MMS, contacts, notifications,
  phone state, photos; no internet), `navRoute` architecture wording, and an
  Accessibility Mode feature bullet.
- `.github/ISSUE_TEMPLATE/bug_report.yml`: Diagnostics has only **Copy** (Save
  was removed) — fixed the instructions.
- `scripts/Developer.md`: AVD `Pixel_7_API_35` → `Pixel_7_API_36`, full declared
  permission list, test matrix extended with the newer regression scripts.
- `scripts/README.md`: screenshots are evidence only; tests assert from
  uiautomator dumps.

## Accessibility mode (2026-09-19)

✅ User request: make the app usable for disabled users.

**Phase 1 — TalkBack compliance (always on, no visual change).** New pure
`ui/A11y.kt` (`touchTarget` clamps to 48dp, `describe` joins labels). Conversation
rows now expose a merged `contentDescription` (sender · preview · time · unread ·
pinned) and an "Open conversation" click label; `UnreadBadge` is decorative inside
the merged row; undersized tap targets bumped to ≥48dp. `ui/A11yTest.kt`.

**Phase 2 — gated accessibility mode.** `SettingsStore` adds `a11yEnabled`
(master, default false), `a11yFontScalePercent` (85/100/115/130), `a11yBold`,
`a11yHighContrast`, `a11yReduceMotion`, `a11yLargeTouch`. New
`ui/theme/A11yOptions.kt`; `MessagesTheme(..., a11y)` multiplies the system font
scale via `LocalDensity`, swaps in high-contrast schemes (Theme.kt), bolds
typography (`Type.kt`), and provides `LocalReduceMotion` /
`LocalLargeTouchTargets`. Reduce motion suppresses bubble entrance, shimmer and
route transitions. Advanced settings holds the master switch; ON reveals the new
`ui/AccessibilityScreen.kt`. While OFF every option is a no-op, so the default UI
is unchanged. Diagnostics report records the a11y settings.

TalkBack node-tree validation (Google TalkBack is not on the AOSP system image;
verified against the accessibility tree uiautomator/TalkBack both consume):
`clearAndSetSemantics` puts the row description on the same node as the click /
long-click actions — the first attempt left the description on a non-focusable
child while the focusable node stayed empty, which TalkBack would skip. Covered
by a `scripts/test-accessibility.sh` assertion ("description is on the
clickable/activatable node"). Chat-bubble link semantics intentionally left
untouched so in-message links stay reachable.

Tests: `testDebugUnitTest` green incl. `A11yTest`, `A11yOptionsTest`, updated
`TypeTest` / `BubbleEntranceTest` / `DiagnosticsReportTest`;
`scripts/test-accessibility.sh` 23/23 on Android 16 (SDK 36, `emulator-5554`) —
row descriptions on the activatable node, master gating, five options persist,
font 130% visibly grows a text node (63→80px), settings restored. App also
launched with the system Accessibility Menu service bound.

## Issue #207 · Alphanumeric sender IDs shown as digits ("A1 SRB" → "1") — FIXED (2026-09-19)

✅ USER REPORT (comment on #207): a promotional SMS from "A1 SRB" showed as
"1" and the thread could be replied to, unlike other alphanumeric senders.
ROOT CAUSE: `Repository.canonical()` fell back to `address.filter { it.isDigit() }`
for non-parseable addresses, so `"A1 SRB"` → `"1"`. That corrupted value was
stored as the conversation address/name (no participant row exists for
alphanumeric senders) and `samePerson()`'s digit-run comparison could fuse it
with a numeric sender. Sender IDs without digits (`AX-KOTAKB-S`, `DK-AIRCEL`)
were already preserved by the `.ifEmpty { address }` callers, so only
digit-containing IDs were hit.
FIX:
- New pure `data/AddressIdentity.kt`: `canonical()` = E.164 or the trimmed
  original; `samePerson()` = digit run for numbers, exact case-insensitive for
  any address containing a letter; `isReplyable()` = `isLikelyPhoneNumber`.
  `Repository.canonical/samePerson`, `ChatScreen.phoneKey/isPhoneNumber` and
  `SmsSupport.normalizeAddress` now delegate to it.
- One-shot `Repository.repairAlphanumericSenders()` (settings flag
  `alphanumeric_repair_done`, runs at the start of `syncFromSystem`) re-addresses
  legacy rows reduced to digits using the provider's original sender IDs via
  each message's `sys_id`.
- Replies blocked for alphanumeric senders everywhere: notification Reply action
  omitted (`SmsSupport.show`), `QuickReplyReceiver` bails, `MainActivity.send` /
  `retryMessage` guard, and the chat composer is replaced by a
  "can't receive replies" notice instead of an always-erroring input bar.
Tests: `testDebugUnitTest` green incl. new `AddressIdentityTest` 7/7 (canonical
preserves A1 SRB / AX-KOTAKB-S / DK-TEST99; `samePerson("A1 SRB","1")==false`;
number variants still merge; replyable only for dialable numbers).
`scripts/test-alphanumeric-sender.sh` 8/8 (notification has no Reply while a
numeric sender's still does; provider SMS from "A1-SRB" keeps its full ID;
chat read-only; a row corrupted to "1" is repaired to "A1-SRB" on relaunch).
Fails before the fix (5 checks — reply action present, address digit-stripped,
no chat header, composer present, no repair), passes after.
`test-links-and-senders.sh` step 5 updated (was asserting the bug via the
digit-stripped "99" row) and its stale link / settings steps fixed for the
current app. NOTE: `adb emu sms send` parses its sender as a phone number and
strips letters from digit-containing IDs ("A1-SRB" arrives as "1"), so the
provider row is seeded with `content insert`.

## fastlane metadata · translations for all app locales (2026-09-20)

✅ Added `title.txt`, `short_description.txt`, `full_description.txt` under
`fastlane/metadata/android/<locale>/` for every locale the app ships besides
`en-US`: `ar, de, es, fr, hi-IN, ja, ko, pl, pt-BR, ru, zh-CN, zh-TW`
(12 locales × 3 files). Localized `title.txt` matches the app's own localized
`app_name` (الرسائل / メッセージ / Wiadomości / 消息 / 訊息; "Messages"
elsewhere). Descriptions are the translated feature/permission copy with the same
allowed HTML (`p`, `strong`, `b`); no per-locale screenshots added (F-Droid falls
back to the en-US set). Validated: every short description ≤ 80 chars and full
description ≤ 4000 chars, title ≤ 50.

## Repo cleanup · docs/ move + single screenshot location (2026-09-20)

✅ Two consolidations:
- **App dev guides moved into `docs/`** (`Developer.md`, `Development.md`) so all
  app documentation lives under one folder. Root references updated:
  `README.md` → `docs/Developer.md`, `AGENTS.md` → `docs/Development.md` /
  `docs/Developer.md`; `docs/Developer.md`'s licence link is now `../LICENSE`.
  `README.md` and `AGENTS.md` stayed at the repo root (GitHub/F-Droid/agent
  tooling expect them there). The `scripts/` docs are a separate set and
  untouched.
- **F-Droid screenshots single-sourced under fastlane.** `screenshots/fdroid/`
  and `fastlane/metadata/android/en-US/images/phoneScreenshots/` held the same
  20 filenames but had drifted (fastlane copies dated 2026-08-23, root set
  2026-09-05). Fastlane is the location F-Droid reads, so the fresher
  `screenshots/fdroid/` images were copied over it, `screenshots/fdroid/` was
  deleted, `scripts/take-fdroid-screenshots.sh` now writes straight to
  `fastlane/metadata/android/en-US/images/phoneScreenshots/`, and the README
  screenshot table points there. `.gitignore` dropped the `!screenshots/fdroid/`
  exception (root `screenshots/` stays ignored for ad-hoc captures).
  No more mirrored/duplicated set to drift.

## Repo cleanup · drop stale in-repo F-Droid metadata template (2026-09-20)

✅ Removed `fdroid/com.anindra.messages.yml`. It was a submission template from
the initial F-Droid onboarding, referenced by nothing (no Gradle, script, CI, or
`.circleci` job) and stale (1.0.4 / code 8 / commit f981c35 while the live
metadata is 1.0.26 / code 29). F-Droid reads metadata only from
`gitlab.com/an1ndra/fdroiddata` (`metadata/com.anindra.messages.yml`, updated by
the `release.yml` `sync-fdroiddata` job), never from an in-repo `fdroid/` file.
Kept `fastlane/metadata/android/en-US/`, which F-Droid *does* read from the
repo (title/short/full description, icon, screenshots, changelogs).

## CodeQL security-and-quality cleanup · alerts #8 #9 #12 #13 #15 #22 #23 #24 #25 #27 #28 #29 #30 #31 #32 #33 — FIXED (2026-09-20)

✅ All 16 open `security-and-quality` alerts on `main`:
- **Useless null checks** (#30/#31, `MainActivity.kt:505/510`): `Context.getDisplay()`
  is `@NonNull`, so the `display?.…` guards in the `SDK >= R` display-mode probe
  were dropped (properties now read directly off `display`).
- **Field masks super field** (#15, `Repository.kt:1`): the Compose-generated
  `$stable` field in `ImportResult.Success/Error` shadowed the one in the
  `sealed class ImportResult` parent. Converted `ImportResult` to a `sealed
  interface` (interfaces get no `$stable`), so no generated field masks a
  superclass field anymore.
- **Deprecated calls**:
  - #33 `TelephonyManager.phoneCount` → new pure `phoneCountForSdk()`:
    `activeModemCount` on SDK ≥ 30, `SubscriptionManager.activeSubscriptionInfoCountMax`
    below.
  - #32 `KeyGenParameterSpec.Builder.setUserAuthenticationValidityDurationSeconds(-1)`
    → removed; pre-R already defaults to per-use auth (validity -1), so the
    legacy else-branch was a no-op.
  - #25 `SmsManager.getSmsManagerForSubscriptionId` → reflective
    `legacyManagerForSubscription(subscriptionId)` helper (the method is the only
    per-SIM API on 29–30 but deprecated on S+).
- **Unread locals** (#8/#9 `isList`/`isChat`, #12 `cs`, #22/#23
  `showEntrySkeleton`/`hasEarlierButton`, #24 unused `context`, #27
  `appInForeground`, #13/#28 unused destructured `addr`/`name`) removed; the
  destructured `for` bindings now use `_`.
Tests: `testDebugUnitTest` 92/92 incl. new `ImportResultTest` 4/4 and
`phoneCountForSdk` coverage in `DiagnosticsReportTest`; `SimLabelsTest` asserts
`Default`/`Unknown` are identity singletons after the `data object` → `object`
change. `scripts/test-codeql-cleanup.sh` 20/20 on emulator-5554 (13 source
guards that the deprecated/flagged patterns stay gone + launch / inbound SMS /
diagnostics collect with no FATAL). Wired into `run-all-tests.sh`.
NOTE: the "field masks super field" alert local builds never warned about (it is
Compose-compiler generated) — the `sealed interface` change also removes it from
the next CodeQL scan, unlike the earlier false-positive dismissal attempt.

## Backup location · privacy · blocked-keywords UI · Coil (2026-09-19)

✅ User requests:
1. **Coil image loading** (was: hand-rolled `BitmapFactory` + `LruCache`). Added
   `io.coil-kt.coil3:coil-compose:3.3.0` (pinned — 3.4+ pulls Kotlin stdlib
   2.4 which is incompatible with the project's Kotlin 2.2.20). `ImageBubble`
   and `PersonAvatar` now use `AsyncImage`; removed `BitmapCache` and
   `loadContactPhoto`.
2. **Issue #212 · backup to an individual path**: Settings → "Backup location"
   opens the SAF folder picker (`OpenDocumentTree`), persists the tree URI
   (`SettingsStore.backupTreeUri`, `takePersistableUriPermission`) and
   `Repository.backupDatabase` writes there via `DocumentsContract.createDocument`
   (falling back to `Documents/Messages` when unset). New pure `BackupLocation`
   label helper. This is the supported way to back up to a removable SD card.
3. **Privacy mode disables backup**: the Backup row and Backup location row are
   disabled (subtitle "Turn off Privacy mode to back up messages") and
   `Repository.backupDatabase` refuses via the new pure `BackupPolicy`.
4. **Blocked keywords UI**: dialog now has a title icon + count badge, an add
   field (tag leading icon, `+` submit, IME Done), and a card list with
   dividers and an empty state.
Note: an in-field SIM swap control was prototyped and then removed on request —
SIM selection then lived in the chat 3-dot menu only. Issue #227 requested the
in-field control back (see the 2026-09-21 entry above); it now sits beside send
while the menu rows remain.
Tests: `testDebugUnitTest` 76/76 (`BackupLocationTest` 4/4, `BackupPolicyTest`
2/2); `scripts/test-backup-sim-coil.sh` (backup row + picker, keywords dialog,
privacy-mode disable, Coil launch). `assembleDebug` + R8 `assembleRelease` green.

## Issue #211 · Status-bar notification icon too small — FIXED (2026-09-18)

✅ ROOT CAUSE: both notification builders used the adaptive launcher foreground
(`R.drawable.ic_launcher_foreground`) as the small icon. That drawable is a
108dp canvas whose speech-bubble glyph only spans 12→60 (~47%), so at the ~24dp
status-bar size the silhouette rendered at roughly half the size of system icons.
FIX (same artwork, second enlarged copy — launcher/splash unchanged):
- New `drawable/ic_stat_message.xml`: 24dp / 24×24 viewport, identical pathData,
  one group transform (`scale 0.45833`, `translate -4.5`) mapping the glyph
  bounds to ~92% of the canvas.
- `sms/SmsSupport.kt`: both `setSmallIcon(...)` calls (incoming + send-failed)
  now use `ic_stat_message`; `ic_launcher_foreground` is untouched so the
  splash/launcher icon keeps its adaptive safe-zone sizing.
FOLLOW-UP (icon design changed — lines missing): the status bar tints the small
icon as a single-color alpha silhouette, so the opaque white bubble and the
opaque blue `strokeColor` lines collapsed to the same tinted color. The lines
now live as line-shaped subpaths inside the bubble path with
`android:fillType="evenOdd"`, so they are punched out as negative space and
survive tinting. `ic_launcher_foreground` keeps its original stroke lines.
Tests: `testDebugUnitTest` `NotificationIconTest` 6/6 (notification reuses the
launcher bubble path, lines are evenOdd cut-outs with no strokes, notification
glyph fill ≥ 0.85, launcher fill ≤ 0.6, 24 viewport, both setSmallIcon calls
wired); `scripts/test-notification-icon.sh` 9/9 — resolves the POSTED record's
icon id via `dumpsys notification --noredact`, maps it through
`aapt2 dump resources` on the installed APK and asserts it is `ic_stat_message`
(not the launcher foreground), and checks the compiled viewport/artwork plus
the evenOdd fill / absence of strokes. Script fails before each fix (2/7 for
size, 2/9 for strokes), passes after. `test-notification-posts.sh` still green.

## Issue #210 · MMS never imported/displayed — FIXED (2026-09-18)

✅ ROOT CAUSE: import only read `content://sms`; nothing read the MMS provider,
so provider MMS never appeared even when set as the default SMS app.
FIX:
- New `data/MmsSupport.kt`: box/type filtering (`msg_box=1 m_type=132` inbox,
  `2/128` sent), single-phone-participant peer resolution (group MMS skipped),
  part→content mapping with unsupported-attachment notice, charset decode table,
  1 MiB streamed-text cap, provider URIs.
- New `data/MmsProviderReader.kt`: reads `content://mms` threads, `/addr` and
  `/part`, streaming text parts with the size cap.
- `Repository.kt` DB v16: `messages.transport` column; unique `sys_id` index is now
  `(transport, sys_id)`; `importProviderMms()` runs in `syncFromSystem`; purge,
  system-sync, backup/restore and local inserts are transport-aware; conversation
  snippet shows `@Lock`/`Photo` for media.
Tests: `testDebugUnitTest` `MmsSupportTest` 6/6; `scripts/test-mms-import.sh`
(seed provider MMS → import, transport/timestamp/subId preserved, idempotent
reimport, text rendered in conversation).

## Debug tooling · fake dual-SIM on the single-SIM emulator (2026-09-15)

✅ USER REQUEST: the stock Android emulator is single-SIM (verified: only
`-no-sim` / `-icc-profile` / `-sim-access-rules-file`; `hw.gsmModem` is the sole
telephony hardware property; `dumpsys isub` shows one subscription). To exercise
the dual-SIM UI without a dual-SIM phone, added a **debug-only fake SIM source**.
Implementation:
- New `data/SimCard.kt`: `SimCard` data class (decoupled from `SubscriptionInfo`)
  + `SimCards.load(context)` and `SimCards.setDebugOverride(enabled, debuggable)`.
  The override is gated on `ApplicationInfo.FLAG_DEBUGGABLE`, so release builds
  always see the real subscriptions.
- `SettingsScreen`, `ChatScreen` and `DiagnosticsReport` now read `SimCards.load`
  instead of `SubscriptionManager.activeSubscriptionInfoList` directly.
- `MainActivity`: `--ez fake_dual_sim true` applies the override (also via
  `onNewIntent`). The fake list is T-Mobile (subId 1, slot 0) + Vodafone
  (subId 7, slot 1) — subId 7 deliberately != slot+1 so the label logic is
  exercised (renders "Vodafone (SIM 2)", never "SIM 7").
Usage: `adb shell am start -n com.anindra.messages/.MainActivity --ez fake_dual_sim true`
Tests: `testDebugUnitTest` 48/48 (`SimCardsTest` 2/2);
`scripts/test-fake-dual-sim.sh` 7/7 (two SIMs shown, no raw "SIM 7", selecting
the second updates row+pref, Default restored, no fake SIM without the flag).
Wired into `run-all-tests.sh`.

## Issue #209 · Crash on Android 10–13 (NoSuchFieldError) — FIXED (2026-09-15)

✅ ROOT CAUSE (reproduced on an API 31 emulator, stack trace captured):
`AppViewModel`'s contact loader referenced
`ContactsContract.CommonDataKinds.Phone.ENTERPRISE_CONTENT_URI` unconditionally.
That field was only added in **API 34** (`api-versions.xml`: `since="34"`), so
on Android 10–13 the field access threw `NoSuchFieldError` — an `Error`, not an
`Exception`, so the surrounding `catch (_: Exception)` did not catch it and the
app died on launch (the reporter's "error pops up and the app closes").
`ENTERPRISE_CONTENT_FILTER_URI` is since API 24, but `ENTERPRISE_CONTENT_URI`
is the API-34 one that bit us.
FIX:
- New `data/EnterpriseContacts.kt` (`MIN_SDK = 34`, `isSupported`, and a
  `@TargetApi(34) phoneUri()` so the field reference lives in its own method
  the verifier never resolves on older devices).
- `MainActivity` guards on `EnterpriseContacts.isSupported(SDK_INT)` and falls
  back to `Phone.CONTENT_URI` (personal profile) below API 34; the catch is now
  `Throwable` so a linkage error can never kill the app again.
Tests: `testDebugUnitTest` 46/46 (`EnterpriseContactsTest` 1/1);
`scripts/test-android12-launch.sh` 4/4 on an **API 31** emulator
(`ANDROID_SERIAL=emulator-5556`) — no FATAL, no NoSuchFieldError, home screen
reached; skips on API ≥ 34. Verified the API 35 build still works too.

## Keyword blocking + diagnostics/avatar improvements (2026-09-15)

✅ USER REQUEST (three parts):
1. **Block keywords** — a "Blocked keywords" option in Settings → Advanced.
   A message whose body contains any blocked keyword (case-insensitive) is
   dropped entirely: not stored, no notification, no sound. Managed with an
   add/remove dialog.
   - `data/KeywordFilter.kt` (pure `isBlocked`), `SettingsStore.blockedKeywords`
     (StringSet) + `isKeywordBlocked`, `sms/SmsReceiver` skips matching messages
     before persisting/notifying, `ui/BlockedKeywordsDialog.kt`, `AppViewModel`
     add/remove helpers.
2. **Diagnostics: drop Save, add detail** — the Diagnostics dialog now has only
   **Close · Copy** (Save removed on request). The report gained sections for
   App (version/package/targetSdk/first-install/last-update/settings),
   Device (release/codename/incremental/security-patch/base-OS/device/product/
   hardware/board/bootloader/build-ID/display/type/tags/host/user/ABIs 32+64/
   build-time/emulator/kernel/Java-VM/CPU-cores/font-scale), System (memory,
   low-memory, app heap, storage, battery), and Data (conversation/message
   counts, DB size, pending crash reports). `DiagnosticsReport.format` now takes
   a `DiagnosticsData`; counts come from new `Repository.totalConversationCount`
   / `totalMessageCount`.
3. **Contact photo delay** — `PersonAvatar` re-ran the ContactsContract
   `phone_lookup` query on every composition and never cached the "no photo"
   result. New `ui/PhotoUriCache` caches the resolved photo URI (incl. a blank
   entry for contacts with no photo), so only the first load hits the provider.
4. **Reorganized** the Advanced screen into logical groups (Conversations /
   Links / Privacy & security / Notifications / Appearance / Support) and moved
   the main Settings "Advanced" row to the bottom of the list.
Tests: `testDebugUnitTest` 42/42 (`KeywordFilterTest` 4/4, `PhotoUriCacheTest`
3/3, `DiagnosticsReportTest` 4/4); `scripts/test-keywords.sh` 7/7 (add keyword →
message dropped, not stored, no notification; normal message arrives; remove →
cleared); `scripts/test-diagnostics.sh` 7/7 (sections + Close/Copy, no Save);
`test-advanced-move.sh` 18/18 still green. Wired into `run-all-tests.sh`.

## Settings → Advanced: move toggles + font picker (2026-09-15)

✅ USER REQUEST: move Privacy mode, App lock, Drafts, Send sound and Receive
sound out of the main Settings screen into Settings → Advanced, and add a Font
picker there too.
Implementation:
- `ui/AdvancedSettingsScreen.kt`: new group with Privacy mode, App lock, Drafts,
  Send sound, Receive sound (same behaviour as before, incl. the biometric
  availability check for App lock and `NotificationHelper.ensureChannel` for
  Receive sound), plus a **Font** row that opens a radio dialog.
- `ui/SettingsScreen.kt`: the five rows (and their now-unused state) removed.
- Fonts: `res/font/{dm_sans,inter,figtree}.ttf` (variable) +
  `poppins_{regular,medium,semibold,bold}.ttf` (static), all SIL OFL, with
  licenses in `assets/licenses/`; `ui/theme/Type.kt` gains
  `AppFonts.familyFor(key)` and `MessagesTheme(font = ...)` applies the chosen
  family. `SettingsStore.fontFamily` **defaults to `system`**;
  `AppViewModel.fontFamily` is observable. The picker matches the
  "Notification sound" dialog: plain radio rows + **OK / Cancel** (Cancel keeps
  the current font), listing **System default + 4 bundled fonts** (DM Sans,
  Inter, Figtree, Poppins).
Tests: `testDebugUnitTest` 19/19 (`AppFontsTest` 3/3, `TypeTest` 2/2);
`scripts/test-advanced-move.sh` 18/18 (moved rows absent from main Settings,
present in Advanced, font picker switches + persists + restores). Updated
`test-settings-live.sh` (Drafts), `test-notification-sound.sh` (Receive sound)
and `test-privacy-features.sh` (App lock / Privacy mode) to reach Advanced.
Wired into `run-all-tests.sh`.

## UI font — DM Sans as a Google Sans stand-in (2026-09-15)

✅ USER REQUEST: make the app text look closer to Google Messages. The earlier
Material You + home-search-bar pass was reverted (user did not like it); the
only kept change is the font. Inter was tried first, then swapped for DM Sans
(more geometric, closer to Google Sans).
Why DM Sans: Google Sans (and Product Sans) are proprietary and cannot be
redistributed in this GPL app. DM Sans is a free/OFL Google Sans alternative.
Implementation:
- `res/font/dm_sans.ttf` — the DM Sans variable font (`opsz`/`wght`), plus the
  SIL OFL text at `assets/licenses/DMSans-OFL.txt`.
- `ui/theme/Type.kt`: `MessagesFontFamily` maps 400/500/600/700 to the variable
  font via `FontVariation.Settings`; `messagesTypography()` remaps every
  Material 3 text style to it, and `MessagesTheme` passes it as the app
  typography. Colors/shapes unchanged (no dynamic color, search bar restored).
Tests: `testDebugUnitTest` 16/16 (`TypeTest` 2/2 — every style uses the bundled
family); `scripts/test-font.sh` 3/3 (APK ships dm_sans.ttf + OFL license, app
launches). Wired into `run-all-tests.sh`.

## Issues #208 / #192 · SIM label + display-scale diagnostics users can share (2026-09-15)

✅ USER REQUEST: issue #208 reports the Settings SIM card showing a random
number ("SIM 7" / "SIM 3") instead of the carrier name, and issue #192 reports
the whole UI changing scale/resolution when the app opens. Both are
device-specific and hard to reproduce, so add a **Diagnostics** report (device +
SIM + display) the user can share/save for a GitHub issue.
Root causes found while wiring the logs:
- #208: `SettingsScreen` resolved the SIM row label only from an async
  `SubscriptionManager.activeSubscriptionInfoList` that was still empty on
  first composition, then fell back to `settings_sim_label` with the raw
  **subscriptionId** → "SIM 7". Now a `LaunchedEffect` loads the list on entry
  and the label is resolved by a pure `SimLabels.resolve()` (carrier + slot, or
  slot, or "Unknown SIM" — never the raw id).
- #192: `MainActivity.onCreate` forced `preferredDisplayModeId` to the
  max-refresh display mode, but a `Display.Mode` bundles resolution **and**
  refresh rate — on panels where the top-refresh mode is a different resolution
  (OnePlus 8 Pro) the whole UI rescaled. FIXED: new pure
  `DisplayModeSelector.bestModeId()` only bumps the refresh rate **within the
  current resolution** (returns null when there is no same-resolution faster
  mode), so the resolution/scale never changes. The diagnostics still log the
  current mode, all supported modes and the preferred mode id.
Implementation:
- New `diagnostics/DiagnosticsReport.kt`: collects app/device info, **app state**
  (default-SMS role, granted permissions, locale, time zone, theme, notifications),
  every active subscription (subscriptionId, simSlotIndex, carrierName,
  displayName, mccMnc, countryIso, embedded), selected subscriptionId,
  phoneCount, and the display mode list; pure `format()` is JVM-testable.
  `saveToDownloads()` writes `Downloads/Messages/messages-diagnostics.txt`.
- New `diagnostics/DiagnosticsDialog.kt` + a **Diagnostics** row in
  Settings → Advanced: previews the report with **Close · Save · Copy** in that
  left-to-right order (no Share — it was removed on request).
- New `data/DownloadsStore.kt` shared by the crash reporter and diagnostics;
  `data/SimLabels.kt` (pure label resolution).
Tests: `testDebugUnitTest` 30/30 (`SimLabelsTest` 4/4, `DiagnosticsReportTest`
4/4, `DisplayModeSelectorTest` 4/4, plus the crash suite);
`scripts/test-diagnostics.sh` 8/8 (row → report dialog with app + SIM + display
sections → Close present, Share absent, button order Close < Save < Copy →
saved file contains the display modes); `scripts/test-sim-label.sh` 2/2 (select
the carrier SIM → Settings row shows "T-Mobile (SIM 1)", not a raw id);
`scripts/test-display-mode.sh` 3/3 (launch does not change resolution/density/
mode — the AVD has a single mode, so the selection logic is covered by
`DisplayModeSelectorTest`). All wired into `run-all-tests.sh`.

## Issue #209 · Crash on Android 12 — capture crash logs for GitHub issues (2026-09-15)

✅ USER REQUEST (issue #209 "Crash Android 12"): the app crashed on launch on
Android 12 with no actionable error and no way for the reporter to capture it.
Added a self-contained crash reporter so a user can export the crash log as a
ZIP and attach it to a GitHub issue. The static audit had already ruled out the
usual Android-12 suspects (every filtered component has `android:exported`,
all PendingIntents carry a mutability flag, no background service starts), so
this gives us the actual stack trace instead of guessing.
Implementation:
- New `crash/CrashReporter.kt`: `CrashReporter.install()` sets a global
  `Thread.setDefaultUncaughtExceptionHandler` (chained to the previous handler)
  from `MessagesApplication.onCreate` — installed before all other init so
  init-time crashes are captured too. It formats app version (via
  PackageManager; `BuildConfig` is not generated in this project), Android SDK,
  manufacturer/model/brand/fingerprint, exception class/message and the full
  stack trace, then writes synchronously to
  `filesDir/crash_reports/crash-<stamp>.txt` (capped at the 5 newest to survive
  crash-loops). Pure `CrashReportFormatter` + `CrashReportStore.buildZip` are
  JVM-testable.
- Crash-loop safety: the same report is ALSO published to
  `Downloads/Messages/messages-crash-report.txt` via MediaStore (API 29+, no
  permission). If the app crashes on every launch and its UI is unreachable,
  the log is still retrievable from a file manager — which is exactly the
  issue #209 case.
- New `crash/CrashReportDialog.kt`: on the next launch the app shows a
  "Crash report" M3 dialog — **Save ZIP** (writes
  `Downloads/Messages/messages-crash-report.zip` containing all reports, then
  toasts the location), **Copy** (clipboard), **Delete** (clears the internal
  reports). The original `ACTION_SEND` share of `application/zip` was dropped:
  on AOSP/Bluetooth-only devices the chooser offered just "Choose Bluetooth
  device", useless for attaching to a GitHub issue — saving to Downloads lets
  the user attach it from the GitHub app/web.
- `MainActivity.kt`: `AppViewModel.pendingCrashReports` (loaded off-main) drives
  the dialog; `exportCrashReports()` saves the zip. Strings in
  `strings_main.xml`. No new permissions; `file_paths.xml` untouched.
Tests: `testDebugUnitTest` 18/18 (`CrashReportFormatterTest` 4/4);
`scripts/test-crash-reports.sh` 7/7 (launch -> `am crash` -> report captured
internally AND in Downloads/Messages -> dialog shown -> valid zip saved to
Downloads -> Delete clears). Wired into `run-all-tests.sh`.
NOTE: catches JVM exceptions only — native crashes / ANRs are not captured.

## Issue #203 · Contacts "Text" button opens the list, not the contact's chat (2026-09-14)

✅ USER REPORT: tapping the message/Text button next to a number in Contacts
launched Messages on the conversation list (no recipient), and a chat opened
later for a trashed thread showed a blank header and rejected sends with the
misleading "You can't send messages to alphanumeric senders like """ dialog.
Root causes (three):
1. The manifest advertises `SENDTO`/`SEND` for `sms:`/`smsto:`/`mms:`/`mmsto:`,
   but `MainActivity` only read the internal `open_conversation_address` extra
   and never parsed `intent.data`, so the recipient in `smsto:<number>` was
   dropped (`act=android.intent.action.SENDTO dat=smsto:...`, verified via
   logcat and the real Contacts app on emulator-5554).
2. `MainActivity` was not `singleTop`: a second `smsto:` intent while the app
   was already on top returned `START_DELIVERED_TO_TOP` but `onNewIntent` was
   never called, so warm launches silently did nothing.
3. `getOrCreateConversationBlocking` / `conversationIdForAddress` reused a
   trashed conversation row (`deleted_at>0`) by address; `ChatScreen` filters
   `deleted_at=0`, so it rendered a blank header and `convo?.address ?: ""` made
   `isPhoneNumber("")` false → the alphanumeric dialog.
Fix:
- `MainActivity.kt`: new `recipientFromIntent()` parses `sms/smsto/mms/mmsto`
  URIs (strips `?body=`, takes the first of `;`/`,` recipients, URL-decodes);
  `pendingOpenAddress` is now Compose state so warm `onNewIntent` recomposes;
  a new `"opening"` route holds a neutral surface while the chat resolves —
  set in BOTH `onCreate` and `onNewIntent` — so the list never flashes before
  the chat (verified cold + warm: route goes `opening → chat`, never `list`).
- `AndroidManifest.xml`: `android:launchMode="singleTop"` on `MainActivity`.
- `data/Repository.kt`: `getOrCreateConversationBlocking` un-trashes the matched
  thread; `conversationIdForAddress`/`matchConversationId(activeOnly=true)` skip
  trashed rows; `syncFromSystem` skips blank provider addresses.
- `ui/ChatScreen.kt`: blank address no longer triggers the alphanumeric dialog.
Verified on emulator-5554: tapping the Contacts "Text" button lands directly on
the contact's chat; back returns to the home list; warm `sms:`/`smsto:`, `?body=`
stripping, multi-recipient, and a trashed thread (restored, header + send) all
work. Regression: `scripts/test-issue-203-sms-intent.sh` (18/18).

## CodeQL alerts #1/#2/#3 · implicit PendingIntent (2026-09-13)

(Alert #3 section below; alerts #1/#2 now resolved by the same inline-intent fix in ScheduledMessageSender.)

## CodeQL alert #20 · random-used-once (2026-09-13)

✅ ROOT CAUSE: `java/random-used-once` flagged `BackupCrypto.kt:43` — a new
`SecureRandom()` was created and used only once per `encryptWithPin()` call.
Wasteful (re-seeds entropy pool each invocation) and unnecessary since
`SecureRandom` is thread-safe to share.
FIX: hoisted a private `val secureRandom = SecureRandom()` into the `BackupCrypto`
object; all salt/IV generation now reuses the same instance.
VERIFIED: `assembleDebug` ✓; `test-backup-restore.sh` ✓ (PIN-protected backup →
restore round-trip passes).

File: `data/BackupCrypto.kt`

## CodeQL alert #15 · field-masks-super-field (2026-09-13)

✅ ROOT CAUSE: `java/field-masks-super-field` flagged `Repository.kt:1` with
empty region and message "field shadows another field called $stable in a
superclass."  `$stable` is a synthetic field generated by the Compose Compiler
plugin for `@Stable`/`@Immutable` types — it does not exist in source.
`Repository` is a plain Kotlin class (implicit `Any` superclass, no `$stable`
field); the diagnostic is a Compose compiler artifact that does NOT reproduce in
local builds (`compileDebugKotlin` produces zero `masks` warnings).
STATUS: flagged as false positive; cannot dismiss via API (token lacks Security
events write).  Needs user to dismiss manually in the UI or grant the token the
`security_events: write` scope and re-run the dismiss PATCH.

File: N/A — no source change required.

## CodeQL alerts #1/#2/#3 · implicit PendingIntent (2026-09-13)

✅ ROOT CAUSE: `java/android/implicit-pendingintents` flagged the quick-reply
notification action (`github.com/an1ndra/Messages/security/code-scanning/3`).
The reply PendingIntent must be `FLAG_MUTABLE` (RemoteInput needs the system to
inject reply text; immutable → silently dropped on Android 15+), and CodeQL's
`ExplicitIntentSanitizer` (`ImplicitPendingIntents.qll`) is intra-procedural
only. Building the explicit Intent in a helper (`QuickReplyReceiver.createReplyIntent`)
bypassed the sanitizer — so Copilot's autofix (`setPackage`) did NOT close the
alert (still `open` on main @ `fd0c6e75`, 2026-09-07).
FIX: inlined the explicit Intent (`Intent(context, QuickReplyReceiver::class.java)`
+ `setPackage` + extras) into `SmsSupport.show()`, the same method that creates
`PendingIntent.getBroadcast(...)`; inlined code reads as explicit to the
receiver → sanitizer blocks the taint. Removed the now-unused helper.
VERIFIED: `assembleDebug` ✓; `test-notification-posts.sh` ✓ (cold + warm paths,
"Reply action (RemoteInput) wired"); quick-reply ✓ (reply lands in system Sent
box, 0 crash-buffer entries).
ALSO FIXED: `test-quick-reply.sh` `set -o pipefail` crash on a clean device —
`CLEAR_NODE=$(ui_tags | grep ... | head -1)` exits 1 when no "Clear all" node
exists (added `|| true`).
FOLLOW-UP: manual path of `test-quick-reply.sh` tells the user to type+send,
then the script re-runs `type_text`/send → `input text ''` error if the field is
already gone (collide between script-driven and human-driven reply).

ALERTS #1/#2 (same rule, `ScheduledMessageSender.kt` `setAlarmClock`/`setExact`
sinks; pendingIntent built in `buildPendingIntent()` helper → same cross-method
sanitizer bypass): same inline-explicit-intent pattern applied — `schedule()`
now builds `Intent(context, ScheduledMessageSender::class.java)` (`ACTION_SEND`
+ extras) inline right before `PendingIntent.getBroadcast(...)`,
`buildPendingIntent()` remains used only by `cancel()` (intent equality for
cancel still holds: same component/action/requestCode). VERIFIED:
`assembleDebug` ✓; `test-scheduled-send.sh` ✓ (message persisted + sent); 
`test-delayed-send.sh` ✓ (countdown + auto-send uses the alarm path).
File: `sms/ScheduledMessageSender.kt`.

PR #190 (`fix/codeql-pendingintent` from main) carries the alert #3 fix (SmsSupport
+ QuickReplyReceiver) AND the #1/#2 fix (ScheduledMessageSender) + the #20 fix
(BackupCrypto). MERGE BLOCKED: fine-grained PAT lacks "Pull requests: write"
(PR create OK, merge 403) + "Actions: write" for the security.yml dispatch +
"Security events" for alert dismissal — needs manual merge or extended token,
then `workflow_dispatch` security.yml on main and re-check alerts #1/#2/#3/#20.

UPDATE (2026-09-14): the inline-intent fix above did **NOT** close the alerts. A
fresh CodeQL 2.27.0 scan of merged main (v1.0.24 @ `51ad75c`) still reported all
three — `SmsSupport.kt:240` (`NotificationManagerCompat.notify`),
`ScheduledMessageSender.kt:86/88` (`setAlarmClock`/`setExact`). Root cause:
CodeQL's `ExplicitIntentSanitizer` is intra-procedural and the sink lived in a
separate `notify()` helper; the alarm Intents were also built with a `.apply {}`
block and had no `setPackage`.
REAL FIX (Develop commit `1fab96b`):
- `ScheduledMessageSender.schedule()`: build the alarm + show Intents with plain
  statements (no apply-block) + `setPackage(context.packageName)`, in the same
  method as the AlarmManager sink.
- `SmsSupport.show()`: build the reply/mark-read Intents with plain statements
  and inline `NotificationManagerCompat.notify()` (removed the `notify()` helper).
VERIFIED with the CodeQL CLI 2.27.0 bundle CI uses, DB built from the fixed tree:
`java/android/implicit-pendingintents` = **0 results**; full
`java-security-and-quality.qls` = 13 (CI's v1.0.24 had 16 = these 13 + the 3 PI
alerts). Functionality: `assembleDebug` ✓, `testDebugUnitTest` 12/12 ✓,
`test-notification-posts.sh` ✓, `test-scheduled-send.sh` ✓. The 3 alerts will
close on the next security scan of `main` (weekly cron or next release tag).

## CodeQL alert #21 · insecure-local-authentication (2026-09-14)

✅ ROOT CAUSE: `java/android/insecure-local-authentication` flagged the
message-lock unlock callback in `ChatScreen.kt` (`onAuthenticationSucceeded`).
The query flags any `BiometricPrompt.AuthenticationCallback.onAuthenticationSucceeded`
that never reads its `result` parameter (i.e. performs no cryptographic
operation), so the unlock can be bypassed by UI-hooking tools.
FIX: new `data/MessageLockCrypto.kt` — a Keystore AES key requiring user
authentication for every use (biometric strong + device credential on API 30+,
biometric on API 29). `lockUnlockSelection()` now passes a
`BiometricPrompt.CryptoObject(cipher)` and the callback runs a real crypto
operation (`cipher.doFinal`) on `result.cryptoObject.cipher` before unlocking.
VERIFIED: `testDebugUnitTest` 14/14 (`MessageLockCryptoTest` 2/2);
`scripts/test-message-lock-auth.sh` 3/3 (seed -> lock -> @Lock -> unlock).

## Issue #180 · Search contacts in both the personal and work profile (2026-09-13)

✅ USER REQUEST: contacts from the work (managed) profile must appear in the
contact picker (badged) and resolve by name in conversations, not just the
personal address book.
Mechanism (reverse-engineered from the Google Messages APK + verified on the
google_apis API 35 emulator): the public ENTERPRISE content URIs expose work
contacts cross-profile once the app holds READ_CONTACTS in the work profile:
- `Directory.ENTERPRISE_CONTENT_URI` (directories_enterprise) enumerates
  directories; the work profile is id 1000000000 (`Directory.ENTERPRISE_DEFAULT`).
- `Phone.ENTERPRISE_CONTENT_URI` (data_enterprise/phones) returns personal +
  work contacts merged in one query; work rows carry
  `contact_id >= ENTERPRISE_DEFAULT` (1000000000 + local id).
- `PhoneLookup.ENTERPRISE_CONTENT_FILTER_URI` needs a `?directory=<id>` param.
Implementation:
- `MainActivity.kt` `AppViewModel.contacts`: loads `ENTERPRISE_CONTENT_URI`,
  flags `workProfile` from `contact_id >= ENTERPRISE_DEFAULT`; any failure
  falls back to the plain `CONTENT_URI` (byte-identical for personal-only
  devices — verified: no work profile → PLAIN == ENTERPRISE, same 1 row).
- `ui/NewChatScreen.kt` + `ui/ChatScreen.kt` ForwardPicker: briefcase badge
  (`WorkProfileBadge` in `ui/Components.kt`) next to work contacts.
- `ui/ConversationsScreen.kt` — `vm.contacts` collected, `workNums` set built,
  `workProfile` threaded through `SwipeableConversationItem` →
  `SwipeConversationItem` → `ConversationRow`, badge rendered next to names.
- `ui/ChatScreen.kt` `ChatTopBar` — `vm.contacts` collected at top,
  `workProfile` computed from `convo.address`, badge rendered in header.
- `data/Repository.kt` `lookupContactName`: plain PhoneLookup first, then the
  enterprise filter per non-default directory → work numbers resolve to names
  (home list, chat header, notifications).
Test: `scripts/test-work-profile-search.sh` (6/6) — sets up the work profile
via `test-work-profile-contacts.sh`, asserts the picker badge (work contact
badged), home list row resolves work number by name + shows badge, and
chat header shows name + badge.

## Bug · Copy/Forward must hide URLs when "Hide links from messages" is ON (2026-09-12)

✅ USER REQUEST: with "Hide links" enabled the chat strips the URL, but the
Copy menu pasted the RAW body with the URL, and Forwarding sent it the same way.
What you see must be what you copy/send.
Implementation:
- `ui/ChatScreen.kt` (both bubble composables, `ChatBubble` + `MessageRow`): the
  Copy menu item now derives the text from the same rules as the display —
  `isLockedAndHidden -> "@Lock"`, `hideLinks -> hideUrls(msg.body)`, else raw.
- `MainActivity.kt` `forwardMessage`: forwards the URL-redacted body when
  hide-links is ON.
- Audited the remaining raw-body paths: notification snippet and home-list
  preview/draft already redact; "Copy link" is only reachable on a visibly
  highlighted link (impossible while hiding); `sendText`/`retryMessage` are the
  real SMS send path and must stay raw.
Test: `scripts/test-hide-links.sh` now long-presses a bubble, taps Copy, pastes
into the compose input (`KEYCODE_PASTE`), and reads the EditText back — asserts
the clipboard has no URL while hide is ON and includes the URL again once OFF
(31/31).

## Feature · Notification sound picker + preview on selection (2026-09-12)

✅ USER REQUEST: let the user pick the incoming-message notification sound in Settings (Default + bundled tones instead of only the system default), hear a preview when picking an option, and tighten the gap between the picker options.
Implementation:
- `SettingsStore.kt`: new `notification_sound` pref (string) with constants `default` / `app_sound` / `dragon_studio` / `universfield_09` / `universfield_062`.
- `sms/SmsSupport.kt` `NotificationHelper`: `soundUriFor(context, selection)` + `selectedSoundUri()` resolve the tone (channel upsert and per-notification `n.sound` use it, `null` = system default); new `previewNotificationSound(context, selection)` plays a bundled tone via MediaPlayer (USAGE_NOTIFICATION) or the system default via RingtoneManager, releasing any previous preview first.
- `ui/SettingsScreen.kt`: "Notification sound" row under "Receive sound" showing the current label; radio picker dialog (Default (system) / Classic / Dragon Studio / Chime / Bubble) with `padding(vertical = 2.dp)` rows (was 4.dp); tapping an option plays its preview; OK persists the pref and re-creates the channel.
- New tones in `app/src/main/res/raw/`: `dragon_studio.mp3`, `universfield_09.mp3`, `universfield_062.mp3` (`notification_sound.mp3` already existed).
Follow-up fix (changing the sound had no effect): Android `NotificationChannel` sound is **immutable** after creation, and playback uses the CHANNEL's tone — the single `messages` channel stayed frozen on whatever tone was set first, while only the per-notification `n.sound` field followed the setting (so `dumpsys` looked right but the wrong tone played). `NotificationHelper` now maps each selection to its own channel id (`messages_default` / `messages_app` / `messages_dragon` / `messages_uf09` / `messages_uf062` / `messages_silent`), creates the one matching the current setting, and soft-deletes the stale variants so only one "Messages" entry shows. `channelId(context)` is used by `ensureChannel()`, incoming notifications, and send-failure notifications.
Verified on emulator: picker shows 5 options; tapping each plays an active MediaPlayer player (`dumpsys audio` → `state:started … usage=USAGE_NOTIFICATION content=CONTENT_TYPE_SONIFICATION`); switching the setting swaps the active channel — `messages_dragon` (`mSound=android.resource://com.anindra.messages/2131623936`), `messages_default` (`content://settings/system/notification_sound`), `messages_silent` (`mSound=android.resource://…/silent.wav`, importance HIGH), prior variants `mDeleted=true`.
Test: `scripts/test-notification-sound.sh` (20/20) — now also asserts the active channel's `mSound`, the field Android actually plays.
Follow-up fix ("Receive sound" OFF killed the popup — two layers): (1) a channel with `setSound(null,null)` is treated by Android as low-importance and never heads-up, so the silent `messages_silent` channel could not pop — the channel now plays a bundled 50ms silent clip (`app/src/main/res/raw/silent.wav`) instead, keeping `IMPORTANCE_HIGH`. (2) `show()` no longer calls `setSilent(true)` for the sound-off case: that groups the notification under the `"silent"` group key (androidx convention, confirmed in core 1.18.0 `isSilent()`), and grouped notifications without a summary are suppressed from heads-up. Verified on emulator: `messages_silent` → `mImportance=4`, `mSound=android.resource://…/2131623938`, the posted record has no `groupKey=silent`, and `SingleNotificationStats.airtimeCount=1` proves the popup was actually displayed (uiautomator can't see the SystemUI overlay; the record is the ground truth). Regression: `scripts/test-notification-sound.sh` now asserts the silent channel carries the silent clip AND the popup's `airtimeCount`.

## Issue #184 · Incoming SMS notification shows phone number instead of contact name

✅ USER REPORT: notifications from saved contacts showed the raw phone number as the notification title instead of the contact name (tested on Android 12).
Root cause: `NotificationHelper.show()` set the content title directly to `from` — the raw sender address — and never consulted the address book.
Fix: `SmsSupport.kt` resolves the title through `Repository.contactNameFor(from)` (reuses the existing contact cache/lookup) and falls back to the number only when the contact is not saved. Privacy mode keeps the generic "New message" title unchanged. The lookup runs on the background thread SmsReceiver already posts from.
Verified on emulator (`dumpsys notification --noredact`): SMS from +15551230010 (demo contact "Sarah") → title `Sarah Sarah`, raw number absent.
Test: `scripts/test-issue-184-notification-name.sh`

## ui/chat-design-update · App stuck / crashes / chats won't load on a real phone (2026-09-12)

✅ USER REPORT: built the `ui/chat-design-update` branch with the Develop Build workflow and installed on a physical phone — the app gets stuck, crashes, and sometimes never loads any chats.
Root cause (real-phone scale): with a provider full of SMS history (Google Messages mirrors everything), every sync ended with `mergeSplitConversations()` that had to complete **inside** the sync task: `runOnIo { … }` blocks via `CompletableFuture.get()` until the O(C²) heal finishes, and each pair comparison ran `PhoneNumberUtils.compare()` + libphonenumber `parse()` — seconds-to-minutes on a phone with hundreds of threads. The home-list and chat flows share the same SQLite connection, so they wait behind it: the list shows nothing and the app looks frozen ("stuck / chats not loading"); force-stop + relaunch just lands back on the same slow path.
Fix (all in `data/Repository.kt` unless noted):
- `samePerson()` is now pure digit comparison (`filter{isDigit}` equality + `+1` drop). Still merges the #183 cases (`+15551234567` vs `15551234567`) at ~zero cost, drops the expensive `PhoneNumberUtils.compare` and libphonenumber `canonicalPhoneNumber` from the per-lookup and per-pair hot paths.
- `mergeSplitConversations()` is queued on the sync executor (`syncExecutor.execute { … }`) instead of blocking via `runOnIo` — the "Loading" UI clears as soon as the import passes its data; the heal runs in the background, still serialized with imports (same single thread).
- Removed the now-unused `com.googlecode.libphonenumber` dependency (`libs.versions.toml` + `app/build.gradle.kts`).
- Removed the duplicated "Sending in N seconds…" banner that rendered twice on the chat screen (`ui/ChatScreen.kt`).
Verified on a rooted emulator seeded with 15,000 provider SMS: first-launch import 6s, home list renders, a chat opens, no crash, warm relaunch provider pass 2s. New regression: `scripts/test-large-provider-startup.sh` (seed provider → fresh install → import/land/chat/relaunch + crash watch). Existing suites re-run clean: issue-183 split-threads 5/5, message-delete-undo 11/11, empty-chat-removal 11/11, initial-sync 2/2, import-mirrors 5/6 (step 6 is the third-party SMS-IE UI, flaky on the AVD).

## Issue #179 · Open app to view recent messages first (2026-09-11)

✅ Two parts:
- Chat screen opened ~3 rows above the newest message: `scrollToItem(messages.size - 1)` ignored the 3 loading-skeleton rows (and optional "Load earlier" button) the LazyColumn renders ABOVE the message rows. Now scrolls to `listState.layoutInfo.totalItemsCount` with a fallback retry (`LaunchedEffect(messages.size)` + 80ms). File: `ui/ChatScreen.kt` · test: `scripts/test-issue-179-scroll.sh`
- Home list scroll behaviour (final, after three user corrections). Auto-scrolling on every new message was rejected — it yanks the list while the user is reading; and the app must not first show the old position then visibly jump to the top on open. Rules: (a) app just opened at the top + message arrives → reveal the new conversation; (b) user has scrolled down + message arrives → leave their position untouched; (c) open/reopen → the newest (unread) rows are shown at the top directly, no jump. Implementation: the `LazyListState` is deliberately non-saveable and recreated on the empty→loaded transition (`remember(conversations.isNotEmpty()) { LazyListState(0,0) }`) — a saveable state restored the old offset (then jumped), and a single state reused across the empty first composition anchored to the last row once the list arrived (LazyColumn keeps the previously visible item), which is what showed old messages on open; `snapshotFlow` tracks `isScrollInProgress` to know if the user manually scrolled away (key-anchoring shifts while idle are ignored); a `LaunchedEffect(displayed)` reveals a conversation whose unread count increased only when the user has NOT scrolled away, and skips seeding on the empty first emission so the initial load never looks like a live arrival. File: `ui/ConversationsScreen.kt` · test: `scripts/test-issue-179-home-scroll.sh`
Verified on emulator: open lands on the true newest row with `firstVisibleItemIndex=0` (no jump); opened-at-top + receive reveals the new row; scrolled-down + receive leaves the top row unchanged; force-stop → reopen lands on the top row.

## Issue #183 · Some imported conversations split into sent and received messages

✅ USER REPORT: after restoring an SMS Import/Export backup, the same contact appeared as two threads — one holding only sent messages, one only received.
Root cause: every address→conversation path used exact string equality on the stored provider `ADDRESS`, but the same person is stored under two formats: received SMS carry the sender number as delivered by the network (E.164, `+15551234567`) while sent SMS store the dialed form (bare `15551234567`). Same SIM, same number, two spellings → two buckets → two threads. (Reporter confirmed all messages were "SIM 1" and the number never changed.)
Fix (all in `data/Repository.kt`):
- New `samePerson(a,b)`: matches `PhoneNumberUtils.compare(context,…)` plus a digits/`+1` NANP fallback; never merges zero-digit alphanumeric senders.
- `getOrCreateConversationBlocking` + `conversationIdForAddress`: exact `address=?` first, then `samePerson` scan → reuse the existing thread instead of creating a duplicate (send/receive/quick-reply/scheduled/new-chat paths all benefit).
- `mergeSplitConversations()`: one-time/ongoing heal that folds already-split threads (fold messages, draft, archived flag, notification settings into the earliest row) — runs after every system sync and also covers backup `mergeDatabase` (restore no longer re-splits).
- No schema change → no migration; blocked-numbers, trash, archive, drafts, reactions, lock, search are all keyed by conversation_id/separate tables and are untouched.
Verified on emulator: regression script `scripts/test-issue-183-split-threads.sh` went from `4 passed, 1 failed` to `5 passed, 0 failed` (Mom = ONE conversation, 2 in + 2 out; control merged); a manufactured pre-fix split in the local DB was healed to a single thread on relaunch and the home list shows one `+1-555-123-4567` row.

## Issue · Backup import no longer repopulates the system SMS provider (2026-09-12)

✅ USER REPORT: backed up in-app, deleted every message from the app, re-imported the backup — messages showed in our app but the default Messaging app showed nothing, and SMS Import/Export exported `0 SMS`.
Root cause: `importDatabase`/`mergeDatabase` only swapped/merged the private `messages.db`; nothing ever wrote back to `content://sms`, so sibling apps (which read only the system provider) saw an empty history.
Fix (in `data/Repository.kt`):
- New `pushLocalMessagesToProvider()`: best-effort mirror of non-deleted local messages into `Telephony.Sms.CONTENT_URI`. Address is joined from `conversations` (the `messages` table carries no address in the v14 schema), provider `sys_id`s already present are skipped (no re-import duplicates), and new provider `_id`s are written back to the local rows. Maps app status → provider status (`failed`→STATUS_FAILED, sent/delivered→STATUS_COMPLETE), preserves `date`/`sub_id`, and degrades silently when the app isn't the default handler or the provider rejects a row. Called on both the REPLACE and MERGE import paths.
- First build failed the query with `no such column: address` (mirror SQL referenced `messages.address` which doesn't exist in v14) — fixed with a `JOIN conversations c ON c.id = m.conversation_id`.
Verified on emulator: backup 2 messages → wipe provider + `pm clear` app → in-app restore → provider back to 2 rows (`RepoMirror: push: attempted=2 linked=2`), default Messaging shows the restored thread, SMS Import/Export exports `2 SMS(s) and 0 MMS(s) exported`. Regression: `scripts/test-import-mirrors-provider.sh` (new) covers the full chain.

## P0 · App lock auto-disables when no device credential exists (no dead "Turn off" control)

✅ Follow-up to the no-credential lockout fix. Instead of showing a "Turn off App lock" bypass button anyone could hit on an already-inert lock, the app now auto-disables App lock (`settings.appLockEnabled = false`) and shows an honest info screen: "App lock is off" / "App lock can't be used because this device has no screen lock... to verify it's you. Set one up to turn App lock back on." — buttons: `Set up screen lock` (opens device Settings.ACTION_BIOMETRIC_ENROLL) + `Got it` (dismiss → home). No dead control, no fake lock screen. Works for all `canAuth` outcomes other than SUCCESS (NONE_ENROLLED, NO_HARDWARE, etc.).
Verified on emulator: cleared device credential → pref auto-flipped false, info screen appeared (no "Turn off" button) → "Got it" → home. Restored PIN+fingerprint → prompt path works again.

## P0 · Deleted messages no longer reappear after restart

✅ USER REPORT: messages deleted from home → Trash → Empty trash → restart → old messages reappeared.
Root cause: `syncFromSystem()` re-imports every provider message whose `sys_id` is absent from the local DB on app launch/resume, but a local-only delete never touched the system SMS provider — so after Empty trash cleared local rows, the next launch's sync resurrected them from `content://sms`.
Fix: permanent-delete paths now also delete the matching rows from the system SMS provider (app is the default SMS app, and `WRITE_SMS` added to the manifest as belt-and-suspenders). Applied in `emptyTrashSuspend()`, `purgeOldTrashSuspend()`, `deleteConversationSuspend()` via new `purgeProviderMessages()` (best-effort; skips on SecurityException). Verified on emulator: empty-trash of 15105550199 → provider row gone → cold restart → conversation stays gone (local msgs 0, provider 0 rows).

## P0 · Notification uses system default sound, not the bundled custom MP3

✅ USER REPORT: incoming SMS notifications played the app's bundled custom tone (`R.raw.notification_sound`) instead of the user's system default notification sound.
Root cause: the "messages" notification channel was created with the custom resource URI. Android notification channels are immutable after creation, so upserting the channel later (`createNotificationChannel` with a different sound) is silently ignored — only the channel name/description are updateable. Verified via `dumpsys notification` (channel `mSound` stayed `android.resource://.../2131623936` across rebuilds) and debugging showed `getDefaultUri(TYPE_NOTIFICATION)` returns a valid `content://settings/system/notification_sound`.
Fix (both layers):
- `NotificationHelper.ensureChannel` now creates the channel with `setSound(RingtoneManager.getDefaultUri(TYPE_NOTIFICATION))` when receive-sound is on, `setSound(null,null)` (silent) when off — correct for fresh installs.
- `NotificationHelper.show()` sets `notification.sound` directly on the platform `Notification` so every post overrides any legacy/stale channel tone. NB: the buffer-level `NotificationCompat.Builder.setSound()` was discovered to be a no-op (emitted notification came back `sound=null` in dumpsys), which is why the field is set post-`build()`.
- Settings "Receive sound" row now also refreshes the channel on toggle (`NotificationHelper.ensureChannel`); subtitle reads "Use the system notification sound when a message arrives". `playReceiveSound` removed; `playSound()` is send-sound only.
Verified on emulator (`dumpsys notification --noredact`): fresh-install channel `mId='messages'` → `mSound=content://settings/system/notification_sound`; notification record → `sound=content://settings/system/notification_sound`. Old legacy channel would keep the stale tone but the per-notification sound now wins for playback unless the user has explicitly locked the channel's sound.

## P0 · Locking the latest message still leaked its snippet on the Main screen

✅ USER REPORT: after locking the newest message from the chat screen, the conversation list still showed the raw message text as the row snippet.
Root cause: `Repository.setLockedSuspend()` only flipped `messages.locked`; the `conversations.snippet` column was never rewritten, so the home list kept showing the plain body of the now-locked message.
Fix: `setLockedSuspend()` now calls new `refreshSnippetForLockToggle(messageId)` — only rewrites the snippet when the toggled message is that conversation's newest (`ORDER BY timestamp DESC, id DESC LIMIT 1`), setting `"@Lock"` (plain text, no emoji — user rejected the lock emoji as unprofessional) when locked, else the plain body / `Photo` / `Video` / `Voice message` / `Attachment` by media type. Verified on emulator: long-press "final sound check" → Lock → back to list → row shows `@Lock`; menu item gone/restored consistent with Forwarding toggle.
Files: `data/Repository.kt`. Manual check reuses `scripts/test-message-lock.sh` flow (then check the home-row snippet).

## P0 · "Forward" context-menu item visible even when forwarding is disabled

✅ USER REPORT: the long-press context menu on a message showed "Forward" even though Forwarding was turned off in Settings.
Root cause: the `Forward` `DropdownMenuItem` was rendered unconditionally; only the long-press handler respected `forwardingEnabled`.
Fix: `forwardingEnabled: Boolean` threaded from `ChatScreen` → `ChatMessageList` → `MessageRow` (default `false` on the row), and the Forward item is wrapped in `if (forwardingEnabled) { ... }`. Call site passes `vm.settings.forwardingEnabled`.
Verified on emulator: Forwarding off → long-press shows only Copy/Lock; Forwarding on → Copy/Forward/Lock.
Files: `ui/ChatScreen.kt`.

## P1 · Advanced settings: permanent delete + reverse swipe + link behaviour (#177/#178)

✅ NEW Settings → Advanced screen holding 4 toggles — Permanent delete (default off), Reverse swipe actions (default off), Highlight links (moved here from the main Settings list, default on), Link open warning (default on). All backed by SettingsStore prefs (`permanent_delete_enabled`, `reverse_swipe_enabled`, `link_open_warning_enabled`) via the existing `revision` StateFlow so toggles apply LIVE.
- Permanent delete ON: chat 3-dot Delete and the home swipe/sheet Delete now show `PermanentDeleteConfirmDialog` ("Delete permanently?" warning) before calling `deleteConversation` → `Repository.deleteConversationSuspend()` hard-deletes (local + system-provider purge, no trash). Verified: confirmed delete removed the conversation from home AND trash with zero message rows left.
- Reverse swipe ON: homepage `SwipeConversationItem` swaps directions — swipe RIGHT trashes, swipe LEFT archives (background color + icon swap with it). Verified in SQL: swipe-right row got `deleted_at`, swipe-left row got `archived=1`; both restored afterwards.
- Link open warning OFF: tapping a highlighted link opens the browser directly instead of the "Caution: external link" dialog (both states verified — dialog shows when ON, browser foregrounds with no dialog when OFF).
- Also fixed `scripts/env.sh` `center_of`/`center_of_contains`: the query was embedded raw into an ERE, so `+1-555-…` number lookups (plus/`.`/`(`/`)`) never matched (`+` quantifies the quote). New `re_escape()` escapes ERE metachars before grepping.
- Regression: `scripts/test-advanced-settings.sh` (22 checks, all passing) — asserts "Highlight links" absent from main Settings, the 4 Advanced toggles, link dialog/direct-open for both warning states, permanent-delete dialog shown + Cancelled non-destructively, reverse-swipe trash/archive + restore, and all prefs returned to defaults.

Files: `ui/AdvancedSettingsScreen.kt` (new), `ui/SettingsScreen.kt`, `data/SettingsStore.kt`, `MainActivity.kt`, `ui/ConversationsScreen.kt`, `ui/ChatScreen.kt`, `scripts/test-advanced-settings.sh`, `scripts/env.sh`, `TODO.md`.

## P1 · Recognize phone numbers with parenthesized area codes (issue #176)

✅ USER REPORT: sending to numbers stored as `(555) 555-0123` was blocked with "You can't send messages to alphanumeric senders" — `isPhoneNumber()` only allowed digits and `+`, so parenthesized area codes failed the guard.
Fix: `isPhoneNumber()` (ui/ChatScreen.kt) now also permits `( ) - . ` and spaces while still rejecting letters (alphanumeric senders like DK-AIRCEL stay blocked); `SmsSender` normalizes the stored address before `sendTextMessage` (strips formatting, keeps digits + optional leading `+`) via new `normalizeAddress()`.
Verified on emulator-5554: NewChat manual entry `(555) 555-0999` accepted ("Send to" enabled, no error), `VM-HDFCBK` still rejected, chat send hands off cleanly (message 29 status `sent`, convo address stored raw as `(555) 555-0999`). Test: `scripts/test-parentheses-number.sh`.

Files: `ui/ChatScreen.kt`, `sms/SmsSupport.kt`, `scripts/test-parentheses-number.sh`, `TODO.md`.

Hand this file + AGENTS.md (same folder) to any AI agent. Tasks are ordered by
priority; each has acceptance criteria and file pointers. Verify on
`emulator-5554` with `scripts/*.sh` before marking done.

---

## Phone normalization + display formatting (feature/phone-normalization)

✅ Implemented phone number normalization and display formatting (Material 3 pattern):
- Added `libphonenumber:8.13.55` dependency
- New `data/PhoneNumberUtils.kt`: E.164 conversion, locale-aware display formatting, caching, region resolution (SIM → SIM list → locale), NANP fallback for US/CA
- `data/Repository.kt`: DB v15 with `participants` table, `getOrCreateConversationBlocking` normalization, `runParticipantMigration()` one-shot pass (merges split conversations by canonical E.164, populates participants, normalizes blocked numbers)
- `data/Models.kt`: `Conversation.display` field (address)
- All UI screens updated: `ChatScreen`, `ConversationsScreen`, `ContactDetailsScreen`, `TrashScreen`, `NewChatScreen`, `SettingsScreen` — use `display` and formatted numbers
- ProGuard rules for libphonenumber
- `regionFor` fixed: handles `null` region codes (fictional 555 numbers)
- Test: `scripts/test-phone-normalization.sh` (15/15) — seeds 6 mixed-format conversations, verifies merge, E.164 storage, participant table population, display formatting, and idempotent second launch

File: `data/PhoneNumberUtils.kt`, `data/Repository.kt`, `data/Models.kt`, `data/SettingsStore.kt`, `MessagesApplication.kt`, `ui/ChatScreen.kt`, `ui/ConversationsScreen.kt`, `ui/ContactDetailsScreen.kt`, `ui/TrashScreen.kt`, `ui/NewChatScreen.kt`, `ui/SettingsScreen.kt`, `proguard-rules.pro`, `scripts/test-phone-normalization.sh`

---

## Completed (DO NOT re-implement)

### Core Architecture
- ✅ M3 full color system (light/dark) from seed #0B57D0
- ✅ Data layer: SQLiteOpenHelper v5, Flow-based Repository, SettingsStore
- ✅ SMS: SmsSender (multi-SIM), SmsReceiver, MmsReceiver, NoConfirmationSmsSendService
- ✅ NotificationHelper with tones

### Screens
- ✅ ConversationsScreen: search w/ autofocus, avatars (custom `ic_person_placeholder.xml`), unread badges, Start chat FAB, archive icon toggle
- ✅ ChatScreen: aligned input bar, send button visibility, call icon, save-contact banner, date dividers, status line, draft loading/saving, message forwarding, blocked number check dialog, delayed sending, Block/Unblock in 3-dot menu
- ✅ SettingsScreen: card-based sections with icons, proper visual hierarchy
- ✅ NewChatScreen: contact picker + manual number entry

### Features
- ✅ MMS image sending: attachment button, ModalBottomSheet, PickVisualMedia + TakePicture, ImageBubble
- ✅ Failed message UX: red "Not sent · Tap to retry", retryMessage
- ✅ SIM card selection: Settings row, permission-gated dialog, SubscriptionManager
- ✅ SIM switcher icon in input pill (top-right of "Text message" field, dual-SIM "1/2" icon `ic_dual_sim.xml`, tap = cycle SIMs, toast feedback, hidden while typing) — test: `scripts/test-sim-inputbar.sh`
- ✅ Chat header: contact name or formatted number
- ✅ Adaptive launcher icon
- ✅ Custom vector drawable `ic_person_placeholder.xml` (Wikimedia reference)
- ✅ Avatar colors: Pink #FF63B8, Coral Red #EE675C, Orange #FA903E, Cyan #4ECDE6, Purple #AF5CF7
- ✅ Profile icon: pink background with white person silhouette
- ✅ Default SMS app prompt: AlertDialog on first launch, RoleManager.ROLE_SMS
- ✅ Backup/Import: backupDatabase() + importDatabase() via MediaStore/SAF

### QKSms-Inspired Features
- ✅ Long-press context menu: QKSms-style ModalBottomSheet with Pin/Unpin, Archive, Delete, Block
- ✅ Pinned conversations (DB column + toggle in settings + visual indicator)
- ✅ Drafts (auto-save, restore on open, visual indicator)
- ✅ Archiving (DB column + toggle in settings + archive view)
- ✅ Swipe actions (SwipeToDismissBox: swipe-right=archive, swipe-left=delete)
- ✅ Number blocking (blocked_numbers table + check on incoming SMS)
- ✅ Message forwarding (long-press → ForwardPicker)
- ✅ Delayed sending (configurable delay countdown + cancel)
- ✅ DB v5: pinned/draft columns, blocked_numbers, scheduled_messages tables
- ✅ Scheduled messages (long-press send → DatePickerDialog + TimePicker → AlarmManager)
- ✅ Settings Features section with all toggles organized by category

### Recent Updates
- ✅ Real SMS sync: seed data removed; syncFromSystem() reads Telephony.Sms.CONTENT_URI (dedupe by sys_id), runs on app start + resume
- ✅ DB v6: `sys_id` column on messages
- ✅ Write-backs: sent → system Sent box; received → system Inbox (when default SMS app)
- ✅ READ_SMS permission (manifest + runtime request)
- ✅ Default SMS role check: RoleManager.isRoleHeld(ROLE_SMS); emulator fix: `adb shell cmd role add-role-holder android.app.role.SMS com.anindra.messages`
- ✅ Contact names refresh on resume (refreshContactNames + NORMALIZED_NUMBER matching)
- ✅ 3-button nav fix: navigationBarsPadding on chat bottom bar
- ✅ Save-contact banner: floating overlay (78% opacity), phone-number-only guard, no layout push
- ✅ Release signing: release.keystore + Messages-release.apk
- ✅ Per-SIM switcher icon: `ic_sim_1.xml`/`ic_sim_2.xml` show the SELECTED SIM's card+number in the input pill (top-right of field); hidden while typing; tap = cycle SIMs — test: `scripts/test-sim-inputbar.sh`
- ✅ SIM indicator in chat status line: sent messages show "· SIM 1" or "· SIM 2" when sub_id is available (dual-SIM display like Google Messages)
- ✅ SIM tracking: Message model includes subId field, DB v12 migration, SmsReceiver extracts subscription ID from intent, sendText/receiveMessage/writeSentToSystem pass subId
- ✅ Sound picker removed: custom notification sound import feature removed entirely; hardcoded default beep (TONE_PROP_BEEP2/TONE_PROP_ACK) for message sounds; "Message sounds" on/off toggle kept
- ✅ Block sends to alphanumeric sender IDs (DK-AIRCEL…): chat send/schedule guarded with dialog; NewChat manual entry restricted to phone numbers — test: `scripts/test-links-and-senders.sh`
- ✅ Highlight links in messages: URLs become tappable (blue underline) opening the browser; Settings → Messages → "Highlight links" toggle (default on) — test: `scripts/test-links-and-senders.sh`
- ✅ Trash system: swipe-left / sheet Delete moves conversations to trash (DB v8 `deleted_at`), UNDO snackbar, Settings → Privacy → Trash screen (restore / delete forever / empty trash), auto-purge after 30 days on app start, new SMS from trashed address restores the thread; swipe needs ~65% travel (less sensitive) — test: `scripts/test-trash.sh`
- ✅ Swipe threshold actually enforced: material3 `positionalThreshold` is ignored (known bug, issuetracker 471021165 — settle at ~50% + 125dp/s velocity), so short swipes deleted rows; gated with `confirmValueChange` + `progress >= 0.65f` in `SwipeConversationItem` (ConversationsScreen.kt) — test: `scripts/test-swipe-threshold.sh`
- ✅ Trash confirmations + polish (issue #87): "Empty trash" and "Delete forever" now ask M3 AlertDialog confirmation before destroying data; Trash rows restyled to match main list (48dp avatar, 12dp padding, gray restore icon, inset dividers); empty state shows 30-day retention hint
- ✅ Per-conversation notification settings: DB v9 `conversation_notifications` table (ON DELETE CASCADE), notification toggle in ContactDetailsScreen + ChatScreen 3-dot menu, NotificationHelper.show() checks per-conversation setting before posting — test: `scripts/test-notifications.sh`
- ✅ Mark all as read: Settings → General row
- ✅ Real send confirmation: SmsStatusReceiver + sent/delivery PendingIntents flip rows sending→sent→delivered or failed; failures show red "Not sent · Tap to retry"; MMS gated for alphanumeric senders
- ✅ Draft fix: clearing text now erases the stored draft on back
- ✅ Contact photos: avatars show contact profile pictures when available
- ✅ Dark-mode bubble text: explicit onSurface/onPrimaryContainer colors (ClickableText regression fixed)
- ✅ Settings redesigned to GM style: icon-less rounded card groups, no section headers, same functionality
- ✅ Back navigation fixes: Archived/search views return to list on back (no more app close), root screen guarded with "Press back again to exit" (accidental swipes no longer kill the app) — test: `scripts/test-back-nav.sh`
- ✅ Draft fix v2: leaving chat via top-bar ← arrow also saves/clears draft (was bypassing BackHandler)
- ✅ F-Droid prep: conditional release signing (keystore optional, passwords via env), machine-specific JDK pin moved out of repo, GPL-3.0 LICENSE, README, gradle wrapper, fastlane metadata (title/descriptions/changelogs), .gitignore covers keystore/apk/local caches
- ✅ CI GPG signing (fdroid-release.yml): gpg wrapper as `gpg.program` passing passphrase via `--passphrase` + loopback pinentry — `--passphrase-fd 0` is unusable with git (git feeds commit data on stdin); GNUPGHOME exported in-step AND via GITHUB_ENV; GPG_PASSPHRASE passed to later steps via multi-line `<<EOF` env format. E2E verified locally: signed commit + signed tag through the wrapper. Requires secrets GPG_PRIVATE_KEY + GPG_PASSPHRASE.
- ✅ Backup restore fix: encrypt/decrypt failed when the DB size made the ciphertext an exact multiple of GCM's 16-byte block — Android's provider returns `null` from `Cipher.doFinal()` when all input was already flushed by `update()`, so `write(null)` raised NPE inside `decrypt()`, the valid backup was misread as "legacy unencrypted", and import reported a misleading error; `update()`/`doFinal()` outputs are now null-guarded before write. Verify — test: `scripts/test-backup-restore.sh`
- ✅ Import verified against PRE-FIX backups (10:53/11:02/11:10, created by the buggy encrypt): file format is byte-identical pre/post fix (12-byte IV + AES-GCM payload + tag), so an old backup imports cleanly AS LONG AS the same device-bound Android-Keystore key (`messages_backup_key`) still exists — i.e. the app was UPDATE-installed in place, not uninstalled. If the app was uninstalled/reinstalled, the key is gone and the old backup fails decrypt → falls to raw-copy → rejected as "Invalid or corrupted backup file" (correct: data is unrecoverable, by design). Emulator proof: backups made before the 21:17:37 fresh install fail to import, those made after restore fine.
- ✅ `scripts/test-backup-restore.sh` rewritten for the current UI (avatar tap 975,226 → scroll → Backup/Import rows): creates a fresh backup, then imports the NEWEST .enc by filename (picker's first visible row is the OLDEST file, which may belong to a lost key and correctly fails); asserts the live `messages.db` mtime changes (epoch seconds via `toybox stat -c %Y`) and the home list renders after restart. Wired into `scripts/run-all-tests.sh`. NOTE: SAF-picker auto-scroll is flaky on the emulator (works manually); more swipes added but the rebuild picker occasionally misses rows.

## P0 · Real data only — Demo/F-Droid seeding removed

✅ ALL Demo/Dummy data removed per user request:
- Deleted `data/DemoData.kt` (seeder) + the 10 `avatar_*.png` demo resources
- `Repository.init` no longer seeds on empty DB; removed `systemSmsCount()` + `purgeDemoConversations()`
- `Components.loadContactPhoto` no longer maps demo numbers to avatar resources (real contact photos only)
- Verified: fresh `pm clear` + initial-sync imports ONLY real SMS from the system provider; home shows real numbers/messages, no Sarah/Mom/demo rows

## P0 · Import un-trashes restored conversations

✅ Blank-home-after-import fixed: `importDatabase()` now runs `UPDATE conversations SET deleted_at=0 WHERE deleted_at>0` after a successful swap, so conversations that were in the Trash when the backup was made are visible on the home screen after restore (user hit a blank home because the imported backup contained trashed conversations). CAVEAT: backups created BEFORE the demo-removal still contain seeded demo rows; make a fresh backup.

## P0 · install.sh fixed

✅ `scripts/install.sh` used a hardcoded `~/tools/gradle-9.2.1/...` path that doesn't exist → rewired to `./gradlew` with a robust JAVA_HOME fallback chain (`~/.local/java/jdk-21.*` → `~/tools/jdk21` → exported `$JAVA_HOME`); verified to build+install even when the shell exports an invalid JDK. Also fixed `env.sh` ADB default (`$HOME/Android/Sdk` → `$HOME/android`).

## P1 · Scheduled messages UI

✅ DONE. Long-press send button → M3 DatePickerDialog → TimePicker → saves to DB + sets AlarmManager alarm. Scheduled messages list with cancel in Settings.

## P2 · Quick reply from notification

✅ DONE. `RemoteInput` on notification + `QuickReplyReceiver` BroadcastReceiver sends SMS from notification inline reply. Registered in AndroidManifest.

File: `sms/SmsSupport.kt`, `sms/QuickReplyReceiver.kt`

## P3 · Message locking

✅ DONE. `locked` column in messages table (DB v10), Lock/Unlock in message context menu, biometric/PIN prompt via `BiometricPrompt`, locked messages show "@Lock" (no emoji — user rejected the lock emoji) until authenticated, re-lock on chat exit. Test: `scripts/test-message-lock.sh`

File: `data/Repository.kt`, `data/Models.kt`, `ui/ChatScreen.kt`

## Splash screen dark mode

- ✅ Splash now follows dark mode: added `values-night/themes.xml` (dark Material parent), `values-v31` + `values-night-v31` with `windowSplashScreenBackground` matched to app surface (#F8F9FC light / #131314 dark). Verified brightness 238 light / 30 dark. Test: `scripts/test-splash.sh`

## Skeleton loading shimmer

- ✅ Shimmer skeleton placeholder while content loads (8 rows with animated gradient circles/bars matching GM style). 400ms hold before real content appears.

## Demo data for F-Droid

- ✅ 10 realistic conversations seeded on fresh install (Sarah, Mom, Work, Jake, Emma, Dad, Pizza Palace, Alex, Dr. Patel, Gym Buddy) with 3-5 messages each, unread badges, pinned item
- ✅ 6 contact avatar PNGs (colored circles with initials) in `res/drawable-xxhdpi/`
- ✅ `DemoData.kt` seeds conversations + messages when DB is empty; `loadContactPhoto` returns demo avatars for seeded numbers
- ✅ F-Droid/README screenshots saved in `screenshots/fdroid/` (20 images: home/chat/settings/reply × dark/light, plus scheduled picker, trash, contact details, new chat, archive × dark/light; mirrored in `fastlane/.../phoneScreenshots`). Script: `scripts/take-fdroid-screenshots.sh` (all taps dump-derived, per-shot verify). Prereq: `scripts/insert-demo-contacts.sh` seeds the Contacts provider for the demo numbers

## Chat UI adjustments (user request)

- ✅ Save-contact banner hidden in chat window (code commented out, easily restorable)
- ✅ SIM selector moved from input pill to chat 3-dot menu (per-SIM rows with radio buttons, carrier names, persists selection); hidden on single-SIM devices. Test: `scripts/test-sim-menu.sh`
- ✅ Notifications toggle removed from chat 3-dot menu (per-conversation toggle remains in Contact details screen)
- ✅ Archive menu item fixed (was a dead control — onClick only closed the menu); now archives, toasts, returns to list. All chat-menu options verified: Add people→contact editor, Details, Archive/Unarchive, Delete→trash, Block/Unblock. Test: `scripts/test-chat-menu.sh`

## Contact details header photo

- ✅ Header avatar now uses `PersonAvatar` (loads real contact photo) instead of hardcoded placeholder — matches the participant row which already showed the photo

## P2/P3/P5 follow-up fixes

- ✅ Crash fix: DB self-healing in `Db.onOpen` — recreates `conversation_notifications` and adds missing `locked` column even when an intermediate APK shipped a broken migration
- ✅ Message long-press fix: replaced `ClickableText` with plain `Text` (links handled natively by Compose) so the bubble's `combinedClickable` long-press fires; Copy/Lock menu reachable again
- ✅ Verified: link taps still open browser (`test-links-and-senders.sh`), lock persists across restart

## Recent fixes

- ✅ Back navigation on gesture devices: ~~`onBackPressed()` override in MainActivity~~ SUPERSEDED by unified BackHandler stack (see next entry); `enableOnBackInvokedCallback="false"` in manifest
- ✅ Skeleton flash fix: skeleton only shows on first app load (400ms), not on back navigation (static `hasLoadedOnce` flag)
- ✅ OTP highlighting: 4-8 digit standalone numbers highlighted in primary color with medium weight in message bubbles
- ✅ Privacy mode enhancements: notification content hidden (shows "New message" / "You have a new message"), `android:taskAffinity=""` for recent apps content hiding, `FLAG_SECURE` on window
- ✅ App lock: fingerprint/PIN authentication on app launch (BiometricPrompt from AndroidX Biometric), graceful fallback on devices without biometric hardware, toggle in Settings > Privacy
- ✅ Message unlock simplified: removed biometric prompt for lock/unlock in chat context menu (direct toggle)
- ✅ Avatar palette expanded: 16 colors, 10 demo avatar PNGs (256x256) seeded via DemoData
- ✅ `FragmentActivity` base class (required for BiometricPrompt)
- ✅ Smart OTP detection: keyword-gated tiered matcher in new `ui/OtpDetector.kt` (adjacent keyword, grouped "482 913"/"4433-2211", bare 6-digit with strong keyword), currency + year-shaped guards; bold primary highlight; JUnit coverage in `OtpDetectorTest` — test: `scripts/test-otp.sh`
- ✅ OTP highlight decoupled from "Highlight links": turning the link toggle OFF no longer drops OTP highlighting — `rememberLinkedText` (ui/ChatScreen.kt) previously skipped the whole annotated builder when `highlight` was false (killing OTP styling too) and applied OTP + URL styling together when true; it now always applies the OTP style and gates only URL spans/link annotations behind the toggle. OTP stays bold-highlighted; the link toggle affects only links. Follow-up: the "Hide links from messages" redaction path also ran through a plain `AnnotatedString` (dropping OTP styling whenever hide was ON) — it now styles stripped text with the same OTP matcher, so OTP stays highlighted in every combination of the three link toggles. Test: `scripts/test-otp-link-independence.sh` (19 checks: link tap shows Caution dialog with highlight ON, nothing when OFF, OTP rendered with hide ON and URL stripped, hide→highlight dependency chain, defaults restored)
- ✅ Crash fix: back from chat killed the process (`ConcurrentModificationException` in `Repository.notifyChanged` when draft-save raced Flow listener churn); listeners now a `CopyOnWriteArrayList` — reported via real-device logcat
- ✅ Screen transitions: all routes animate via a single direction-aware `AnimatedContent` (forward = slide-in-from-right, back = slide-out-to-right, same-depth = fade); replaces instant `when(navRoute)` swaps and the chat↔details-only animation

File: `MainActivity.kt`, `SettingsScreen.kt`, `SmsSupport.kt`, `AndroidManifest.xml`, `Components.kt`, `DemoData.kt`

## Back-stack fix (2026-08-24)

- ✅ BUG: system BACK (button or gesture) from the contact profile screen jumped to the conversation LIST instead of returning to the chat — caused by the removed `onBackPressed()` override mapping `"details" -> "list"`
- ✅ BUG: two competing back systems (`Activity.onBackPressed` override + per-screen Compose `BackHandler`s). The override bypassed the dispatcher entirely, so button-back from chat skipped `leaveChat()` and silently DROPPED drafts
- ✅ FIX: deleted the `onBackPressed()` override; ONE top-level `BackHandler` in `MainActivity` pops a virtual stack: `details→chat`, `trash→settings`, everything else→`list`. Child-screen handlers (draft save, search clear, double-back-exit guard) still win via dispatcher priority (last-registered wins)
- ✅ BONUS: draft is now saved when leaving chat via the back BUTTON (previously only the ← arrow did) 
- ✅ BONUS: `--ez open_settings true` script hook now actually opens Settings (was only suppressing the SMS-role dialog), and `onNewIntent` honors `set_theme`/`open_settings` on warm starts too
- Test: `scripts/test-back-stack.sh` (8 checks, all passing); regression: `scripts/test-back-nav.sh` still green

File: `MainActivity.kt`, `scripts/test-back-stack.sh`

## Storage & first-launch fixes (2026-08-24)

- ✅ BUG: demo conversations seeded on devices with real SMS (seed ran whenever local table was empty, before system sync) — now seeds only when READ_SMS granted AND system provider empty; polluted installs are auto-purged on launch
- ✅ First launch now keeps skeleton loading until initial system-SMS import completes (`Repository.initialSyncDone` StateFlow), not a fixed 400 ms
- ✅ SmsReceiver incoming write-back hardened: checks RoleManager role in addition to getDefaultSmsPackage, logs failures instead of swallowing
- ✅ Verified storage guarantees: uninstall-safe (history re-imports from system provider), cross-app mirror both directions — test: `scripts/test-sms-mirror.sh` (all passing)
- ✅ Fixed `env.sh center_of_contains` bounds regex; `test-back-stack.sh` no longer depends on demo rows

File: `data/Repository.kt`, `data/DemoData.kt`, `sms/SmsReceiver.kt`, `ui/ConversationsScreen.kt`, `scripts/test-sms-mirror.sh`

## Initial-sync progress bar + OTP duplicate fix (2026-08-24)

- ✅ BUG: first launch showed no progress indication while system SMS imported in background — determinate `LinearProgressIndicator` ("Loading messages") now renders under the home header while `Repository.initialSyncProgress` (0..1, null=idle) is active; bar only appears when there is pending work, dismisses on completion
- ✅ BUG: same OTP message appeared twice after import — `SmsReceiver`/`writeSentToSystem` wrote to the system provider WITHOUT linking the returned `_ID`, so sync re-imported them whenever the SMSC timestamp skewed past the ±2 min match window; now provider row is inserted FIRST and its `_ID` is stored via `receiveMessage(..., sysId)` / linked back in `writeSentToSystem`
- ✅ Hardened legacy linker: matches `is_me` + nearest timestamp within ±24 h (was ±2 min, no sender filter)
- ✅ Sync runs serialized on a single-thread executor (overlapping onResume threads could double-import)
- ✅ DB v11: migration collapses rows sharing a `sys_id`, deletes unlinked local twins of already-linked messages, creates unique partial index `idx_messages_sys_id (sys_id>0)`; onOpen recreates the index if missing; inserts tolerate constraint races
- ✅ Verified: bulk-import bar render/dismissal (4k SMS), zero duplicate groups post-migration from fabricated v10 corruption (3 copies → 1), fresh OTP receive stores exactly 1 copy — test: `scripts/test-initial-sync.sh`

File: `data/Repository.kt`, `sms/SmsReceiver.kt`, `MainActivity.kt`, `ui/ConversationsScreen.kt`

## P4 · Auto-delete old messages

Settings option to auto-delete messages older than N days.

- Add setting in SettingsStore
- Cleanup logic on app launch or via WorkManager

File: `data/SettingsStore.kt`, `data/Repository.kt`

## P5 · Custom notification settings per-conversation

✅ DONE. `conversation_notifications` table (DB v9, ON DELETE CASCADE), Repository methods, toggle in ContactDetailsScreen + ChatScreen 3-dot menu, NotificationHelper checks before posting.

## F-Droid auto-sync (2026-08-26)

- ✅ `release.yml` now syncs the F-Droid metadata automatically: after the GitHub Release publishes, a `sync-fdroiddata` job clones `an1ndra/fdroiddata` (branch `com.anindra.messages`) with the `GITLAB_TOKEN` secret and rewrites versionName/versionCode/pinned commit/CurrentVersion(Code) in `metadata/com.anindra.messages.yml`, then pushes — updating fdroid MR !46632; no-op-safe on re-runs
- ✅ Removed the duplicate "Update fdroiddata MR" step + `update_fdroiddata` input from `fdroid-release.yml` (Release workflow is now the single owner; no push race)
- ✅ `fdroid-release.yml` deleted — one-click UI release-cutting dropped; releases are cut locally (bump + signed commit/tag push), `release.yml` handles everything after

## Contact picker truncation fix (2026-08-26)

- ✅ Issue #98: NewChatScreen hard-capped contacts at 200 (`out.size < 200`) with no truncation indicator; worse, the picker's search filter ran POST-truncation, so contacts beyond #200 were unfindable by name
- ✅ Removed the cap; `rememberContacts()` loads unbounded off the main thread via `produceState` + `Dispatchers.IO` (same pattern as contact photos in Components.kt); LazyColumn already virtualizes rendering
- ✅ Regression script seeds >200 uniquely-named ("ZzqNNN", sort-last) contacts via parallel content-provider workers, then asserts the LAST one appears when searched — test: `scripts/test-contacts-limit.sh`

File: `ui/NewChatScreen.kt`, `scripts/test-contacts-limit.sh`

## Archive swipe UNDO (2026-08-26)

- ✅ Issue #97: swipe-right archive fired silently while swipe-left delete showed an UNDO snackbar; also bottom-sheet "Archive" had zero feedback
- ✅ Added `archiveWithUndo()` (archive → "Conversation archived · Undo" snackbar → unarchive on tap), threaded as `onArchive` callback through `SwipeableConversationItem`/`SwipeConversationItem`; bottom-sheet Archive now routes through it too (chat 3-dot menu keeps its toast — no snackbar host in ChatScreen)
- ✅ Regression script swipes right on the topmost list row, asserts the snackbar + Undo action appear, taps Undo and asserts the row returns — test: `scripts/test-archive-undo.sh`

File: `ui/ConversationsScreen.kt`, `scripts/test-archive-undo.sh`

## Quick-reply receiver threading fix (2026-08-26)

- ✅ Issue #90 code fix: `QuickReplyReceiver` now uses `goAsync()` + `CoroutineScope(SupervisorJob() + Dispatchers.IO)` (ScheduledMessageSender pattern); DB write, SMS send and system-mirror all off the main thread with try/catch + `finish()` in `finally`; notification cancel moved after durable DB insert
- ✅ Regression script `scripts/test-quick-reply.sh`: clears shade → injects fresh SMS (app force-stopped = cold path) → opens notification → tries raw `motionevent DOWN/UP` on the Reply action → types reply → asserts the row lands in system Sent box (`content://sms/sent`) + crash buffer clean
- ⚠️ Automation limit (documented in script): systemui re-routes injected taps (`input tap`, swipe-hold, motionevent) from action buttons to the row body → auto-cancels instead of opening inline reply; script falls back to a MANUAL STEP prompt for that one tap, then resumes automated verification
- ✅ Verified end-to-end with manual shade tap: `autoreplyping90` landed in system Sent box, crash buffer clean — test: `scripts/test-quick-reply.sh`

File: `sms/QuickReplyReceiver.kt`, `scripts/test-quick-reply.sh`

## Chat list O(n²) fix (2026-08-26)

- ✅ Issue #94: `messages.indexOfFirst { it.id == msg.id }` ran inside the LazyColumn `items` lambda — O(n) per composed item, O(n²) per frame during scroll; replaced with `itemsIndexed(messages, key = { _, msg -> msg.id })` so the index comes from LazyListScope directly (zero lookups, zero allocations)
- ✅ Regression script opens a conversation, flings to top to assert the idx==0 "Today" divider renders (chat opens bottom-scrolled, so the first divider is lazily off-screen — assertion scrolls up first), plus asserts the last-own-message status line (`H:MM • SMS`) at the bottom — test: `scripts/test-chat-render.sh`

File: `ui/ChatScreen.kt`, `scripts/test-chat-render.sh`

## Critical/high batch fixes (2026-08-26)

- ✅ Issue #81 (critical): scheduled sends could lose text or leave ghost rows — `ScheduledMessageSender` now wraps the radio hand-off in its own try/catch: on throw, the stored message is marked `"failed"` (retriable "Not sent · Tap to retry") instead of staying `"sending"` forever; `deleteScheduledMessage` runs unconditionally once content is durably stored, so no zombie schedule entries can accumulate
- ✅ Issue #82 (high): `SmsReceiver.onReceive` did system-provider insert + local DB write + notification synchronously on the main thread with no goAsync — restructured to goAsync + `CoroutineScope(SupervisorJob() + Dispatchers.IO)` with processing in `processIncoming()` and finish in finally; multipart grouping and role checks unchanged
- ✅ Issue #85 (high): `ImageBubble` decoded full bitmaps inside `remember {}` on the main thread — now `produceState` + `withContext(Dispatchers.IO)` keyed on uri (same pattern as PersonAvatar); null-check moved to a local val for smart-cast
- ✅ Regression scripts: `test-scheduled-send.sh` (drives ScheduledMessageSender via root broadcast — receiver is exported=false so plain shell broadcasts are dropped; asserts message renders + mirrors to Sent box), plus existing `test-sms-mirror.sh` (incoming path) and `test-chat-render.sh` all PASS on emulator-5554
- ⚠️ Pre-existing stale script noticed: `test-p2-p3-p5.sh` P3 step expects `resource-id="row_N"` nodes that no longer exist in ChatScreen — broken before today's changes, needs a separate refresh

File: `sms/ScheduledMessageSender.kt`, `sms/SmsReceiver.kt`, `ui/ChatScreen.kt`, `scripts/test-scheduled-send.sh`

## Medium/low batch A fixes (2026-08-26)

- ✅ Issue #89: `ensureChannel()` moved above the `canPost()` early-return in both `show()` and `showSendFailed()` — notify() with an unknown channel is a silent no-op, so the channel must exist before any bail-out; verified with a pm-clear cold install + injected SMS (notification posts)
- ✅ Issue #83: `MessagesApplication.onCreate` no longer runs trash purge + system-SMS sync on the main thread — both launched in `CoroutineScope(SupervisorJob() + Dispatchers.IO)`; UI already gates on `initialSyncDone`
- ✅ Issue #95: file-level `private var hasLoadedOnce` replaced by a process-scoped field on `AppViewModel` (`vm.hasLoadedOnce`) — same skeleton-flash suppression semantics without module-wide mutable state
- ✅ Issues #84 + #100: Components.kt date helpers migrated to thread-safe `java.time` — shared `SimpleDateFormat` vals gone (DateTimeFormatter is immutable), `sameDay`/`isYesterday` now compare `LocalDate`s (zero Calendar allocations per row, DST-correct yesterday via `LocalDate.now(zone).minusDays(1)`); divider format hoisted to a named formatter
- ✅ Verified: build green; `test-chat-render.sh` PASS ("Today" divider via new java.time path), cold-start + incoming-notification probe PASS

File: `sms/SmsSupport.kt`, `MessagesApplication.kt`, `MainActivity.kt`, `ui/ConversationsScreen.kt`, `ui/Components.kt`

## Medium/low batch B fixes (2026-08-26)

- ✅ Issue #92: `NotificationHelper` used `from.hashCode()` for notification ids and QuickReplyReceiver's PendingIntent, so two senders sharing a hash could overwrite each other's notification; `showSendFailed()` also collided with incoming ids. Now uses `(convoId ?: from.hashCode().toLong()).toInt()` as the stable notifId; `QuickReplyReceiver` reads `EXTRA_NOTIF_ID` from the intent (with hashCode fallback for stale intents); `showSendFailed` posts under a `"failed"` tag to decouple from incoming ids
- ✅ Issue #93: `ChatScreen` stored the delayed-send `Job` in `mutableStateOf` — cancel and restart raced against Compose recomposition. Replaced with a counter-based `LaunchedEffect(sendAttempt)` that Compose cancels/rearms automatically on key change; no mutable `Job` state needed
- ✅ Verified: `test-delayed-send.sh` PASS (auto-send after 5s countdown, Cancel aborts with no Sent-box entry)

File: `sms/SmsSupport.kt`, `sms/QuickReplyReceiver.kt`, `ui/ChatScreen.kt`

## Medium/low batch C fixes (2026-08-26)

- ✅ Issue #88: `ContactDetailsScreen` had a "Search" `DetailActionButton` with `onClick = {}` — removed the button and its `Icons.Rounded.Search` import (hard rule #2: every visible control must do something real)
- ✅ Issue #96: `SettingsScreen` copied all settings into `remember` state at initial composition; external changes (e.g. `--es set_theme dark` deep link) never synced. `SettingsStore` now emits a `revision: StateFlow<Int>` that increments on every write; `SettingsScreen` collects it and re-keys each `remember(revision)` block so stale locals are replaced on recomposition
- ✅ Issue #99: `ChatScreen.kt` was 1341 lines with a ~640-line `ChatScreen` composable. Extracted three focused composables: `ChatTopBar` (top bar + 3-dot menu with SIM picker, archive, delete, block/unblock), `ChatMessageList` (LazyColumn with message rows, retry, forward, lock/unlock), `ChatSchedulePicker` (date + time picker flow). `ChatScreen` now delegates to these composables, reducing inline logic and improving maintainability

File: `ui/ContactDetailsScreen.kt`, `data/SettingsStore.kt`, `ui/SettingsScreen.kt`, `ui/ChatScreen.kt`

## Performance batch D fixes (2026-08-26)

- ✅ Issue #111: `ChatScreen` created a new `Executors.newSingleThreadExecutor()` on every recomposition. Wrapped in `remember { }` so the executor survives recomposition
- ✅ Issue #110: `ConversationsScreen` computed `displayed = conversations.filter { ... }` on every recomposition, allocating a new List each time. Wrapped in `remember(conversations, showArchived, query)` to avoid unnecessary allocations
- ✅ Issue #103: `ImageBubble` called `BitmapFactory.decodeStream` without `inSampleSize`, causing OOM on large photos. Added two-pass decode: bounds first with `inJustDecodeBounds=true`, then downsampled decode
- ✅ Issue #109: Already fixed — `PersonAvatar` uses `produceState` + `Dispatchers.IO`
- ✅ Issue #107: `AppViewModel.conversationById()` filtered the full conversation list on every DB change. Added `Repository.conversationByIdFlow()` with a direct `SELECT ... WHERE id=?` query
- ✅ Issue #104+#105: `refreshContactNames()` and `syncFromSystem()` ran unconditionally on every `onResume()`. Added 5-minute throttle via `lastResumeTime` timestamp in `MainActivity`
- ✅ Issue #108: `notifyChanged()` was called per-write during sync. `syncFromSystem()` already batches the single call at end; the real fix was #104/#105 throttle reducing resume-time calls
- ✅ Issue #114: `ImageBubble` and `PersonAvatar` decoded bitmaps from disk on every recomposition/scroll with zero caching. Added singleton `BitmapCache` (`LruCache`, 50 entries) in `Components.kt`; both composables now check cache before disk decode and store decoded bitmaps after
- ✅ Issue #112: `syncFromSystem()` performed individual INSERT/UPDATE per message without explicit SQLite transaction (each auto-commits = fsync per statement). Wrapped the entire sync loop in `beginTransaction()`/`setTransactionSuccessful()`/`endTransaction()`. Reduces ~20,000 fsyncs to 1 for 10k messages — expected 10-100x faster initial sync
- ✅ Issue #120: `biometricExecutor` created via `remember{}` in ChatScreen but never shut down — each chat visit leaked a thread. Added `DisposableEffect(Unit) { onDispose { biometricExecutor.shutdown() } }` so threads are reclaimed when ChatScreen leaves composition
- ✅ Issue #116: `notifyChanged()` fired on every DB write (23 call sites), each re-querying the full conversations table. Added 100ms debounce via HandlerThread — rapid successive writes (send+receive+markRead) coalesce into a single re-query, eliminating UI flicker and redundant table scans
- ✅ Issue #115: `loadContactPhoto()` decoded full-resolution bitmaps (~48MB for 4000x3000 photos) for 48dp avatars. Added two-pass decode with `inSampleSize` targeting 144px, reducing memory to ~65KB per photo
- ✅ Issue #113: `MessageRow` received full `unlockedIds: Set<Long>` — unlocking one message created a new Set causing ALL rows to recompose. Replaced with `isUnlocked: Boolean` computed per-message in `ChatMessageList`, so only the affected row recomposes
- ✅ Bugfix: `ChatTopBar` guarded block/unblock menu with `SettingsStore::blockingEnabled.javaClass != null` (always true). Replaced with proper `blockingEnabled: Boolean` parameter

File: `ui/ChatScreen.kt`, `ui/ConversationsScreen.kt`, `data/Repository.kt`, `MainActivity.kt`, `ui/Components.kt`

## Security hardening (2026-08-27)

- ✅ Issue #129: `allowBackup="false"` in AndroidManifest to prevent unencrypted ADB backups
- ✅ Issue #130: All notification builders use `VISIBILITY_PRIVATE` — no message content in lock screen
- ✅ Issue #131: Biometric bypass fixed — `canAuth` checked on app resume, not just first launch
- ✅ Issue #132: All PendingIntents use `FLAG_IMMUTABLE` — prevents mutation attacks
- ✅ Issue #133: Clipboard auto-clear after 60s in ChatScreen
- ✅ Issue #134: Phone number masked in failure notification when privacy mode is on
- ✅ Issue #135: URL validation — non-http/https schemes rejected in link tap handler
- ✅ Issue #136: Scheduled message input validation — phone number format + empty body check
- ✅ Issue #137: Debug log statements removed from SmsReceiver and SmsSupport
- ✅ Issue #139: Encrypted backup with Android Keystore AES-256-GCM (`BackupCrypto.kt`)
- ✅ Issue #141: Biometric prompt required to unlock individual messages in ChatScreen
- ✅ Issue #142: Thread safety — `dbExecutor` single-threaded executor for all DB writes in Repository
- ✅ Issue #145: Removed unused `NoConfirmationSmsSendService` stub from manifest

File: `AndroidManifest.xml`, `sms/SmsSupport.kt`, `MainActivity.kt`, `ui/ChatScreen.kt`, `sms/SmsReceiver.kt`, `data/Repository.kt`, `data/BackupCrypto.kt`

## Stability bug fixes (2026-08-27)

- ✅ Issue #146: `importDatabase()` crashed on corrupted/non-SQLite files — rewrote with `ImportResult` sealed class, pre-validation via `isValidSqliteFile()` (checks magic header), backup-before-swap, `db` changed from `val` to `var` for safe reinit
- ✅ Issue #147: Closed as `not_planned` — `SmsReceiver` already uses `goAsync()` + `Dispatchers.IO`
- ✅ Issue #148: `conversationByIdSuspend()` ran DB query on Main thread — wrapped in `dbExecutor.submit` + `CompletableFuture.get()` to dispatch to background thread
- ✅ Issue #149: `messageCount` called as direct DB query inside Composable — added `messageCountFlow()` using existing `observe` pattern; `ChatScreen` now uses `collectAsState` with sync fallback
- ✅ Issue #150: `importDatabase()` failure silently swallowed — `ImportResult.Error` carries specific message; `SettingsScreen` shows "Import failed: {message}" toast

File: `MainActivity.kt`, `data/Repository.kt`, `ui/ChatScreen.kt`, `ui/SettingsScreen.kt`

## Settings toggles: SIM indicator + send/receive sounds (2026-08-27)

- ✅ Split single "Message sounds" toggle into separate "Send sound" and "Receive sound" toggles in SettingsStore + SettingsScreen
- ✅ Added "SIM indicator" toggle in Settings → Appearance section — when off, SIM label hidden from chat bubbles
- ✅ Wired `showSimIndicator` setting through `ChatMessageList` → `MessageRow` in ChatScreen
- ✅ Wired `sendSoundEnabled`/`receiveSoundEnabled` into `SmsSupport.playSound()`

File: `data/SettingsStore.kt`, `ui/SettingsScreen.kt`, `ui/ChatScreen.kt`, `sms/SmsSupport.kt`

## Deferred

- ✅ Issue #106: Implemented simple LIMIT200 pagination. `Repository.messages()` now accepts `limit`/`offset` params (default `Int.MAX_VALUE`/0 for backward compat). Added `messageCount()`. `ChatScreen` maintains `pageLimit` state starting at200; "Load earlier messages" button at top of chat list increases limit by200. No new dependencies.

## Progressive chat loading + visible conversations loading (2026-08-30)

- ✅ Chat screen no longer loads every message at once: latest 40 render first with a 3-row shimmer skeleton, then 40 more load automatically as you scroll (capped at 400), then a "Load earlier messages" button appears for older history (`INITIAL_CHUNK`/`AUTO_CHUNK`/`AUTO_CAP`/`LOAD_EARLIER_STEP` in ChatScreen). Flows re-keyed on `remember(conversationId[, pageLimit])` because Compose `collectAsState` keys on the flow instance (verified in bytecode).
- ✅ Conversations screen keeps the skeleton + determinate "Loading messages" bar up for the WHOLE system import on a first/empty-DB launch (`loaded = minSkeletonShown && syncDone`, removed the premature `|| listArrived` escape hatch that let an empty first DB emission skip the loading UI). Warm starts skip it because `initialSyncDone` seeds from `firstImportDone`.
- ✅ When the inbox is empty because SMS access is missing (or was denied), the screen shows an "Allow SMS access" panel instead of a blank list — buttons: **Allow access** (request READ_SMS, then re-import), **Retry loading** (`Repository.requeryFromSystem()` resets `initialSyncDone` so skeleton/bar show again), **Open app settings**. Permitted state re-checked via a `LifecycleEventObserver`.
- ✅ `vm.conversations` remembered (`remember(vm)`) so the DB flow isn't recreated per recomposition.
- Note: READ_SMS is auto-granted (`GRANTED_BY_ROLE`) to the default SMS handler, overriding `pm revoke` — panel only manifests on first-run denial before the role is granted.

File: `ui/ConversationsScreen.kt`, `ui/ChatScreen.kt`, `data/Repository.kt`, `MainActivity.kt` · test: `scripts/test-loading-screen.sh`

## Merge import option (2026-09-06)

- ✅ Import is a SINGLE "Import messages" row that opens a dialog with two modes: "Merge with existing messages" (default, keeps current data + adds backup's missing messages/contacts, deduped, trash-lift, live refresh) and "Restore (replace all)" (explicit, destructive — file-swap replace + restart). No separate restore row
- ✅ Restored messages are marked UNREAD: every incoming (is_me=0) message added by a merge bumps its conversation's `unread_count` (mirrors a live receive), so restored conversations show an unread badge after import
- ✅ `Repository.importDatabase(context, uri, pin, mode)` has `mode: ImportMode = REPLACE`; `ImportResult.Success` carries an optional `merged` count (number of messages added), surfaced as "Restored N messages" toast
- ✅ `mergeDatabase()` (in-place, no file swap, no restart needed): matches conversations by `address`, lifts trash on backup-imported conversations (`deleted_at=0`), inserts messages deduped by (conversation, timestamp, is_me, body) + unique `sys_id>0` guarded, refreshes the newest-preview only when merged rows are newer, merges `blocked_numbers` (INSERT OR IGNORE) and per-conversation notification toggles for newly added conversations — all atomic in one transaction
- ✅ Wired `mode` through `AppViewModel.importDatabase` and the SettingsScreen import UI + PIN flow; merge emits `notifyChanged()` so the home list refreshes live (only replace needs the restart)
- ✅ Merge SQL validated against real SQLite dumps (dedupe, trash-lift, preview guard, blocked/notif merge); JUnit-only project (no Robolectric), full UI drive deferred to emulator — test: `scripts/test-merge-import.sh` (injects NUM_A + NUM_B, imports the newest .enc via Merge, asserts BOTH survive without restart)
- ✅ Import now shows a blocking M3 "Loading messages" dialog (`CircularProgressIndicator` + live "N messages loaded") while a backup applies — MERGE reports rows written so far (throttle-free, per-row `onProgress` marshalled to the main thread), REPLACE reports the backup's total message count before the atomic file swap; dialog is un-dismissable and always closes (VM catches repo throws). Test: `scripts/test-import-loading.sh` — generates a 10 000-message PIN backup on the host (Python + cryptography, exact BackupCrypto format), merges into a cleared app, verifies the dialog appears with an INCREASING count (observed 1894/10000 mid-import) and the 20 conversations land on the home list
- ✅ Test-script hardening: merge-import test matches conversations by last-message preview (number formatting is locale-dependent), force-stops for a clean home landing in Step 0, and navigate Back to the list in Step 4 (merge refreshes in place — no restart)

File: `data/Repository.kt`, `MainActivity.kt`, `ui/SettingsScreen.kt`, `scripts/test-merge-import.sh`, `scripts/test-import-loading.sh`

## Settings toggles apply LIVE (no restart) — Drafts / Pinned / Swipe actions (2026-09-06)

- ✅ USER REPORT: toggling Settings switches (Drafts, Pinned conversations, Swipe actions) did nothing until the app was restarted. Root cause: `ConversationsScreen` keyed `rowSettings` on the `vm.settings` singleton (`remember(vm.settings)`), so row-level settings froze at first composition; the swipe-key in `remember(conversations, showArchived, query)` similarly ignored settings changes.
- ✅ Fix: `val settingsRevision by vm.settings.revision.collectAsState()` (SettingsStore's `_revision` StateFlow; every setter bumps it) drives `remember(settingsRevision)` for `RowSettings`, which now also carries `swipeEnabled`. Items use `rowSettings.swipeEnabled && !showArchived`. Drafts gating in `ChatScreen` and the pinned-unpin revert in `SettingsScreen` already used `remember(settingsRevision)`.
- ✅ Verified LIVE on emulator (no restart between toggles): Drafts toggle ON/OFF immediately shows/hides `Draft:` previews; Pinned OFF removes the pin-row from the long-press sheet; Swipe actions ON → full 900ms swipe trashes a row with UNDO, OFF → identical gesture does NOT trash (row shows as a long-press instead — emulator injected swipes are read as long-presses). All toggles restored to ON after testing; unit tests + `assembleDebug` pass.

File: `ui/ConversationsScreen.kt`, `data/SettingsStore.kt`, `ui/ChatScreen.kt`, `ui/SettingsScreen.kt` · test: `scripts/test-settings-live.sh`

## Incoming-SMS notification silently dropped / never posted (2026-09-05)

- ✅ BUG: with the app as default SMS handler, injected inbound SMS stored to the DB but NO system notification ever appeared — on the emulator (API 35) AND the vivo (API 36)
- ✅ ROOT CAUSE #1 (SmsReceiver.kt:84): the foreground guard was INVERTED — `if (!appInForeground || isConversationOpen(...)) continue` skipped the notification pipeline whenever the app was NOT in the foreground (i.e. always — the normal background case). Corrected to `if (appInForeground && isConversationOpen(...)) continue`
- ✅ ROOT CAUSE #2 (SmsSupport.kt): the reply action's PendingIntent used `FLAG_IMMUTABLE`. On Android 15+ a RemoteInput reply action backed by an IMMUTABLE PendingIntent is SILENTLY dropped by NotificationManagerService — `numEnqueuedByApp` increments in `dumpsys notification` usage-stats but `numPostedByApp` stays 0, no logged reason. The system must inject the reply text into the intent, so it must be MUTABLE (matches Quik/QKSMS: `FLAG_UPDATE_CURRENT or FLAG_MUTABLE`). Bisected on emulator: minimal notif posts → +RemoteInput drops → +icon unchanged (drops) → +`FLAG_MUTABLE` + `setSemanticAction(SEMANTIC_ACTION_REPLY)` posts
- ✅ Also added `setSemanticAction(SEMANTIC_ACTION_REPLY)` and a real action icon (`ic_reply`) to match the canonical Google Messages / Quik form (hard rule #2 — toolbar action no longer icon=0)
- ✅ Restored full production notification (BigTextStyle + custom channel sound) on top of the fix; verified cold AND warm-background paths both post with Reply action wired + sound present (`mSound=android.resource://...`)
- Resume-point: verify on the real vivo later (needs a release build signed with the vivo keystore `223e351c`, PM will replace the 1.0.14 build) — test: `scripts/test-notification-posts.sh`

File: `sms/SmsReceiver.kt`, `sms/SmsSupport.kt`, `res/drawable/ic_reply.xml`

## Release v1.0.21 (2026-09-06)

- ✅ Cut v1.0.21 at `7512e5a` (settings-live toggles fix + merge-import polish): versionCode 24, versionName "1.0.21"; tagged `v1.0.21`; pushed to `origin/main` — GitHub `release.yml` handles the release build (keystore from secrets), security gate, GitHub Release publish, and fdroiddata MR sync.
- ✅ Build green locally (`assembleDebug`) before tagging.

## Regression guardrails

After any task: run `scripts/run-all-tests.sh`, eyeball screenshots
(01-home, 04-sent, 11-settings, 15-theme-dark), ensure build green, no new
permissions beyond listed in AGENTS.md, and zero dead controls introduced.
