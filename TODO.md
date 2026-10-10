# TODO

> Moved from the Messages app repo (2026-09-13). This is the project's
> task/tracking history — issues, verification notes, and the regression
> scripts that test them (all in this repo). Hand this file + `AGENTS.md`
> (same folder) to any AI agent working on the scripts.

## Picking someone opens them, not a group (2026-10-10)

Tapping "Alex" in the new-chat list opened the **Roadtrip** group. A group
carries its primary contact's address, so when the person has no private
thread of their own there was nothing better to return.

`ORDER BY (SELECT count(*) FROM conversation_recipients ...)=1 DESC` sorts
groups *last*, but `LIMIT 1` still takes one when there is nothing else —
ordering was never going to fix this. The picker now passes
`privateOnly = true`, which excludes groups from the query outright and
creates a fresh 1:1 instead.

Inbound deliberately keeps the looser rule: a text from a group member who
has no 1:1 of their own belongs in the group.

Tests: `NewChatSkipsGroupTest` (4) and `test-new-chat-skips-group.sh`
(9/0 after, 6/3 with `privateOnly` removed).

## A group is listed by its own name (2026-10-10)

The home list filed "Sarah + Dad" under "Sarah". A group's `address` is its
primary contact's, so the ordinary "known contact shows their name" rule
picked the wrong name — and the label a screen reader announced for the row
had it too.

The legacy list had the group branch and the redesigned one never did, which
is why only the redesigned UI showed it. The rule now lives once, in
`ContactDetails.listLabel`, and both lists call it; the visible title in each
was a third copy of it and now reuses the same `senderLabel` the row is
announced with, so the two cannot disagree.

Tests: `ContactDetailsListLabelTest` (5) and
`test-conversation-list-group-title.sh` (4/0 under either UI flag, and 3/1
with the redesigned list's group branch removed — which reproduces the
reported symptom exactly).

## One contact-details page (2026-10-10)

The contact page existed twice — `ui/ContactDetailsScreen.kt` and
`ui/legacy/LegacyContactDetailsScreen.kt` — and `use_new_ui` picked between
them, so anything fixed in one stayed broken in the other. The legacy page is
deleted; the redesigned one carries its behaviour and both flag values render
the same page.

Kept from the legacy page, because it was the better one:
  - the group name is edited in place, pencil below the name, caret at the end
  - a group shows no Call/Info, no number under the name, and no Block row
  - the notifications switch uses the brand thumb/track colours

Regained from the redesigned page: the hoisted `scrollState`, so returning to
the page keeps its position.

Tests: `ContactDetailsWiringTest` (12) and `test-contact-details-single-page.sh`,
which asserts the page renders the same with `use_new_ui` off and on.

Two things this uncovered, still open:
- **The redesigned conversation list still titles a group by its primary
  contact**, so a "Sarah + Dad" thread reads as "Sarah" in the home list. The
  legacy list prefers `groupTitle`; the redesigned one does not. The regression
  script finds the group row by a snippet marker because of this.
- `use_new_ui` still forks the conversations, settings, advanced and
  accessibility screens. Those are four more pages to merge, the same way.

## MMS observability (2026-10-10)

The `:mms` stack reported nothing: every `MmsDiagnostics` callback is a no-op
by default and `MmsFacade` built the stack without a recorder, so "nothing
arrived" and "nothing was reported" were indistinguishable. MMS debugging now
has one surface, and it is plain text.

| Change | Where |
|---|---|
| `MmsDebugRecorder` wired in as the process-wide diagnostics | `sms/MmsFacade.kt` |
| New events: fit outcome, download request/completion, pending sweep, logged lines | `mms/spi/MmsDiagnostics.kt` |
| Logcat mirror under tag `MmsTrace` | `mms/debug/LogcatMmsDiagnostics.kt` (new) |
| `MmsTrace` — the one logging call MMS code uses | `sms/MmsTrace.kt` (new) |
| All 29 `Log.` calls in the 5 MMS files routed through it | `MmsDownloader`, `SmsSupport`, `MmsComposer`, `SmsStatusReceiver`, `MmsReceiver` |
| MMS provider import traces offered/imported/already-present counts | `data/Repository.kt` |
| Download result now carries the HTTP status (Phase A) | `MmsDownloadReceiver` -> `MmsDownloader.onComplete` |
| "MMS activity" block in the report | `diagnostics/DiagnosticsReport.kt` |
| Carrier facts + derived `imageLimitsReported` | `sms/SimMmsProbe.carrierFacts` |

The `MmsImport` counts are the duplicate-picture evidence: "offered" growing
while "already present" does not is exactly what an unlinked outbox row looks
like.

Tests: `test-mms-diagnostics.sh` (8 checks) plus JUnit in
`mms/.../MmsDebugRecorderTest`, `LogcatMmsDiagnosticsTest` and
`app/.../MmsDiagnosticsWiringTest`.

The "no bare `Log.` in MMS files" guard lives in the script, not in JUnit: the
test JVM's `File.exists()` disagreed with the directory listing and the shell
for `SmsSupport.kt` in this environment, so asserting on file contents from a
unit test is not reliable here.

Still to do: Phase B (blurry picture in `:mms`, `imageLimitsReported` +
size x quality ladder), then the `:mms` send migration.

## MMS send path moved to the :mms package (2026-10-10)

Sending no longer goes through `MmsComposer` on the vendored AOSP stack. The
whole vendored module is gone: `android-smsmms`, its gradle include, its five
ProGuard keep rules, the CodeQL `paths-ignore`, plus `MmsComposer`,
`MmsImageSizing` (+test) and `ComposerParserInteropTest`.

| Change | Where |
|---|---|
| `MmsSender` reads the attachment and calls `Mms.send` | `sms/MmsSender.kt` (new) |
| `MmsPendingSends` maps `tr_id` -> app message id on disk | `sms/MmsPendingSends.kt` (new) |
| `sendMms` delegates (60 lines of PendingIntent/overrides gone) | `sms/SmsSupport.kt` |
| Receiver answers `SEND_SENT`, settles by `tr_id` | `sms/SmsStatusReceiver.kt` |
| `linkMmsRow` records the provider row **and** the mapping table | `data/Repository.kt` |
| `platformSource` resolves the default SIM | `mms/net/CarrierProfile.kt` |
| `FileProviderWiringTest` rewritten for the new wiring | `app/src/test/...` |

Two things the bundle did not have and this repo needed:

- `linkMmsRow` also writes `message_provider_ids`. Chat deletion and import
  dedupe read that table here, so a link that only filled `messages.sys_id`
  would fix the duplicate on screen and then let the provider row come back as
  a fresh 1:1 once the chat was deleted.
- `platformSource` resolved no subscription at all for `-1`, and `Mms` calls it
  directly for report headers, so a send on the default SIM silently lost its
  delivery/read report headers.

**Two real bugs found by the new observability, both fixed:**

1. `MmsFacade.of(context, diagnostics)` compiled fine while still passing the
   facade's own recorder to the stack, so the caller's hook was silently
   dropped - the outbox link never fired and the picture would still have
   appeared twice. `test-mms-send.sh` caught it.
2. The forwarding hook added to keep both records only overrode five of the
   fourteen `MmsDiagnostics` callbacks, so `attachmentFitted` went back to being
   a no-op and the encode decision vanished from the trace. Every method is now
   forwarded, and a test pins the full set.

Tests: `test-mms-send-path.sh` (11 checks), `test-mms-send.sh` (10, real send
through the probe on the AVD), `MmsSenderTest`, `MmsSendResultWiringTest`.

**Not verified here:** a send on a real carrier. The AVD answers every send with
code 12, so receipt, delivery reports and the group-MMS semantic change (one
PDU to all recipients, rejected when the profile says group MMS is off) still
need a SIM.

## MMS: carrier refusals, live update, and a reason for a rejected PDU (2026-10-10)

Second round, from a device report. Receiving works from one sending app but
not another, so the difference is in how the *sending* client encoded the
message, not a carrier quirk.

| Change | Where |
|---|---|
| `PduParser.failureReason` names the rule that refused a PDU | `pdu/PduParser.kt` |
| Retrieve-Status is checked before a container is demanded, so a refusal parses | `pdu/PduParser.kt` |
| A refusal, or an unreadable PDU under 512 bytes, drops the announcement | `sms/MmsDownloader.kt` |
| `importDownloadedMms` calls `notifyChanged()` | `data/Repository.kt` |
| The send result line carries `httpStatus=` | `sms/SmsStatusReceiver.kt` |

**The unreadable 187 KB PDU is still unexplained.** `failureReason` exists so
the next report says which check refused it; until that line is seen, the
cross-app receiving failure is not fixed. The author's `parseContentDisposition
= false` retry was deliberately **not** taken — it is a guess, and shipping a
guess as a fix is how the real cause gets missed. It is two lines once the
logged reason points at that field.

Changes 2 and 3 fix dead announcements being re-requested on every launch
forever, which is real and explains the three old 56-byte rows looping. They
do not explain the 187 KB PDU, and the report says so.

**Also fixed: `test-mms-retry.sh` leaked its rows.** `seed_pending` was called
in a command substitution, so the `CREATED` it appended to was discarded with
the subshell and cleanup deleted nothing. The rows stayed pending, so every
later launch re-requested all of them, which filled the Diagnostics event ring
and made `test-mms-diagnostics.sh` report "recorder or report wiring is
broken" on a perfectly healthy build. Tracked in a file now; a run leaves zero
rows behind.

Tests: `aCarrierRefusalWithNoMessageContainerStillParses`,
`aRejectedPduRecordsWhichRuleRefusedIt`,
`aParsedPduClearsAPreviouslyRecordedFailure` (all fail without the change);
`test-mms-send.sh` gained the `httpStatus=` check (fails without it);
`test-mms-pdu.sh` now runs the `transport` package too.

**Not verified here:** anything needing a real MMSC. The refusal path, the
187 KB PDU and the retry budget all need a SIM; the AVD answers every download
with an I/O error, so those branches are covered by JUnit only.

**Still to do:** the picture fitter still caps dimensions from
`SmsManager.getCarrierConfigValues()`, which reports the AOSP defaults when the
carrier sets nothing. Wiring `Mms.receive` to the receiver would retire
`MmsDownloader`'s own announce/store path and answer the carrier at the same
time.

## MMS send and receive actually reach the MMSC (2026-10-10)

An incoming MMS was never stored and every download failed with code 5; a send
failed with code 4. Three separate causes, none of them the picture size the
report blamed it on (the PDU was 37 KB).

| Change | Where |
|---|---|
| WAP push is parsed and stored instead of relying on a platform-filed row | `sms/MmsReceiver.kt`, `sms/MmsDownloader.kt` |
| Download destination is a staging file, not a `content://mms/<id>` row | `sms/MmsStaging.kt` (new), `sms/MmsDownloader.kt` |
| `AnnouncementRows` refuses rather than naming a row the platform cannot write | `sms/MmsFacade.kt` |
| One grant decision for both platform destinations | `mms/transport/PlatformMmsAccess.kt` (new) |
| Phone recipients go out as `number/TYPE=PLMN`, stripped again on read | `pdu/EncodedStringValue.kt`, `PduComposer.kt`, `PduParser.kt` |
| `From` is the insert-address token unless the device can name that line | `sms/MmsFacade.kt` |
| Retrieved message keeps the subscription it was announced under | `data/MmsSupport.kt`, `data/MmsProviderReader.kt` |

**The notification is still never acknowledged.** The dedupe on Content-Location
stops a repeat push being stored twice, but a carrier given no
M-NotifyResp.ind keeps re-delivering, and on a permanently-failed row the
sweep keeps asking for a URL that 404s. `Mms.receive` answers on every branch;
nothing calls it yet, and this change did not wire it up.

**`AnnouncementRows` now refuses on purpose.** Pointing the `:mms` path at a
staging file needs a read-back too — `receive` returns `AWAITING_PLATFORM` and
nothing in `:mms` reads the file back. A refusal defers, which `receive`
already handles; pointing it at a file that nobody reads would store nothing at
all, which is harder to diagnose than the code 5 it replaces.

Tests: `test-mms-download.sh` gained 2 checks (the destination is a staging
file, and no staging file is left behind); `AddressTypeTest` (5) and
`PduComposerTest` pinned against the new 115-octet send request;
`FileProviderWiringTest`/`MmsFacadeWiringTest` inverted onto "no provider row
as a destination", verified failing against the old build.

**Pre-existing failures, not from this change** (each confirmed by rebuilding
unmodified `HEAD` and re-running): `test-mms-support-check.sh` (3) and
`test-alphanumeric-sender.sh` (1).

**Still to do:** the picture fitter still caps dimensions from
`SmsManager.getCarrierConfigValues()`, which reports the AOSP defaults when the
carrier sets nothing — so a 1.2 MB source becomes 231x480 in a 288 KB budget.
Start from a 2048 px long edge and step down with the quality ladder instead.
Wiring `Mms.receive` to the receiver would retire `MmsDownloader`'s own
announce/store path and answer the carrier at the same time.

## F-Droid screenshots trimmed to 8 feature shots (2026-10-09)

`take-fdroid-screenshots.sh` captured 15 shots (12 light + 3 dark) and the
README mirrored 8 of them. The set is now **8 light-mode shots**, each on a
named feature, and the README mirrors all 8:

| # | Shot | Screen |
|---|---|---|
| 01 | `01-home.png` | Conversation list |
| 02 | `02-settings.png` | Settings |
| 03 | `03-chat.png` | Chat thread (Dad) |
| 04 | `04-contact.png` | Contact details |
| 05 | `05-reaction.png` | Long-press reaction picker |
| 06 | `06-typing.png` | Composer with a draft |
| 07 | `07-sim-switcher.png` | Chat menu with fake dual-SIM rows |
| 08 | `08-new-chat.png` | New conversation / contact picker |

- The script empties `fastlane/.../phoneScreenshots` first, so the 15 old files
  are gone and only the 8 remain.
- Two matcher fixes were needed: `verify`/`verify_any` now read the decoded dump
  (`ui.decoded.xml`), because uiautomator escapes 👍 as `&#128077;` and the
  literal never matched; the typed draft had a transposed word ("On smy way").
- `README.md` now points at the 8 files, in two 4-up rows.
- Data comes from `insert-demo-contacts.sh` + `seed-demo-conversations.sh`
  (dummy contacts). Run passes 8/8 checks on `emulator-5554`.

## #304 App not shown in share intents from other apps (2026-10-09)

| Issue | Feature | JUnit | Regression script |
|---|---|---|---|
| #304 | App appears in SMS/text/image share sheets; accepts shared body/image; tapping an image opens a full-screen preview | `ManifestShareIntentFilterTest`, `ImagePreviewWiringTest` | `test-share-intent-filters.sh` |

Other apps (bank payment receipts, share-to-SMS) could not hand a message to us
because `MainActivity` only declared `SENDTO` for the `smsto:` scheme and had no
`ACTION_SEND` filter at all.

- **Manifest** now declares `SENDTO` for `sms`, `smsto`, `mms`, `mmsto` and a
  separate `ACTION_SEND` filter for `text/plain`, so the platform offers the app
  in both URI-based and MIME-based share sheets.
- **Intent handling** extracts the shared body from the `?body=` query on an
  SMS URI or from `Intent.EXTRA_TEXT` on an `ACTION_SEND`, then pre-fills the
  chat composer. A `SENDTO` with a recipient opens that chat directly; an
  `ACTION_SEND` without a recipient opens the New Chat picker and carries the
  body through once a contact is chosen.
- `ChatScreen` gained `initialDraft` + `onInitialDraftConsumed` so the shared
  text is applied once and consumed, preventing it from leaking into later chats.
- Verified to **FAIL** on the unfixed build (`1 passed, 4 failed` — `SENDTO sms`,
  `ACTION_SEND text/plain`, and both UI paths missing) and **PASS** with the fix
  (`5 passed, 0 failed`).

### Follow-up: image sharing (same issue)

The reporter came back with "on image share I can't see our message app". The
text fix had added `ACTION_SEND` for `text/plain` only, so a photo's share sheet
— which sends `image/*` — still did not offer the app at all. Fixing the text
case alone left the more common share path broken.

- `ACTION_SEND` now also answers for `image/*`, and a new
  `ACTION_SEND_MULTIPLE` filter covers a multi-photo selection (Gallery shares
  those as a list, which `EXTRA_STREAM` as a single Uri would miss).
- `sharedMediaFromIntent` reads `EXTRA_STREAM` in both its single-Uri
  (`ACTION_SEND`) and list (`ACTION_SEND_MULTIPLE`) forms, falling back to
  `clipData` for senders that use that instead.
- **The incoming URI is copied into the app's cache before anything else.** The
  grant a share intent carries is scoped to the *task*, so it dies with the
  activity — and the share flow necessarily outlives it, because the user still
  has to pick a recipient. Reading the caller's URI at send time would fail
  intermittently with no obvious cause. The copy is what travels on, which the
  script asserts via the stored `media_uri` containing `/shared/`. The copy also
  keeps a file extension, so the URI still resolves to a MIME type (see below).
- Shared text accompanying a shared image is that image's caption, not a second
  message, so it is sent with the MMS (`sendMediaMessage` gained a `caption`
  parameter) and never also left sitting in the composer. Text and media are
  read from one `LaunchedEffect` so the two cannot disagree about which case
  they are.
- Tests: `ManifestShareIntentFilterTest` +2 (`image/*` under `SEND`,
  `image/*` under `SEND_MULTIPLE`).
- Regression: `test-share-intent-filters.sh` extended with the two filter
  queries, the recipientless-image picker check, and an end-to-end send
  asserted from the database *and* from the rendered bubble. Verified the honest
  way — removing only the two image filters, rebuilding and reinstalling — it
  reports **5 passed, 4 failed**; restored, **12 passed, 0 failed**. The
  extension assertion was likewise confirmed by reverting just
  `sharedExtension()` in place (**11 passed, 1 failed**). Final state is
  **14 passed, 0 failed**.

  Two traps here, both paid for in a debugging round:

  1. **The delivered status is not observable here.** The carrier config has no
     MMS keys, so every send is answered with code 12 and the row lands as
     `failed`. Asserting delivery status would be a permanent false failure;
     the stored row is the signal. This is the same trap as `test-mms-send.sh`.
  2. **`tap_text "Send to"` never matches.** The New Chat row label is
     `Send to “<number>”` with curly quotes, so an exact-text match misses and
     `center_of_contains` chokes on the quote bytes. The script parses the node
     and taps the enclosing bounds itself.
  3. **A hand-rolled test JPEG is not an image test.** The first fixture was a
     few hand-written bytes ending in an FFD9 marker. Coil could not decode it,
     so the bubble was empty — which read exactly like the extension bug below
     and cost a wrong diagnosis. The fixture is now a real 400x400 PNG encoded
     with `zlib`/`struct` at generation time. A tiny-but-valid image would fail
     the same way: below the bubble's practical size the node never appears.

### The cached copy kept no file extension

Independently of the above, the cache copy was named `share-<ts>-<rand>` with no
extension. `FileProvider` derives a MIME type from the file name, so the stored
URI resolved to no type at all. Coil happened to sniff the bytes and still
render, so this is **not** what made the bubble look empty — but it left the
MMS part's MIME to be guessed downstream rather than declared, which is exactly
the kind of thing that bites on a codec that does not sniff.

`sharedExtension()` takes the extension from the source URI's own path segment
where it is a plausible one, and otherwise from the resolved MIME type
(png/webp/heic/gif, defaulting to `.jpg` as the app already does for an untyped
attachment). The script asserts the stored `media_uri` ends in a real image
extension, which fails against the extensionless name.

### Tapping an image did nothing at all

Third round on the same thread: the image arrived and rendered, but tapping it
did nothing. The image branch of `ChatBubble` wired its `combinedClickable`
`onClick` to the bubble's generic `onTap`, which toggles *link reveal* — a
mechanism an image has no part in, since there is no URL to hide. The tap ran,
changed a state list nothing read, and appeared to do nothing.

- The image branch now routes its tap to a new `onImageTap(msg.mediaUri)`.
  Selection still wins over the preview while the selection toolbar is up,
  otherwise a tap meant to mark a message would open a full-screen view instead.
- New `ImagePreview`: the bubble crops to `ContentScale.Crop` inside a
  260dp cap, so anything legible in the original is illegible there. The
  preview is `ContentScale.Fit` on an opaque backdrop with one close control —
  no zoom, no chrome, because the only question it answers is "what is in this
  picture". Back, the close button, and a tap on the backdrop all dismiss.
  The image swallows its own tap so only the backdrop closes it.
- The `BackHandler` that dismisses the preview is registered **before**
  `leaveChat`'s. Compose dispatches back to the most recently registered
  handler, so registering it last would have made back leave the chat with the
  preview still up.

  This ordering is invisible in the source and only shows up as "back does
  nothing", so `ImagePreviewWiringTest` pins it explicitly rather than leaving
  it to a reviewer's eye.

- Tests: `ImagePreviewWiringTest` (4) — the tap routes to `onImageTap`, the URI
  is held in state and rendered from it, the preview uses `Fit` not `Crop`, and
  back dismisses the preview rather than the chat. These are source-level
  because neither the tap target nor the dismissal is JVM-constructible.
  `ImagePreview` also gets a `@PreviewLightDark` entry, which
  `PreviewCoverageTest` requires of every visual composable in `src/main`.
- Regression: `test-share-intent-filters.sh` taps the rendered bubble and
  asserts the preview opens, then that back closes it. "Full-screen" is decided
  by width, not by a string: the bubble caps at 260dp (~683px at 420dpi) while
  the preview letterboxes across the window, so >800px can only be the
  preview. Verified to **fail** with the tap rewired to `onTap` (**13 passed,
  1 failed**), then **14 passed, 0 failed** restored.

  Two environment traps here, both of which produced a wall of failures that
  had nothing to do with the change under test:

  1. **A fresh install shows "Set as default SMS app?" over everything.** It
     appears once, on first launch after an install that is not the role
     holder, and it sits on top of whatever the share intent opened — so every
     UI assertion downstream failed while the manifest queries still passed.
     The script now dismisses it as setup.
  2. **The AVD dropped off the bus mid-run** and the script kept driving a dead
     device, reporting each step as a product failure. `require_device` now
     aborts instead, the same guard `take-fdroid-screenshots.sh` uses. This one
     cost a real debugging detour: the failures looked like a regression in the
     code that had just been green.

## #300 follow-up: screen wake still failed with Privacy mode on (2026-10-09)

The first #300 fix wired up the full-screen intent, but `shouldWake()` still
required `!privacyMode`. The reporter's diagnostics showed Privacy mode was
enabled, so the screen never woke even though every other link in the chain
(permission, channel importance, keyguard) was healthy.

- Privacy mode now hides content from screenshots/recordings; it no longer
  blocks the screen-wake path. The full-screen-intent trampoline no longer
  forwards to `MainActivity` (which would surface content over the keyguard);
  it just turns the screen on and lets the heads-up notification show.
- The trampoline also acquires a short `SCREEN_BRIGHT_WAKE_LOCK |
  ACQUIRE_CAUSES_WAKEUP` to force the panel on for Samsung/OneUI devices where
  `setTurnScreenOn` alone is not enough.
- `MainActivity` gained a debug probe `--ez privacy_mode true|false` so the
  regression script can drive the toggle without UI navigation.
- Tests: `WakeOnLockTest.wakesInPrivacyMode` (was `neverWakesInPrivacyMode`);
  `FullScreenIntentWiringTest.trampolineAcquiresAScreenWakeLock`.
- Regression: `scripts/test-notification-wake.sh` now locks the device with
  Privacy mode enabled, sends an SMS, and asserts the screen wakes. Verified
  to **FAIL** when `shouldWake` is restored to require `!privacyMode`
  (`13 passed, 1 failed`), then **PASS** with the fix (`14 passed, 0 failed`).

## Dependency bump sweep (2026-10-09)

Bumped all open Dependabot PRs and verified the integration points still work:

| Dependency | From | To | Where changed |
|---|---|---|---|
| `actions/cache` | v4 | v6.1.0 | `.github/workflows/pr-build.yml` |
| `github/codeql-action/*` | v4.37.9 | v4.38.2 | `.github/workflows/security.yml` (init, analyze, upload-sarif ×2) |
| `androidx.core:core-ktx` | 1.16.0 | **held at 1.16.0** | `gradle/libs.versions.toml` — 1.19.x requires `compileSdk 37+`, which breaks F-Droid |
| `androidx.fragment:fragment-ktx` | 1.6.2 | 1.9.1 | `app/build.gradle.kts` |
| `io.coil-kt.coil3:coil-compose` | 3.3.0 | **held at 3.3.0** | `gradle/libs.versions.toml` — 3.6.x requires `compileSdk 37+`, which breaks F-Droid |
| `com.googlecode.libphonenumber:libphonenumber` | 8.13.55 | 9.0.40 | `gradle/libs.versions.toml` |
| `org.json:json` | 20240303 | 20260814 | `app/build.gradle.kts` (test-only) |
| Gradle wrapper | 9.6.0 | 9.8.0 | `gradle/wrapper/gradle-wrapper.properties` |

- `DependencyApiSmokeTest` pins the JVM-visible APIs: libphonenumber
  parse/format/display, `org.json` round-trip, and class availability for
  Coil3, `androidx.core` NotificationCompat and `androidx.fragment`
  FragmentActivity.
- Regression: `scripts/test-dependency-bump.sh` builds, installs, cold-launches,
  checks New Chat number normalization (libphonenumber), incoming-SMS
  notification posting (`androidx.core`), and the App lock settings row
  (`androidx.fragment`). **8 passed, 0 failed** on `emulator-5554`.
- F-Droid build verified with `gradlew-fdroid assembleRelease`: Gradle 9.8.0
  was downloaded from the transparency log and the release APK built cleanly,
  keeping `compileSdkVersion='36'` and `compileSdkVersionCodename='16'`.
- Full `./gradlew testDebugUnitTest` stays green.
- `.github/dependabot.yml` now ignores minor/major updates for
  `androidx.core:core-ktx` and `io.coil-kt.coil3:coil-compose` until the
  project is ready for `compileSdk 37+`.

## 3-digit service/short codes (198, 199) could not be sent (2026-10-08)

`PhoneNumberUtils.isLikelyPhoneNumber` required 4–15 digits, so India's
198/199-style service numbers were treated as non-dialable. The shared gate
`AddressIdentity.isReplyable` therefore disabled the New Chat "Send to" row,
hid the chat composer for existing short-code threads, and stripped reactions /
notification replies from them.

- Split the dialability decision from the E.164-parse gate:
  - `isDialableAddress` admits 3–15 digit numbers (short codes replyable).
  - `isLikelyPhoneNumber` stays 4–15 digits so libphonenumber never tries to
    parse a short code; `toE164` returns null and the address survives verbatim.
- `AddressIdentity.isReplyable` now uses `isDialableAddress`.
- Tests: `PhoneNumberUtilsTest.shortServiceCodesAreDialableButNotE164Parsed`,
  `AddressIdentityTest.shortServiceCodesAreReplyable`.
- Regression: `scripts/test-short-code-send.sh` — New Chat accepts 198, the
  Send-to row is clickable, and the opened chat shows a composer. **4/0** on the
  fixed build.

## New Chat now focuses the search field and opens the keyboard on launch (2026-10-08)

The New Chat screen opened with the search field unfocused, so the user had to
 tap it before typing. It now requests focus in `LaunchedEffect(Unit)` and the
TextField modifier wires a `FocusRequester`, bringing the keyboard up
automatically.

- `NewChatScreen.kt`: `remember { FocusRequester() }`,
  `LaunchedEffect(Unit) { focusRequester.requestFocus() }`, and
  `Modifier.focusRequester(focusRequester)` on the search `TextField`.
- Test: `NewChatScreenFocusTest` (source-level wiring: requester, launch effect,
  and modifier all present).
- Regression: same `scripts/test-short-code-send.sh` asserts the EditText has
  `focused="true"` immediately after opening New Chat.

## The "Advanced" label drifted: five sweep scripts could never open the screen (2026-10-08)

The settings row is titled "Advanced settings", but `center_of`/`tap_text`
match node text **exactly**, so `tap_text "Advanced"` never matched it.
Scripts whose fallback was `tap_contains "Advanced"` still worked
(`test-hide-links.sh` does exactly that), but the ones whose fallback was
`center_of_contains` — which only *computes* coordinates and never taps — or
which had no fallback at all failed everything downstream: `test-diagnostics`
(1/7), `test-codeql-cleanup`, `test-advanced-move` (5/18), `test-keywords`
and `test-backup-sim-coil` all failed at "could not open Advanced" /
"Diagnostics row not found" / "Blocked keywords dialog did not open".

- Normalised every row **lookup** to the real label: `tap_text`, `scroll_to`,
  `scroll_until`, `tap_until`, `center_of`, `center_of_text`, `y_of`,
  `textxy`, `tap_settings_row`, `assert_gap_between_rows` and the
  `grep 'text="Advanced"'` scans — 34 lines across 19 scripts. Genuine
  substring uses are untouched: `tap_contains "Advanced"`, `grep -q
  "Advanced"`, and the settings-search `type_text "Advanced"`.
- Re-run green: `test-diagnostics` **8/0**, `test-codeql-cleanup` **20/0**,
  `test-advanced-move` **21/0**, `test-keywords` **19/0**,
  `test-backup-sim-coil` **16/0**.
- Regressions: `test-hide-links` **29/2** (the same two pre-existing
  copy-helper failures) and `test-accessibility` **5/19** — verified
  *identical* with the original file restored against the same build, so its
  19 failures are a separate pre-existing drift in the accessibility feature
  flow (the master toggle does not reveal the options), not the label.

## run-all-tests.sh verdict (2026-10-08)

Full sweep on `emulator-5554` against the branch tip after the 13-fix pass:
**26 of 36 steps clean, 10 fail — every failure reproduces on the pre-session
baseline (`a244e97`, installed from a detached worktree) or needs a component
this AVD does not have. None is attributable to the fixes.**

| Script | Cause |
|---|---|
| `test-diagnostics.sh`, `test-codeql-cleanup.sh` | Advanced never opens — same drift as below |
| `test-advanced-move.sh`, `test-keywords.sh`, `test-backup-sim-coil.sh` | same drift |
| `test-backup-restore.sh`, `test-import-mirrors-provider.sh`, `test-merge-import.sh`, `test-import-loading.sh` | backup/import UI flows on this AVD — identical on the baseline ("Set backup PIN dialog not shown", "not found in picker") |
| `test-issue-183-split-threads.sh` | requires the third-party `SMS Import / Export` APK, not installed |

Baseline confirmation: `test-diagnostics.sh` **1/7** and
`test-import-mirrors-provider.sh` ("Set backup PIN dialog not shown") fail
identically with the pre-session APK installed.

**Known script drift (worth a fix, pre-existing):** `center_of`/`tap_text`
match the node text **exactly**, and the settings row is now titled
"Advanced settings" (it was "Advanced"). `tap_text "Advanced" || tap_contains
"Advanced"` still works — `test-hide-links.sh` does exactly that and passes —
but the scripts whose fallback is `center_of_contains` (which only *computes*
coordinates and never taps) never open the screen and fail everything after.
14 scripts contain the exact-match call; the fix is one line each
(`tap_text "Advanced settings"`, or `tap_contains` as the fallback).

## The :mms network request excluded MMS-only APNs and ignored the subscription (2026-10-08)

`MmsNetworkBinding` asked for `NET_CAPABILITY_INTERNET` alongside MMS, so the
one network the carrier provisions for MMS — an MMS-only APN, which has no
INTERNET capability — was excluded outright; and the request carried no
subscription specifier, so on a dual-SIM device SIM B's exchange could run on
SIM A's network.

- The request now requires only MMS (on the cellular transport) and pins the
  subscription with a `TelephonyNetworkSpecifier` when one is named. What the
  request has to be is a pure `MmsNetworkSpec` (pinned when the id is a real
  subscription, i.e. > 0), so the decision is JVM-tested.
- The connectivity manager became a constructor seam: the platform's
  `getSystemService(Class)` is *final*, so a context stub could not vary it,
  and under the unit-test stubs `NetworkRequest.Builder()` answers every call
  with a default, so the request object itself carries nothing to assert. The
  builder's source is therefore pinned by `MmsNetworkRequestWiringTest`
  (MMS yes, INTERNET no, specifier only when named) — the honest regression
  for a shape a JVM test cannot construct.
- New `scripts/test-mms-network.sh` gates all five tests by name.
  Break-the-fix: restoring the old request shape in place (INTERNET re-added,
  specifier removed) fails the two wiring tests — `4 PASS / 1 FAIL`; restored,
  `5 / 0`.

## :mms acknowledged partial messages and left failed sends in the outbox (2026-10-08)

Two send/receive bookkeeping faults, both found in review and both invisible
to the existing tests because those tests asserted the fake's recorded call
rather than the provider row:

- **A failed part write still returned success.** `persistIn` ignored
  `persistPart`'s result, so a message whose attachment never landed came back
  as persisted — and the inbound path acknowledges retrieval on any non-null
  result. A failed part now rolls the written parts back and returns null.
- **A refused send stayed in the outbox.** The failure branches called
  `setPendingErrorType(outbox, …)`, but that writes `ERROR_TYPE` on the
  *message* URI while the pending queue lives at `content://mms-sms/pending`
  (and nothing populates it). The row was never moved, so a failed send looked
  in flight forever. It now moves to `MmsBox.FAILED` — the non-addressable
  failed box the store contract already pins.
- **Two sends in the same second shared an id.** `transactionIdFor` hashed
  second-resolution time + recipients + class only, and the id is the MMSC's
  only deduplication key (the callback's request code derives from it too). A
  per-process nonce, clock-seeded so a restart does not repeat the previous
  run, is now folded in.

- `TelephonyMmsStoreTest` +1, and `MmsFacadeTest`'s refused/unreadable send
  tests rewritten to assert the *failed box* instead of `pendingErrors`.
  `SendReqBuilderTest.twoSendsGetDifferentTransactionIds` (its two sends were
  a second apart) became `twoSendsInTheSameSecondGetDifferentTransactionIds`.
  The fake resolver gained the whole-parts-collection delete the rollback uses.
- Break-the-fix: with only the production changes stashed, those 4 tests fail;
  restored, `:mms` is green.
- New `scripts/test-mms-facade.sh` gates the three send guarantees by name (a
  rename would otherwise leave the suite green); `test-mms-store.sh` guards
  `aMessageWhoseAttachmentCouldNotBeWrittenIsNotPersisted`. Both re-run green:
  **6/0** and **5/0**.

## The :mms parser rejected valid bare forms and escaped on forged lengths (2026-10-07)

Two hostilities, both found in review:

- **Valid bare forms were rejected.** `readContentType` always demanded a
  value-length first, and `readEncodedStringValue` always demanded
  value-length + charset — but both values legally arrive bare (OMA-MMS-ENC:
  Content-type-value is Constrained-media | Content-general-form, and
  Encoded-string-value is Text-string | Value-length Char-set Text-string),
  and the reference accepts both. A carrier sending either got a null PDU
  instead of its message.
- **A forged encoded-string length escaped as a crash.** `index + length`
  was computed before checking the length against what actually remained, so
  a length near `Int.MAX_VALUE` overflowed the stop index negative, slipped
  past the bound check, and a later read threw
  `ArrayIndexOutOfBoundsException` — which `parse()` did not catch, breaking
  the never-throws contract on hostile input.

Both sides now read the leading octet the way the reference does (below 0x20
is a length, anything else is already the value; 0x00 is the empty value),
the length is checked against `remaining` before any index arithmetic, and
`parse()` catches an out-of-bounds read as defense in depth.

- `PduParserTest` +4: the bare constrained-media Content-Type, the bare
  text-string To, the empty encoded value, and the forged length (which
  fails pre-fix by *escaping*, not by asserting).
- Break-the-fix: with the production changes stashed, all four fail — the
  forged-length one via the escaping exception; restored, all green.
- `scripts/test-mms-codec.sh` now gates the four parser-contract tests
  alongside the three composer vectors: 7 named tests, **21/21**.

## The :mms wire format disagreed with the reference stack (2026-10-07)

Two conventions the module's own round trips could not see, both found in
review and both pinned against the production reference stack rather than
against the module's own parser:

- **Uintvar groups went out least-significant first** — 128 was `0x80 0x01`
  where WAP-230 §3.1 (and the reference) require `0x81 0x00`. Writer and
  reader agreed with each other, so every in-house round trip passed and only
  a carrier would have rejected the PDU.
- **X-Mms-Content-Type was emitted first** — the composer sorted headers by
  field code, where 0x84 sorts before Message-Type (0x8C). The reference
  parser stops reading headers at Content-Type, so every mandatory header
  after it became body bytes.

Both directions are pinned by a new `ComposerParserInteropTest` in the app's
test set (production still sends through the vendored stack; the new
`testImplementation(project(":mms"))` is what lets the two stacks prove they
read each other before any switch-over). The fixture's 300-byte part crosses
the 127-byte single-octet length boundary in both directions. Getting the
reference composer to run JVM-only took a `ContextWrapper(null)` stub — its
constructor stores the resolver but only ever opens it for a part carrying a
data Uri — and the reference writes phone recipients with the `/TYPE=PLMN`
suffix, which the app's own `MmsSupport.phoneAddress` already strips.

- `WspTest`'s two pins were themselves wrong (`0x80 0x01` for 128,
  `0xAC 0x02` for 300) and now pin the wire, not the code.
- `PduComposerTest`'s pinned M-Send.req vector is reordered (Content-Type
  last), and `theContainerContentTypeWritesStartBeforeType` — which asserted
  Content-Type came *first* — became `theContainerContentTypeClosesTheHeaderBlock`.
- `docs/Mms/02-pdu-wire-format.md` records both rules (uintvar most
  significant group first; Content-Type closes the header block).
- `scripts/test-mms-codec.sh`: **21/21** — its vectors are read out of the
  test source, so the reorder flowed in without restating them; its stale
  ascending-order comment updated.
- Break-the-fix, the honest way: with only the production changes stashed,
  the new expectations fail **6 ways** (both interop directions, the pinned
  vector, the container test, both uintvar pins); with them restored, 683
  tests green across `:mms` and `:app`.

## Search leaked hidden content, missed old hits, and announced a bare marker (2026-10-07)

Three follow-ups to the all-history home search, all found in review:

- **A locked message's body leaked through search.** The all-history SQL
  matched raw bodies, so searching a locked message's text surfaced its
  thread — proving the secret the app masks everywhere. **"Hide links" was
  bypassed the same way**: a URL removed from every list and chat still
  surfaced its thread when searched. Both are one rule — a query may only
  match what the user can see — which now lives once, in
  `MessageSearch.matchesVisible` (a locked body never matches; with Hide
  links on, only the redacted body does, through the same `hideUrls` the UI
  paints). SQL stays a LIKE prefilter and cannot quietly disagree with the
  rule. The hide-links setting is threaded through the search state so a
  toggle re-answers the query.
- **Home search surfaced threads the chat could never reach.** The chat
  computed matches only over the loaded window and auto-paging stopped at
  400, so a hit in a 421-message thread was listed at home but unreachable in
  the chat. Matches now come from the whole thread
  (`Repository.messageIdsMatching`), the pager grows past the cap in
  `LOAD_EARLIER_STEP` chunks while a hit is older than what is loaded, and
  the scroll effect re-runs when the focused row finally arrives — without
  re-triggering on later chunk loads, because the marker is the id it last
  scrolled to, so there is no #284-style snap-back.
- **The focused hit replaced its readable text for TalkBack.** The marker
  `contentDescription` swapped the bubble's body for "Search result". It is
  additive now (`A11y.describe(body, marker)`: "see the code. Search
  result"), built on the existing tested join.
- Tests: `MessageSearchTest` (+1: visible matching never sees locked bodies
  or hidden links) and `A11yTest` (+1: the announcement keeps the body).
  New `scripts/test-search-privacy.sh` — fails before the fix with the two
  leaks (`2 passed / 2 failed`, the toggle verified on through the app's own
  prefs), passes after `4/0`. Its settings navigation force-stops first,
  because the `open_settings` deep link only opens from a cold start — that
  cost a debugging round to find.
  `test-home-search-all-messages.sh` re-anchored on a 421-message thread
  whose only hit is the *oldest* message (seeded in one recursive-CTE
  insert) — fails before (`1/2`), passes after (`3/0`). The three
  search-result marker greps (scroll / highlight / all-messages) now match
  the combined announcement. Re-run green: `test-chat-search-scroll` (5/5 —
  the scroll rework kept the no-snap-back), `test-chat-search-highlight`
  (3/3), `test-in-chat-search` (8/8), `test-home-search-flicker` (3/3),
  `test-home-search-phone` (10/10). `test-hide-links` fails its two
  copy-round-trip helper assertions **identically on the stashed baseline**
  — pre-existing helper flake, not from this work.

## The composed PDU was served from outside the FileProvider's cache root (2026-10-07)

`MmsComposer.pduContentUri` built the outgoing PDU's content URI by hand —
`content://<authority>/<filename>` — while `file_paths.xml` exposes the cache
root under the `mms` name segment, so the real URI was
`content://<authority>/mms/<filename>`. The telephony process reads the PDU
from that URI over binder (`IMms.sendMessage` — nothing is read in-process),
so no send could ever be opened. `test-mms-send.sh` still passed: it accepts
`msg_box=5` and status `failed`, and on this AVD the platform answers every
send with code 12 (`MMS_ERROR_MMS_DISABLED_BY_CARRIER`) regardless of the URI,
so the send outcome cannot distinguish a readable PDU from an unreadable one.

- The URI now comes from `FileProvider.getUriForFile`, so the URI and the XML
  path mapping cannot drift apart again — the mapping has one owner
  (`file_paths.xml`). A new `FileProviderWiringTest` pins that contract at the
  source level: the composer must derive the URI through `getUriForFile` and
  must not hand-build a `content://` URI, the manifest authority must be
  `${applicationId}.fileprovider`, and the cache root the PDU is written to
  must be the one the XML exposes.
- Two diagnostic log lines make the two ends observable: the composer logs the
  composed URI and size (`MmsComposer` tag), and the sent callback logs the
  platform's result code (`MmsSend`). The code-12 finding above is what the
  second one surfaced.
- `scripts/test-mms-send.sh` gained a URI-shape assertion (the composer's log
  line must show the PDU under the provider's `mms/` root). Verified the honest
  way: **8 PASS / 1 FAIL** with the hand-built URI restored and a fresh build +
  reinstall, **9 PASS / 0 FAIL** with the fix. `test-mms-carrier-config.sh`
  re-run green (8/8) — it drives the same composer through the debug probe.
- Honest limitation, recorded here: the platform-side *open* of the fixed URI
  could not be observed end-to-end on this AVD — every send is answered with
  code 12 with both the broken and the fixed URI, no MMS keys are set in the
  carrier config, and the phone process logs nothing about the send. The URI's
  correctness is pinned by its shape, the XML contract, and the wiring test,
  not by a completed transfer.

## Incoming MMS was requested from a made-up URL, and the WAP push was dropped (2026-10-07)

Two halves of one dead end, both from the #236 receive path. The downloader
asked the platform to fetch the **package name** as the MMS location URL
(`downloadMultimediaMessage(context, context.packageName, …)`), and the
receiver required `intent.data` — which a WAP push never carries, the PDU
rides in the broadcast's "data" extra — so a real push never started a
download at all. Even a perfect sweep asked the platform to fetch
"com.anindra.messages".

- The pending row carries the real destination: the provider's `ct_l`
  (Content-Location). `MmsProviderReader.pendingDownloads()` now returns
  `MmsSupport.PendingDownload(id, contentLocation)` per announced row, and
  `MmsDownloader.request` passes it as the location URL, keeping the row URI
  as the content URI the platform writes the RetrieveConf to. A row with no
  `ct_l` is refused with a log line — there is nowhere to point the platform
  at.
- `MmsReceiver` no longer reads `intent.data`: the platform has already filed
  the announced row when it broadcasts, so the push (and every broadcast
  missed while the app was not the default handler) is covered by the same
  `requestPending` sweep. The recognition decision (`isMmsWapPush`) and the
  blank-location rule (`downloadLocation`) live in `MmsSupport`, where they
  are unit-testable.
- Tests: `MmsSupportTest` (+2: WAP-push recognition by action+type, and the
  Content-Location a download can be requested from).
  `scripts/test-mms-download.sh` extended: the pending fixture is seeded with
  `ct_l`, the sweep assertion now requires the request to come **from** the
  seeded Content-Location, and a new section delivers a WAP push (explicit
  component — a shell-sent *implicit* `WAP_PUSH_DELIVER` is never dispatched
  by AMS, confirmed in the broadcast-queue dumps — while the receiver's
  filter registration was confirmed via the package dump's Receiver Resolver
  Table) and asserts the push alone starts the request. Fails before the fix
  with `4 PASS / 2 FAIL` (made-up URL + dropped push, each for its own
  reason), passes after with `6 PASS / 0 FAIL`, verified the honest way
  (fresh build + reinstall before every run).
- `test-mms-retry.sh` seeds now carry `ct_l`, since a row without one is no
  longer requestable — `7 PASS / 0 FAIL` after the change.

## The provider-sync prune deleted every imported MMS (2026-10-07)

`136ae6f` (2026-10-02) taught the doomed-row side of the prune to namespace
MMS ids negative (`providerKey`), but the live provider-id set was still built
with raw positive ids from both transports — so `-id` was never in the set and
**every** provider-backed MMS was pruned by the same `syncFromSystem` pass that
imported it. An imported MMS never survived a sync; it vanished before the
first frame that could show it. `test-mms-import.sh` (#210) had last been run
green on Sep 24, eight days before the prune existed, so nothing caught the
regression.

- The namespacing decision now lives once, in `data/ProviderPresence.kt`
  (`key(transport, sysId)`). `PROVIDER_MESSAGE_SOURCES` carries each source's
  transport so the live-set build keys through it too — both sides of the
  comparison call the same function, so they cannot disagree about which side
  of zero an id lives on.
- `ProviderPresenceTest` (4): the sign convention, the cross-transport
  non-match, and the survival case.
- `scripts/test-mms-import.sh` is the regression — it already covered import +
  a second sync; it just had not been run since the prune landed. Fails before
  the fix at 'existing provider MMS imported' (`1 PASS / 1 FAIL`), passes after
  `5 PASS / 0 FAIL` including idempotent reimport. Verified the honest way both
  times: fresh `assembleDebug` + reinstall before each run.
- `test-sms-mirror.sh` re-run around it: §1–3 green on both builds; §4
  (fresh-install re-import) fails **identically on the stashed baseline** —
  pre-existing, not from this work (same status as `test-chat-render.sh` /
  `test-multipart-sms.sh` below).

## Chat bubble corners: flat joins, one connected block (2026-10-07)

The corner redesign shipped in the #284 working tree squared off each
bubble's *outer* edge (the screen-edge side) and kept the joined side rounded,
so a middle bubble was fully rounded and a run of same-sender messages read
as a stack of separate bubbles. Reviewed against real Google Messages and
rejected. The final design:

| position | received (tS, tE, bS, bE) | sent |
|---|---|---|
| SINGLE | 18, 18, 4, 18 | 18, 18, 18, 4 |
| FIRST | 18, 18, 4, 18 | 18, 18, 18, 4 |
| MIDDLE | 4, 18, 4, 18 | 18, 4, 18, 4 |
| LAST | 4, 18, 18, 18 | 18, 4, 18, 18 |

- Everything except MIDDLE is what commit `9159b0e` originally shipped: a
  lone bubble and the first of a run share the "tail" — only the bottom
  corner on the sender's stack side (start/left for received, end/right for
  sent) is flat, the other three stay rounded — and the last of a run is
  flat on the corner joined from above. MIDDLE alone changed from fully
  rounded to flat on both stack-side corners, so a run reads as one
  connected block.
- `bubbleCorners()` in `ui/MessageGrouping.kt` is the only production change.
  Every bubble surface — the real bubble, the loading skeleton and the
  preview row — plus the `BubbleShape` logcat marker render through it, so
  none can re-derive the corners and disagree (the skeleton's hand-synced
  corner literals had already drifted when the redesign landed).
- `BubbleCornerShapeTest` and `MessageGroupingTest` pin the full table.
- `test-bubble-corners.sh` re-anchored (SINGLE + MIDDLE assertions; its
  FIRST/LAST assertions already described the design, having gone stale
  against the uncommitted redesign rather than against history). Verified
  the honest way, rebuild + reinstall before every run: **2/6 FAIL** on the
  flat-outer design, then **6/2 FAIL** on the flat-both SINGLE design (only
  the two SINGLE assertions failing), then **8/8** after each fix.

## Issue #284 second follow-up: number search is a contact search, and the jump to the top (2026-10-08)

Reporter filed a second patch from a Claude session (`issue-284-number-search-and-chat-scroll.patch`,
written against `ac8ffdb`, never compiled or run where it was written). Four of the five
items shipped; the scroll-to-latest button was declined.

- **A number query is now a contact query and nothing else.** `ConversationList.filter`
  splits on `AddressIdentity.isNumberQuery` (digits plus `+ - ( ) .` and spaces). A
  number query matches addresses only — not `name`, not `snippet`, not
  `messageMatchIds`. That is what stops every chat that merely *mentions* a number
  from being listed, and it also drops the `snippet.contains` path that let a digit
  inside a sender name or a snippet match a number query. `rememberMessageMatchIds`
  bails before the debounce for a number query, so the `LIKE` scan over every message
  body never runs, and it clears `HeldMessageMatches` too or a previous text query's
  ids survive into the number query.
- **`X1 INFO`-style sender IDs no longer flicker per keystroke.** The old
  `matchesNumber` stripped the address to digits, so `X1-SRB` became `"1"` and
  `q.endsWith(a)` was true for every query ending in `1` — present for `101`, gone for
  `1010`, back for `10101`. An address containing a letter is now rejected outright,
  the same rule `samePerson` already used. `AddressIdentityTest` had a comment
  declaring `matchesNumber("ABC123", "123")` true and "harmless"; that is now false
  and asserted false.
- **A contact is found from the first digits.** A suffix test cannot succeed until
  the query is nearly complete, so containment replaced it — compared against the
  E.164 digits and two national spellings (trunk zero kept, and stripped), which is
  what a contact is actually typed as. The last-seven `compareDigits` rule stays as
  the final fallback. New `PhoneNumberUtils.nationalDigits` derives the national run
  via libphonenumber and is cached on the canonical E.164, so it is one `format` per
  unique number rather than one per keystroke.
- **One and two digits leave the list unfiltered.** Both the number-match and the
  message-search paths reject a query under `MIN_SEARCH_DIGITS`, so a query in that
  window used to match nothing and blanked the list mid-typing. New
  `AddressIdentity.tooShortToBeNumber`, checked *before* the number-query branch —
  that ordering is load-bearing and was wrong on the first attempt.
- **Opening a search result no longer jumps to the top of the history.**
  `searchWantsOlder` keyed on `searchMatches.first()`, the *oldest* match, so one
  ancient hit anywhere in the thread made the pager walk the whole history in
  `LOAD_EARLIER_STEP` (200) jumps while the view sat on the newest hit, which was
  already loaded. It now follows `focusedSearchId`, which is already
  `focusedOverrideId ?: searchMatches.lastOrNull()` — so previous/next still pages an
  older match in on demand.
- **`MainActivity.handoffSearchQuery`** nulls a number query before it reaches
  `chatSearchQuery`, so opening a contact neither scrolls to nor highlights a message.
  Both conversation lists needed no change; they pass the raw query through and this
  decides once for both.

Deliberately **not** shipped, and stated as such in the #284 reply:

- **No scroll-to-latest button.** A missing feature rather than a defect: permanent
  clutter above the composer, in every chat, to work around a bug the paging fix
  removes. Revisit if asked.
- **No message search for number queries.** A code inside a message (an OTP) is no
  longer findable from the home search. In-thread search already covers the whole
  conversation, so it is the better tool for that job anyway.

Tests: `AddressIdentityTest` (+6, incl. the `101`/`1010`/`10101`/`101010` table and
the trunk-zero/leading-zero national forms), `ConversationListTest` (+3),
`test-number-search.sh` (new, 13 checks), `test-chat-search-scroll.sh` (extended:
seed grown past `LOAD_EARLIER_STEP` with an old hit so the jump actually reproduces).

Two traps worth keeping, both paid for in real time here:

- **The scroll seed must exceed `LOAD_EARLIER_STEP`.** At 120 messages the whole
  history lands in a single prepend, the anchor is never lost, and the script passed
  against reverted code — a green run proving nothing. 400 messages makes the pager
  take the 200-row steps that break `LazyColumn`'s bounded-window key anchoring.
- **A body match can mask a broken address match.** Check 2 (partial number finds the
  contact) passed against reverted code once the seed also carried the number inside
  a message body, because `messageMatchIds` surfaced the row on its own. The seed is
  now two-phase: check 2 runs clean, then `seed_self_number` adds the body hit that
  check 4 needs in order to be discriminating.

Unrelated and pre-existing: `test-alphanumeric-sender.sh` check 1 ("alphanumeric
notification wrongly offers a Reply action") fails identically on stock `HEAD`.

## Issue #284 follow-up: contact number, flicker, and the scroll snap-back (2026-10-07)

Three of the four items left open in the #284 thread. Both conversation lists
get the same fix; the legacy list is the *default* (`use_new_ui=false`) and had
neither the message search nor the handoff at all.

- **A saved contact is now findable by its phone number.** `AddressIdentity
  .matchesNumber` was a digits-only suffix test, which cannot see a national
  spelling: the thread holds `+919876543210` while the contact is dialled and
  typed as `09876543210`, and neither digit run suffixes the other. It now falls
  through to the last-seven `ContactLookup.compareDigits` rule that contact
  lookup already uses, rather than keeping a second, narrower copy of it.
  Note `+20…` (Egypt) happened to suffix-match already — `2` + `0` + N — so a
  test using it proves nothing; 91 and 44 are the cases that actually failed.
- **The result list no longer blanks on every keystroke.** A number query
  matches no contact name, so the whole result set came from the message-match
  flow, and collecting it with an empty initial value emptied the list for a
  frame each time. `HeldMessageMatches` now keeps the outgoing ids until the new
  query answers, and the query is debounced. The shared search state moved to
  `ui/ConversationSearch.kt` so the two lists cannot drift again — which is how
  the legacy list lost the phone-number match in the first place.
- **Scrolling in a chat no longer snaps back up to the search hit.** The scroll
  effect was keyed on the hit's row *index*, and the pager prepends older
  messages in 40-message chunks, so each chunk load shifted the index and
  re-fired `scrollToItem`. It is keyed on the message id now, and the focused
  match is derived (`focusedOverrideId ?: searchMatches.lastOrNull()`) instead of
  stored as an index that a chunk load used to reset.
- The legacy list now takes `(Long, String)` from `onOpenConversation` and
  passes the query through, so a hit is highlighted and jumped to on the
  default UI as well.

Tests: `AddressIdentityTest`, `ConversationListTest`, `HeldMessageMatchesTest`,
`test-home-search-phone.sh` (extended), `test-home-search-flicker.sh` and
`test-chat-search-scroll.sh` (new).

Two notes worth keeping:

- **The flicker could not be asserted from `uiautomator`.** The blank is one or
  two frames and a dump takes ~1s; Compose's key-based anchoring also restores
  the scroll position afterwards, so nothing persistent was left to check. The
  rule is pinned in `HeldMessageMatchesTest` instead, and
  `test-home-search-flicker.sh` is an end-to-end guard, not a fail-before gate.
- **Scroll assertions must hide the IME first.** The soft keyboard covers the
  lower half of this AVD, so a swipe aimed at the bottom of the screen lands on
  the keyboard and silently tests nothing. This cost real time twice.

## Home-search handoff: highlight + scroll in chat (2026-10-05)

Searching the home list and tapping a conversation opened the chat at the
bottom, so the user could not see where the keyword was. The active home query
is now carried into the chat, which highlights every matching message and
scrolls to the newest hit.

- `ConversationsScreen.onOpenConversation` is now `(Long, String)`; the second
  value is the trimmed query while the search field is open (blank otherwise).
  `MainActivity` keeps it in `chatSearchQuery` and passes it to `ChatScreen`;
  every other way into a chat (new, scheduled, spam, intent, group) clears it.
- `data/MessageSearch.kt` holds the pure rules: case-insensitive `matches`,
  `ranges` for the styled spans (matching without folding keeps offsets valid),
  and `focusedId` for the newest matching message. Unit tested in
  `MessageSearchTest`.
- `ChatScreen` computes the matching ids and the focused id, and the existing
  bottom-on-load effect now prefers the focused row (`scrollToItem`). The match
  is scrolled to once it loads, including after a later chunk arrives.
- The match flashes like a settings jump: the keyword background and the
  focused bubble's border fade in, hold ~1.6s, then fade out (`animateFloatAsState`
  over the app's motion tokens), so the pointer is temporary and vanishes. The
  persistent `Search result` content description (`chat_search_result`, added to
  all 13 locales) stays on the hit so a uiautomator dump can assert it without a
  screenshot. The keyword tint is layered on the finished `AnnotatedString` so
  the animation does not re-run Linkify every frame.
- `test-chat-search-highlight.sh` seeds a conversation named with the keyword
  and one matching message that is the *oldest* of 46, searches the home list,
  opens the row, and asserts the message is visible and marked. Verified to
  FAIL on a build with `focusedId` forced null (rebuilt + reinstalled).

## Reaction chip stays on the message's own side (2026-10-05)

The reaction chip was briefly end-aligned during this work; the user reviewed it
and chose the original behaviour — incoming chip on the left, outgoing on the
right — so the alignment is unchanged. `test-message-reactions.sh` and
`MessageReactionsTest` carry no position assertion.

Observed while checking the physical phone: on a real device that is also the
default SMS handler, the reaction fallback texts (`Reacted 👍 to …` /
`Removed 👍 from …`) showed up as ordinary messages in the thread. That is the
#188 app-to-app protocol being echoed/stored by the sending side; the local
single-emulator roundtrip test cannot see it. Left as-is pending a decision.

- `test-reaction-roundtrip.sh`'s "ordinary text still stored" check matched
  every `just a normal reply%` row, including orphans left by other scripts
  whose rowids were later reused; it now matches the run's unique body.

## Home search across all messages (2026-10-06)

Issue #284 feedback: the home search only matched a conversation's newest
message (the snippet). A word buried in an older message did not surface its
thread, even though the query already carries into the chat and jumps to a
match.

- `Repository.conversationIdsMatchingMessage(query)` returns the ids of
  conversations with a matching non-deleted message (`body LIKE %query%`,
  escaped, observed like the other flows).
- `ConversationList.filter` takes that set and matches it alongside
  name/address/snippet/number, so a hit anywhere in a thread lists it. The
  parameter sits before the trailing `snippetFor` lambda so existing trailing
  lambda call sites keep compiling.
- Opening the thread still uses the handoff: it scrolls to the newest matching
  message and flashes it.
- Tests: `ConversationListTest.aHitAnywhereInTheThreadSurfacesTheConversation`;
  `test-home-search-all-messages.sh` seeds a thread whose only hit is 30
  messages old, searches it, and asserts the thread lists and opens on the hit.

## In-chat search (2026-10-05)

The overflow menu gained a Search item that opens a search field in the top bar
(same styling as the home list) and matches **only the open conversation**.

- `ChatScreen` holds `searchOpen`/`chatQuery`; the active query is the in-chat
  one while open, otherwise the home-list handoff. `MessageSearch.matches`
  filters `messages`, `step` clamps the next/previous movement.
- The bar shows a `n of m` counter and up/down buttons (`Previous match` /
  `Next match`); typing focuses the newest hit, Previous walks older, Next
  newer. Every move scrolls to the hit and replays the same flash highlight as
  the handoff. Back closes the search.
- The two arrow buttons are a compact pair (36dp targets, 28dp glyphs, with
  `LocalMinimumInteractiveComponentSize` cleared) so they sit close together
  instead of the default 48dp-apart top-bar actions.
- The search `TextField` pins `textStyle = bodyLarge`, otherwise it inherited
  the top bar's title style and rendered much larger than the home search.
- New strings `chat_search`, `chat_search_hint`, `chat_search_previous`,
  `chat_search_next`, `chat_search_counter` in all 13 locales.
- `ChatSearchBar` has a preview; `ChatTopBar` previews pass `onSearch`.
- `MessageSearchTest` covers `step`; `test-in-chat-search.sh` seeds two hits 20
  messages apart, opens the menu, types, and walks previous/next.

## Shorter swipe-to-act (2026-10-05)

Making the required swipe for a conversation action smaller. Google Messages
commits on a short flick, but M3's `SwipeToDismissBox` has a hardcoded
mid-drag target switch at **half the row** (issuetracker 471021165), and the
app additionally gated the release on `progress >= 0.65f`, so the gesture
needed ~65% of the width.

- The fraction now lives once in `SettingsLayout.SWIPE_COMMIT_FRACTION`
  (`0.30f`) and is passed to **both** `positionalThreshold` and the
  `confirmValueChange` gate in `SwipeConversationItem` (`ConversationsScreen.kt`)
  and in `LegacyConversationsScreen`. A slow release is settled through
  `positionalThreshold`, so 30% commences the action; because the fraction sits
  below the library's hardcoded half-row switch, that switch can no longer
  decide the gesture.
- `test-swipe-threshold.sh` previously pinned 31%/56% travel as "must bounce".
  Re-anchored to 17% bounces / 39% commits. The new script was verified to
  **fail** on the old 0.65 build (constant temporarily reverted, rebuilt,
  reinstalled) before passing on 0.30 — the same revert also failed
  `SwipeThresholdTest`.
- Tests: `SwipeThresholdTest` (constant is small and both screens gate on it),
  `scripts/test-swipe-threshold.sh`.

## Message reactions (2026-10-05)

Branch `feat/own-mms-package`, issue #188. Long-press a message to attach a
local emoji reaction. The data layer already existed (`messages.reactions`,
`setReactionsSuspend`, `serializeReactions`/`parseReactions`,
`AppViewModel.setReactions`); only the UI was missing.

- The picker is an anchored sibling of the bubble in a custom `Layout`: it is
  placed just above the pressed bubble but the Layout reports the bubble's size,
  so opening it never reflows the list or moves the bubble (a picker inside the
  bubble added its height and pushed everything down; one in the top bar was too
  far away). It animates in and out with a fade + scale, honouring reduce-motion.
  It offers the app's 8 `EMOJIS`; tap toggles.
- A reaction renders as a single bordered pill on the bubble's bottom edge. A
  row of separate surfaces below the bubble read as a message the user sent.
- The picker is shown for the single *selected* message (derived from the
  selection, not a separate pressed-id): selecting a second message hides it,
  and deselecting back to one shows it on the remaining message.
- Reactions are refused on a concealed locked message: the SMS fallback would
  quote its body and defeat the lock. Once unlocked, it can be reacted to.
- Reactions are local-only, but each add/remove also sends a readable SMS
  fallback (`Reacted 👍 to <snippet>` / `Removed 👍 from <snippet>`) through
  `SmsSender.sendRaw`, which stores no row so it never appears as our own bubble.
- The notice is **send-only**: `ReactionFallback` builds the text and nothing
  parses it, so on the receiving install it arrives as an ordinary message
  bubble (`Reacted 👍 to <snippet>`). `36f1adf` had made it a protocol that
  applied the emoji to the referenced message; that was reverted at the user's
  request — the text reads as a message again. Wording kept as-is (English,
  quote-free, so a recipient without the app understands it and a plain
  `sms send` can carry it).
- A locked/concealed message is not reacted to (the fallback would leak its body),
  and the picker is not offered where a message cannot be sent (alphanumeric
  sender IDs, blocked numbers).

Tests: `MessageReactionsTest` (toggle, preserve imported counts, order, quote,
and the locked-message gate); `ReactionFallbackTest` (wording, one SMS segment,
60-char cap); `test-message-reactions.sh` (5/5); `test-reaction-roundtrip.sh`
(5/5 — asserts the notice IS stored as a message and the referenced message
carries no reaction); `test-reaction-cases.sh` (9/9).

Verified to **fail** on the pre-revert build (reverted, rebuilt, reinstalled)
before passing: the roundtrip script reported `reaction was applied to the
referenced message (':1')`.

## Short codes: cannot message "198" (2026-10-08) — OPEN

`isLikelyPhoneNumber` requires 4–15 digits, so a 3-digit short code fails
`isReplyable` → `isPhoneNumber` → the composer is never composed and the chat
renders `AlphanumericNotice` instead ("You cannot send messages to alphanumeric
senders like 198"). `NewChatScreen` gates the same way, so the thread cannot
even be started from search.

Planned fix: split the two questions the single predicate answers. Keep
`isLikelyPhoneNumber` (4–15) gating `toE164`/`displayFor`/`nationalDigits`, so
parse cost and E.164 behaviour are unchanged, and add `isDialableAddress` (no
letters, 3–15 digits) for `AddressIdentity.isReplyable` only. Identity must not
move: short codes have no E.164, so `canonical("198")` has to stay `"198"` or
threads split. The same predicate gates the notification actions (`MainActivity`
394/479/504/559/789), which unblock for free.

Open question for the user: whether 1–2 digit addresses should also become
sendable (plan keeps the floor at 3).

`env.sh` matching fixes found here: `dump_ui` now deletes the remote dump,
confirms it succeeded and retries (a segfault left a stale file that read as the
wrong screen); `ui_decode` decodes the numeric character references uiautomator
writes for emoji (`&#128077;`) so a literal search matches; `ui_has` and
`center_of_top` match against the decoded dump, the latter picking the topmost
of several identical labels (the picker bar vs the reaction badge).

## Unread-at-top defaults off (2026-10-05)

Branch `feat/own-mms-package`. Compared against QUIK SMS (`quik-sms/quik`,
built from source): its `unreadAtTop` preference defaults to `false`, so its
inbox is strictly newest-first. Ours defaulted `unreadAtTopEnabled` to `true`,
so an older unread thread could sit above a newer read one — the actual latest
message was pushed down and took a scroll to find. The default is now `false`;
the "Unread at top" toggle stays available for anyone who wants it.

`ConversationListTest.unreadAtTopDefaultsToOff` pins the default.
`test-unread-at-top-default.sh` (6/6) does `pm clear`, asserts the switch is off
on a fresh install — read from `android layout`, because uiautomator is
unreliable against this Compose screen — then proves opting in still toggles the
preference. Against the old default it fails 4/2, so it is a real guard.

## Import & export log restyle (2026-10-05)

Branch `feat/own-mms-package`. The log was a flat column of text with no card
and no status, and the newest run was buried at the bottom. It now reads like
the rest of the settings surface.

- Each run is a `GroupedRowCard` carrying a success/failure disc, the operation
  (Import/Export, or a Restore mark when startup self-healing produced the
  entry), the reason, conflict rows with a warning icon, the `format · mode`
  meta line, and the timestamp.
- The outcome is carried three ways — icon shape, colour, and a status pill
  reading "Succeeded"/"Failed" — so it survives a monochrome screen and a
  screen reader. A second pill shows "Retried N×" when `attempts > 1`.
- Runs are listed **newest first**: the run a user just performed is the one
  they are checking, and it should not sit below twenty old ones.
- The empty state is a centred history icon over the existing text.
- Three strings (`transfer_log_status_ok`, `transfer_log_status_failed`,
  `transfer_log_retried`) were added to the base and **all 12 locales**.
  `TransferLogScreenWiringTest` pins the pills and the newest-first order;
  `test-transfer-log.sh` gained an assertion that the outcome pill renders
  (13/13), verified to fail on a build that drops the wording.

## Backup/restore self-healing with retry and backoff (2026-10-05)

Branch `feat/own-mms-package`. Backup and restore can fail transiently — storage
busy, a MediaStore insert that races, a source stream that opens empty — and a
single attempt meant a periodic backup could wait a whole interval, or a restore
could be abandoned mid-way. Every path is now bounded-retry with exponential
backoff, and an interrupted restore heals itself at startup.

| Layer | What changed | JUnit | Regression script |
|---|---|---|---|
| Retry core | `TransferRetry`: transient vs permanent, capped exponential backoff | `TransferRetryTest` | `test-backup-retry.sh` (8/8) |
| Backup | snapshot once, verify, retry the destination write; partial file deleted | `TransferRetryTest` | `test-backup-retry.sh` |
| Worker | transient failure -> `Result.retry()` (capped), WorkManager exponential backoff, one-shot retry on next launch | `PeriodicBackupSchedulerTest`, `BackupHealthTest` | `test-backup-retry.sh` |
| Restore | staging and merge retried; interrupted REPLACE swap recovered at startup | `ImportRecoveryTest` | `test-backup-retry.sh` |
| Report | transfer log carries `attempts`/`recovered`; Diagnostics prints a Backup section | `TransferLogTest` | `test-transfer-log.sh` |

- `TransferRetry` mirrors `MmsRetry`: `IOException` / SQLite-locked are
  transient, a wrong PIN or corrupt file is permanent and stops on the first
  attempt. The budget is finite (`MAX_ATTEMPTS = 3`); after it the failure is
  recorded and the normal schedule resumes — no unbounded retry.
- The backup snapshots the database once, then retries streaming that stable
  file, instead of re-reading the moving database each attempt. Snapshots are
  unique per run, so a manual backup and the periodic worker can never delete
  each other's file.
- `PeriodicBackupWorker` and the new `BackupRetryWorker` both delegate to
  `AutomaticBackup`. The retry is a **distinct class** so
  `WorkSpec ... LIKE '%PeriodicBackupWorker%'` still names exactly the periodic
  job that `test-periodic-backup.sh` reads back.
- `Repository.recoverInterruptedImport()` runs synchronously in
  `MessagesApplication.onCreate`, before any Activity opens the database: a
  missing live file is rebuilt from `pre_import_backup.db` (or a valid
  `import_temp.db`), and the recovery is written to the transfer log. It keeps
  the pre-import copy if the live file is still broken, so the next launch can
  try again instead of deleting the only history.
- Debug probe `--ez backup_export_probe true --ei backup_fail_first N` injects N
  transient failures into the destination write so the on-device script can
  observe the retry; `--ez transfer_log_probe true` dumps the log.
- `test-backup-retry.sh` was confirmed to fail on the unfixed build (retry and
  recovery disabled): 6 of 8 failed, then 8/8 pass once restored.
- `test-backup-heal-scale.sh` (opt-in; **overwrites local history**) seeds 5000
  conversations / 10000 messages and proves the same two paths at scale:
  retried backup holds all 10000 messages with `integrity_check=ok` (~2.2 s),
  and startup recovery restores the database (~1.0 s) with no OOM or crash.
  It is deliberately **not** in `run-all-tests.sh`.

## #300 Incoming SMS does not wake a locked screen (2026-10-08)

| Issue | Feature | JUnit | Regression script |
|---|---|---|---|
| #300 | Full-screen intent wakes the screen for an incoming SMS | `WakeOnLockTest`, `FullScreenIntentWiringTest` | `test-notification-wake.sh` |

A heads-up popup is a *peek*: the panel stays asleep on a locked screen. Only a
full-screen intent is treated as a user-initiated wake, and the app had neither
the intent nor the permission — which is the whole bug.

- **The chain, all three links required.** `USE_FULL_SCREEN_INTENT` declared in
  the manifest (granted at install up to Android 13; on 14+ it is only
  auto-granted to calling/messaging apps, which the SMS role satisfies);
  `setFullScreenIntent()` on the incoming notification when
  `shouldWake(...)` holds; and `sms/FullScreenSmsActivity`, a translucent
  trampoline that sets `setShowWhenLocked`/`setTurnScreenOn`, forwards to
  `MainActivity` and finishes. The trampoline is deliberately *not*
  `MainActivity` — the platform FSI policy requires the target not be the app's
  primary launch activity. It also re-checks `isKeyguardLocked` on entry and
  bails, so a stale intent cannot hijack a screen the user is already using.
- **`shouldWake` is pure** (locked ∧ notifications ∧ receive-sound ∧ ¬privacy)
  so the truth table is unit-tested without a device. Privacy mode suppresses
  the wake because the trampoline would otherwise surface content over the
  keyguard.
- **Sticky channel demotion** (found on the way, independent of #300):
  `createNotificationChannel()` upserts and **cannot raise importance once the
  user has touched the channel**, so sound, heads-up and FSI die permanently and
  the app has no way back. `recoverDemotedChannel()` deletes and recreates when
  importance is below `IMPORTANCE_DEFAULT`. `IMPORTANCE_DEFAULT` itself is left
  alone — a deliberate "quiet" choice stays respected, only a broken channel is
  rebuilt.
- **Diagnostics** now reports `Full-screen intent: granted/denied`,
  `Channel importance: 4 (high)`, `Keyguard locked: yes/no` and
  `Wake screen for new messages: will wake/headsup only`, plus a hint pointing
  at Settings → Notifications when the permission is denied. That is what
  separates "our code didn't set it" from **OneUI's global "Full screen
  notifications" toggle**, which discards the intent outright and which no app
  can override. It reads the live permission and channel the notifier reads; it
  re-derives nothing.
- **`test-notification-wake.sh`** asserts each link separately (permission,
  channel importance, the screen actually leaving `mWakefulness=Asleep`, and the
  trampoline actually launching), because each can be present while the others
  are not. Verified **9 failures on the unfixed build, 0 after**.

  Four traps, each of which made the script assert the wrong thing. None are
  visible from the JUnit side:

  1. **The AVD has no lock credential.** `isKeyguardLocked` is false, the wake
     is correctly declined, and the test measures the absence of a keyguard
     rather than a broken fix. The script now sets and clears a PIN itself.
  2. **The notification record is consumed on launch.** The platform removes it
     ~250 ms after a full-screen intent fires — narrower than one adb
     round-trip, so polling `fullScreenIntent=` can never catch it. Asserting it
     would be a permanent flake. It is a documented `[SKIP]`; the trampoline
     launch observed in logcat is the real proof, and it is strictly stronger.
  3. **Channel importance dumps as
     `NotificationChannel{mId='messages_default'…mImportance=4}`**, not the
     `NotificationChannel(id=…importance=…)` form the grep first guessed.
  4. **A conversation row's label is in `content-desc`, not `text`**, wrapped
     in bidi isolate marks — so grep the marker alone, not a `text="…"` match.

  Asserting the *outcome* (wake + launch) rather than the notification
  artifact also sidesteps a race worth knowing about: once the screen is on the
  keyguard is unlocked, so the app re-posts the same notification **without** a
  full-screen intent, replacing the record entirely.

## Notification delete, passwordless backup, periodic backup (2026-10-05)

Branch `feat/own-mms-package`. Three GitHub issues in one pass:

| Issue | Feature | JUnit | Regression script |
|---|---|---|---|
| #285 | Notification "Delete" action trashes the newest message | `NotificationDeleteActionTest` | `test-notification-delete.sh` (4/4) |
| #290 | Opt-in periodic backup, Daily/Weekly | `PeriodicBackupSchedulerTest` | `test-periodic-backup.sh` (10/10) |
| #292 | Passwordless (plaintext) backup behind a warning | `BackupPasswordlessWiringTest` | `test-backup-unencrypted.sh` (3/3) |

- **#285** adds `sms/DeleteMessageReceiver` (non-exported), declared in the
  manifest and attached to the per-conversation notification next to Reply and
  Mark as read. It moves the newest incoming message to Trash, so it stays
  recoverable, and cancels the notification. The test asserts the action is on
  the notification via `dumpsys notification`, then fires the receiver as root
  (non-exported receivers are unreachable from a non-app shell) and checks
  `deleted_at>0` on a still-present row.
- **Notification actions** (follow-up to #285): Reply, Mark as read and Delete
  are each gated by their own setting, toggled from Advanced settings →
  Notifications — inline in the legacy Advanced screen, on the Notification
  settings screen in the new UI. `NotificationActionSettingsTest` pins the
  gating and both UIs; `test-notification-actions.sh` (11/11) flips the prefs
  and checks the posted action set with `dumpsys notification`.
- **#292** splits `Repository.backupDatabase` into a shared `writeBackup` and
  adds `backupDatabaseUnencrypted` (plain copy, recorded as `BackupFormat.RAW`).
  There is **no separate "back up without PIN" option**: in the "Set backup PIN"
  dialog, pressing **Save with the PIN fields empty** writes the plaintext
  database behind the warning; a PIN still produces the encrypted file. Both
  UIs behave the same. The test drives the real UI with `android layout` and
  checks the written file's SQLite magic.
- **#290** cannot prompt for the PIN in a background worker, so it schedules the
  same plaintext snapshot. The periodic toggle and Daily/Weekly cadence live
  **inside the "Set backup PIN" dialog** (not General settings).
  `PeriodicBackupScheduler` maps the stored interval to a WorkManager period
  (Daily=1d, Weekly=7d); `PeriodicBackupWorker` skips when the setting is off or
  privacy mode blocks backups. The test reads the schedule back from
  WorkManager's `WorkSpec.interval_duration` and its state, so the toggle's
  effect is proven, not just the switch position.

**New `android` CLI helpers in `env.sh`:** `layout_json`, `layout_center`,
`layout_center_exact`, `layout_has`, `tap_layout`, `tap_layout_exact`,
`scroll_to_layout`, `close_documents_ui`. `android layout` returns JSON with a
`center` and an `off-screen` flag, which the uiautomator-dump helpers cannot
express; note it nests children under `children` (not `content`) and only
captures app windows — the notification shade is SystemUI and stays invisible to
it, which is why #285 asserts on `dumpsys notification` instead.

## Message re-lock kept the body visible (2026-10-05)

Branch `feat/own-mms-package`. Locking a message, unlocking it, then locking it
again left the body readable: the toolbar said locked (toast + "Unlock" label),
but the session reveal cache was never cleared on lock, so `isLockedAndHidden`
stayed false for the rest of the chat session.

The reveal cache is now mutated through `MessageLockState` (lock removes,
unlock adds, `isHidden` is the single render/copy rule), so the DB flag and the
session cache can no longer drift. `MessageLockStateTest` pins the
lock -> unlock -> lock cycle, including that `onLock` removes only the targets.

`test-message-lock-auth.sh` gained a third phase that re-locks and asserts the
body is hidden again. Against the unfixed APK it ran 3 passed / 1 failed
(`re-lock did not hide the body`); after the fix it runs 4 passed / 0 failed.

## `:mms` module: three regression scripts (2026-10-03)

Branch `feat/own-mms-package`. The new `:mms` Gradle module (package
`com.anindra.messages.mms`) replaces the vendored `android-smsmms`. It is **not
yet wired into the app** — `app/build.gradle.kts` still depends only on
`:android-smsmms`, and `grep -r com.anindra.messages.mms app/src` is empty — so
none of these scripts assume new UI exists.

| Script | Covers | Needs an emulator |
|---|---|---|
| `test-mms-pdu.sh` (6/6) | `:mms` PDU + SMIL unit tests, counted from the JUnit XML | no |
| `test-mms-codec.sh` (21/21) | the three golden PDU vectors, octet for octet | no |
| `test-mms-store.sh` (6/6) | provider persistence: the store contract tests | no |

**All three are emulator-free.** They run `./gradlew :mms:testDebugUnitTest`
and read `mms/build/test-results/testDebugUnitTest/`, because the PDU and SMIL
layers are deliberately free of `android.*` imports (`mms/build.gradle.kts`
comments this) so they run under plain JUnit. None of them writes to the
telephony provider database, so they need neither `adb root` nor a writable
`mmssms.db` — the opposite of `test-mms-send.sh` / `test-mms-import.sh`, which
are emulator-only for exactly that reason. That is what makes them usable as a
pre-commit gate rather than as device sweeps.

### Counts come from the XML, not from Gradle's console

`--tests` filters are applied and the numbers are summed from the `<testsuite>`
attributes with `xml.etree`, so a `[PASS] 141 PDU/SMIL tests ran` line is the
count the test task recorded. The results directory is deleted first: a stale
XML from a previous green run is exactly how a script ends up passing on broken
code. `--rerun-tasks` is there for the same reason — Gradle's up-to-date check
would otherwise skip the run that is supposed to be the evidence.

`test-mms-pdu.sh` also requires all nine PDU/SMIL test classes to report a
result file. A `--tests` filter that silently matches nothing still exits 0, so
"the task ran" is not by itself evidence that anything was tested.

### `test-mms-codec.sh` is the one that matters, because a vector can stop being checked

`PduComposerTest` pins three PDUs octet for octet: an 11-octet
M-NotifyResp.ind, a 45-octet M-ReadRec.ind, a 105-octet one-part M-Send.req.
Nothing else would notice if those went away — the parser accepts whatever the
composer produced, so a round-trip test cannot see a wrong header order, and
deleting the assertion leaves the suite green. **Renaming or deleting a golden
test is therefore a silent wire-format regression**, and the script is built to
catch that first:

- the expected octets are **read out of the test source, never restated here**.
  Each vector is parsed from inside that one function's own `hexOf(...)` call,
  so a hex literal in a neighbouring test cannot be swept into it, and the test
  file stays the single copy. Restating the octets in the script would be a
  second copy that can drift from the first.
- the three lengths (11 / 45 / 105) are asserted, so a shortened vector fails
  even if the composer and the vector were edited in lockstep.
- each vector is cross-checked against the **production** field codes, read
  from `MessageType.kt` and `HeaderField.kt` rather than hardcoded — including
  `HeaderField.MMS_VERSION_1_2`, evaluated from its `(1 shl 4) or 2` source form
  so the short-integer encoding of MMS 1.2 is pinned too. Kotlin's `or`/`shl`
  are bitwise, which Python spells `|`/`<<`. If a constant is renamed the
  script **aborts loudly** instead of skipping the check.
- structural invariants that a hand-edited vector still has to satisfy: each
  text field null-terminated, and the M-Send.req body entry's declared
  header/data lengths accounting for exactly the octets that follow.
- finally it runs the three named tests and reads each `<testcase>` by name.

### `test-mms-store.sh` is a stand-in, and says so

The brief was to exercise provider persistence through the app's own
Diagnostics surface rather than emulator-only database writes, *if such a
surface exists*. **It does not.** `DiagnosticsReport` has exactly one MMS line,
`MMS carrier config:` — a per-SIM dump of `CarrierConfigManager` keys from
`SimMmsProbe.carrierFacts`. Nothing in the report reads `content://mms`, so
there is no way to seed a message through Diagnostics and read it back, and
nothing to assert against. Inventing that probe would be inventing UI.

So the script covers the persistence contract where it is specified today: the
store package's JVM tests, which drive `TelephonyMmsStore` against a
`FakeContentResolver`. It names all 23 guarantees it requires
(`boxValuesAreTheProviders`, `fiveIsFailedAndNotATemporaryBox`,
`pendingQueueAsksForDueRetryableRowsOnly`, `subIdProbeRunsOnceAndItsAnswerIsReused`, …)
so a renamed or deleted one fails the script even though the suite stays green.

**Follow-up when `:mms` is wired in:** extend `DiagnosticsReport` to report
provider state (row counts per box, a probe verdict) and rewrite this as a
`uiautomator` script asserting that text. That covers the *real* provider
rather than the fake, which is the whole point of the Diagnostics route.

### Verification — every script proven to fail

A script that passes on broken code is worse than no script, so each was run
against deliberately broken code. `--rerun-tasks` matters here: without it
Gradle skips the run and the script reads the previous green XML.

| Script | What was broken | Observed |
|---|---|---|
| `test-mms-pdu.sh` | `PduComposer.encodeContentType` start/type parameter order swapped | `[FAIL] 2 failing PDU/SMIL tests`, exit 1 |
| `test-mms-codec.sh` | same swap | `[FAIL] failing vector test(s): aOnePartSendReqIsPinnedOctetForOctet` |
| `test-mms-codec.sh` | golden test **renamed** | `[FAIL] PduComposerTest has no @Test named aNotifyRespIsExactlyElevenOctets…` + `only 2 of 3 reported a result` |
| `test-mms-codec.sh` | golden test **deleted** | both the missing-vector line and `only 1 of 3` |
| `test-mms-codec.sh` | vector **edited** to match a swapped composer | `[FAIL] failing vector test(s): aOnePartSendReqIsPinnedOctetForOctet` |
| `test-mms-codec.sh` | MMS-Version header dropped **and** vector + length + name updated in lockstep | `[FAIL] pins 9 octets, not the 11 the wire format requires` + `[FAIL] opens <Message-Type 0x83> <MMS-Version 0x92>` |
| `test-mms-store.sh` | `TelephonyMmsStore` never writes `sub_id` on persist | `[FAIL] 2 failing store tests` (`persistWritesMessagePartsAndAddresses`, `subIdProbeRunsOnceAndItsAnswerIsReused`) |
| `test-mms-store.sh` | `boxValuesAreTheProviders` **deleted** | `[FAIL] these provider guarantees are no longer asserted: boxValuesAreTheProviders` |

The MMS-Version row is the one that matters most: it is a change that keeps the
JUnit test, its vector, its length and its name all self-consistent, and only
the cross-check against the production constants catches it.

### Two traps worth keeping

- **A regex over JUnit XML silently mis-parses.** The obvious
  `<testcase name="…"[^>]*(?:/>|>.*?</testcase>)` cannot match a self-closing
  `<testcase …/>` when the alternation's second branch is tried first across
  lines, so only *some* test names are found — and the script reports "only 1 of
  3 named vector tests reported a result" for a run where all three ran. Use
  `xml.etree.ElementTree`, which gets this right.
- **Gradle failed with `java.io.EOFException`** on `:mms:testDebugUnitTest` once,
  with no compiler error and a `[PASS] the :mms test task produced results`
  line above it. A concurrent build in the same tree was the cause; a re-run
  was green. Not reproducible, and not attributable to these scripts — noted so
  the next agent does not chase it.

**Not in `run-all-tests.sh`.** That sweep installs the APK and drives the
emulator; these three need neither, so adding them would only lengthen a sweep
they do not belong to. Run them directly.

## Telephony declared as an optional hardware feature (2026-09-30)

Lint flagged `PermissionImpliesUnsupportedChromeOsHardware` six times, once per
SMS/MMS/phone-state permission. The manifest requested `SEND_SMS`, `RECEIVE_SMS`,
`READ_SMS`, `WRITE_SMS`, `RECEIVE_MMS`, `RECEIVE_WAP_PUSH` and `READ_PHONE_STATE`
but declared no `<uses-feature>` at all, so the platform inferred
`android.hardware.telephony` as **required**. Google Play filters on that
implied feature, which would have hidden the app from ChromeOS and
telephony-less tablets — the exact devices where the simulated-SIM path is the
only thing that works.

One opt-out before `<application>` fixes all six:

```xml
<uses-feature
    android:name="android.hardware.telephony"
    android:required="false" />
```

`aapt2 dump badging` on the installed APK is the proof, and it is worth reading
the two states side by side — this is not a cosmetic manifest annotation:

| | telephony line in badging |
|---|---|
| before | `uses-feature: name='android.hardware.telephony'` (required) |
| after | `uses-feature-not-required: name='android.hardware.telephony'` |

**Verification**

- `ManifestTelephonyFeatureTest` (5 tests) parses the source manifest and
  asserts the feature is declared exactly once, is `required="false"`, is a
  direct child of `<manifest>` before `<application>`, and that every
  telephony-implying permission actually declared is covered by the opt-out.
  The parser must set `isNamespaceAware = true` or `getAttributeNS` silently
  returns `""` for `android:*` and the tests pass vacuously.
- `scripts/test-telephony-feature-optional.sh` — pulls `base.apk` off the device
  and runs `aapt2 dump badging` on it, so a manifest that is right in source but
  dropped by the merge pipeline still fails. Also relaunches the app to confirm
  the optional feature did not break startup.

Confirmed both fail before the fix and pass after. Ran on the Android 11
(`Pixel_Android11`, SDK 30) emulator. `:app:lintDebug` errors went 80 → 74, the
exact six removed; the remaining 74 are pre-existing and unrelated.

## Permission-gated SIM/carrier reads: explicit `SecurityException` (2026-09-30)

Follow-on to the telephony `<uses-feature>` work. Lint flagged four
`MissingPermission` errors — `getConfigForSubId` in `MmsCarrierConfig` and
`SimMmsProbe`, `activeSubscriptionInfoList` in `SimCard` and `PhoneNumberUtils`.

**This was a signal problem, not a crash.** Every one of the four sites already
handled the denial at runtime: two used `runCatching { }` and two used
`catch (_: Exception)`, and `SecurityException` is an `Exception`. Lint's
`PermissionDetector` credits neither — it wants an explicit
`catch (SecurityException)` or a `checkPermission` call — so a *handled*
degradation read as an unhandled crash. Each call now sits in an explicit
`catch (_: SecurityException)` returning a documented default:

| site | default on denial |
|---|---|
| `MmsCarrierConfig.load` | null bundle → `MmsConfig` falls back to the AOSP MMS limits |
| `SimMmsProbe.carrierConfig` | null config → `SimMmsCheck` reports the SIM unknown |
| `SimCards.load` | empty SIM list |
| `SimCards.ownNumber` | null `SimCard.number` (READ_PHONE_NUMBERS is never requested) |
| `PhoneNumberUtils.resolveRegion` | the locale's country |

`ownNumber` is extracted from the inline `runCatching` so its "blank → null"
rule is readable; the rest are one-line catch changes.

**A pre-flight `checkSelfPermission` would have been the wrong fix.** The grant
can be revoked between the check and the call, so the catch is load-bearing.
A `checkSelfPermission` guard would also have meant skipping the read
entirely, losing the degradation to a locale default.

**Rejected: a shared `orDefaultOnDenied { }` helper.** Wrapping the reads in one
inline helper looked like the obvious cleanup, but lint does not see through the
lambda — all four errors came straight back (74 errors instead of 70). The
`SecurityException` catch has to be lexically in the calling method.

**Verification**

- `PermissionGuardTest` (3 tests) — source-level, because a JVM test has no
  package manager to revoke against. Asserts each gated call is followed within
  15 lines by a `catch (_: SecurityException)`, and that no `runCatching`
  creeps back in. **Confirmed 3/3 fail against the original code.**
- `scripts/test-permission-denied-degrades.sh` — the runtime half: revokes
  READ_PHONE_STATE and READ_PHONE_NUMBERS with `pm revoke`, relaunches,
  navigates Settings → Advanced → MMS support (the one screen that exercises
  both changed call sites via `SimMmsProbe.run`), and asserts no fatal. With the
  permissions denied the screen renders "No active SIM found", which is the
  degradation actually being observed rather than assumed. Re-grants on exit.
  **This script also passes against the original code** — correctly so, since the
  original was runtime-safe. It is a characterization test that locks the
  guarantee in, not a fail-before/pass-after regression; `PermissionGuardTest`
  is the one that discriminates.

Gotcha worth keeping: logcat splits a fatal across two lines
(`FATAL EXCEPTION: main` / `Process: <pkg>`), so the crash detector needs
`grep -A3` before matching the package name — filtering on `FATAL EXCEPTION`
alone matches nothing and the count is silently always 0. `grep -c` also exits 1
on a zero count, so a `|| echo 0` guard appends a second line and every
`[ -gt 0 ]` downstream errors out instead of failing. Both were caught by
running the detector against synthetic log fixtures.

`:app:lintDebug` errors 74 → 70; the remaining 70 are pre-existing and unrelated.

## Per-direction swipe actions + settings redesign (2026-09-27)

Two pieces of work that share the settings-row component.

### Swipe actions are configured per direction

There was a single "Swipe actions" on/off switch plus a "Reverse swipe actions"
switch, which can only express three states: both-off, archive-left, or
delete-left. Google Messages lets you pick an action per side, so left and right
now hold independent `SwipeAction` values.

`data/SwipeAction.kt` is the new enum (`OFF`, `ARCHIVE`, `DELETE`,
`MARK_READ_UNREAD`, `PIN`, `BLOCK`). `storageValue` is asserted by
`SwipeActionTest` because these are persisted ints — renumbering would silently
repoint an existing user's configuration at a different action.

**Migration.** `swipe_left_action` / `swipe_right_action` default to *absent*,
not to a value. On first read, if they are absent, the pair is derived from the
old `swipe_actions_enabled` + `reverse_swipe_enabled` booleans and written, so it
happens exactly once:

| old state | left | right |
|---|---|---|
| `enabled=false` | OFF | OFF |
| `enabled=true`, `reverse=false` | ARCHIVE | DELETE |
| `enabled=true`, `reverse=true` | DELETE | ARCHIVE |

`reverse_swipe_enabled` stays readable so a downgrade does not crash, but nothing
writes it any more. `swipe_actions_enabled` lost its property entirely — with
OFF available per direction there is no separate master switch to get out of
sync, and `swipeEnabled` is now derived as `left != OFF || right != OFF`.

A direction set to OFF is disabled with
`enableDismissFromStartToEnd` / `enableDismissFromEndToStart`, not just made
inert, so the row cannot be swiped that way at all. The 0.65 threshold and its
`confirmValueChange` guard are untouched.

**Every action is undoable** through a shared `withUndo` snackbar helper —
archive, delete, mark read/unread, pin and block all offer Undo. This needed two
new repository primitives (`setReadSuspend`, and `unpin`/`setPinned` on the
view model) because the existing ones could only move state one way.

### The picker is a settings row with a live preview

Modelled on quik (`quik-sms/quik`, the QKSMS successor — *not* Fossify, which
has no swipe settings at all). Its two rows carry the current action as a
subtitle, a trailing all-caps "CHANGE", and a **mock conversation row** showing
the real swipe colour and icon.

`SwipeActionPreview` reuses the gesture's own `background()`, `iconTint()` and
`icon()` helpers, so the preview cannot drift from the behaviour it advertises,
and it positions the icon with the same `SWIPE_ICON_INSET` token the real
`backgroundContent` uses. The disabled option is labelled "None" to match quik,
and the row's summary uses the neutral "Mark read/unread" rather than the
direction-dependent wording the swipe background needs for TalkBack — hence the
split into `labelRes()` and `a11yLabelRes()`.

`SettingsRow` grew two optional slots, `trailing` and `preview`. The clickable
moved from the inner `Row` to a wrapping `Column` so the preview is part of the
tap target, as it is in quik.

### Two bugs the preview itself exposed

Both were invisible in code review and only showed up in a pixel measurement of
a screenshot:

1. **The colour block was not flush with the row edge.** The preview `Row` packed
   its children at the start, so a trailing block ended ~48dp short of the edge
   and left a visible gap. Fixed by giving the mock row `weight(1f)`.
2. **The icon was centred in the block** rather than inset from the row's edge,
   which is where the real gesture puts it. Now 24dp from the outer edge.

Measured after the fix at 420dpi (1dp = 2.625px), both previews: block exactly
252px = 96.0dp, flush against the correct edge, glyph inset 29.0dp / 30.1dp from
the outer edge, vertical centre offset 0px. The ~5dp over the nominal 24dp is
the vector glyph's own padding inside its 24dp box, and it matches on both
sides.

`SwipeDirection.resolveAction()` and `revealsTrailingEdge` are pure and
unit-tested so the composable cannot re-introduce either.

### Two test bugs found on the way

- `test-swipe-threshold.sh` searched for `555-123-0731`, but the row renders the
  number grouped as `(555) 123-0731`, so it never found its row and reported
  "could not prepare test row". It now matches the subscriber part only.
- The picker dialog's rows were only clickable on the radio itself; tapping the
  label did nothing. Now `Modifier.selectable` on the row, matching the M3
  single-choice pattern.

### Tests

- `SwipeActionTest` — storage-value stability, round-trip, unknown-value
  fallback, and the three legacy migration cases.
- `SwipeDirectionTest` — per-direction resolution, OFF not leaking across
  directions, the revealed edge, and the preview token geometry (icon fits the
  block; the mock fits a 360dp screen).
- `test-swipe-actions.sh` — all six actions per direction through the real UI
  and the persisted value, both directions differing at once, "None" surviving a
  full leftward swipe, delete-plus-undo round trip, and the legacy migration
  (including that the new keys get written).
- `test-swipe-threshold.sh` — unchanged behaviour, still green.

## MMS carrier-config parity with GrapheneOS Messages — core hardening (2026-09-27)

The send/download path read **nothing** from `CarrierConfigManager`; every MMS
limit was hardcoded. On a carrier that caps image size or message size, the app
composed an oversized PDU, handed it to the network, and the user got a bare
"Not sent" with no way to tell the attachment was too big. Delivery and read
reports were always `VALUE_NO` regardless of the carrier.

Three new pure-logic seams carry the logic, all unit-tested:

- `data/MmsConfig.kt` — per-SIM values plus a `CarrierValues` interface so
  `from()` is testable with a fake. The `KEY_*` names mirror the public
  `CarrierConfigManager.KEY_MMS_*` constants; I pulled the literal strings out
  of `android.jar` with `javap -constants` rather than trusting memory, which is
  what caught that the keys are `maxMessageSize` / `enabledNotifyWapMMSC` and not
  the longer `MMS_*` spellings. `MmsConfigTest` asserts those strings directly,
  since a rename upstream would otherwise silently revert every limit.

  Only the six values the send path enforces are modelled. `recipientLimit` and
  the SMS-to-MMS thresholds are applied by the platform from the overrides
  bundle, so they were dropped rather than kept as a second source of truth that
  can disagree with it.
- `data/MmsImageSizing.kt` — `fitWithin` (cap + aspect ratio) and `sampleSize`
  (power-of-two subsampling that stays at or above target).
- `data/MmsRetry.kt` — GrapheneOS's AUTO_RETRY / MANUAL_RETRY / NO_RETRY split
  with exponential backoff, replacing a flat 5-minute cooldown that treated a
  missing data network the same as a carrier 404.

`sms/MmsCarrierConfig.kt` is the thin Android adapter and caches per
subscription, invalidated on resume so a SIM swap is picked up.

### Three things that only showed up on the device

- **`CarrierConfig` is not in `android.jar` at all** (hidden system API), so the
  constants have to come from `CarrierConfigManager` and the key strings are
  literal. `getConfigByComponentForSubId` is the non-deprecated replacement for
  `getConfigForSubId` and it returns an **empty bundle for this app**, which
  would silently discard every limit — verified on API 36. `getConfigForSubId` is
  used with a `@Suppress("DEPRECATION")` and a comment saying why.
- **Subsampling alone cannot hit the cap.** 900x600 at `inSampleSize=8` decodes
  to 113x75, not 100x67, because subsampling only lands on powers of two. The
  first version logged `900x600 -> 112x75` against a 100x100 cap; the explicit
  `createScaledBitmap` to `target` is what actually enforces it. The
  `test-mms-carrier-config.sh` downscale assertion is what caught this.
- **`enabledMMS` defaults to false on the AOSP emulator**, so an
  `if (!config.enabled) reject` guard made every MMS send fail and broke
  `test-mms-send.sh`. The guard was dropped: the platform already refuses MMS for
  a carrier that disables it, and duplicating the check only risks disagreeing
  with the platform.

### Also fixed while in here

- The composer read the whole attachment with `readBytes()` — an OOM risk on a
  large photo. Now streamed with a hard cap; oversize raises the same
  `TOO_LARGE` outcome as the composed-PDU check.
- `MmsSupport.shouldRetryDownload` / `DOWNLOAD_RETRY_COOLDOWN_MS` removed as dead
  code, with the covering test moved to `MmsRetryTest`.
- `MmsDownloadReceiver` never read the result code the platform delivers, so
  every failure was silently identical. It now classifies.

### Tests

- `MmsConfigTest` (7), `MmsRetryTest` (9), `MmsImageSizingTest` (8) — 289 unit
  tests green, no failures.
- `scripts/test-mms-carrier-config.sh` (8) — drives **real** carrier config via
  `cmd phone cc set-value` and asserts downscale, the size cap, and the report
  headers. Verified it fails on the pre-fix build: 3 failures (no downscale,
  `d_rpt`/`rr` both 0x81).
- `scripts/test-mms-retry.sh` (7) — asserts the request is made once, the result
  is classified, and the row is released from backoff on a non-transient
  outcome. Verified failing on the pre-fix downloader: 3 failures.
- Unaffected: `test-mms-send` (8), `test-mms-download` (5), `test-mms-import` (5).
- `test-chat-render.sh` and `test-multipart-sms.sh` fail, but they fail
  identically on a stashed baseline — pre-existing, not from this work.

### Traps worth remembering

- **`cmd phone cc set-value` rejects a bare `false`** ("Unable to parse null /
  false as a BOOLEAN") and `null` is not accepted for a boolean either, so a
  boolean override **cannot be reset to false** once set true. The only way back
  is `cmd phone cc clear-values -s SLOT`, which drops *every* override on the
  slot. Both scripts therefore save each key up front and re-read after every
  write, because a rejected write leaves the previous value silently in place and
  the test would otherwise pass against stale config.
- **`get-value` output is column-aligned and padded**, so the value is the last
  whitespace-separated field, and `get-value` **lags the write** — a single
  read-back races and reports a false failure.
- **The provider persists the `image/*` part row without its data blob** (both
  `_data` and `text` are null), so SQLite cannot be used to check the encoded
  dimensions. The assertion has to come from what the composer actually wrote,
  which is why `MmsComposer` logs the source -> encoded dimension transition.


||||||| 2003c10
## Crowdin sync repaired, and dates finally follow the locale (2026-10-02)

Finishes the community-translation setup for #175.

### The duplicate file trees

Crowdin held **822** strings for a project with 411. Two leftovers sat at the
project root alongside the real tree:

- `main/app/src/main/res/values/` — empty, "Nothing to translate"
- `strings*.xml` flat at the root — the pre-`preserve_hierarchy` copy, and the
  one the translations were attached to

That is also why French read **48%**: 410 translated on the flat copy, 410
untranslated on the nested one, averaged. Not a real number.

`preserve_hierarchy: true` was never the problem — the run log shows correct
paths. It only applies to uploads made *after* it was set, so the old flat files
had to be deleted by hand. Both leftovers deleted; now **411 strings, one
tree**, and the 12 languages sit at **97-98%**.

### `upload_translations` removed

It was a one-off repair left enabled after the wipe, and it is destructive:
every scheduled run pushes the repo's locale files over whatever a translator
has improved in Crowdin but not yet merged. Guarded in `CrowdinWorkflowTest`
(7 cases) and in `test-translations.sh`, so it cannot come back silently.

**Consequence worth remembering:** hand-editing `values-fr/strings.xml` is now
one-way. The app ships your edit, but Crowdin never hears about it, and the next
export for that language overwrites it with Crowdin's stored copy. There is no
setting that gives both durability and translator safety.

### Locale-aware dates

`"MMM d"`, `"EEE, MMM d"` and `"EEEE, MMM d, yyyy"` were literal patterns.
Field order is CLDR data, not formatting trivia, so French rendered `sept. 26`
where it reads `26 sept.`, and Japanese `9月 26` instead of `9月26日`.

Replaced with skeletons (`DatePatterns.kt`) resolved per locale through
`DateFormat.getBestDateTimePattern`, cached **per locale** — the old top-level
`val`s captured `Locale.getDefault()` at class-init, so a per-app language
change left the process formatting in the old language forever.

`formatGroupLabel` also hardcoded the English string `"Yesterday"`; it now takes
the resolved label from `R.string.time_yesterday`.

### Verification

- `test-date-locale.sh` (new): switches the per-app locale via
  `cmd locale set-app-locales`, backdates one conversation so the row falls
  through to the date branch, and asserts the **order** of day and month in
  en / fr / de / ja. English is the control.
- Fails before the fix (5 assertions, `sept. 26` / `Sept. 26` / `9月 26`) and
  passes after (8/8).
- Conversation rows expose sender+snippet+timestamp through `content-desc`
  because the row merges into one a11y node. Scraping `text=` finds only the
  title and the FAB — the trap that made the first run of this script report
  nothing at all.

### Still open

- **Moderated project joining is OFF.** `realgooseman` joined as Translator
  unmoderated. Turn it on in Settings -> Privacy & collaboration.
- **`test-chat-render.sh` fails** on a clean API 36 AVD: it greps `text=` for
  conversation rows, send-status and day dividers, all of which are
  `content-desc`. Pre-existing, unrelated to the date work, left unfixed rather
  than half-patched.
- `emulator-5554` holds a v24 database (`feat/combine-branches-with-ui-toggle`
  is `DB_VERSION = 24`, `main` is 21). Installing `main` over it crashes on
  launch with `Can't downgrade database from version 24 to 21`. Verification
  was done on a second AVD, `emulator-5556`.

## Crowdin community translations: locale plumbing made data-driven (2026-09-29)

Sets up the Crowdin panel for issue #175 so native speakers can correct strings
directly. Crowdin project `git-messages`, GitHub integration connected to
`an1ndra/Messages` branch `main` in *Source and translation files* mode;
translations come back as a PR on `l10n_main`, never straight onto `main`.

**Deliberately did not use a separate `translate` source branch.** The service
branch already keeps translation commits off `main`, so a second source branch
would only have added a merge in each direction. Created and reverted during
setup; `main` is the single source branch.

### Repo-side

- `crowdin.yml` at the repo root, committed to `main`.
  - `escape_quotes: 2` — the repo backslash-escapes apostrophes (`l\'application`)
    and French leans on them in nearly every string. Crowdin's default (`''`
    doubling) would have corrupted all 12 locales on first export.
  - `languages_mapping: android_code: {es-ES: es}` — Crowdin only offers
    `es-ES`, whose `%android_code%` is `es-rES`, exporting to `values-es-rES/`.
    That directory only serves Spain; es-MX users would silently fall back to
    English. Pinned to plain `es` so the existing `values-es/` is reused.
  - No credentials committed; the GitHub App authenticates.
- `values-hi-rIN/` → `values-hi/`, and `locales_config.xml` `hi-IN` → `hi`.
  Crowdin has no `hi-IN` language, only `hi`, so it would have exported to a
  *new* `values-hi/` beside the old one. Renaming first avoids two Hindi dirs.

### Tests: locale list was hardcoded in three places

`TranslationParityTest` asserted the exact 12 directory names and
`LocaleConfigTest` demanded exact parity with `locales_config.xml`. Crowdin
creates a `values-<lang>/` directory the moment a language is *added*, long
before anyone translates it — so the first new language turned CI red until
three files were hand-edited together.

- New `LocaleCatalog` (test source set) reads `locales_config.xml` as the single
  source of truth. Crowdin drives translations off the same list, so adding a
  language is now a one-file change.
- Parity checks iterate only locales that have content, so an untranslated
  language is tolerated while a translated one must still be complete.
- `test-translations.sh`: dropped `assert len(locales) == 12` for the same
  reason, and added a `crowdin.yml` consistency check (translation pattern,
  `es-ES: es` mapping, `escape_quotes: 2`, no `values-hi-rIN`, `values-hi`
  present).

Verified both ways: the checks **pass** with an empty undeclared `values-it/`
added (the Crowdin pre-creation case) and **fail** when `de` is dropped from
`locales_config.xml`, when the `es-ES` mapping is removed, and when `hi` is
reverted to `hi-IN`. `./gradlew testDebugUnitTest` 267/267 green;
`bash scripts/test-translations.sh` 4 passed / 0 failed on `emulator-5554`.

### Still open

- **The one-time import pulled in only 4 of the 12 shipped languages.**
  Reports show 5,339 words against a 1,358-word source (~3.9x = four languages).
  In: zh-CN 98%, zh-TW 98%, pt-BR 97%, es-ES 98%. At 0%: **ar, de, fr, ja,
  ko, pl, ru**. The split is exact — every language whose Crowdin code carries a
  region imported, every plain two-letter code did not. `hi` is not in the
  project at all.
  Strong suspect is the `languages_mapping: android_code: {es-ES: es}` block,
  added in the same change: a *partial* mapping appears to break default
  resolution for every language it does not mention. Reverted it to isolate
  the cause. The config check now validates the general invariant (if a mapping
  exists, every shipped locale must resolve to a directory that exists) rather
  than hardcoding `es-ES: es`, so a partial mapping cannot come back unnoticed.
- **`es-ES` is still unresolved.** Crowdin only offers `es-ES`, whose
  `%android_code%` is `es-rES`, so without a mapping Spanish exports to
  `values-es-rES/` and es-MX users fall back to English. Deliberately left
  unmapped while the import bug is isolated. Note the config check reads the
  tags in `locales_config.xml` (which say `es`) and so cannot see this on its
  own — it will be caught once a complete mapping is added, but not before.
  Also note `values-es-rES` only serves Spain, so renaming the directory is not
  a fix; the mapping is the only real option.
- **Project language list is Crowdin's 29 defaults**, not the 12 shipped
  languages. Needs trimming, and `hi` adding.
- **"Export only when fully translated" is off** on every language. Until it
  is on, a partial language exports a `values-<lang>/` with missing keys and
  `TranslationParityTest` fails on the `l10n_main` PR.
- **Date/time patterns are hardcoded in English order** in
  `ui/Components.kt` (`MMM d`, `EEE, MMM d`), `ui/MessageGrouping.kt`
  (`EEEE, MMM d`, `EEEE, MMM d, yyyy`) and `ui/TimeFormat.kt`. French needs
  `d MMM`. `Locale.getDefault()` is already passed for month/day *names*, so
  only the pattern order is wrong. **Crowdin cannot fix this** — it is a code
  change (CLDR skeletons via `DateTimeFormatterBuilder.getLocalizedDateTimePattern`).
  This is the second half of the #175 request from `realgooseman` and is
  untouched.

## Four long-standing test failures, all test bugs (2026-09-25)

Found while merging #247 and #248. Each was confirmed to fail on clean
`Develop`, and **every one turned out to be a broken assertion or a silent
abort in the script — no app code was wrong and none needed changing.**

### 1. `test-privacy-features.sh` aborted silently at step 2

`set -euo pipefail` plus this:

```bash
get_privacy_pref() {
    … | grep 'privacy_mode' | sed …
}
```

`privacy_mode` is **absent from the prefs XML until the user actually toggles
it**, because `SettingsStore` falls back to the default in code. So `grep`
exited 1, and the assignment `CURRENT=$(get_privacy_pref)` killed the whole
script with no message and exit 1. Every later step had never once run — the
test had been "failing" at step 2 for as long as it had existed.

Now defaults to `false` and tolerates the missing key. With that fixed the test
reaches step 3 for the first time, and a second fragility showed up: it opened
the notification shade with a single swipe and a single dump, so a shade that
wasn't ready yet made the title assertion fail while the body assertion passed
(consistent with a *closed* shade, where neither is visible). It now retries the
swipe and polls.

### 2. `test-trash.sh` asserted a string that has never existed

It checked `text="Manually"` on a manually trashed row. There is no `Manually`
string anywhere in `res/`, and never was in this flow: the Trash screen renders
the **deletion date** for a manual row, and a reason tag only for a
keyword-blocked one. The assertion was added in `a158feb` ("keyword-blocked
messages land in Trash with a reason tag") for the keyword scenario and ended up
sitting in the manual one, then survived the redesign that moved keyword
messages to Spam & blocked.

Now asserts the real behaviour: the date is shown, and a manual row carries no
reason tag.

**Left alone, worth a decision:** `TrashScreen`'s `TrashReasonTag()` branch is
now unreachable. Nothing sets `conversations.deleted_reason = 'blocked_keyword'`
any more — since the Spam & blocked redesign only the **message** row gets that
reason (`Repository.receiveBlockedMessage`). The tag can therefore only appear on
rows written by an older build, so it may be worth keeping as legacy-data
labelling or removing as dead UI. Not touched here.

### 3. `test-alphanumeric-sender.sh` matched against a bidi-isolated header

It asserted `text="A1-SRB"` on the chat header. The header is actually
`\u2066A1-SRB\u2069` — wrapped in Unicode LTR isolates by `BidiText.ltr()` so the
sender ID cannot be reordered inside RTL text, which is the whole point of the
feature. The app is right; the exact-match grep could never fire. New
`strip_isolates` helper in `env.sh`.

### 4. `test-spam-blocked.sh` raced the loading skeleton

"Unblock restores it to the inbox" did `sleep 6` then one dump. The conversation
list renders a **loading skeleton while the startup sync settles**, so the row is
simply absent from that dump. It passed 3 of 4 runs. Now polls via the new
`wait_for_text`, which is the fix the earlier `ui_tags | grep -q` note in this
file called for but which was never applied to this assertion.

### `env.sh` additions
- `wait_for_text "<text>" [attempts]` — polls past the startup skeleton. Uses
  `grep -c`, never `grep -q`.
- `strip_isolates` — removes U+2066/U+2069 so assertions can match visible text.

### Screenshots removed
`receive-sms.sh` called `shot` twice on **every** invocation, so any test using
that helper silently wrote PNGs — against the rule that screenshots need the
user's permission. Both `shot` calls are gone; `07-list-with-unread.png` and
`06-incoming-notification.png` were deleted. The privacy test still passes 5/5
and asserts through uiautomator dumps only.

### Results
`test-trash.sh` 10/10 · `test-alphanumeric-sender.sh` 8/8 ·
`test-spam-blocked.sh` 9/9 · `test-privacy-features.sh` 5/5, each re-run to
confirm stability. No JUnit test added, because no app code changed — the defect
was in the tests themselves.

## Grouped notifications: expanding shows the conversation (#219-09-25)

✅ USER SUGGESTION (#219 comment 5827316702): "make notification shows all messages
of 1 person when we extend that notification instead of just showing last
message, but that's not issue or bug".

Each post replaced the record with a `BigTextStyle` body, so expanding showed one
long message and nothing of what came before it. Now
`NotificationCompat.MessagingStyle`, carrying the sender's recent messages, the
conversation title, and a `Person` per side.

The notification id was already stable and untagged per conversation, which is
what makes the grouping possible — the same key that dismissed one conversation's
notification now accumulates that conversation's history.

### It has to be rebuilt, not appended

`notify(id, …)` **replaces** the record. So the history cannot be added to
incrementally: every post re-reads the last few messages
(`Repository.recentMessageLines`) and re-adds them. `NotificationHistory.window`
keeps the newest 5, oldest first (the order MessagingStyle expects) and drops
blank lines, which the system would otherwise render as empty rows.

### `setGroupConversation(true)` had to go

The first version set it, on the assumption that it was needed to make the
notification behave like a conversation. It made Android mint an **extra system
record** with id `2147483647` and key `…|ranker_group|…` — a phantom third
notification that broke the record count and the per-conversation dismissal. The
history renders correctly without it, and the script now asserts no `ranker_group`
record appears so it cannot creep back.

### The `grep -q` / `pipefail` trap, again
`record_exists() { block_for_id … | grep -q "NotificationRecord"; }` reported
"no notification record" *while the very next assertion read three message lines
out of the same block*. `grep -q` exits on its first match, `awk` upstream dies of
SIGPIPE, and `set -o pipefail` turns that into a false negative. `blk_has()` uses
`grep -c` instead. This is the same trap already recorded for `ui_tags | grep -q`
earlier in this file.

### Tests
- `NotificationHistoryTest` (6) — **227 JUnit / 0 failures**
- `test-grouped-notifications.sh` **15/15**, verified to **fail before the fix**:
  ```
  [FAIL] the record carries 0 of 3 messages
  [FAIL] the record is not a MessagingStyle
  [FAIL] the record has no conversation title
  [FAIL] expected 5 lines after 8 messages, got 0
  [FAIL] the first sender's history changed to 0 lines
  ```
  Asserts one record per sender, the 5-line cap, the newest line last, two senders
  never sharing or clobbering history, per-conversation dismissal still working,
  and `number=1` unchanged so the launcher badge is unaffected.
- debug and R8-minified release both build

### Pre-existing failures, unrelated to this change
All three confirmed to fail identically on clean `Develop`:
- `test-alphanumeric-sender.sh` — "chat header lost the sender ID"
- `test-privacy-features.sh` — stalls at step 2, "Enable privacy mode"
- `test-trash.sh` / `test-spam-blocked.sh` — see the retention entry above

`test-notification-badge.sh` still passes 7/7, which is the important one: the
badge invariant (`number=1` per record) survives the restyle.

## Retention: purge Spam & blocked too, and make the window configurable (2026-09-25)

✅ USER SUGGESTION (#219 comment 5827316702): "just like everything is purged in
trash after 30 days, you should implement that for Spam & blocked too, and
eventually give us to choose if we want for 30 days or more."

`purgeOldTrashSuspend()` selected only `conversations.deleted_at > 0`, so it
reached neither of the other two filed-away buckets, both of which accumulated
forever:

- keyword-blocked messages — `messages.deleted_at > 0 AND blocked_reason != ''`
  in a conversation that is still active, so the conversation predicate misses
  them entirely
- blocked senders — `conversations.blocked = 1` with `deleted_at = 0`

Three buckets now share one `RetentionPolicy`, with the window user-selectable
(7 / 30 / 90 / 365 days) under **Settings → Advanced → Auto-delete**.

Blocked senders are aged by `conversations.timestamp` rather than a deleted_at
that is never set for them, so a sender who keeps texting is not purged out from
under the user while they are reading it.

### A crash this introduced, and the trap behind it

The first version aliased the columns (`DELETE FROM messages m WHERE
m.deleted_at>0 …`). Android's SQLite rejects that:

```
SQLiteException: near "m": syntax error, while compiling:
DELETE FROM messages m WHERE m.deleted_at>0 AND m.blocked_reason!='' AND …
```

It threw from `MessagesApplication.onCreate`, so the app crashed on **every
launch** and the purge never ran — the feature was worse than the gap it filled.
Every column in the predicates is unambiguous within its own table, so the
aliases are gone, and `RetentionPolicyTest` asserts no predicate qualifies a
column so the shape cannot come back.

### Tests
- `RetentionPolicyTest` (7) — **229 JUnit / 0 failures**
- `test-retention.sh` **12/12**, verified to **fail before the fix**:
  ```
  [FAIL] old keyword-blocked message survived
  [FAIL] old blocked sender survived
  [FAIL] blocked sender conversation row survived
  [FAIL] Auto-delete section not found in Advanced
  ```
- The script seeds backdated rows and restarts the app, because the purge only
  runs from `Application.onCreate`. It clears `retention_days` at the end so it
  stays idempotent — the first version left it at 7 and the "defaults to 30"
  assertion failed on the second run.
- debug and R8-minified release both build

### Pre-existing failures, unrelated to this change
`test-trash.sh` ("trash row reason tag missing") and `test-spam-blocked.sh`
("conversation not restored to the inbox") both fail identically on clean
`Develop`; confirmed by stashing this branch and re-running.

## Auto-delete: in Advanced, per-folder windows, per-bucket switches (2026-09-25)

✅ USER REQUEST, after #247 shipped: move the Auto-delete setting into Advanced,
let the user choose how long each folder keeps things, and choose which buckets
are cleaned up at all.

### Two windows, not one

`RetentionPolicy.daysFor` resolves a window per bucket: Trash keeps its own,
and both Spam & Blocked buckets share one because they are a single folder. So
the two numbers are set where they apply rather than in one place governing
things the user thinks of as separate.

- `purgeRetainedSuspend(buckets, trashDays, spamDays)` computes a cutoff per
  bucket, so the two windows really are independent.
- `RetentionBucket` names the three buckets; `activeBuckets(enabled, trash,
  keywordMessages, blockedSenders)` turns the four switches into the set the
  purge acts on. Empty means nothing is touched, so "master off" and "all three
  off" are the same path.
- Blocked senders and deleted chats are the only buckets that remove a
  conversation row. A keyword-blocked message is removed on its own, so the
  cleanup never takes away a chat the user is not looking at.

### The setting is reachable from the folder it governs

`AutoDeleteDurationAction` is an app-bar icon on Trash and on Spam & Blocked,
with the current window in its accessibility label ("Auto-delete after 30
days", or "Auto-delete is off for this folder" when that folder's buckets are
both off). It was a full-width row above the tabs first, which pushed the list
down and looked wrong.

### A collapsible layout that was reverted

Advanced was also restructured into collapsible groups, with the rarely used
options (swipe direction, permanent delete, links, sounds, diagnostics,
auto-delete) folded behind headers. It was reverted at the user's request: the
headers did not match the plain rows around them, and a different background on
a header read as worse than the flat list, not better. Advanced is back to its
original flat groups, with Auto-delete added as one more group and Diagnostics
still last. `CollapsibleSettingsGroup` is gone.

### Tests
- `RetentionPolicyTest` (14) — **241 JUnit / 0 failures**, up from 7
- `test-retention.sh` **37/37**, up from 12/12, verified to **fail before the
  change**:
  ```
  [FAIL] Auto-delete section not found in Advanced
  [FAIL] blocked senders were purged even though the option is off
  [FAIL] rows were purged with auto-delete switched off
  ```
  The assertions that matter are the asymmetric ones: one bucket switched off
  leaves exactly that bucket's rows alone while the other two are still purged;
  the master switch off purges nothing; and the two folder windows stay
  independent when one is changed from the other folder's page.
- `scroll_top` and `scroll_to` were added because `wait_for_text` neither
  scrolls nor scrolls back up, and several Advanced rows sit outside the first
  screen
- debug and R8-minified release both build

### Two traps worth remembering
The dumped text for "Spam & Blocked" is literally `Spam &amp; Blocked`, and the
helpers `re_escape` their search argument, so searching for `&` or for `Blocked`
cannot match it — only the escaped form can. And after `pref_reset` deletes the
retention keys, editing them with `sed` writes nothing and the code defaults
apply, so a test that wants a bucket off has to switch it through the UI.

## #219 follow-up: SIM switch hidden + trashed thread resurrected (2026-09-25)## #219 follow-up: SIM switch hidden + trashed thread resurrected (2026-09-25)

✅ USER REPORT (#219 comment 5827316702). The same comment confirms the earlier
#219 notification fix and the spam contact names now work. Two bugs came out of
it, and both were already known-but-regressed rather than new.

### 1. The SIM switch fix had been reverted, and the test enforced the bug

The composer gated the control on `sims.size > 1 && draft.isBlank()`, so typing
hid it and dismissing the keyboard never brought it back, because the draft was
still nonblank. There was no IME state in the condition at all.

This was fixed once already and then lost:

- `2a61769` (Sep 22 12:42) SIM switcher ships with the `draft.isBlank()` gate
- `e637b71` (Sep 22 19:01) "…+ SIM always visible" removes the gate — the fix
- `f0d6a77` (Sep 22 20:43) `Revert "Merge pull request #233…"` **reintroduces
  the gate 1h42m later**, collateral from untangling the spam-blocked stack
- `2cc3566` (Sep 25) PR #243 changes the icon design and slot numeral only

The reply "Fixed it need to merge it" on the issue was accurate about intent, but
the fix had already been reverted the previous evening, so nothing flagged it.

`test-sim-inputbar.sh` made it durable: commit `dd1d830` flipped the expectation
to "hidden while typing" to match the code, and its return-check only passed
because it cleared the draft with four backspaces instead of dismissing the
keyboard — i.e. it tested the workaround, not the reported sequence.

Now `SimSwitcher.shouldShowSwitch(simCount)` is the single rule for showing the
control (composer and three-dot menu), the gate is gone, and the script asserts
the reported sequence: type → dismiss keyboard → still there.

### 2. A keyword-blocked message resurrected a trashed conversation

`receiveBlockedMessage()` called `getOrCreateConversationBlocking()`, which
resets `conversations.deleted_at = 0` so an ordinary new message revives a
trashed thread. For a blocked message that is wrong: the message is stored
soft-deleted, so the conversation came back into the inbox with nothing in it
(the snippet only ever picks up non-deleted messages) — a row the user had
emptied, reappearing blank.

`InboundIngest.restoresTrashedConversation(kind)` now gates it: only
`InboundKind.NORMAL` restores. `receiveSpamMessage()` had the same latent bug
and now passes `InboundKind.BLOCKED_NUMBER`.

Two comments described the old Trash behaviour and had to go, since they made
the current code look broken on read:
- `SmsReceiver.kt` "move its conversation to Trash"
- `Repository.kt` "recoverable via Trash → Restore"

Neither ever happened since `e637b71`. Blocked messages live in
**Spam & blocked → Messages**; the Trash message query deliberately excludes
them (`FolderRows.TRASH_SELECT` has `blocked_reason=''`).

### 3. Stale saved SIM rendered the slot numeral as "0"

The numeral was `sims.indexOfFirst { it.subscriptionId == currentSimId } + 1`, so
a persisted id that no longer matched any SIM gave index `-1` and the icon showed
**"0"** until tapped. Only reachable with exactly two SIMs, since 3+ renders a
generic "D".

`SimSwitcher.selectedIndex()` now falls back to 0 the same way `next()` already
did. The deeper cause was the state, not the display: both normalisation sites
in `ChatScreen` only handled `currentSimId == -1`, so a stale id survived into
`vm.send(...)`, and `SmsSender.manager()` guards only `-1` before calling
`createForSubscriptionId(staleId)` — which throws on a real device. Both sites
now test `sims.none { it.subscriptionId == currentSimId }`, which covers `-1`
and stale alike.

### Tests
- `SimSwitcherTest` +4, `InboundIngestTest` (3) — **221 JUnit / 0 failures**
- `test-sim-inputbar.sh` **12/12**, `test-keywords.sh` **19/19**
- Both verified to **fail before the fix**:
  ```
  [FAIL] Switch SIM missing after dismissing the keyboard
  [FAIL] conversation was resurrected into the inbox (deleted_at='0')
  [FAIL] slot numeral wrong for a stale saved SIM (renders 0)
  [FAIL] stale pref left as '99' instead of being normalised
  ```
- debug and R8-minified release both build

Note: one `test-keywords.sh` run failed a single assertion immediately after the
49s release build and passed on the three runs after it. Treated as AVD timing,
not a regression — the keyword path is untouched by this change.

### Still open from the same comment (suggestions, not bugs — no rush)
- 30-day auto-purge exists for Trash only (`purgeOldTrashSuspend`, keyed on
  `conversations.deleted_at > 0`). It covers neither keyword-blocked messages
  (conversation stays active) nor blocked-number conversations
  (`conversations.blocked = 1`), so both accumulate forever. Making retention
  user-configurable means threading a setting into the current `days = 30`.
- Notifications use `BigTextStyle`, so expanding one dumps the whole text.
  Grouping per conversation with inline reply needs `MessagingStyle`.

## Comment density pass (2026-09-25)

✅ USER REQUEST on the badge work (#244): the code had picked up far more
comments than the repo rule allows — "no comments unless genuinely
non-obvious".

- `Motion.kt` went from 24 comment lines out of 88 to 3 of 66. Most restated
  the name of the constant or function directly beneath them, e.g.
  `/** M3 duration tokens, in milliseconds. */` above `DURATION_SHORT4 = 200`.
- The badge work went from ~35 comment lines to 2. Four call-site comments
  restated `clearConversationNotification`'s own name, and the narration of the
  old `cancelAll()` behaviour was left to `git blame`.

What survives is the genuinely non-obvious part: that launchers aggregate the
notification number, so it is 1 per conversation, and that the motion helpers
collapse to an instant `snap()` under reduce-motion so call sites never branch
on the accessibility option themselves.

No behaviour change. 209 JUnit / 0 failures on `Develop` at the trim, 214 after
the badge merge. (#245, #244)

## Launcher icon badge shows no unread count (2026-09-25)

✅ USER REPORT (#227 comment 5827727611): notifications arrive, but the app icon
shows **no count** while other apps on the same launcher do. A second, separate
defect turned up while verifying it.

### 1. No badge number was ever published

The app called `notify()` without `setNumber()`. That is the field Android
launchers read for the **numeric** badge; launchers that render a count rather
than a plain dot show nothing at all without it. The app had no
`setNumber`/`setBadgeIconType` call anywhere, and no total-unread query existed.

- `NotificationHelper.show()` now publishes a badge number. Verified visually on
  `emulator-5554` with **Lawnchair** installed as the home app: the icon shows a
  count, where the stock AOSP Launcher3 only ever draws a dot.
- The number is **1 per conversation, not the unread total**. Launchers that
  render a count *aggregate across the app's active notifications* - Lawnchair
  sums them, and publishing the unread total rendered a badge of **45** for three
  notifications that each carried 15. With 1 each the badge is the number of
  unread conversations, which is also what messaging apps conventionally show.

### 2. Opening any chat wiped every notification (found while verifying)

`ChatScreen` called `NotificationManagerCompat.cancelAll()` when a conversation
opened, so opening **one** chat cleared the notifications of **all** the others.
The launcher badge is derived from active notifications, so the count vanished
as soon as any chat was opened - the badge could never stay up.

Reproduced on `emulator-5554`: two unread senders, 3 active notifications,
opened one chat -> **0** notifications left, while the other conversation was
still unread.

- New `NotificationHelper.clearConversationNotification()` cancels only that
  conversation's message notification and its `"failed"`-tagged sibling
  (delivered-failed posts under a tag, so the tag has to be cleared too).
- Replaced `cancelAll()` at all four sites: `ChatScreen` and three in
  `MainActivity` (open from a conversation row, open from a notification, and
  `onNewIntent`).
- After the fix the same sequence gives **3 -> 2**: only the opened
  conversation's notification is dismissed.

### Not changed: the per-tone notification channels

`ensureChannel()` keeps 7 channel ids and deletes the other 6 on every post, so
changing the sound setting deletes the old channel - and with it that channel's
notifications, which also drops the badge and produces Android's "1 category
removed" message. That is real, and it was reproduced, but it is a separate
defect from the count not appearing at all, and fixing it means collapsing the
per-tone channels into one stable channel - a behaviour change to the sound
picker that has already been reviewed. Left for its own change.

### Tests
- `BadgePolicyTest` (5 tests): the per-notification value is 1, a non-positive
  count is never published, and the dismiss pair is scoped to one conversation.
- `scripts/test-notification-badge.sh` **7/7**, verified to **fail before the
  fix** with the exact reported symptoms ("no positive badge number", and
  "3 -> 0" notifications on opening a chat) and pass after.

Two things worth knowing about verifying a badge, both learned the hard way:

- **The stock AOSP Launcher3 can only draw a dot.** It has no numeric badge
  implementation, so no app can show a number on the emulator's own home screen.
  Lawnchair (FOSS, from its GitHub releases) was installed to prove the count
  visually.
- **A launcher needs notification-listener access**, and granting it by writing
  `settings put secure enabled_notification_listeners` does *not* work - the
  system still reports 0 enabled listeners. `cmd notification allow_listener` is
  the supported route. Without it the launcher sees no notifications and badges
  nothing, which looks exactly like an app bug.
- **`am force-stop` cancels the app's notifications**, so a test that restarts
  the app before opening a conversation destroys the very notifications it is
  trying to observe. Deliver the open-conversation intent to the running app
  instead.

Files: `sms/SmsSupport.kt`, `sms/BadgePolicy.kt`, `data/Repository.kt`,
`ui/ChatScreen.kt`, `MainActivity.kt` · tests: `BadgePolicyTest`,
`test-notification-badge.sh`

## Shared motion tokens + conversation list placement motion (2026-09-25)

✅ USER REQUEST: audit the app for missing animation, then implement it.

Audit result: the app had good motion in a few places (route transitions, bubble
entrance, shared shimmer) but **no motion tokens at all** — durations were inline
literals (`tween(300)`, `tween(150)`, `tween(1100)`) and everything used the
pre-M3 `FastOutSlowInEasing`. Worse, the accessibility **reduce-motion** setting
was only honoured in three places, so turning it on still left the FAB morph,
tab scale, swipe background, selection toolbar and emoji panel animating.

- **New `ui/theme/Motion.kt`**: the M3 duration tokens, the three emphasized
  easing curves, and the spring constants, plus `motionTween()` / `motionSpring()`
  which return a normal spec or an instant `snap()` when reduce-motion is on, so
  callers never branch on the accessibility flag themselves. The pure accessors
  live on the `Motion` object so they are unit-testable, and the spec builders are
  deliberately **not** `@Composable` so `MotionTest` can call them directly.
- **Conversation list placement motion**: `Modifier.animateItem()` on each keyed
  row, with token-driven fade-in/out and a spatial spring for placement. A
  modifier had to be threaded through `SwipeableConversationItem` →
  `SwipeConversationItem` → `ConversationRow` to reach the row.
- **Reduce-motion now honoured everywhere**: navigation slides/fade, bubble
  entrance, shared shimmer, swipe background colour, Start Chat FAB morph,
  ExpressiveTabs, the chat selection toolbar, and the emoji panel.
- **Two motion bugs fixed while wiring the tokens**:
  - `ExpressiveTabs` was springing **colours** (not a physical property) and had
    `indication = null`, which killed the M3 state layer. Colours now use an
    emphasized tween, and the ripple is back alongside the press scale.
  - The emoji panel's `AnimatedVisibility` had no authored enter/exit and now
    expands/shrinks from the top on the M3 curve.

Note on scope: the remaining audit findings (chat status/date-separator
transitions, schedule-picker step swap, Toast→Snackbar for contextual actions,
tab content crossfades) are **not** in this change. They are polish, not
accessibility gaps, and are better as their own commits.

Tests: `MotionTest` (10 tests: M3 duration values, the three emphasized curves,
reduce-motion collapsing durations to 0, linear easing under reduce-motion, and
both spec builders degrading to `snap`) and `test-motion-system.sh` **16/16**.

Script notes worth keeping — three of the failures during this work were bugs in
the test harness itself, not the app:

- **`ui_tags | grep -q X` is a false negative under `set -o pipefail`.** `grep -q`
  exits on the first match, `ui_tags` dies with SIGPIPE, and the pipeline reports
  failure even though the text was right there. `has_text()` uses `grep -c`
  instead, which consumes all input. **`test-message-actions.sh` still has 8 of
  these and is latently flaky for the same reason.**
- **The conversation list shows its loading skeleton while the startup sync
  settles**, so a single dump taken right after a mutation reads as "empty list".
  All assertions now poll (`wait_for_text` / `wait_for_absent`).
- **Matching rows by substring is ambiguous**: the options sheet's "Archive" is a
  substring of the top bar's "Archived" icon, and `row_center` checks
  `content-desc` first, so the script was pressing the Archived button. Sheet
  actions use `tap_exact` now.

Verified on `emulator-5554` with uiautomator (no screenshots): archiving, undo
re-insertion, swipe, chat navigation, bubble rendering, emoji panel open/close,
and the whole flow again with Accessibility mode + Reduce motion enabled.

Animation *timing* itself is not asserted, because a `uiautomator dump` takes
roughly a second and cannot sample a 200 ms transition.

Files: `ui/theme/Motion.kt`, `ui/ConversationsScreen.kt`, `ui/ChatScreen.kt`,
`ui/ExpressiveTabs.kt`, `ui/Components.kt`, `MainActivity.kt` · tests:
`MotionTest`, `test-motion-system.sh`
## Import source picker follows the M3 radio button guidelines (2026-09-25)

✅ USER REQUEST: the "This app's backup / A .sqlite3 or encrypted backup file from
Messages" rows did not look or read right; follow the Material 3 dialog and radio
button guidelines.

The old rows were **not** radio buttons in any meaningful sense: each rendered
`RadioButton(selected = false)`, nothing was ever selected, and tapping a row
immediately fired the file picker. That breaks the guidelines on three counts —
a radio group must have one option pre-selected, a radio must reflect selection,
and *"radio buttons should take effect immediately, unless they're in a dialog or
page that needs to be saved"*.

- `ImportRadioGroup` replaces `ImportChoiceRow`: a `selectableGroup()` column of
  rows, each `Modifier.selectable(role = Role.RadioButton)` with a
  `RadioButton(selected = …, onClick = null)` inside, so **the whole row is the
  tap target** (guideline: selecting works by tapping either the radio or its
  label) and TalkBack gets real radio-group semantics instead of two fake radios.
- **One option is pre-selected** (Messages) and the group cannot be emptied,
  which is why the confirm button is never disabled — matching *"disable
  confirming actions until a choice is made"* without needing a disabled state.
- **Selection no longer acts on its own.** The dialog now has a trailing
  **Continue** button that opens the picker, with **Cancel** as the dismissive
  action, per *"the confirmation button is always closest to the edge"*. This is
  also the fix for the old behaviour where tapping a row launched the file
  picker with no way to change your mind.
- The Merge/Restore dialog got the same treatment, so both import steps now look
  and behave the same. Its descriptions stay, because "keep what is here" vs
  "delete it first" is the whole point of that choice.
- Labels shortened to **Messages** and **SMS Import / Export**, each with the
  file extensions it reads: **Messages (.enc)** and **SMS Import / Export (.zip,
  .json)**. Note `.enc`, not `.asc` — that is what `exportEncryptedDatabase`
  actually writes (`messages_backup_<ts>.enc`); a legacy raw `.sqlite3` is still
  accepted by the picker.
- Dropped the "Choose which app made the backup." intro line and the per-option
  descriptions at the user's request, and deleted the three strings left unused
  when the separate sms-ie row was removed.

Verified on `emulator-5554` with uiautomator (no screenshots): the dialog reads
`Choose backup to import / Messages (.enc) / SMS Import / Export (.zip, .json) /
Cancel / Continue`; Messages is pre-selected; tapping the *SMS Import / Export*
label moves the selection and leaves the dialog open; **Continue** then opens the
SMS Import picker, and picking Messages first opens the app's own picker.

- `test-sms-ie-import.sh` still 14/14, `testDebugUnitTest` green.

Files: `ui/SettingsScreen.kt`, `res/values/strings_settings.xml`,
`res/values/strings_components.xml` · tests: `test-sms-ie-import.sh`
## Import: one entry point for both backup sources (2026-09-25)

✅ USER REQUEST: fold the sms-ie option into the existing "Import messages" row and
make the choice obvious, then wipe the app and restore a real backup.

- **Settings → "Import messages"** now opens a **"Choose backup to import"**
  dialog: *This app's backup* (`.sqlite3` / encrypted) or *SMS Import / Export*
  (`.zip` / `.json`). The separate "Import from SMS Backup & Restore" row is gone,
  so there is one import entry instead of two near-identical ones.
- Both sources then get the **same "How should this backup be applied?" step**
  (Merge / Restore), which is what people actually need to decide. Previously
  sms-ie could only ever merge.
- **Restore now works for sms-ie too**: `Repository.importSmsIeFrom` takes an
  `ImportMode`, and REPLACE calls the new `clearAllMessages()`, which drops
  messages, conversations and participants in one transaction and leaves
  settings alone. The wipe decision lives in `SmsIeBackupPolicy.clearsExisting`
  so it is unit-testable without a database.
- The `sms_ie_probe` debug extra accepts `sms_ie_probe_mode=replace` so the
  Restore path is scriptable like Merge already was.

Verified on `emulator-5554` through the **real UI** (uiautomator, no
screenshots): Settings → Import messages → SMS Import / Export → picked
`messages-2026-09-25.zip` in the SAF picker → Restore (replace all) → **523
messages / 141 threads**, exactly the backup's contents. Separately, the system
provider was cleared too and the app re-imported the same file: the app store
ends up at exactly 523 messages with the 8 MMS images present in
`files/mms-import/`.

One thing worth knowing: **this app mirrors the system SMS/MMS provider**, so
wiping only the app's own store is not enough on a device whose provider still
holds messages — the next launch syncs them back. Restore is exact on a fresh
install (empty provider), which is the case that matters for a user moving from
another messaging app.

- Fixed a leak in `test-sms-ie-import.sh`: cleanup removed its DB rows but left
  the copied MMS attachments in `files/mms-import/`, so each run orphaned an
  image. Now removed too.
- `test-sms-ie-import.sh` also covers Restore: seeds a canary message, imports
  with `replace`, and asserts the canary is gone, all 3 backup records are back,
  and no empty conversations survive. **14/14** (the script wipes the app in that
  section by design, so it is not for a device holding real data).

Files: `data/Repository.kt`, `data/SmsIeBackup.kt`, `MainActivity.kt`,
`ui/SettingsScreen.kt`, `res/values/strings_settings.xml` · tests:
`test-sms-ie-import.sh`, `SmsIeBackupTest`
## Import backups from SMS Import / Export (sms-ie) (2026-09-25)

✅ USER REQUEST: let users import the backup files produced by
[tmo1/sms-ie](https://github.com/tmo1/sms-ie) instead of being stuck with our own
encrypted backup format.

Validated against the **real app**, not just the spec: installed
sms-ie v2.11.1 on the emulator, seeded real SMS through the radio, had the app
export `messages-2026-09-25.zip` (523 records) and imported that file here —
523 messages landed, MMS images rendered in the chat, no crash. Two real-format
details came out of that and are covered by tests:

- **Every provider column is exported as a JSON string** (`"date":
  "1790279506000"`, `"type": "1"`, `"m_type": "132"`), because Android stores
  those columns as text. `SmsIeBackup` therefore coerces via `optInt`/`optLong`
  and there is a test pinned to the verbatim export shape.
- MMS binary parts live in the ZIP's `data/` directory and are matched to parts
  by the **filename only**; the `_data` tag carries the full source path.
  `SmsIeReader` strips that path and resolves the basename.
- v2 (2.0.0+) is a ZIP of `messages.ndjson` (one record per line) plus `data/`;
  v1 (<2.0.0) is a bare JSON array. Both are accepted — the v1 path was
  exercised end to end as well.
- `sub_id` is deliberately dropped rather than restored: sms-ie does this too by
  default because restoring `sub_id` makes messages disappear on Android 14+.
- Contact names (`__display_name`) are ignored on purpose; this app resolves
  names from the device contacts, so a stale name from another phone would pin
  the wrong label in the conversation list.

- New `data/SmsIeBackup.kt` (pure, unit-tested): direction/status mapping for SMS
  `type` and MMS `msg_box`, seconds-vs-milliseconds MMS timestamps, peer
  resolution (sender for inbox, recipient for sent), text/image part extraction.
- New `data/SmsIeReader.kt`: ZIP/NDJSON/plain-JSON loading with a size guard on
  each part.
- `Repository.importSmsIe` matches conversations by canonical address, maps
  status, and copies MMS attachments into `files/mms-import/` so they survive the
  backup file disappearing; the URI is served by the existing FileProvider
  (`file_paths.xml` gained the matching path).
- UI: Settings → "Import from SMS Backup & Restore" with a ZIP/JSON picker, and
  a debuggable-gated `sms_ie_probe` intent extra because the SAF picker is not
  scriptable.
- Not included: call logs, contacts and blocked numbers, which sms-ie also
  exports. Contacts are not imported by sms-ie itself either, and call
  permissions would be a new permission for this app.

Tests: `SmsIeBackupTest` (9 tests: type/box mapping, MMS timestamp units, v1
array, v2 NDJSON with joined parts, sent-MMS peer from `__recipient_addresses`,
records without an address, text fallback to the part's data file, real export
string shape, extension mapping) and `scripts/test-sms-ie-import.sh` (10/10),
which builds a genuine v2 ZIP fixture with the same field shapes the app writes
and asserts 3 records land with the right direction, status, transport and a
stored image.

File: `data/SmsIeBackup.kt`, `data/SmsIeReader.kt`, `data/Repository.kt`,
`MainActivity.kt`, `ui/SettingsScreen.kt`, `res/values/strings_settings.xml`,
`res/xml/file_paths.xml`, `app/build.gradle.kts` · tests:
`test-sms-ie-import.sh`, `SmsIeBackupTest`
## Issues #232 / #235 / #231 · Select all, Save MMS picture, Copy part of a message (2026-09-25)

✅ USER REQUESTS, all three landed in the chat selection overflow:
- #232 `itsSamBz`: multi-select already existed but there was no **Select all**;
  the reporter had asked twice after the owner pushed back.
- #235 `tmpjx555`: save MMS content (e.g. a picture) to the device.
- #231 `ramonyouc3540` (also an open PR from the reporter): copy only part of a
  message text.

- `SelectionToolbar.showMore` — the overflow is now reachable for *any*
  non-empty selection, not only a single message, because it carries
  "Select all". `SelectionToolbar.selectAllCandidates(allIds, lockedIds)` takes
  every **unlocked** message, so a locked message can never be swept into a bulk
  trash.
- `MessageSelectionToolbar` overflow now lists Select all, Select text and Save
  image (each shown only when meaningful: body non-blank for Select text, media
  present for Save image), then Share / View details / Lock/Unlock for a single
  message.
- `MmsSupport.mimeForSavedAttachment` / `savedAttachmentName` resolve the
  attachment's type and build `"<contact>_<timestamp>.<ext>"`, keeping spaces and
  dropping only path-unsafe characters. `DownloadsStore.writeImage` writes
  through `MediaStore.Images` to **Pictures/Messages** with
  `IS_PENDING`, which is why no storage permission is needed on API 29+.
  `AppViewModel.saveMessageImage` reads the bytes through the resolver (so both
  `content://mms/part/...` and our own cache URIs work) and toasts the result.
- #231 is a **dialog** with the message text, not an in-bubble selection mode.
  First attempt made the bubble a `SelectionContainer`: that swallowed the
  long-press and left the user with no visible way back — reported as "click
  Select text and all the settings disappear". The dialog keeps every hold-a-
  message option reachable, and the platform's own handles/Copy work inside it.
  The dialog is opened a beat after the dropdown closes, otherwise the menu's
  dismiss click lands on the new dialog's scrim and closes it immediately.
  The body is rendered as plain selectable text — a read-only text field was
  tried and rejected because the outlined box looked out of place against the
  rest of the chat.

Tests: `SelectionToolbarTest` (+2: more-menu visibility, select-all skips
locked), `MmsSupportTest` (+2: saved-name sanitising, mime by extension) and a
new `scripts/test-message-actions.sh` (15/15) which seeds two text MMS plus one
image MMS into the provider and asserts Select all selects everything, skips the
locked message, Select text opens the dialog with a selectable field and leaves
the hold-message options intact, and Save image lands a file in
Pictures/Messages. `scripts/test-message-selection.sh` was repaired as well
(19/19): it seeded through the emulator radio, which duplicated the same three
messages 36 times and made the script unusable, and it asserted Copy hid itself
and "Forward" lived in the overflow, neither of which is true.

Note: uiautomator cannot see the platform text-selection handles, so the script
asserts the dialog, the selectable field and the surrounding options rather than
the handle UI itself.

File: `ui/SelectionToolbar.kt`, `ui/ChatScreen.kt`, `data/MmsSupport.kt`,
`data/DownloadsStore.kt`, `MainActivity.kt`, `res/values/strings_chat.xml` ·
tests: `test-message-actions.sh`, `test-message-selection.sh`,
`SelectionToolbarTest`, `MmsSupportTest`
## Issue #236 · Incoming MMS never arrives (receive path) — FIXED (2026-09-24)

✅ USER REPORT (tmpjx555, Nokia 3.4 / Android 12 / SDK 31, F-Droid 1.0.26,
`high`): "It still doesn't work for me on Android 12" — MMS neither received
nor sent. Follow-up to #210.

- ROOT CAUSE: since KitKat the **default SMS app** must download incoming MMS
  itself. The carrier announces one as an empty `msg_box=1, m_type=130`
  provider row and sends `WAP_PUSH_DELIVER`; the platform no longer fetches it.
  `MmsReceiver.onReceive` was an **empty no-op**, and `MmsSupport.isImportable`
  only accepts `m_type=132` (`RETRIEVE_CONF` = already downloaded), so the row
  was skipped forever and the MMS was silently dropped on every Android version.
  #210 only fixed importing MMS that were *already* downloaded — its test seeds
  a complete `132` fixture, which is why the gap was invisible.
- `sms/MmsReceiver.kt`: real `WAP_PUSH_DELIVER` handling (action + MIME + data
  URI) that hands the message to the downloader.
- `sms/MmsDownloader.kt` (new): `SmsManager.downloadMultimediaMessage` with a
  MUTABLE completion `PendingIntent`, per-message 5-minute retry cooldown, and
  a `requestPending()` sweep for announcements whose WAP broadcast was missed.
- `sms/MmsDownloadReceiver.kt` (new, registered in the manifest): on completion
  imports the downloaded MMS and posts a notification per new inbound message.
- `MainActivity.onResume` calls `MmsDownloader.requestPending(...)`.
- `MmsSupport`: `PDU_*` constants, `PENDING_DOWNLOAD_SELECTION`,
  `isPendingDownload`, `shouldRetryDownload`, `messageContentUri`, `InboundMms`.
  `MmsProviderReader.pendingDownloadIds()` queries undownloaded inbox rows.
- `Repository.importProviderMms()` now returns the inbound messages it imported
  (for notification) and is exposed as `importDownloadedMms()`. Deliberately not
  wrapped in `runOnIo`: it already serializes writes on the same single-thread
  executor, and nesting would deadlock.
- Sending MMS was **separately broken and is now fixed** — see the #236 send
  entry below.

Tests: `MmsSupportTest` (+2: pending-download predicate/selection/URI, retry
cooldown) + `scripts/test-mms-download.sh` (seeds a real `m_type=130` row with
`addr` and **no parts** into the provider DB, resumes the app, asserts a download
was requested for that `content://mms/<id>` via the `MmsDownload` log tag, that
the undownloaded row is not fabricated into an empty message, and that nothing
crashed). Fails before the fix with `4 PASS / 1 FAIL` ("app never requested a
download"), passes after with `5 PASS / 0 FAIL`. `test-mms-import.sh` (#210)
still 5/5.

File: `sms/MmsReceiver.kt`, `sms/MmsDownloader.kt`, `sms/MmsDownloadReceiver.kt`,
`data/MmsSupport.kt`, `data/MmsProviderReader.kt`, `data/Repository.kt`,
`MainActivity.kt`, `AndroidManifest.xml` · tests: `test-mms-download.sh`,
`MmsSupportTest`
## Issue #236 · Outgoing MMS never transmitted (send path) — FIXED (2026-09-24)

✅ Same report as the receive-path entry above ("receiving / sending MMS").

- ROOT CAUSE: `SmsSender.sendMms` handed the **picked media URI** to
  `SmsManager.sendMultimediaMessage`. That URI must point at the MMS *message*
  to transmit — a `content://mms/outbox/<id>` row or a content URI serving a
  composed binary PDU — so the transaction service found no PDU and the send
  died immediately. No outbox row was ever created either.
- CORRECTION to the earlier note above: the `FLAG_IMMUTABLE` sent-intent was
  **not** a defect. It only blocks the platform's *fill-in extras*; the broadcast
  result code still arrives, which is all `SmsStatusReceiver` uses. quik/klinker
  use `FLAG_UPDATE_CURRENT or FLAG_IMMUTABLE` too. The defect was the URI alone.
- Vendored `android-smsmms/` — klinker's Apache-2.0 fork of the AOSP MMS stack
  (the `com.google.android.mms` PDU classes are hidden from the public SDK, so
  they cannot be replaced by framework calls). Taken from `quik-sms/quik`, added
  as a Gradle module; only the PDU/SMIL subset is called by the app.
- New `sms/MmsComposer.kt`: builds the `SendReq` (from-address, `addTo` per
  recipient, date, attachment part + optional text part, **SMIL** part at index
  0, message size/class/expiry/priority, delivery + read report `0`), persists it
  via `PduPersister.persist(..., Telephony.Mms.Outbox.CONTENT_URI, ...)`,
  re-loads it, composes the binary with `PduComposer(...).make()` and serves the
  `.dat` from `cache/` through the app FileProvider. Modern AOSP has no `app_id`
  column on `pdu`, so the app-side id travels in the sent PendingIntent instead.
- `SmsSender.sendMms` now persists → composes → `sendMultimediaMessage` with
  `MMS_CONFIG_GROUP_MMS_ENABLED` and a `FLAG_UPDATE_CURRENT or FLAG_IMMUTABLE`
  sent-intent carrying the message id, outbox URI and PDU file path.
- `SmsStatusReceiver`: new MMS branch moves the provider row to
  `MESSAGE_BOX_SENT`/`MESSAGE_BOX_FAILED` from the broadcast result code,
  deletes the composed PDU file, and — unlike SMS — never mirrors an MMS into
  the SMS sent box (#91).
- `res/xml/file_paths.xml` exposes `cache/` so the PDU file can be served.
- Debug-only probe (`--es mms_probe <media uri> --es mms_probe_to <number>`,
  debuggable-gated like `fake_dual_sim`) so a send can be driven on an emulator
  with no MMSC.
- R8 keeps added for the vendored PDU/SMIL packages so release minification
  cannot strip them.

Tests: `MmsSupportTest` (+2: `defaultAttachmentMime` fallback incl. by file
extension, `outgoingParts` attachment + optional text) + new
`scripts/test-mms-send.sh` (seeds a PNG through the app FileProvider, drives one
MMS send, asserts the provider holds an `m_type=128` PDU with a SMIL part, the
image part and a `type=151` recipient, that the row lands in an
outbox/sent/failed box, that the sent callback resolved the app row to a real
status, and that the composed PDU file is cleaned up). Fails before the fix —
"no outgoing MMS PDU in the provider outbox" — and passes after (8 PASS / 0
FAIL).

NOT verified on hardware: actual delivery still needs a real carrier/MMSC; the
emulator can only prove the PDU, provider record, hand-off and callback.

File: `android-smsmms/` (vendored), `sms/MmsComposer.kt`, `sms/SmsSupport.kt`,
`sms/SmsStatusReceiver.kt`, `data/MmsSupport.kt`, `MainActivity.kt`,
`res/xml/file_paths.xml`, `proguard-rules.pro`, `settings.gradle.kts`,
`gradle/libs.versions.toml` · tests: `test-mms-send.sh`, `MmsSupportTest`
## Issue #219 · Notifications stop for a sender after their chat was opened (2026-09-24)

✅ USER REPORT (Zokii0): once a sender tripped a blocked keyword, every later
message from that same sender still arrived in the app but never produced a
notification. Reporter saw the same on a second sender after that sender's
first keyword-block.

- ROOT CAUSE: `ForegroundTracker`'s open address was set when a chat opened
  (`ChatScreen`) but only cleared by the `MainActivity` BackHandler — which is
  shadowed by `ChatScreen`'s own `BackHandler`/back arrow, so the in-app back
  button never cleared it. The receiver runs in the main process (no
  `android:process`), so `openAddress` stayed latched on the last-opened
  sender for the life of the process, and `SmsReceiver` skipped
  `NotificationHelper.show` for exactly that address forever. Opening the chat
  is what users do to check a keyword block, hence the keyword correlation.
- `ui/ChatScreen.kt`: `DisposableEffect` now clears the open conversation on
  dispose, so every exit path (back arrow, system back, archive, delete, route
  swap) releases it.
- `sms/NotificationPolicy.kt` (new): pure `skipForOpenThread(appInForeground,
  threadOpen)`, used by `SmsReceiver` and `NotificationHelper.show`. The
  receiver's gate is now foreground-aware, matching the helper, so a backgrounded
  app no longer suppresses a thread's notifications.
- `MainActivity.kt`: dropped the now-dead `wasChat` clear.
- `ForegroundTracker.kt`: now in-memory only. The startup restore from
  SharedPreferences (plus the uncalled `persist`/`persistIfForeground`) is gone —
  a stale `open_address` written by an older build would otherwise re-latch a
  sender on upgrade and keep the bug alive on the reporter's device even with
  the dispose-clear in place. `MessagesApplication` no longer calls `init`.

Tests: `NotificationPolicyTest` (suppresses only when foreground AND that
thread is open) + `scripts/test-keyword-followup-notification.sh` (opens a
sender's chat, leaves via the in-app back arrow, then sends a follow-up from
that same sender and asserts `dumpsys notification` has it; control sender
never opened still notifies). Fails before the fix on the follow-up assertion
(6 PASS / 1 FAIL), passes after (7 PASS / 0 FAIL).

Pre-existing script repairs found while running the suite:
`test-keywords.sh` still asserted keyword-blocked messages are dropped
outright, but they are parked in Spam & blocked — now asserts kept-once, not
visible in the chat, no notification, and that a normal message from another
sender does notify. `test-notif-dismiss-on-open.sh` counted the `dumpsys`
`AppSettings` line as a notification (so its dismissal assert could never
fail) and tapped a fixed coordinate — now launches the app, filters
`NotificationRecord(...pkg=...)`, and taps the row found from the message body.

File: `ui/ChatScreen.kt`, `sms/NotificationPolicy.kt`, `sms/SmsReceiver.kt`,
`sms/SmsSupport.kt`, `sms/ForegroundTracker.kt`, `MainActivity.kt`,
`MessagesApplication.kt` · tests: `test-keyword-followup-notification.sh`,
`test-keywords.sh`, `test-notif-dismiss-on-open.sh`
## Spam & blocked / Trash · Messages tab shows the sender name (2026-09-24)

✅ USER REQUEST (follow-up to the contact-details work): on the Spam &
blocked → Messages tab and the Trash → Messages tab, a row whose sender is a
saved contact rendered only the formatted number — the stored
`COALESCE(p.display_destination, c.address)` column was mapped into the
sender-name slot instead of `c.name`.

- `data/FolderRows.kt`: shared column-index/SELECT contract for both folder
  queries (`COL_NAME = c.name`, no `participants` join), plus pure
  `blockedMessage`/`trashedMessage` builders.
- `Repository.blockedMessages()` / `trashedMessages()` consume `FolderRows`
  and map the sender name from `c.name` only.

Tests: `FolderRowsTest` (SELECT projections resolve `c.name`, display column
and `participants` join are absent, builders keep the saved name) +
`scripts/test-folder-sender-name.sh` (seeds saved contact Fran /
+15551230022 with a `…0022` display destination, one parked keyword-blocked
message and one normal message trashed through the UI; asserts both folder
Message tabs show `Fran`; fails before the fix with 2 FAILs, passes after;
DB-seeded so the flaky emulator radio/duplicate delivery can't leak rows).
## Contact details · show the number under a saved name (2026-09-24)

✅ USER REQUEST: on the conversation-details screen a saved contact showed only
the name — the phone number was never rendered, so the user could not see which
number the contact was saved under.

- New pure helper `ContactDetails` (`isKnown`/`title`/`subtitle`): a saved
  contact titles with the name and shows the formatted number beneath it; an
  unknown sender titles with the number and has no subtitle.
- `ContactDetailsScreen` uses the helper in both the profile header (number
  under the name) and the contact card row (name + number).

Tests: `ContactDetailsTest` (name+number, number-only, alphanumeric sender) +
`scripts/test-contact-details.sh` (seed Sarah / +15551230010, open details,
assert the name and a `…0010` number line; fails before the fix).
## CI · pin GitHub Actions runners to ubuntu-24.04 (2026-09-21)

✅ GitHub will migrate the `ubuntu-latest` label from Ubuntu 24.04 to Ubuntu
26.04 between Oct 19 and Nov 19, 2026. Pinned every `runs-on` (11 across
`develop-build.yml`, `rc.yml`, `security.yml`, `virustotal.yml`,
`release.yml`) to `ubuntu-24.04` so CI stays deterministic. `ubuntu-26.04` is
available for an explicit test run when we want to validate the new image.
## Screenshots · F-Droid set rebuilt on contacts with real names + photos (2026-09-26)

✅ USER REQUEST: add dummy contacts to the emulator and re-take the F-Droid
screenshots, with each contact saved in the phone book under a proper name and
image. Picked, with the user: generate monogram avatars for everyone (rather
than reuse the six sample photos the AVD ships), align the seeded inbox to the
phone book, and curate one clean numbered set.

**Why every avatar used to be a placeholder.** Two independent faults:

1. *The inbox and the phone book used different numbers.* `seed-demo-conversations.sh`
   seeded `+1555771xxx` while `insert-demo-contacts.sh` created `+1555123xxxx`.
   `PersonAvatar` resolves a photo with `ContactsContract
   phone_lookup/<conversation address>`, so no conversation ever matched a
   contact. Both scripts now read one roster from `demo-data.sh`, and
   `seed-demo-conversations.sh` refuses to run if a conversation number is
   missing from it.
2. *The provider's display name was being rebuilt from given+family.*
   `data10` (display name style) must stay UNDEFINED: with FULL_NAME the
   provider joins the parts the wrong way round and "Work Group" reached the
   conversation list as "GroupWork" (and "Sarah Chen" as "ChenSarah"). The
   earlier note below about fixing this "by clearing the family-name field" was
   a workaround for the same thing; `test-demo-contacts.sh` now asserts
   `raw_contacts.display_name` so it cannot regress.

**Photo storage, for the record.** The provider keeps a contact photo as a
thumbnail blob in `data.data15` of the mimetype=photo row, with `data14` and
`contacts.photo_file_id` left NULL — then `contacts/<id>/photo` serves the
thumbnail. `content` cannot express a blob (`--bind x:b:` is *boolean*), so
those writes go through `sqlite3` as root. Setting `data14`/a `photo_files`
row instead makes the provider serve a file from the photo store, and a missing
file renders as a bare coloured circle with no glyph, because `PersonAvatar`
only draws the silhouette when the URI resolves to null.

Also fixed along the way: the old seeder passed multi-word names unquoted, so
the device shell split them and the insert failed **silently** — that is why
the old phone book had "Pizza Palace", "Dr. Patel" and "Gym Buddy" showing as
bare numbers. And `photo_files`/stale `data14` from an earlier manual attempt
now get cleared on every seed.

**New/rewritten here:** `demo-data.sh` (canonical roster), `make-demo-avatars.py`
(monogram generator, drawn from the app's own avatar palette in
`ui/Components.kt`), `test-demo-contacts.sh` (91 assertions, re-seeds then
checks alignment, names, thumbnail decodability and photo-store hygiene),
`take-fdroid-screenshots.sh` (rewritten; the old one still targeted a 20-image
dark/light set and had grown duplicate helpers). Set is now 15 shots:
`01-conversations` … `15-settings-dark`.

`seed-demo-conversations.sh --wipe` now also empties the telephony provider.
The stock AVD image ships ~400 sample messages and `syncFromSystem()`
re-imports whatever is still there on the next launch, so wiping only
`messages.db` left the screenshots buried in junk rows.

The AVD is still touchy: it ANRed and then crashed mid-run twice, so
`take-fdroid-screenshots.sh` aborts outright if the device stops responding
rather than overwriting good shots with broken ones. No app code changed, so
there is no JUnit test to add — `test-demo-contacts.sh` is the guard.

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
SIM selection stays in the chat 3-dot menu only.
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
- ✅ Trash system: swipe-left / sheet Delete moves conversations to trash (DB v8 `deleted_at`), UNDO snackbar, Settings → Privacy → Trash screen (restore / delete forever / empty trash), auto-purge after 30 days on app start, new SMS from trashed address restores the thread; swipe needs ~30% travel (`SettingsLayout.SWIPE_COMMIT_FRACTION`) — test: `scripts/test-trash.sh`
- ✅ Swipe threshold enforced below the library's hardcoded half-row switch: material3 `SwipeToDismissBox` switches its mid-drag target at half the row regardless of `positionalThreshold` (known bug, issuetracker 471021165 — ~50% + 125dp/s velocity), so short swipes used to delete rows and the app over-corrected to 65%; the shared `SettingsLayout.SWIPE_COMMIT_FRACTION` (0.30f) now feeds both `positionalThreshold` and `confirmValueChange` in `SwipeConversationItem`/`LegacyConversationsScreen` — test: `scripts/test-swipe-threshold.sh`
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
## Spam & blocked · one folder, M3 tabs, keyword messages, SIM always-on (2026-09-22)

✅ USER REQUEST: fold the redundant "Blocked numbers" row into one **Spam &
blocked** screen with Material 3 tabs (Conversations | Messages); park
keyword-blocked SMS as messages (not the whole contact); keep the SIM switcher
always visible.

- Keyword-blocked SMS now soft-deletes just the message (`messages.blocked_reason`
  + `deleted_at`; DB v20) and the conversation stays in the inbox; the SMS is
  listed under **Spam & blocked → Messages**.
- `SpamBlockedScreen` rebuilt with `PrimaryTabRow`/`Tab`: Conversations (blocked
  numbers, Unblock) + Messages (keyword blocks, Delete). Removed the separate
  `BlockedNumbersScreen`, its Settings row/route/strings and
  `test-blocked-numbers-list.sh`.
- SIM switcher renders whenever `sims.size > 1` (no draft/keyboard gate).

Tests: `test-keywords.sh` 11/11 (message soft-deleted + listed under Messages,
conversation in inbox), `test-spam-blocked.sh` 9/9, `test-sim-inputbar.sh` 7/7
(visible while typing).
## Spam & blocked folder · GM-like block behaviour (2026-09-22)

✅ USER REQUEST (GM-like): blocking a number moves its conversation out of the
inbox into a **Spam & blocked** folder (kept, recoverable), later messages from
that number are stored there with no notification, and Unblock restores the
thread. Reachable from **Settings → Spam & blocked** (below Trash); the overflow
menu on the main list was removed. No Trash involvement.

- DB v19 adds `conversations.blocked`; `Conversation.blocked`; `matchesView`
  (`INBOX`/`ARCHIVED`/`SPAM_BLOCKED`) filters blocked out of the inbox and
  archives. `Repository.receiveSpamMessage` stores without unread/notify;
  `blockNumber`/`unblockNumber` flag the conversation. `SmsReceiver` routes a
  blocked sender's SMS there instead of dropping it.
- New `SpamBlockedScreen` (`Settings → Spam & blocked`) lists blocked threads
  with a "Blocked" tag and Unblock; `ConversationsScreen` rows show a block
  badge; blocking from a chat returns to the list with a "Moved to Spam &
  blocked" toast.

Tests: `ConversationFilterTest` (view partitioning) + `scripts/test-spam-blocked.sh`
(block → leaves inbox → kept in the folder with badge → Unblock → back in inbox;
9/9 on `emulator-5554`).
## Settings · Blocked numbers list (2026-09-22)

✅ USER REQUEST: a way to see blocked numbers. Settings → "Blocked numbers"
(under Number blocking) opens `BlockedNumbersScreen` — each blocked number with
an Unblock action, plus an empty state. The Settings row subtitle shows the
count ("None" / "N blocked"). Wired through `AppViewModel.blockedNumbers()` (the
previously-unused `Repository.blockedNumbers()`) and a `blocked` nav route.

Tests: new `BlockedNumbersTest` (subtitle helper) + `scripts/test-blocked-numbers-list.sh`
(block via the long-press sheet → number listed → Unblock → removed).
## Trash · blocked messages kept + delete-reason tag (2026-09-22)

✅ USER REQUEST: keyword-blocked messages are no longer dropped — they are
stored and their conversation is moved to Trash (recoverable via Restore) with
no notification. Trash rows carry a reason tag under the number: "Manually"
(user) or "Keyword" (keyword block). Messages from a blocked number are still
dropped entirely (never stored, never in Trash).

- `Repository.receiveBlockedMessage` inserts the message and sets
  `conversations.deleted_at` + `deleted_reason`; `SmsReceiver` routes a blocked
  keyword (`KeywordFilter.route` → `blocked_keyword`) through it and drops
  messages from a blocked sender (`isAddressBlocked`).
- New `TrashReason` constants; DB v18 adds `conversations.deleted_reason`
  (default `manual`); every manual trash path records `manual`. `TrashScreen`
  renders a small reason tag.
- `keywords_hint` now says matching messages go to Trash.

Tests: `KeywordFilterTest` route cases + `TrashReasonTest`; `test-keywords.sh`
(message kept, reason `blocked_keyword`, no notification, "Keyword" tag);
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
## Chat · SIM switcher icon redesign (2026-09-23)

✅ USER REQUEST: the in-field SIM glyph is now a single tintable 24dp Fossify
Commons outline (`ic_sim_vector`, white placeholder fill, tinted
`onSurfaceVariant` like the other input-bar icons). The old cutout-style
`ic_sim_1`/`ic_sim_2`/`ic_dual_sim` are deleted, along with `SimIcon`/`iconFor`.
The slot number ("1"/"2", or "D" for 3+) is overlaid on the icon as a bold
`labelSmall` in `colorScheme.surface` — a knockout numeral that stays legible on
the `onSurfaceVariant` fill in both light (light numeral on dark card) and dark
(dark numeral on light card) themes. Input-bar trailing row: 40dp clickable
`Box`, SIM glyph left of the emoji, hidden while a draft exists.

Tests: `SimIconDrawableTest` (white tint-only fill, 24dp, Fossify card shape,
old icons gone) and new `SimBadgeColorTest` (icon `onSurfaceVariant` tint,
label `colorScheme.surface`, no `Color.White`/`onPrimaryContainer`) kept green
with `test-sim-inputbar.sh` (8/8: dual button present, slot numeral rendered,
cycles + wraps the pref, hidden while typing, absent on single-SIM).
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

## Issue #219 comment · grouped notifications show read history (2026-09-25)

USER REPORT: expanding a conversation notification showed the sender's whole
recent history, including the user's own replies, and sometimes did not say who
the messages were from.

✅ Read state lives only in `conversations.unread_count` (there is no per-message
read flag), so the history query is now bounded by it:
`Repository.notificationHistory()` selects `is_me=0, deleted_at=0` newest-first,
limited by `NotificationHistory.takeCount(unread, MAX_LINES)` and reversed, so
the record holds exactly the missed messages. `takeCount` floors at 1 line
because the message that triggered the post is itself unread. Superseded
`recentMessageLines()` deleted rather than left as a second query to drift.
Sender name is unchanged: `groupedStyle` still sets `conversationTitle`, and
Android renders it in the header even when every line is the same sender (the
per-line name is dropped by the platform in that case, confirmed on emulator).

Tests: `NotificationHistoryTest` +3 (`takeCount` bounded by unread, capped at
MAX_LINES, never zero). `test-grouped-notifications.sh` 19/19, new section seeds
a read backlog and asserts read messages stay out of the record — verified
failing against the pre-fix query.

NOTE (environment): a nested `runOnIo` inside `notificationHistory` deadlocked
`SmsReceiver` on the single-thread `dbExecutor`, which looked like the AVD radio
dropping SMS. The count read is now inlined in the same block.

## Issue #219 comment · badge climbs while the chat is open (2026-09-25)

USER REPORT: the unread badge kept going up while sitting in the very chat the
messages were arriving in.

✅ `receiveMessage` incremented `unread_count` unconditionally and only the
*notification* was suppressed, after the write. `receiveMessage` now takes
`markUnread` and the receiver derives it from
`NotificationPolicy.countsAsUnread(foreground, threadOpen)`, the exact negation of
the suppression it already applies, so a thread on screen stays read on arrival.

Tests: `NotificationPolicyTest` +2 (`countsAsUnread` is false only for the open
thread). `test-notification-badge.sh` 10/10, new section opens a chat, injects a
message and asserts the conversation's unread stays 0 and the total is unchanged
— verified failing (unread 0->1, total 17->18) against the pre-fix receiver.

NOTE: `test-notif-dismiss-on-open.sh` was counting every notification record for
the package, so it failed whenever another conversation or Android's autogenerated
`ranker_group` summary was present. Now scoped to its own conversation id, and
the record pattern allows the `user=UserHandle{0}` field that dumpsys prints
between `pkg` and `id`.

## Issue #219 comment · Spam & Blocked delete and Empty (2026-09-25)

USER REPORT: deleting a blocked message did nothing if you left the screen, a
blocked conversation could only be unblocked (never deleted), and neither tab had
an Empty action.

✅ The delete was issued from a coroutine that only resumed after the snackbar
returned, in a `rememberCoroutineScope` that leaving the screen cancels — so the
delete silently never ran. The message is now deleted on tap and the snackbar
only offers Undo, which re-inserts the row soft-deleted with its original
`blocked_reason` (added to `BlockedMessage`/`BLOCKED_SELECT`) so it lands back in
the blocked folder rather than the normal chat. New `deleteBlockedConversation`
(purges the blocked messages, drops the block), `deleteAllBlockedMessages`, and
`unblockAllNumbers` for the Conversations tab, plus a per-row Delete beside
Unblock and a per-tab Empty in the app bar behind a confirm dialog.

Tests: `FolderRowsTest` +1 and `BlockedMessage.blockedReason` asserted.
`test-spam-blocked.sh` 16/16, new section seeds the blocked state and covers all
three fixes — verified failing against the pre-change build (delete "cancelled
by leaving the screen", no Empty action, no Delete action).

NOTE: the pre-existing "conversation back in the inbox" assertion used
`wait_for_text`, which never scrolls, so with the rows earlier scripts leave
behind the restored conversation sat below the fold. Replaced with a local
scrolling poll. Confirmed pre-existing: it fails identically on the build
without these changes.

## Issue #219 comment · blocked senders never aged out (2026-09-25)

USER REPORT: a blocked sender that keeps receiving messages never ages out of
Spam & Blocked, so the folder only ever grows.

✅ `BLOCKED_CONVERSATION_SQL` aged blocked senders by `conversations.timestamp`,
which is last activity — so every new delivery from the sender reset its own
clock and the purge could never reach it. The old comment treated that as
deliberate ("a sender who keeps texting is not purged out from under the user"),
but the user reads it as unbounded growth, and it was the wrong side of the
trade: a *recently* blocked sender whose messages happened to be old was purged
immediately, which the same test also caught.

New `conversations.blocked_at` (schema v21), set when a number is blocked and
cleared when it is unblocked or bulk-cleared. Blocked inbound keeps the original
value (`CASE WHEN blocked_at>0 THEN blocked_at ELSE ? END`) so a long-running
block is not restarted by each new message. The predicate is now
`blocked=1 AND blocked_at>0 AND blocked_at<?`; the `blocked_at>0` guard leaves a
row whose block date is unknown out of the purge. Migration backfills
`blocked_at=timestamp` for already-blocked conversations, so they get a full
window from the upgrade instead of being purged on first run.

Tests: `RetentionPolicyTest` — `blockedSendersAreAgedByWhenTheyWereBlockedNotBy
LastActivity` (renamed, it asserted the old contract) and
`blockedSendersWithAnUnknownBlockDateAreLeftAlone`. `test-retention.sh` 40/40,
new rows cover a long-blocked sender still being written to (must be purged) and
a recently blocked sender with old messages (must be kept) — all three new
assertions fail against the old predicate. The seed now restarts the app first,
because `blocked_at` arrives via a migration that only runs when the app opens
the database.

## Spam & Blocked row icon actions

The blocked-conversation row used two text buttons, which is heavy in a list row
and inconsistent with the Messages tab beside it where Delete is already an
icon. Both are now IconButtons: a bin for Delete, a padlock for Unblock, tinted
and labelled the way `TrashScreen` already does it.

`test-spam-blocked.sh` 17/17. Two assertions were matching the old text buttons
and now read `content-desc`; added one that Unblock is its own control rather
than folded into the row.

The padlock is a hand-traced vector, so `VectorDrawableTest` (app) guards it: the
viewport must stay on the artwork's measured ink bounds, no transform group may
come back, and the declared dp size must stay in the band that optically matches
a Material glyph. That last one exists because the bounds were got wrong twice -
reading the shackle arc's start point (y=136) as the top of the art when its
apex is at y=10, which pushed it negative and let VectorDrawable's clip eat the
whole shackle. The numbers are now measured by rasterising the source SVG and
reading the alpha bbox, and the file says so.

## Spam & Blocked action icons

The app-bar Empty action and both per-row deletes all drew a bin, so "clear the
whole tab" and "delete this one thing" were indistinguishable by glyph. Empty is
now a bin on its own, matching the trash already in the app bar for "Empty trash"
in the Trash folder, and a per-message delete is an X.

Empty is icon-only, so its label moved onto the icon as a content description -
verified present in the dump as `content-desc="Empty"`, without which the control
is announced as just "button". The per-message X is pinned to 22.dp, which is
what the bin it replaced already was.

The padlock was nudged up 4% to 13.26x18.36dp, which is 6.8% over the Material
bin's ink height rather than matching it, and the size band in
`VectorDrawableTest` was tightened around that value so a later edit cannot
quietly shrink it back.

`test-spam-blocked.sh` 17/17. The app-bar assertion moved from `text="Empty"` to
`content-desc="Empty"`, since the action no longer has a text label.

Fixed a latent bug in `VectorDrawableTest`: it asserted the old 357x370 viewport,
so when the drawable was corrected to the measured 360x498 bounds the assertion
was left stale and passing for the wrong reason.

## Spam & Blocked undo + unified row icons

**Undo on caught messages.** Each row in Spam & Blocked > Messages now offers an
undo arrow beside the X. It returns the message to its conversation, and is only
enabled once the message would no longer be caught - while a matching keyword is
still on the block list, restoring would just hide it again.

`blocked_reason` records only *that* a row was caught, never which keyword, so
the gate (`SpamRestore.canReturnToChat`) asks whether any keyword currently on
the list still matches the body. Six JUnit cases cover it, including a blank
entry on the list, which must not make every message unrestorable.

**One icon language across Spam & Blocked and Trash.** They had drifted: the same
X was red in Trash and grey in Spam, and restore was grey in Trash and blue in
Spam. Now derived from one rule - undo `primary`, permanent delete `error`,
neutral `onSurfaceVariant`. The padlock is gone; the conversation row uses undo
for unblock and X for delete like everywhere else.

**`ic_padlock` and its test removed.** The icon became unused, and leaving an
asset plus a test that only guarded that one asset is dead weight. Both are in
#256 if they are wanted back.

**`IconTint` for dark mode.** A disabled control used a fixed 0.38 alpha of
`onSurfaceVariant`. On a dark surface that lands near 2.2:1, under the 3:1 that
UI components need, and the icon reads as missing rather than disabled. Dark mode
now keeps 0.62.

## Import/export log (2026-10-02)

✅ USER REQUEST: show import/export logs in the app, including failures and
conflicts.

Settings → **Advanced → Import & export log** lists the last 20 runs, each with
its outcome, the reason it failed, added/seen/skipped counts, and the
per-category conflict tallies. The same last five runs are appended to
`Diagnostics → Diagnostics` as a `--- Transfers ---` block, so a script can
assert on them without opening the screen.

**What was silently lost, and now is not:**

- **`ImportReport.skipped` and `.truncated` had zero readers.** They were
  computed at the end of `importStaged` and dropped on the floor at the one call
  site, which kept only `added`.
- **`importStaged` had no duplicate detection at all.** Re-importing the same
  backup duplicated every message, and the run reported `added = seen`. It now
  keys on conversation address + timestamp + direction + transport + body and
  skips repeats, tallying them under `already present`. (Deliberately *not* the
  provider id — that belongs to whichever device issued it, the same reasoning
  as `LegacyBackupSchema.adoptProviderIds`.)
- **`mergeDatabase` skipped duplicates with a bare `continue`** — no counter, so
  "merged 4,000" was indistinguishable from a run that had merged 600 and
  dropped 3,400.
- **`added++` ran unconditionally after `insert()`.** A refused insert (a
  constraint, a full disk) incremented `added` and looked like a success.
- **`backupDatabase` returned a bare `Boolean` from six `return false` sites.**
  A revoked SD-card permission and a rejected PIN produced the same `false` and
  the same toast. It now returns `ExportResult`, and every failure goes through
  `exportFailed()` so it is both shown and logged.
- **`importSmsIe` collapsed `ImportResult` to an `Int`** (`-1` for any error),
  so "Wrong PIN or corrupted file" and "Cannot read that backup file" both
  surfaced as `settings_import_sms_ie_failed`. The `ImportResult` now reaches
  the UI intact.

**Counting lives next to the decision.** `Repository.Conflict` holds the reason
strings, and each site that skips a message increments its own bucket.
`TransferConflictCountingTest` fails the build on a `skipped++` with no
`conflicts.count()` nearby — a skip that does not say why is exactly the silent
loss this log exists to expose.

**Recorded in the Repository, not the ViewModel**, so the debug probes the
scripts drive log through the same call the UI makes, and the `TransferLog`
logcat dump reads `TransferLogStore` rather than recomputing anything.

Files: `data/TransferLog.kt` (new), `data/Repository.kt`, `data/BackupCrypto.kt`
(`encryptWithPin` returns bytes written, so a truncated export is catchable),
`ui/TransferLogScreen.kt` (new), `MainActivity.kt`,
`diagnostics/DiagnosticsReport.kt`, both settings screens, 13 locales.
Tests: `TransferLogTest`, `TransferConflictCountingTest`, `test-transfer-log.sh`.

## Traps worth remembering

- **A Compose `IconButton`'s disabled state is on the clickable parent View, not
  on the node carrying the content description.** The `content-desc` node reports
  `enabled="true"` either way, so grepping it reports every control as enabled.
  `undo_states()` walks up to the nearest `clickable` ancestor; without that this
  looks like the gate silently does nothing.
- **`blocked_keywords` is a string-set**, so the prefs entry must be a `<set>`
  element. A plain `<string>` of the same name makes `getStringSet` throw
  `ClassCastException` and crashes the app on opening the screen.
- **`db()` in this script wraps the statement in single quotes** for the remote
  shell, so SQL literals in it have to be escaped. `dbq()` pipes over stdin and
  sidesteps that; use it for anything non-trivial.
- Sections that empty a folder affect **every** row in it, not just their own
  seeded markers, so a later section may find nothing. Re-seed rather than
  asserting against an empty tab.
- **`&` in an Android string reaches uiautomator XML as `&amp;`,** so a row
  titled `Import & export log` greps as `Import &amp; export log`. Grepping for
  the raw `&` silently finds nothing and reads as "the row is missing". Also
  note that a row's title and the screen's top bar carry the same string — match
  on the subtitle to prove the *row* is on screen, not just the title bar.
- **Never run two `test-*.sh` against the same AVD at once**, and check the
  device is still there between scripts. They share one emulator, one database
  and one `ui.xml`. A dead AVD makes every script report a handful of failures
  that have nothing to do with the code — a whole suite once came back
  `0 passed, 2 failed` per script, identically, which was the emulator gone
  rather than a regression.
- **A script that seeds rows must delete them on exit.** Several scripts share
  `+15551230010`, and since a private chat and a group can now both belong to
  the same contact, a leftover row makes "the conversation for this number"
  ambiguous for the next script. That showed up as
  `test-group-send-duplicates` dropping to 2/4 whenever it followed another.
  It now selects the conversation with more than one recipient rather than
  taking whatever row comes first.
- **Two conversations can now share an address**, so a row cannot be found by
  address alone. `getOrCreateConversationBlocking` takes `privateOnly`, and the
  group row has to be reached from the list rather than
  `--es open_conversation_address`.
- **`test-backup-restore.sh` and `test-merge-import.sh` currently fail at the SAF
  picker step on this AVD** ("newest .enc not found in picker") — confirmed
  pre-existing on a clean checkout, not caused by the transfer-log work. The
  backup is written correctly (`ls` shows it); the picker just does not list it.
