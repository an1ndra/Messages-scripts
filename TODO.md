# TODO

> Moved from the Messages app repo (2026-09-13). This is the project's
> task/tracking history — issues, verification notes, and the regression
> scripts that test them (all in this repo). Hand this file + `AGENTS.md`
> (same folder) to any AI agent working on the scripts.

## About screen (2026-10-30)

Asked for: an About option "so user can see about me and the app", plus star /
report-issue / share actions and a diagnostics attachment on the issue.

**Where it sits.** The last row of General settings, *after* Advanced. About
therefore takes `RowPosition.LAST` (the rounded bottom edge) and Advanced drops
to `MIDDLE` — an ordinary row that keeps the rounding while another sits under
it shows a seam. The legacy sheet gets the same row in its last card, and it is
indexed in `SettingsSearch` (`LegacySettingsIndexTest` fails otherwise).

**The footer is gone.** `SettingsFooter(R.string.messages_footer)` printed
"Messages 1.0 - offline SMS" under the list. The version now lives on About, so
the line was removed from both surfaces instead of duplicated — and because the
footer also supplied the space under the last card, that space became explicit:
`SettingsLayout.BOTTOM_GAP` (20dp), added to both settings lists and to About.
Without it the last card sat flush against the navigation inset.

**The icon.** Reusing `ic_launcher_monochrome` looked like a small bubble
floating in a big box: the launcher vector is drawn in a 108x108 viewport with
the bubble occupying 12..60, so ~55% of it is transparent margin and
`Modifier.size()` did not mean what it looked like. `ic_about_app.xml` is the
same path translated into a 48x48 viewport, so the glyph fills its plate
(96dp glyph in a 136dp plate). The size has no text equivalent, so the screen
logs it (`AboutIcon plate=136.0dp glyph=96.0dp`) and the script asserts it —
the first version of the marker printed a float and the script's integer regex
missed it, which is exactly the class of thing that message exists to catch.

**The issue dialog.** Three actions do not fit an `AlertDialog`'s two-button
row: they wrapped into a ragged block with Cancel stranded underneath (reported
with a screenshot). It is a `Dialog` with full-width stacked buttons now —
primary "Open with diagnostics", then "Open without", then "Cancel".

**Diagnostics prefill.** GitHub silently drops an issue form's `body` prefill
over 4,096 characters, which would leave an empty form, so
`diagnosticsForIssue()` keeps whole lines up to the cap and ends with
"(truncated)". Section order puts app/theme/notifications/SIM first, so the
tail that gets cut is the part least likely to answer a report. The dialog says
what is attached and what never is (message history, contacts, phone number);
the report contains none of those — it carries carrier, slot, MCC/MNC and
country, which is why the dialog comes before the browser.

**Back.** The root dispatcher's `else` sends unknown routes to the list, so
About needed both `BackHandler(onBack = onBack)` and a `"about" -> "settings"`
entry; without them Back left the app.

**Share copy.** Heading plus where to get it: both the release APK and the
F-Droid listing, in all 13 locales.

Verification: `AboutLinksTest` (URLs, 4,096 cap, whole lines, share targets),
`AboutRowPlacementTest` (row order and shapes, footer removal, bottom gap, back
routing, source anchors), `test-about.sh` 21/21 on `emulator-5558` (both
surfaces, icon size, dialog, share sheet, star URL, legacy row).

Also installed **Brave** (`BraveMonox64.apk`, x86_64) on `emulator-5558`: the
AOSP image ships only "WebView Browser Tester", which fails on many real sites,
so link intents had nothing credible to open.

## A saved draft comes back in the composer (2026-10-30)

Reported: "one Draft message I open in chat Text field I cant see them it
disappere". The repo already knew: the #362 note recorded the restore as "a
lambda literal that is never invoked — `if (convo != null && !draftLoaded) { { … } }`
— so a saved draft is never put back in the composer on re-open", and the bidi
script worked around it by seeding the composer through a share intent.

The block runs now, and the decision is a function (`restoredDraft`) so it is
testable off-device: an empty draft or an already-loaded one restores nothing.
`test-draft-restore.sh` seeds the draft straight into the database — the path that
used to fail — and checks it appears on open, survives a round trip, and is still
in the database. Mutation (the restore returning null again) fails it.

## Closing a chat moves instead of dissolving (2026-10-30)

Reported twice: first "There is not chat close animation", then the sharper
version — "opening chat screen showing animation" but not closing.

The transition was asymmetric. Opening slid the chat in **solid**, because the
fade was removed there (the list showed through the bubbles while it rose).
Closing still ran `fadeOut(200ms) + slideOutVertically(300ms)`, so the chat
dissolved into the list faster than it moved — read as a cut, not an animation.

Closing is now the exact mirror: `EnterTransition.None` for the always-visible
list plus a solid `slideOutVertically`. The chat is one opaque surface that
carries the whole move.

Measured, not eyeballed. The app marks both moments (`NavTransition "chat to
list"` and `"chat closed"`); `test-chat-close-animation.sh` presses Back and
compares them:

```
fixed:          chat lived 359ms through the exit animation
mutation (None): chat was torn down after only 34ms
```

Both states stay marked in the app — the transition spec logs one line, and
`ChatScreen`'s dispose logs one line per close — because that gap is the only
pixel-free evidence the exit window exists.

## The chat close animation does run (2026-10-30, measured)

Reported: "There is not chat close animation". Measured instead of guessed, by
logging the transition spec and the chat's teardown:

```
from=chat to=list reduce=false scale=1.0
... 358 ms later: chat torn down
```

So the branch is taken, the platform animation scale is 1.0, and the chat survives
the full 300 ms slide before it is disposed — the exit animation is playing. If a
device shows none, the causes to check are the app's Accessibility "Reduce motion"
(which sets both transitions to None by design) and the system animation scale
(Developer options / "Remove animations"), not the transition spec.

## The composer's attach dot follows the theme (2026-10-30)

Reported: "in light mode in + icon one dot color not looks good?"

The attach button's badge dot was the one fixed colour in the composer:
`#76D1FF`, sampled from Google Messages' **dark** composer and pinned by
`ComposerAttachDotTest`. On a light pill that pale cyan is nearly the colour of
the field it sits on, so the badge read as a smudge.

It is now a scheme role (`ColorScheme.composerAttachDot = primary`), which also
retires the last hardcoded hex outside the seeds and the avatar palette. Light
gives #0B57D0, dark #A8C7FA, and under Dynamic it follows the wallpaper accent.

A dot colour has no text equivalent, so the composer logs `ComposerDot
color=#RRGGBB` and `test-composer-dot.sh` opens a chat in both themes and compares
them: green reports #0B57D0 and #A8C7FA; the mutation (dot back to the cyan) fails
with "the dot is still the dark-composer cyan in light mode".

## Opening a long chat no longer flashes (2026-10-30)

Reported twice: "in one chat screen I have so many messages ... when I open chat I
see chat flickering every time I open chat". Not reproducible on the emulator —
swiftshader at 60 Hz swallows a one-frame flash — so this was fixed from
measurement, not from watching it. Confirm the visual result on a real phone.

Instrumented cold open of a 300-message thread:

```
7 chunk loads, 8 bottom snaps, 0 anchor restores, in 2.5s
```

Each preload inserted 40 rows above the viewport while the list was parked at the
bottom: the visible rows shift for a frame, then the follow-bottom snap pulls them
back. One flash per chunk, seven per open.

Two changes:

- **Older history loads when the reader reaches the top** of the loaded window
  (`shouldLoadEarlier`, three rows of slack), not while parked at the bottom. A
  reach at the top loads one chunk, capped as before; the "load earlier" button
  still covers the cap.
- **The follow-bottom effect stopped being a 4-second wall clock.** It re-snaps
  only while the newest row's bottom is below the viewport, then stops (10s
  safety cap). That removes the twitch after a picture decodes, and fixes a race
  the old window masked: a slow first query outlived the 4s window, so the chat
  opened at the *top* of the loaded rows.

Script: `test-chat-open-stability.sh` seeds 300 messages and asserts the open
prepends nothing (`ChatPreload` stays silent), lands on the newest message, and
that scrolling to the top does load. Mutation — back to "load whenever parked" —
restores the 7 preloads and the script fails.

## Legacy settings share one sheet colour (2026-10-30)

Reported: "in old UI General settings and Advanced setting background colour is
different".

Only `LegacySettingsScreen` set the Scaffold's `containerColor` to the settings
sheet; `LegacyAdvancedSettingsScreen` and `LegacyAccessibilityScreen` fell back
to the theme background, so opening either changed the page colour under the rows
— the mismatch was one tap deeper than the screen that looked right.

The colour now lives in `LegacySettingsScaffold`, which paints the page for all
three screens, and the app bars keep the same role.

**A per-screen report was tried first and was useless.** Each screen logged
`MaterialTheme.colorScheme.surfaceContainer` itself, so removing the Scaffold's
colour left the report saying the right thing — the same duplication that once
had Diagnostics agree with a broken theme. Now the shared scaffold is the only
place that colour exists: a screen that goes back to its own `Scaffold` reports
nothing at all, and `test-legacy-settings-colours.sh` fails on the missing line.

Testing a pixel value without a screenshot: the scaffold logs
`SettingsColors screen=<name> page=#RRGGBB row=#RRGGBB`, and
`test-legacy-settings-colours.sh` opens both screens and compares the two page
colours (green: `page=#1E1F20` twice; mutation, Advanced back on a plain
`Scaffold`: "no colour reported by advanced settings").

## Regional calendars in every date (#363, 2026-10-30)

Dates can now render in Jalali (Persian), Umm al-Qura Hijri, Hebrew, Buddhist,
Japanese, Indian (Saka) or Coptic, chosen in **Advanced settings → Calendar**,
with "Automatic" as the default: `fa` phones get Jalali, `ar` phones Hijri,
everyone else Gregorian. The picker keeps Automatic first (it is the default,
not a calendar) and sorts the rest by the label on screen, so each language gets
its own alphabet.

No dependency was added. Android ships `android.icu.util` with no
`PersianCalendar` *class*, but `Calendar.getInstance(TimeZone, ULocale)` still
builds one from the `@calendar=persian` keyword: `getType()` returns "persian",
the CLDR month names come out per language, and the digits localize on their own
(۱۴۰۵ for `fa`, ١٤٤٨ for `ar`). Verified on both AVDs, so API 30 (ICU 66) and
API 31 (ICU 69) agree.

Four decisions worth keeping:

- **Gregorian stays on `java.time`.** It is the only path whose CLDR behaviour
  the JVM tests can reach; ICU takes every other calendar. `CalendarSystem`
  encodes this as `icuKeyword == null`.
- **The era is stripped.** CLDR appends one to every non-Gregorian date ("Aban 4,
  1405 AP", "Jum. I 15, 1448 AH"), which is a suffix on every timestamp for
  information the chosen calendar already carries. Japanese is the exception
  (`keepsEra`): its year *is* an era year, so "Oct 26, 8" without "Reiwa" reads
  like a bug.
- **"Same year?" is asked in the displayed calendar** (`displayYear`), not the
  Gregorian one. Around Nowruz the two disagree, and a group label that dropped
  the year on a message from another Jalali year reads as if it belonged to the
  neighbouring label.
- **The picker is its own composable** (`CalendarPickerDialog`). It scrolls, and
  a route screen must never create its own scroll state — `SettingsScrollStateTest`
  catches exactly that.

Deliberately not shipped: the issue also asked for a secondary calendar beside
the primary one on every date. That doubles the width of every timestamp in a
list built for one; defer until someone asks again.

The schedule dialog keeps Material3's month grid, which is Gregorian by
construction — it has no calendar parameter at all. Instead of rebuilding a grid
per calendar, the dialog names the picked day underneath it: "In your calendar:
Kartika 8, 1948" (`chat_schedule_calendar_hint`, hidden for Gregorian, formatted
in UTC because the picker hands back UTC midnight).

Also not wired: **Legacy settings** (`use_new_ui = false`) has no Calendar row.
The choice still applies — rendering is shared — but a legacy-UI user cannot
change it. Add the row there if the legacy surface is ever revived.

Tested by `test-calendar.sh` (14 assertions, green on `emulator-5557` and
`emulator-5558`): seeds a pinned conversation at a fixed instant (2026-10-26,
1405-08-04 Jalali / 1448-05-15 Umm al-Qura), asserts Gregorian by default, then
Jalali in the chat label, the list date and the Diagnostics sample, then Hijri,
then back to Gregorian. `CalendarDatesTest` pins the pure decisions
(storage values, language mapping, era stripping) because ICU cannot run
off-device.

Limitation: `cmd locale` does not exist on either AVD, so per-app language
switching cannot be exercised on-device — the `fa → Jalali` and `ar → Hijri`
mappings are covered by the unit test only, and the script can only walk
Automatic → Gregorian.

## Chat opens from the bottom, like GM (2026-10-30)

Recorded GM opening a chat (`screenrecord` + frame diff): the chat panel rises
**vertically** over the still-visible list with rounded corners — it does not
slide sideways. Ours pushed horizontally like a page change, which is what the
"different from GM" note was about.

`MainActivity`'s `AnimatedContent` now special-cases `list -> chat` as
`slideInVertically` from the bottom, and `chat -> list` as the reverse slide-out.
The incoming chat does not fade while it rises: with `fadeIn` the list showed
through the chat's own bubbles, because the fade applies to the whole layer,
background included.

Still different from GM: GM rounds the chat's top corners for the duration of the
transform; ours is square. That needs an animated clip shape, so it is left out
of this change.

## TODO: bubble sides collapse into one hue under a monochrome wallpaper (open)

Sampled from the reviewer's screenshot (#347, 2026-10-30):

```
bubble fill #FD8D94  (48,993 px)   one side
bubble fill #ED8087  (30,330 px)   the other side
text        #4C0312 / #5D101C
```

Two fills, ~6% lightness apart, **identical hue** — under a salmon/red wallpaper
palette both sides read as "the pink bubble".

Cause: both sides come from wallpaper-tinted roles.

```kotlin
val ColorScheme.outgoingBubble: Color get() = primaryContainer        // accent
val ColorScheme.incomingBubble: Color get() = surfaceContainerHighest // also tinted
```

GM never hits this: outgoing is its accent, incoming is a **neutral grey**, so the
pair is always colour-vs-grey. Fix is to strip the chroma from the incoming fill
(keep its lightness and its `onSurface` ink) so the distinction survives any
palette; outgoing keeps following the accent.

Not done yet — it changes bubble colours under Dynamic, so it needs a decision.
Test when it is done: incoming chroma ≤0.08 and outgoing ≥0.12 across a matrix of
monochrome seeds (salmon, blue, green), plus a readability check on the pair.

## Avatars match Google Messages exactly (2026-10-30, decision)

Raised by the #347 review ("contacts colors not adaptive"). A contrast floor on
the fill was implemented, measured and **removed**: keeping a contact's palette
colour only when it clears 3:1 against the page turned every light-mode chip into
a saturated mid tone (cyan, green, amber, teal, pink, coral, orange and blue are
all below 3:1 on white), and it stopped looking like Messages.

Measured on GM instead: the fills are identical in light and dark
(`#FF63B8` in both), there is no ring, and its own white glyph on pink is
2.58:1. GM leans on chromatic contrast and the silhouette rather than luminance,
and the low-chroma entries (brown, indigo, blue-grey) that genuinely blend on
dark are the price of that look.

So: the palette, the hash-based choice and the night-mode ink stay as they are.
`Components.kt` carries that reasoning, `AvatarThemeResolutionTest` pins it (no
surface-dependent selection may reappear), and the contrast work is reverted in
`6f4f3b7` / `1804388`.

## Themed app icon: filled bubble, lines cut out (2026-10-30)

Two rounds of feedback. First: "in system dynamic the app icon lines are not
showing". The `<monochrome>` layer pointed at the **coloured** foreground, which
draws a filled white bubble with blue strokes for the message lines; a themed
icon tints the whole drawable one colour, so the strokes merged into the fill and
the icon rendered as a blank shape. It was changed to line art — which then read
as the wrong way round: "outside of line be fill with color it was before, lines
should be light color".

Reviewed decision (option A of three rendered): a **filled** bubble with the
three lines **cut out** of it. A monochrome layer is a mask, so "light lines on a
filled plate" can only be expressed as holes — one `evenOdd` path whose line
capsules (the 2.5dp strokes expanded to their outer edge) subtract from the
bubble. Nothing is stroked in that layer; an opaque stroke is exactly how the
blank-shape bug happened.

Limits that are not fixable in the app: the launcher picks both colours (plate
and tint), so in a dark-theme launcher the pair inverts — light bubble, dark
lines. The rendered comparison lives at
`/tmp/opencode/icons/icon-option-a-final.png` (light and dark faces). Verified by
rendering the real `pathData` with `fill-rule=evenodd`, not by mock-up art.

Not reproducible on emulator-5558: themed icons arrived in Android 13 and this
AVD is API 31, so the layer is only exercised on a 13+ device. `ThemedIconTest`
pins the wiring, the `evenOdd` fill, the three capsules at the coloured icon's
line positions, and the absence of strokes. The coloured icon is untouched.

## Chat-details switches match settings (#347 review, 2026-10-30)

## Chat-details switches match settings (#347 review, 2026-10-30)

The reviewer's second point: "switch in chat details is not follows style of other
switches in settings (badly maintained colors)".

They were right about the inconsistency, but the settings rows were the correct
side. Material's default pair in this scheme resolves to a light track with a
dark thumb — which is exactly how Google Messages draws a switch — while the
details screen overrode it with the *inverse* (thumb = primary, track =
primaryContainer). The overrides are gone, so both screens now draw the same
control.

## Hold-Send shrinks the circle, then the calendar (2026-10-30)

Scheduling is reached by holding Send, and the press used to give no feedback:
the calendar simply appeared under the finger. Now the send circle shrinks to
45% over `DURATION_MEDIUM1`, sits small for a beat (the picker opens at
`DURATION_MEDIUM1 + 220ms`), and then the date picker animates in. With the
`Scheduled messages` setting off, holding does nothing at all.

The first attempt at this — a "Schedule" label bubble above the button — was
wrong and was reverted without being pushed; the built behaviour is the shrink,
as described.

Refinements after looking at it: the shrink went from 0.45 (the button nearly
vanished) to 0.8, and the picker now animates itself — `ScheduleDialog` scales
and fades from `TransformOrigin(1f, 1f)`, the corner the send button sits in,
instead of a centred `DatePickerDialog` that just appeared. Making it a plain
`Dialog` needed `usePlatformDefaultWidth = false`: the platform cap is below the
DatePicker's 360dp minimum, which cut the Saturday column off the calendar.

Tests: `ScheduleHoldAnimationTest` (6); `ScheduleLongPressTest` re-pinned to the
hold state. Script `test-schedule-hold.sh` (5) replaces
`test-schedule-affordance.sh`, which pinned the clock button that no longer
exists.

## Owner avatar, and two settings rows without descriptions (2026-10-30)

**The app's own avatar reads the device profile.** The header avatar and the
empty-state avatar were a fixed silhouette with `"sms-launcher"` as a contact
key, so a profile picture set on the phone was never shown. `OwnerAvatar` reads
`ContactsContract.Profile.CONTENT_URI` (`CommonDataKinds.Photo.PHOTO_URI`) and
draws the photo; with no profile photo, or without READ_CONTACTS, it falls back
to the silhouette in the colours each site already used.

**Backup messages lost its description; Import messages keeps its own**
("Restore a backup"), as asked — only the backup row is a bare label.

**Owner avatar testing, honestly:** the fallback was verified on the device (no
profile photo → the same silhouette in the same colours). The photo path could
not be exercised on this AVD: `content query content://com.android.contacts/profile`
returns a *virtual* profile row and `raw_contacts` is empty, and the AOSP Contacts
editor offers "Saving to My Google profile" but never writes a raw contact
without an account. So the positive path rests on the query plus
`OwnerAvatarTest`; set a profile photo on a real phone to see it.

## The conversation list blinked; the cross-fade is gone (2026-10-30)

Reported after installing the build: "sometimes I open chat screen and all chats
become blinking".

The cause was mine: the motion pass wrapped the whole conversation surface —
skeleton, list and empty panel — in a `Crossfade`. A cross-fade keeps both
states composed and draws them at partial alpha, so every row is painted twice
while it runs. Replacing the skeleton with the list, or closing a chat back into
it, therefore looked like the list blinking rather than a transition.

The surface swaps instantly again. Row-level motion stays: `animateItem` on the
conversations, chat rows and the other lists is per-row and does not double-draw
the screen. `MotionPolishTest` now asserts the whole-list surface is *not*
cross-faded, so it cannot come back.

## Cleared notifications stayed cleared; per-conversation bubbles (2026-10-30)

Reported after installing a build on a real device: cleared notifications came
back, and "Mark all as read" left the shade untouched. Two independent causes,
both real:

1. **The re-post had no idea a notification had been dismissed.** `BootReceiver`
   fires on `ACTION_MY_PACKAGE_REPLACED` as well as boot, and `repostUnread`
   re-posted every unread conversation — including ones the user had swiped away.
   It now records the dismissal: every conversation notification carries a
   delete intent (`NotificationDismissReceiver`) that stores "dealt with up to
   now" (`SettingsStore.notifClearedUpTo` / `markNotifCleared`), and the re-post
   skips a conversation whose marker is at or past its newest message. A newer
   message still posts.
2. **Mark all as read never cancelled anything.** `markAllReadSuspend` zeroed
   `unread_count` in the database only, so the notifications for the messages it
   had just read stayed on screen. The ViewModel now calls
   `NotificationHelper.cancelAll` after the update.

**Per-conversation bubbles** are back, as a switch in the chat's details screen
("Show in a bubble", on by default). Android's per-app Bubbles page remains the
app-wide switch; this is the per-thread one, which is what GM offers. It is a
plain `bubble_off_<id>` preference read by
`SmsSupport.show` before attaching bubble metadata.

**Mark all as read vs a live bubble — measured in GM, not assumed.** GM's
notification has a MARK AS READ action, and while a bubble was floating for that
chat: tapping it cleared the row's unread badge, and the notification stayed
posted (`flags=0x1010`, `shortcut=73`) with the bubble still on screen. GM has no
"mark all as read" command in this build (the list has no overflow; the profile
avatar is account-gated), so the per-conversation action is the closest analogue,
and it keeps the bubble. Our sweep therefore skips notifications a live bubble
host owns — a blanket cancel would collapse the bubble, because cancelling a
notification is what closes it.

Tests: `NotificationDismissTest` (5) and `PerConversationBubblesTest` (4);
`BadgeRepostWiringTest` re-pinned to the new `show(context, row.address, …)` call.
Script `test-notification-repost.sh`: message → notification → swipe it away →
`install -r` → still gone → a newer message still posts → Mark all as read
clears the shade.

## QUIK import, pinch-zoom option, list animations (2026-10-30)

**QUIK (QKSMS) backup import.** QUIK 4.3.7 was installed on emulator-5558 and a
real backup taken through its own *Backup and restore* screen — 101 messages,
23 KB, at `/sdcard/Download/quikbackup/backup-20261030003332.json`. The format is
a single object, not an array:

`{"messageCount":N,"messages":[{"type":1,"address":"…","date":…,"dateSent":0,
"read":true,"status":0,"body":"…","protocol":0,"locked":false,"subId":-1}]}`

Three things differ from the sms-ie records the importer already reads: the
messages sit under a wrapper object, `read` is a boolean rather than 0/1, and
`serviceCenter` is omitted when null. `QuikBackup` converts each message to the
sms-ie shape (read → 0/1, type kept as `Telephony.Sms.TYPE`, `date_sent` kept
when non-zero) and `Repository.importQuikFrom` hands the converted records to
`importStaged`, so dedupe, merge/replace, the provider mirror and the transfer
log are shared with the existing importer rather than reimplemented.

QUIK's own screen says "Currently, only SMS is supported by Backup and Restore":
there is nothing else in the file — no MMS, no settings, no blocked numbers — so
"import everything" means every field it does write, which the conversion keeps.

It is the third option inside **Import messages**, not a second row: one import
entry, three formats.

**Pinch to zoom** moved to Inbox settings as a bare switch (no description), sitting
directly above Forwarding. Off means the pointer
handler is not installed at all, so a two-finger drag scrolls the list instead of
being captured by a gesture that would then do nothing.

**Animation** added to the lists that still jumped: Add people, New chat,
Scheduled messages, Spam & Blocked (conversations and messages), Trash
(conversations and messages) and the transfer log. Every list that shows rows
now animates placement.

## Composer pill and the attach badge (2026-10-30)

Two visual matches to Google Messages, both measured off the running app rather
than eyeballed.

**Pill.** GM's composer field is 154px (56dp) tall and rounds to 28dp — half its
height, i.e. a true pill. Ours was already the same height but rounded to 24dp,
which reads as a rounded rectangle next to it. `ComposerShapeTest` pins the pair.

**Attach badge.** The "+" in GM carries a dot on the ring's top-right: `#76D1FF`,
~10dp, overlapping the ring so the ring reads as broken at that point. Ours draws
the same dot with a ring of `inputPill` around it (that ring is what cuts the
icon). The colour is the one composer colour that is not a scheme role, so it
lives in `Theme.kt` as `ComposerAttachDot`; `ComposerAttachDotTest` pins the hex,
the top-right placement, the cut-out ring, and that the badge stays decorative.

## Scheduling is discoverable again (#386, 2026-10-29)

The report: "the app claims you can schedule messages … but I don't see any UI
indicator to do so", from an F-Droid install of 1.0.30. Two things were wrong,
and the second was worse than the report knew:

1. The only way to schedule was a **long-press on Send**, with no hint anywhere.
2. `SettingsStore.scheduledMessagesEnabled` was written by the *legacy* settings
   toggle and **read nowhere** — flipping it changed nothing, which is what
   "even after enabling the option" was hitting.

Hold-Send stays the only way in, as before #386: the answer to the report is
that the gesture exists, not another button in the row. What was actually broken
is still fixed — the preference now gates the gesture instead of being written
and never read, and it is exposed in the new Advanced settings screen rather
than only the legacy one.

The composer's Send circle is **always** on screen, dimmed (alpha 0.38) and
inert while there is nothing to send, rather than shrinking away: round 2 of
#347 hid it and the empty chat row read as unfinished.

Tests: `ScheduleLongPressTest` (3) pins hold-Send, the absence of a clock
button, and the setting that gates it. `AppearanceOptionsTest` now pins the
always-visible dimmed Send.
`AppearanceOptionsTest`'s send-button anchor became a regex instead of the exact
one-line `combinedClickable(...)`, since that call is now multi-line. Script
`test-schedule-affordance.sh`: an empty composer shows no control, typing shows
one, tapping opens the picker, and turning the setting off removes it.

## Bubbles is Android's page again (2026-10-29)

The in-app Bubbles page is gone. Android's per-app Bubbles screen
(`ACTION_APP_NOTIFICATION_BUBBLE_SETTINGS`) already offers the same All /
Selected / Nothing choice for this app, and its answer is what the platform
actually enforces, so keeping ours meant two places deciding the same thing —
exactly the kind of drift that put `#000000` in Diagnostics while the theme
painted `#131314`.

Removed: `ui/BubblesSettingsScreen.kt`, its previews, `sms/BubblePolicy.kt`,
`SettingsStore.bubblesMode` / `bubbleSelectedConversations` (+ their keys),
`SmsSupport`'s gate (back to `NotificationBubble.shouldAttach`), the
per-conversation "Show in a bubble" row in `ContactDetailsScreen`, the
`bubbles` route and its strings. The General settings row keeps GM's label-only
look and now calls `openSystemBubbleSettings(context)`.

Tests: `BubblePolicyTest` and `SettingsBubblesTest` deleted with the feature;
`MotionPolishTest` and `PreviewCoverageTest` no longer reference the page.
Script `test-settings-bubbles.sh` rewritten around the system hand-off: the row
must land in `com.android.settings/*Bubble*`, and flipping the platform switch
off must remove the BUBBLE flag from a real notification.

## Bubbles page polish; one sheet colour for every settings screen (2026-10-29)

Three fixes after looking at the page on the emulator next to GM.

**The icon is the app's own.** It was `ic_launcher_foreground` tinted with
`primary`, which is a monochrome glyph, not the launcher icon. The page now asks
`PackageManager.getApplicationIcon` for the real adaptive icon and draws those
bitmap pixels, keeping the bundled foreground only as a fallback for previews
where there is no launcher icon.

**The cards are GM's size.** Measured off the running GM page: 52dp tall with a
16dp gap. Ours were 68dp with a 12dp gap — the row padding drops 22dp → 14dp
(24dp icon + 14 above and below = 52dp), the gap becomes 16dp, and the title
moves up to `displayMedium` to match GM's oversized heading.

**Every settings screen is the same sheet.** General settings had been
re-skinned to GM's colours while Advanced/Accessibility/Inbox and the
`SettingsScaffold` sub-screens still used the default roles, so the page colour
changed as soon as you navigated. A settings row is now *always* the page
background and a settings page *always* paints `surfaceContainer` behind itself
and its app bar; `LocalSettingsRowColor` (the per-screen override) is gone, so no
screen can drift from another. Verified: Advanced settings measures `#1E1F20`
sheet / `#131314` rows, identical to General settings.

The three choices are real, not decorative — measured from `dumpsys notification`
on emulator-5558 with the platform bubbles permission ON: under "All
conversations", `flags=0x1010` (BUBBLE|AUTO_CANCEL) and `shortcut=conversation_61`;
under "Selected conversations" with 61 picked in its details screen, the same
`0x1010`, while an unpicked conversation gets `flags=0x10` and `shortcut=null`;
under "Nothing", no bubble at all. The details switch also wrote
`<set name="bubble_selected_conversations"><string>61</string></set>` when
toggled, which is the value the policy read.

## Bubbles page, settings colours, GM-per-conversation bubbles (2026-10-29)

Three rounds of feedback, each checked against Google Messages on emulator-5558
rather than guessed.

**The settings sheet was too black.** GM paints its General settings as a raised
sheet (`#1E1F20` — verified pixel-for-pixel) with the rows *inset darker*
(`#131314`) and a 2dp gap between them. The page and row roles were already
right; the black band was the **top app bar**, which Material 3 defaults to the
page background (`#131314`). It now takes `surfaceContainer` too, so the title
band, the gaps and the status bar are all `#1E1F20` and only the rows are
`#131314`. Both colours are logged as `SettingsColors page=#… row=#…`.

**"Bubbles" is a page, not a dialog or a subtitle.** GM's row is the bare label
and opens a full sub-screen: back arrow, oversized title, the app's own icon and
name, then three outlined choice cards with no descriptions — the selected one
filled `#2E3133`, outlined in the accent and tinted. Ours mirrors that
(`ui/BubblesSettingsScreen.kt`), on a `bubbles` route at depth 3, and the row
carries no subtitle.

**All three choices work**, not just on/off:
`SettingsStore.bubblesMode` is `all` / `selected` / `none`, and the set is read
through one function — `sms/BubblePolicy.allows(mode, selected, conversationId)`
— which `SmsSupport.show` consults before attaching bubble metadata. Under
`selected`, the conversation's own details screen grows a "Show in a bubble"
switch (`ContactDetailsScreen`), shown only in that mode so it is never a dead
control. The platform's bubbles permission remains a separate gate.

Tests: `BubblePolicyTest` (6) pins the three modes, the empty pick, a null
conversation and an unknown future mode; `SettingsBubblesTest` (9) covers the
label-only row, the route and depth, the three choices, the per-conversation
switch and string parity across all 13 locales; `BubblesSettingsPage` is
state-hoisted so `BubblesPreviews.kt` can render it without a ViewModel and
`PreviewCoverageTest` stays green. 1053 tests, 0 failures. Scripts:
`test-settings-bubbles.sh` drives the page (three options, `Nothing` stored,
bubble flag gone with the platform permission still ON) and
`test-fresh-defaults.sh` covers the new-user defaults.

## New-user defaults, a Bubbles row, and Google Messages' settings colours (2026-10-29)

Four things, all from comparing against Google Messages on emulator-5558.

**Defaults for a fresh install.** A first-time install now starts on the
redesigned UI and **DM Sans**. The UI switch already defaulted to the new
screens (`prefs.getBoolean(KEY_USE_NEW_UI, true)`) — only its doc comment
claimed legacy was the default, so that was corrected rather than the code. The
font needed a seed: `SettingsStore` is now told apart a *new* install from an
*updated* one by `firstInstallTime == lastUpdateTime`, and writes
`font_family=dm_sans` once when the package is new and nothing is stored. An
update therefore never restyles the app under someone who never touched the
setting, and an explicit choice always wins. The getter's fallback stays
`FONT_SYSTEM` so only the seed moves a new user.

**"Bubbles" in General settings**, as GM lists it under the notification rows.
`SettingsStore.bubblesMode` (`all` | `none`, default `all`) gates the bubble
metadata in `SmsSupport.show`: `convoId?.takeIf { bubblesWanted &&
NotificationBubble.shouldAttach(…) }`. The platform's own bubbles permission is
a separate gate and still applies. GM's third choice ("only selected
conversations") is not implemented — it needs a per-conversation opt-in that has
no UI yet.

**Settings colours.** Measured off GM's General settings: the sheet is a raised
page `#1E1F20` with rows inset at `#131314` (dark), the inverse of our previous
look (page `#131314`, rows `#1B1B1D`). The screen now paints
`surfaceContainer` behind rows and publishes `background` to `SettingsRow`
through `LocalSettingsRowColor`, so the legacy settings screen keeps its old
role. Both colours are logged as `SettingsColors page=#… row=#…` — pixels have
no text equivalent, so the script asserts the pattern from logcat instead of a
screenshot.

Tests: `FreshInstallDefaultsTest` (7), `SettingsBubblesTest` (7) covering the
pref default, the notification gate, the row + chooser, the colour roles, the
log line, and string parity across all 13 locales. Scripts
`test-fresh-defaults.sh` (fresh install seeds dm_sans + new settings UI; a
reinstall over the package does NOT) and `test-settings-bubbles.sh` (row and
subtitle, `#1E1F20`/`#131314`, bubble flag with the choice `all`, no bubble
flag after `none`, choice survives a restart).

Answering a side question while doing this: Google Messages' own settings could
not be opened from its UI because (a) another app held the default-SMS role, so
GM showed "To use Messages, make it your default SMS app" and disabled its
menus, and (b) even with the role, the profile avatar that now hosts Settings is
an account gate and this AVD has **0 accounts**. `am start -n
com.google.android.apps.messaging/.ui.appsettings.ApplicationSettingsActivity`
opens it regardless, which is how the colours above were measured.

## Pill and avatars re-based on Google Messages' measured colours (#347 round 3, 2026-10-29)

The round-2 palette read as ugly on a muted wallpaper: the Start chat pill went
`primary` — a solid accent slab that turns dead grey when the wallpaper's
primary is dim — and Dynamic harmonized every avatar 25% toward that accent,
which desaturated the bright GM chips into near-black mud on a slate wallpaper.

Both were re-measured off Google Messages running on emulator-5558, sampled
from screenshots rather than eyeballed:

| Element | GM light | GM dark |
|---|---|---|
| Page background | `#FFFFFF` | `#131314` |
| Top bar | `#F0F4F9` | `#1E1F20` |
| Start chat pill fill | `#D3E3FD` | `#0842A0` |
| Start chat pill ink | `#0842A0` | `#D3E3FD` |
| Avatar fills | `#AF5CF7` `#FA903E` `#4ECDE6` `#FF63B8` | identical |
| Avatar glyph | `#FFFFFF` | `#202124` |

So the pill is the scheme's **primaryContainer** (GM's pill is exactly our light
`primaryContainer` and our dark `primaryContainer`/`onPrimaryContainer` pair),
with `primary` as the ink on a light container and `onPrimaryContainer` on a
dark one. Confirmed pixel-exact after the change: the app paints
`#0842A0` + `#D3E3FD` in dark and `#D3E3FD` + blue ink in light.

Avatars are back to the fixed GM palette in every mode — the theme only flips
the silhouette ink, white on a light scheme and `#202124` on a dark one, through
one function (`ui/Components.kt: avatarGlyphInk`). `avatarsFollowTheme`,
`LocalThemedAvatars`, the HSL harmonizer and `avatarFill`/`avatarOnFill` are gone;
Diagnostics now reports `Avatar ink: #RRGGBB on the fixed GM palette`, resolved
through that same function, so the report cannot disagree with the paint.

Tests: `StartChatPillColorTest` (9, pins the GM hex values per theme),
`AvatarThemeResolutionTest` (6, rewritten: fills fixed, ink flips, one rule),
`ConversationListWiringTest` anchor updated, `DynamicAvatarHarmonizeTest`
deleted with the feature. Scripts re-pinned: `test-start-chat-colours.sh`,
`test-avatar-theme-dynamic.sh`, `test-347-dynamic-colors.sh` (its three seeded
pairs and its avatar line).

Still open for a decision: the palette list still carries 11 Material-500 fillers
(`#FF9800`, `#2196F3`, `#4CAF50`, `#607D8B`, …) that GM never shows. GM appears
to use only the first five entries, so trimming to those would match GM exactly
at the cost of more contacts sharing a colour.

## Opening a chat full-screen retires its floating bubble (#354 round 3, 2026-10-28)

The reporter's third follow-up: with a conversation bubbled and then hosted
collapsed (open the bubble once → Home collapses it to a floating icon while
its activity task keeps hosting), opening that conversation full-screen left
the bubble floating over the chat it duplicated. Root cause: the chat's
mark-read dismissal (`clearConversationNotification`) is *deferred* for any
conversation a live bubble host owns, and the ordinary launch-path clears —
by conversation id in the list, by address hash on `open_conversation_address`
launch — never touch the hosted bubble either.

New `NotificationHelper.retireBubbleForFullChat(context, conversationId)`
(SmsSupport.kt): releases the held conversation from `BubbleHost`, then
cancels the notification (plain id + `"failed"` tag) — cancelling a
notification is what collapses its bubble. Wired into both in-app open paths
in MainActivity: the list row's `onOpenConversation` (both UIs) and the
`open_conversation_address` launch, each called only after the conversation id
is resolved and only on non-bubble launches.

Tests: `NotificationBubbleFullChatRetireTest` (BubbleHost lifecycle + wiring
anchors). Script `test-bubble-fullchat.sh`: bubbles on → message → bubble
floats → hosted → Home-collapse → full-screen open by address → asserts the
bubble surface AND its notification are gone; pre-fix it fails both
(verifed via probe on the stashed build: `bubbles=3 notif=live`).

Pre-existing on emulator-5558 this round (not touched by the change, present
on the pre-fix build identical): `test-notification-bubbles.sh` FAILs on
largeIcon/BubbleIcon (logcat `-s BubbleIcon:D` shows no record for a fresh
sender) and on "Back leaves the bubble open" (Back collapses/resolves the
bubble to gone instead of its floating icon). Both emulated flows worked 2
days ago; treat as AVD drift and re-verify before debugging app code.

## Badge survives reboot and app update; card-mask digits; dialog punctuation (#345 round 2, 2026-10-26)


Three fixes for the follow-up comments on #345 (Samsung A54, Persian locale,
One UI 8.5):

1. **Badge dies after reboot / app update.** A boot and an app update wipe the
   notification shade, and the launcher badge sums the numbers of the app's
   live notifications — unread messages survived in the database but lost
   their badge ("the phone turned off and on again; the counter no longer
   shows any number"). New `sms/BootReceiver` (non-exported,
   `BOOT_COMPLETED` + `MY_PACKAGE_REPLACED`, `RECEIVE_BOOT_COMPLETED`
   permission) calls `NotificationHelper.repostUnread`: one **silent**
   re-post per unread conversation, via `show(silentRepost = true)` (no
   sound, no full-screen wake). It is deliberately NOT wired to onResume —
   a re-post there would resurrect notifications the user dismissed.
   `Repository.unreadForRepostBlocking` selects the same rows the receive
   path posts for (not deleted, not blocked, unread, non-empty snippet).
2. **Card-mask digits reorder inside Persian text.** `5022-29xx-xxxx-9227`
   broke into fragments around the strong-LTR `x` masks and only read
   correctly once selected. `BidiText.NUMBER_RUN` now swallows `xX*` so a
   masked card stays one LTR isolate (verified against the reporter's
   verbatim Pasargad body).
3. **Dialog punctuation parked at the visual start.** On a Persian-locale
   device every window is RTL while this app's strings are English (no
   values-fa yet), so the mark-all-read dialog's trailing "?" painted at the
   visual start. New `directionalStyle()` in `Components.kt` paints dialog
   copy in the string's own strong direction (both settings UIs) and logs
   `DialogBidi dir=Ltr|Rtl` — the paint order itself is invisible to a
   dump, so the direction is reported like BubbleDirection/ComposerDirection.

Tests: `BadgeRepostWiringTest`, `DialogDirectionTest`, and two new
`BidiTextTest` cases (masked cards, the verbatim Pasargad body). Scripts:
`test-badge-reboot.sh` (real arrivals → `adb reboot` → shade re-posted with
the same per-conversation numbers → `adb install -r` → re-posted again),
`test-bidi-card-numbers.sh`, `test-dialog-rtl-punctuation.sh`;
`test-notification-badge.sh` gained the reporter's "6 messages from one
number" case (six arrivals leave `number=6` on the sender notification, so
a launcher-side 0 with the in-app row at 6 is the launcher's rendering, not
the app's count). Pre-fix build: bidi script 4 FAIL, dialog script 2 FAIL,
reboot script FAIL on both re-post assertions (after reboot AND after a
same-version reinstall, verified by updating the device with the pre-fix
APK). Post-fix: all green on emulator-5558, plus 11 PASS
(test-notification-badge), 16 PASS (test-mark-all-read-confirm), and
test-blocked-badge / test-bidi-persian-amount / test-bidi-bank-time /
test-rtl-direction / test-no-network-permission all pass.

Not fixed in this round (reporter follow-up needed): the missing-SMS +
~7h timestamp skew (needs the reporter's logs and a default-handler
confirmation — suspect a non-default-handler import gap or SMSC skew;
`requeryFromSystem` only runs when `needsInitialImport`), and
"6 messages → badge 0" on the launcher side (the app-side number is now
proven correct). values-fa translation would fix the whole English-in-RTL
window class at the root.

## Blocked senders no longer leak into the icon badge (#345, 2026-10-25)

A launcher badge sums the numbers the app's live notifications carry, and the
count a thread publishes is its own unread total. Blocking a sender left its
notification alive: the messages it counted stay unread in Spam & blocked, and
the messages that follow a block are never posted (the receiver files them
silently), so nothing ever replaced or cancelled the number. The icon kept
counting a sender the user had explicitly silenced.

`Repository.blockNumber` now cancels every notification the sender owns —
one per matching conversation row (both address spellings, the same rows
`setConversationBlockedForAddress` flags, via `blockedConversationIds`) plus the
address-hash id `NotificationHelper.show` falls back to when no conversation row
existed — through the new `NotificationHelper.clearBlockedConversationNotifications`.
Both the plain id and the `"failed"` tag are cancelled, and an id a live bubble
host owns is skipped, exactly like `clearConversationNotification`.

Tests: `BadgePolicyTest` pins `idsToDismissOnBlock` (every conversation id, the
hash fallback, dedupe of Long→Int collisions, empty input) and
`BlockedBadgeDismissTest` anchors the wiring (blockNumber calls the helper,
the helper cancels both tags, skips held bubbles, and queries the same address
rows the flag uses). Script `test-blocked-badge.sh` receives two SMS, blocks the
sender from the conversation row sheet (not the chat — opening the chat would
mark it read and dismiss the notification, masking the bug), then asserts the
live notification id is gone, a later SMS from the blocked sender posts no
number, all messages survive in the folder, and the flag is set. Pre-fix build:
2 of 6 FAIL (`notification for id N still live`, `posted number=2`). Post-fix:
6/6 PASS on emulator-5558.

AVD note from this session: `Pixel_AOSP12_AOSP31`'s ramdisk.img had been
re-patched as a **gzip** cpio; this kernel accepts only the legacy-LZ4 framing,
so first-stage `init` aborted with `Failed to mount required partitions early`
and the guest reboot-looped forever (gray window, adb permanently `offline`).
The pristine `x86_64/ramdisk.img` from `x86_64-31_r05.zip` boots fine, and this
image's adbd works without the `persist.sys.usb.config=adb` rewrite — so leave
the stock LZ4 ramdisk in place. `adb root` gives uid 0 (userdebug) which covers
the `su -c` paths, and `run-as` covers the rest.

### The other half of #345 — Saman's split balance — verified against the report

The screenshots on the issue (which only became readable late, from the
`user-attachments` URLs in the issue body) show two distinct problems on
**v1.0.30**: a launcher badge of 4 while the inbox sums 30 unread messages
(the per-conversation count), and a Saman balance painted as
`78,556 مانده ,010`. The badge half is the `BadgePolicy.badgeCount` change
already on `Develop` (v1.0.31); the balance half is `BidiText.isolateNumberRuns`,
which already permits ASCII **and** Persian digits with ASCII, Arabic and
Arabic-Indic separators — but the issue's own string was only covered in the
Persian-digit form. `BidiTextTest.isolatesAPersianLineBalanceWrittenInAsciiDigits`
and the new section of `test-bidi-persian-amount.sh` (seeded with the
photographed body verbatim, 7/7 PASS) pin the ASCII form, so the label cannot
land inside the amount again. What is left for #345 is a release: `9e63840`,
the v1.0.31 badge change and this block fix are all unreleased.


## Start chat pill back to the v1.0.30 colours (2026-10-25)

Feedback: the "Start chat" pill's background and text no longer matched the
v1.0.30 design. That was true — #347 had moved it from `secondaryContainer` +
`primary` to Material's FAB pair `primaryContainer`/`onPrimaryContainer` to fix a
wallpaper palette that made it dark-on-dark. In the seeded themes that swap is
plainly visible: light went from blue-on-pale-blue to near-black navy on a
slightly different blue, dark from light-blue-on-grey-blue to near-white on a
vivid blue.

The pill is back on the v1.0.30 pair: container `secondaryContainer`, content
`primary`. The legibility fix moved into the content rule instead of the pair —
`startChatContent` falls back to `onSecondaryContainer` only when `primary` on
`secondaryContainer` drops below 3:1 (the AVD wallpaper palette: 2.14:1 before).
Seeded light/dark/AMOLED/high-contrast themes all keep `primary`, and
Diagnostics still reports the pair the FAB paints with.

Tests: `StartChatPillColorTest` (5: seeded themes keep the v1.0.30 pair, high
contrast too, a dim wallpaper primary falls back, every resolved pair >= 3:1,
contrast helper sanity). `ConversationListWiringTest` now pins the new
definition. Script `test-start-chat-colours.sh` reads Diagnostics for
light/dark/amoled and compares against the exact seeded pairs — 3/3 FAIL on the
pre-fix build, 3/3 PASS after. `test-dynamic-theme.sh` still passes 5/0, so the
wallpaper fallback is covered too.

## Undo follows LIFO after consecutive swipes (#374, 2026-10-25)

Issue #374: archive six chats in a row and the one Undo snackbar you can see
restores the *first* one. Root cause was Material's `SnackbarHostState`: every
swipe launched its own `showSnackbar` call and those queue **FIFO**, so the
visible snackbar described the oldest action (and the remaining five appeared
one after another, oldest first). The screen now owns the order:

- `UndoStack<T>` (`ui/UndoStack.kt`) is the LIFO stack of pending actions.
- One presenter coroutine shows only the newest entry, cancelling the snackbar
  it replaces (`cancelAndJoin`), so a new swipe never queues behind the old one.
- Undo pops the newest action; the next entry is then offered, so repeated
  Undo keeps walking back. Closing the snackbar (timeout or swipe-away) clears
  the whole window, so stale actions cannot resurface later.
- Every swipe action (archive, delete, mark read/unread, pin, block) and both
  bulk actions go through the same stack.

Tests: `UndoStackTest` (LIFO order, peek does not consume, clear) and
`UndoSnackbarWiringTest` (one snackbar call, replacement cancel, all five swipe
handlers record through `showUndo`). Script `test-undo-lifo.sh` archives two
seeded chats back to back and asserts the *newer* one returns from a single
Undo — it fails 2 assertions on the pre-fix build and passes 8/8 after.

The script reads archive state from sqlite instead of negative uiautomator
dumps: a "row is gone" check costs three dumps (~10s) and outlives the snackbar,
which is what made the first draft report "no Undo snackbar" on a working app.

## Pinch-to-zoom that feels like Google Messages (#348, 2026-10-24)

The report: "not working like GM — I am not able to zoom pinch easily". Two
separate faults, both reproduced with a real two-finger gesture on the emulator:

- **The list ate the pinch.** `Modifier.transformable` on the LazyColumn lost the
  gesture to the list's own scroll: as soon as one finger moved, the scrollable
  consumed the pointers, and `detectTransformGestures` cancels when its changes
  are consumed — for the entire touch sequence. A real pinch starts with one
  finger landing a few milliseconds before the other, so that was the *normal*
  case: the chat only zoomed when both fingers landed on the same frame. The
  handler now watches in `PointerEventPass.Initial`, where it sees two-finger
  events before the scrollable can take them, and consumes them while zooming.
  Two-finger events that keep the finger distance unchanged are not consumed, so
  a two-finger drag still scrolls.
- **The magnitude was thrown away twice.** `transformable` only counts from the
  frame that beats the touch slop, and the start spread lived inside the
  `pointerInput` block, which Compose restarts whenever its lambda changes — and
  this chat recomposes on every zoom step. A 3.3x finger spread therefore moved
  the text 1.19x. `ChatZoom.pinch` measures the ratio from the spread at the
  moment the second finger landed, and `ChatZoom.Pinch` keeps that baseline
  outside the restartable block.

Measured against Google Messages (messages 2023.05.29 on a `google_apis` AVD,
same 1080x2400@420 screen, same injected gestures):

| gesture | Google Messages | Messages before | Messages now |
|---|---|---|---|
| both fingers land together, spread 3.3x | text 112px -> 346px (≈3.1x) | 119% | 250% (the ceiling) |
| one finger drags first, then pinch 3.3x | text 112px -> 346px | no zoom at all | 250% |
| 1.5x spread | — | 105% | 150% |
| pinch in | no change observed | 100% | 70% (the floor) |

So the gesture now matches GM on the two cases that were broken. The remaining
difference is the ceiling: GM reaches at least 3.1x where this app stops at
2.5x, so the same pinch grows visibly less. GM also did not shrink on a
pinch-in in that build; the 70% floor and the one-tap reset stay as they are.

Tests: `ChatZoomTest` (+3: spread, pinch ratio, the baseline surviving a restart),
`ZoomWiringTest` (the transformable assertions now assert the Initial-pass
handler and the consumed two-finger events). Script
`test-chat-pinch-zoom.sh` finally tests the *gesture*: `adb shell input` can only
inject one pointer, so it writes a real two-finger pinch to the emulator's
touchscreen node with `sendevent`. Fails 4/4 of the pinch cases on the old build
(1.19x and no zoom at all).

Emulator gotcha for the next person: the AVD exposes `virtio_input_multi_touch_1`
… `_11`, and **only `_1` is the touchscreen**. Writing to any other node is
silently ignored, which looks exactly like a broken pinch — half an hour went
into that. The script picks `_1` explicitly.

## Per-message RTL/LTR text direction (#362, 2026-10-24)
Issue #362: Persian messages in an English-locale app were laid out as if they
were English — lines hugged the left of the bubble and mixed Persian/English
text did not match Google Messages. Two different rules, because the two places
answer different questions:

- **Message text** — `BidiText.direction(text)`: the first and last strong
  characters decide. Weak characters never vote, so a trailing "!" or a phone
  number at the end is ignored; when the two ends disagree the **last** one
  wins, so "Order 48291 تکمیل شد" is laid out as Persian and "سلام OK" as
  English. The bubble paints through that value (`TextStyle.textDirection`).
- **Composer** — `BidiText.firstStrongDirection(text)`: Unicode P2, the first
  strong character alone, so the caret and the lines flip as soon as a Persian
  word is typed and do not flip back when an English word is appended.

`isolateNumberRuns` now decides through `direction()` too, so the isolate
transform and the painted base direction can never disagree (first strong was
Latin but last strong Persian used to render RTL with no isolates). Also fixed:
`BidiText`'s direction helpers are now unit-testable rather than a private
boolean.

Tests: `BidiTextDirectionTest` (9) — both rules, punctuation/digit immunity,
mixed ends, no-strong-character fallback, and the isolation/direction
agreement; `BidiTextTest.remapShiftsStyledRangeOverIsolates`'s fixture now ends
in Persian (it was mixed, so the new rule lays it out LTR and correctly
isolates nothing). Script `test-rtl-direction.sh` (10/0) drives the real UI and
asserts the `BubbleDirection` / `ComposerDirection` logcat markers the app emits
from the exact `TextStyle` it paints with. Fails 4/10 with the old
first-strong-only rule and a pinned-LTR composer. The composer case enters
Persian through the `sms:?body=` share path, since `adb shell input text` is
ASCII-only — a DB-seeded draft does not work, see below.

**Found, not fixed (separate bug):** `ChatScreen`'s draft restore is a lambda
literal that is never invoked — `if (convo != null && !draftLoaded) { { … } }` —
so a saved draft is never put back in the composer on re-open. It is why the
script seeds the composer through a share intent instead of the database.

### Follow-up from the issue thread (#362, 2026-10-26)
The reporter came back with real Persian broadcasts where the rule above still
picked the wrong direction:

- **Links voted.** `📣ارسال تپسی‌شاپ رایگان شد … l.tpshp.co/3lDXoA` is Persian,
  but the link's Latin letters are strong and sat last, so the *last*-strong
  rule laid the whole bubble out LTR. `direction()` now ignores link ranges:
  `BidiText.linkRanges` recognises both shapes an SMS carries — with a scheme
  or `www.`, and bare like `11r.eu/t` / `l.tpshp.co/3lDXoA`. A bare host needs
  a dot and a two-letter TLD, so "e.g" is not a link and still votes.
  `Linkify.WEB_URLS` remains the authority on what is *tappable*; this is only
  the direction side of the same question.
- **A line of nothing but numbers or a link was still laid out in the
  paragraph's direction.** `کد ورود …\n85904\n\n@tabdeal.org #85904\nلغو11`
  pushed the OTP and the handle line to the wrong edge and reordered them
  against their own reading order. `isolateNumberRuns` now pins any line with
  no strong character outside a link as one LTR run, and skips the per-number
  isolates inside it (the line isolate already covers them — nesting a second
  one changed nothing).

- **Emoji voted LTR.** A second comment on the same thread: "it also sees
  emoji as LTR characters, so it gets whole of my 100% Persian message as an
  LTR message". It does — `Character.getDirectionality(char)` reports a *lone
  surrogate* as `DIRECTIONALITY_LEFT_TO_RIGHT`, and an emoji is a surrogate
  pair, so `📣` at the end of a Persian line was the last strong character.
  Flags are worse: two regional indicators, which Unicode really does class
  `L`. Only letters vote now (`Character.isLetter(codePoint)`), and the scan
  walks **code points**, so a whole emoji is neutral instead of two LTR
  halves. Reproduced with a throwaway `java Dir.java` before changing anything:

      D83C L  HIGH SURROGATES D83C
      1F4E3 . CHEERING MEGAPHONE      (only via the int overload)

`Isolated` now carries `direction` and `ltrLines`, so the count the script
asserts is the one the transform actually produced instead of a second,
re-derivable guess. `styledBody` logs it as
`BubbleBidi: dir=Rtl|Ltr ltrLines=<n>` (the layout itself is unreadable from a
dump, same reason `BubbleDirection` exists).

Tests: `BidiTextDirectionTest` (+3: links don't vote, both link shapes, `e.g`
still votes; emoji at either end; the composer's emoji trap) and `BidiTextTest`
(+3: the issue's OTP/handle message, the bare-link broadcast with its
`ltrLines` count, an emoji-only line). `test-rtl-direction.sh` grew from 10 to
**20** cases — three "link does not vote" bubbles, three "emoji never vote"
bubbles and four `bidi_case` assertions on `BubbleBidi`'s `ltrLines`, one of
which must stay at 0 so the pinning cannot be over-applied. Reverting just the
three rules gives **14 passed / 6 failed**, and exactly the new cases fail;
with the rules back, 20/0.

**Unrelated trap found while running it:** `scripts/env.sh` still defaulted
`ANDROID_SERIAL` to `emulator-5554`, the retired 1080x2400 AVD, while both
AGENTS.md files document `emulator-5558` as the standing default. Every script
therefore sat silent on `adb wait-for-device` — no error, no output, forever.
Default is now 5558 and `env.sh` fails loudly with the connected-device list if
the serial is not attached.

## "Mark all as read" asks first (#355, 2026-10-23)

Issue #355: a user tapped the row while reaching for Notifications and every
unread badge vanished with no way back. The row acted immediately and only
toasted afterwards.

- Both settings UIs (`ui/SettingsScreen.kt` and the legacy `SettingsScreen`)
  now open a confirmation instead of marking read: title "Mark all as read?",
  body "Unread badges will be cleared on every conversation. This can’t be
  undone.", Cancel / Mark all as read. `vm.markAllRead()` and the success toast
  moved into the confirm branch, so backing out changes nothing.
- Two new strings in `strings_settings.xml` × 13 locales
  (`settings_mark_read_confirm_title`, `..._message`).

Tests: `MarkAllReadConfirmTest` (4) — the row only opens the dialog, the single
`markAllRead()` call sits in the confirm branch, cancelling has no side effects,
and the dialog carries its title + body. `test-mark-all-read-confirm.sh`
(16/0) seeds an unread conversation and, in **both** settings UIs, asserts the
dialog appears, the DB badge is still 1 while it waits and after Cancel, and 0
after confirming. Fails on the pre-fix build ("tapping the row marked read
without asking").

## "Theme colours for avatars" switch removed (2026-10-23)

Follow-up to #347. The dynamic (wallpaper) theme made the fixed per-contact
palette the only thing on screen not derived from the wallpaper, so dynamic now
always themes avatars: `avatarsFollowTheme(mode)` in `ui/theme/Theme.kt` is the
one rule, `MessagesTheme` publishes it through `LocalThemedAvatars`, and every
fixed mode (light/dark/amoled/system) keeps the Google-Messages palette.

Since that left the switch dead under dynamic and marginal elsewhere, the row,
the `avatarThemeColors` preference, its `SettingsSearch` entry and its two
strings (× 13 locales) are gone. Diagnostics gained `Avatar fill: theme
(dynamic)` / `Avatar fill: palette (per contact)`, read through the same
function the theme paints through, so the rule stays assertable without a
screenshot.

Tests: `AvatarThemeResolutionTest` (5) — dynamic only, fixed modes keep the
palette, the theme and Diagnostics both go through the shared function, and the
switch is gone from both UIs, search and `SettingsStore`. `AppearanceOptionsTest`
dropped its three avatar-toggle assertions. `test-avatar-theme-dynamic.sh`
asserts no avatar row in either UI and reads the Diagnostics line under dynamic,
system and amoled.

## Send circle is permanent again (2026-10-23)

Feedback after the rc2 build: "how send button was showing in v1.0.30 build,
change it to that — currently when I am typing then only send button showing but
I want to show it everytime". So the #347 decision to drop the button from an
empty composer is reversed:

- `InputBar` always draws the 48.dp circle in `primary`/`onPrimary`, exactly the
  1.0.30 look; nothing shifts when the first character is typed.
- It is only *live* when there is something to send
  (`canSend(draft, hasAttachments)` in `ui/ComposerSend.kt`), so an empty tap
  cannot fire a send and long-press-to-schedule stays text-only. The dump
  reports the difference as `enabled="false"` on the node carrying `content-desc="Send"`.

Tests: `ComposerSendTest` (6) — empty/whitespace false, text or a staged picture
true, cleared false again; `AppearanceOptionsTest` and `PendingMediaWiringTest`
keep watch on the wiring. `test-composer-and-appearance.sh` — 6/0, and it fails
on the pre-change build ("Send is missing from an empty composer").

## Native conversation bubbles (#354, 2026-10-23)

A user asked for Google Messages-style chat bubbles: open a conversation in a
floating bubble from its notification, read and reply there, one bubble per
conversation, on/off through Android's own notification settings.

What the platform actually requires, checked against the AVD (`dumpsys
notification`, `dumpsys shortcut`) rather than assumed:

- The launched activity must be `allowEmbedded` **and** resizable. `MainActivity`
  now declares both; it hosts the chat already, so there is no second chat
  activity to keep in step with the theme/lock/nav decisions.
- A notification only bubbles when it references a **published long-lived
  shortcut**. `NotificationBubble` publishes `conversation_<id>` (short label =
  sender, `Person`, `setLongLived`) and the poster sets `setShortcutId` +
  `addPerson` + `setBubbleMetadata`.
- **The app cannot set `NotificationChannel.setAllowBubbles`**: the platform
  overrides it with `DEFAULT_ALLOW_BUBBLE` for every channel an app creates
  (`PreferencesHelper.createNotificationChannel`), which is why an initial
  attempt to force it produced `mAllowBubbles=-1`. Bubbles are enabled by the
  user (notification's "bubble" chip, or Settings → Notifications → Bubbles),
  which is exactly what the issue asked for. The notification stays a normal
  one until then.
- `BubbleMetadata`'s PendingIntent **must be mutable** — an immutable one makes
  `notify()` throw `IllegalArgumentException: PendingIntents attached to
  bubbles must be mutable`, and `SmsReceiver` swallows receiver exceptions, so
  every message notification silently vanished. The launch intent is explicit
  (component + package + per-conversation data URI) to keep the mutable flag
  safe, and shortcut updates are rate limited (10/interval here), so a shortcut
  is published at most once per conversation and a failure degrades to a plain
  notification instead of losing it.
- **Cancelling a notification cancels its bubble**, and the chat dismisses its
  notification as soon as it is read. `BubbleHost` records the conversations a
  live bubble is showing; `clearConversationNotification` defers the dismissal
  until the bubble host finishes (its `onDestroy` with `isFinishing`).
- In a bubble the chat is the root, so back finishes the activity (collapsing
  the bubble) instead of navigating to the conversation list, and the route
  starts at `"opening"` so the inbox never flashes inside the bubble window.

Tests: `NotificationBubbleTest` (policy: id required, sender must be
replyable) and `NotificationBubbleWiringTest` (manifest flags, shortcut +
metadata wiring, the mutable PendingIntent trap, the deferred dismissal,
Diagnostics reporting). Diagnostics now prints
`Bubbles: allowed by <channels>` and `Bubble shortcuts: <ids>`, read from the
platform instead of re-derived.

Script `test-notification-bubbles.sh` — **12/0** on `emulator-5554` (SDK 35):
notification carries `shortcut=conversation_<id>`, the shortcut is published
and long-lived, bubbles-off leaves an ordinary notification, bubbles-on flags it
`BUBBLE` and shows a bubble surface, the bubble intent opens the chat without
cancelling its notification, and back dismisses both. **3 FAILs** with the
metadata attach removed (rebuild + reinstall) and **1 FAIL** with the
`BubbleHost` guard removed, so the assertions are not vacuous.
`test-notification-actions.sh` 11/0, `test-notif-dismiss.sh` all pass,
`test-grouped-notifications.sh` 18/1 (the pre-existing "number is not 1" badge
assertion, identical on the pre-change APK).
`test-notification-channels.sh` is 7/7 failing before and after: the script
submodule already describes the not-yet-implemented "every conversation owns a
channel" work, unrelated to bubbles.

Not done, deliberately: the bubble's avatar is the app icon, not the contact's
picture. Shortcut and bubble icons have to be bitmaps
(`TYPE_URI`/adaptive-bitmap is what the platform asks for), so a per-contact
avatar means drawing the existing letter avatar into one; the bubble's title
already carries the contact name. Android 10 (API 29) also stays
notification-only: bubbles there need `documentLaunchMode="always"`, and on the
launcher activity that spawns a duplicate task on every launcher tap.

## Appearance feedback on the rc2 build (2026-10-21)

From @Astrid-starr on #347, after trying the dynamic theme:

- **The "Start chat" pill was the wrong colour.** It used
  `secondaryContainer`, which a wallpaper palette can turn into a dark slab. It
  now uses Material's FAB pair, `primaryContainer`/`onPrimaryContainer`
  (`startChatContainer`/`startChatContent` are still defined once and reported by
  Diagnostics). On the AVD's palette that is 13.29:1.
  *(Reverted 2026-10-25: the settled design is v1.0.30's pair — see the top
  entry. The wallpaper legibility fix is now the content fallback.)*
- **A faded send button read as broken.** With nothing to send there is now no
  send button at all, like Google Messages; it appears the moment there is text
  or a staged picture.
- **Avatars can follow the theme.** New setting "Theme colours for avatars"
  (`avatar_theme_colors`) paints them in `primaryContainer`/`onPrimaryContainer`
  instead of the fixed per-contact palette. Provided through `LocalThemedAvatars`
  from `MessagesTheme`, so every avatar in both UIs agrees.
- **The redesigned interface is the default.** `useNewUi` now defaults to true;
  the legacy screens stay reachable, but a fresh install gets the new one (which
  is also where the appearance rows look right).

Tests: `AppearanceOptionsTest` (5) plus `PendingMediaWiringTest` updated for the
new send gate; script `test-composer-and-appearance.sh` — 6/0 (no Send while
empty, appears on typing, disappears when cleared, the avatar row exists and the
switch persists). `test-dynamic-theme.sh` 5/0, `test-chat-pinch-zoom.sh` 9/0,
`test-conversation-multi-select.sh` 10/0 unchanged.

Not done, deliberately: no RC tag was pushed for this batch.

## Issue batch #340–#348 (2026-10-20)

The four actionable reports from the tracker, plus the automation that was
failing on every new issue. Every change ships with JUnit + a script; all of
them were run on `emulator-5554` (SDK 35) against the fixed build.

- **#341 — a conversation emptied from its notification stayed in the inbox.**
  `DeleteMessageReceiver` trashed the message but nothing pruned the thread,
  because the empty-chat prune (`trashConversationIfEmptySuspend`) only ran on
  chat exit and a notification delete never opens a chat. The receiver now
  prunes the conversation it just emptied, and skips the chat the user is
  looking at (`repo.viewedConversationId`) so the open screen is not pulled out
  from under them. Tests: `NotificationDeleteActionTest` (two new assertions);
  script `test-notification-delete-empty-chat.sh` — 4/4 pass, and **2/4 with the
  prune call disabled**, so it is not vacuous.
- **#345 (badge) — the number counted conversations, not messages.** Every
  notification carried `number=1`, so a launcher that aggregates the app's live
  notifications showed the unread *conversation* count while the inbox showed
  unread *messages*. Each notification now carries its own conversation's
  unread count (`Repository.unreadCountFor`), which aggregates to the message
  total. `BadgePolicyTest` rewritten; `test-notification-badge.sh` now asserts
  the published number equals the seeded `unread_count` per conversation (10/0).
- **#345 (bank SMS) — a Persian amount was reordered.** Java's `\d` is
  ASCII-only, so `۱۲۳٬۴۵۶٬۷۸۹` was never recognised as a number run and the
  following word ("مانده") was dropped into the middle of it by the bidi
  algorithm. `BidiText` now matches Arabic-Indic and Extended Arabic-Indic
  digits plus the Arabic thousands/decimal separators and the Arabic comma.
  Tests: three new `BidiTextTest` cases; script
  `test-bidi-persian-amount.sh` (5/0).
- **#340 — several conversations can be selected and deleted at once.**
  Long-press keeps the action sheet it always had (Pin / Archive / **Multi
  select** / Delete / Block); the new "Select more" row, placed right after
  Archive and carrying the dotted-square select-all glyph (the bar's own
  "select all" uses the same glyph, so one icon means one idea), switches the
  inbox into a selection bar. Long-press was briefly made to start a selection
  instead, which read as "the options disappeared", so the sheet is the entry
  point and the bar has Delete, Archive, Select all and Close (no overflow
  submenu). The title row and the bar share `ConversationHeader.HEIGHT`, so the
  list does not move when the bar appears (it used to jump 30px); the script
  compares the same row's top edge before and after. The bar is shared by **both** conversation lists — the
  legacy one is still the default, so a fix in only the redesigned list would
  have missed most users. Bulk delete goes to Trash with one undo; permanent
  delete stays a per-conversation choice because its dialog names one thread.
  Pure set arithmetic lives in `ConversationSelection`, tested by
  `ConversationSelectionTest`; wiring pinned by `ConversationListWiringTest`;
  script `test-conversation-multi-select.sh` (10/0 on the legacy list and 10/0
  with `use_new_ui=true`). Preview added for the bar, so `PreviewCoverageTest`
  stays green.
- **#347 follow-up — the "Start chat" pill painted itself black under a
  wallpaper palette.** `StartChatFab` drew `primary` on `secondaryContainer`,
  which is not a pair Material defines. The seeded scheme made it look fine by
  luck; the AVD's wallpaper palette hands back `secondaryContainer=#6E7488` and
  `primary=#2A4174`, so the pill became dark-on-dark (2.14:1) and read as a
  black blob. The pair now lives in one place (`startChatContent` /
  `startChatContainer`), the FAB paints with it, and Diagnostics reports it as
  `Resolved Start chat colours: #content on #container` — the script computes
  the contrast from that line (4.65:1 now, **2.14:1 with the old pairing**, so
  it fails on the bug). `ConversationListWiringTest` pins the wiring.

- **#347 — Material You wallpaper colours.** New `dynamic` theme mode, offered
  on Android 12+ only: `dynamicSchemeOrNull()` feeds `schemeFor()`, which is
  still the only place a mode becomes a scheme, so Diagnostics reports the
  colour that is actually painted. High contrast and AMOLED still win over the
  wallpaper. Tests: `DynamicThemeWiringTest` (10 cases); script
  `test-dynamic-theme.sh` (4/0, device resolving `dynamic` to `#FAF8FF` rather
  than a seed). AMOLED/light/dark still resolve as before
  (`test-amoled-theme.sh` 10/0).
- **#348 — pinch-to-zoom on the conversation.** The pinch scales the chat's
  font density, not a graphics layer, so text grows and bubbles re-lay out
  instead of being cropped; bounds are 0.8x–2x (`ChatZoom`), remembered per
  conversation while it is open. `adb` cannot inject two fingers, so the
  gesture is driven through the `--ef chat_zoom` hook and the script asserts the
  rendering half. **Refined after tester feedback on rc1** ("works but takes too
  much work"): the range widened from 0.8–2x to 0.7–2.5x, and a pill shows the
  current zoom ("150%") with one tap back to 100% — before that the only way
  back was pinching the other way. Script now 9/0: 252px at 1.0x, 618px at 1.8x,
  the pill appears and resets, and 9x renders exactly like 2.5x.
  **Second pass after the reporter's follow-up** ("takes too much work", with a
  recording next to Google Messages): the pinch now anchors on the two-finger
  centroid — `ChatZoom.anchorAt`/`anchorScroll` read the row under the finger
  before the scale change and scroll it back under the finger afterwards, so the
  message no longer slides away mid-gesture. A **double-tap** zooms in/out in one
  gesture on an empty patch of the list, and the zoom is **persisted per
  conversation** in `SettingsStore` (`chat_zoom_<id>`), so it survives leaving
  the chat and a process kill instead of dying with the screen's saved state.
  Tests: `ChatZoomTest` anchor maths + double-tap target, `ZoomWiringTest`
  centroid/double-tap/persistence wiring, `ChatZoomPersistenceTest` key naming;
  script `test-chat-pinch-zoom.sh` now 14/0 (adds reopen-at-180% after
  `force-stop`, no leak into a second conversation, and a real adb double-tap),
  and **fails 10/2 with the persistence restore and the double-tap handler
  removed**, so those assertions are not vacuous.
- **#346 — the "Issue TODO" workflow was failing on every run** (16/16 since it
  was added, always `HTTP Error 403: Forbidden` from the model endpoint, which
  also emailed a failure notice to whoever filed the issue). Removed rather than
  patched: the credentials live in repository settings the code cannot verify,
  and re-adding it is one file once the endpoint answers. Committed on
  `chore/remove-issue-todo-workflow-main` (based on `main`, because `issues`
  workflows only run from the default branch).

Note for the next run: the emulator's database was at schema **29** (from the
unmerged #339 branch) and this branch is 28, so the app crashed on launch with
`Can't downgrade database from version 29 to 28` until app data was cleared. The
old database was copied to `/sdcard/db-backup-v29/` first.

## #339 channels merged into Develop (2026-10-21)

The channel work had never been merged, so a tester on `v1.0.31-rc1` still saw a
single "Messages" channel. Merging it also merged `scripts` (both sides had
diverged: the channel tests existed only on the feature branch, the
select-more/badge/bidi/zoom tests only on the batch branch). Schema 28 → 29;
`test-notification-channels.sh` is 11/0 on the merged build.

## #354 follow-up: bubbles show the person, not the app (2026-10-26)

Three asks from the reporter on the bubble build, all three done.

**1. The picture.** `NotificationBubble` drew `R.mipmap.ic_launcher` once into a
process-wide cache and reused it for every conversation, and `groupedStyle`
built each `Person` on `R.drawable.ic_stat_message` — so every bubble was the
app's icon and the notification panel had no picture at all (it never set a
large icon). `ConversationAvatar.forAddress()` now resolves, per chat, the
contact photo or the same silhouette-on-palette-colour that `PersonAvatar`
draws in the list, and hands it over as an *adaptive* bitmap so the platform
applies its own icon shape. The poster uses the same icon for `setLargeIcon`,
the MessagingStyle sender and the added `Person`; privacy mode skips it. The
photo cache has a TTL, so a picture added later is picked up.
`ConversationAvatarWiringTest` (3) + `test-notification-bubbles.sh` (17/0, and
13/2 with the poster and bubble reverted).

**2. Back.** Back inside a bubble called `finish()`, which cancelled the
bubble's notification in `onDestroy` and took the bubble with it.
`bubbleBackAction()` + a "Close bubble with Back" setting (default off, as
asked) decide: off means Back shows the chat list and the bubble stays —
collapsed to its floating icon, which is the platform's own Back gesture and
not something the app can keep expanded. Both settings UIs, 13 locales, and the
legacy settings search index. `BubbleBackTest` (3);
`test-notification-bubbles.sh` covers both directions (15/2 with the old
`if (bubbleMode) finish()`).

**3. Fingerprints.** The app-lock prompt lived in `setContent`, so it ran once
per activity creation — cold start, share, rotation, and every bubble open.
`LockSession` keeps the unlock for the process, and an `ACTION_SCREEN_OFF`
receiver ends it, which is where the device lock re-arms anyway. No more
"unlock once until screen lock" guessing: that is what it does now, and nothing
is persisted. `LockSessionTest` (3) + `test-app-lock-session.sh` (4/0) drives
the session through a debug-gated `--es lock_session_probe` because an emulator
has no enrolled fingerprint; 3/1 with the screen-off receiver disabled.

Traps met on the way, for the next person:

- The bubbles script asserted `flags=[^ ]*BUBBLE`, which is what API 35 prints.
  **API 31 prints the mask** (`flags=0x1010`), so the assertion had never held
  on `emulator-5558`; it now reads the mask and tests `FLAG_BUBBLE`.
- `NotificationBubbleWiringTest` anchored on the literal `if (bubbleMode)
  finish()` and `LegacySettingsIndexTest` demanded the new row in
  `SettingsSearch` — both are source-text tests, and both broke on a rename,
  exactly as documented above.
- The new `lock_session_probe` verbs tripped `NavTransitionDepthTest`, which
  reads every `"key" ->` branch in `MainActivity`: they are intent extras, so
  they belong in `NON_ROUTE_WHEN_KEYS`.
- `emulator-5558` itself crashed mid-run (swiftshader, as the root AGENTS.md
  warns). Nothing was lost: restart, reinstall, re-run.

## #339 follow-up 2: channels after the first import (2026-10-26)

The reporter confirmed per-chat channels work, then added: "app creates message
channels for each conversation I have *after* I receive a new SMS after
installing. I think it should do it after installation."

They were right, and it was an ordering bug, not a missing feature. A fresh
install has an empty database, so `MessagesApplication.onCreate` ran
`syncConversationChannels` against nothing; the whole history is imported
afterwards — by `syncFromSystem` there, or by `requeryFromSystem` in
`MainActivity.onResume` once the SMS role and permissions land — and nothing
synced again. Each chat then got its channel only when its first new message
arrived, which is exactly what they saw.

- The launch sync now runs **after** the import, at the end of the same IO
  coroutine.
- `onResume`'s first-run import triggers `syncConversationChannelsAsync`, which
  is new: the same work off the main thread.
- Restore and sms-ie import (`importDatabase`, `importSmsIe`) call
  `syncChannelsAfterBulkImport()` on success. Both land hundreds of rows at
  once, so they had the same gap.

Tests: `NotificationChannelWiringTest.channelsAreCreatedAfterTheImportThatFillsTheDatabase`
pins the ordering by source index (launch sync after `syncFromSystem`, resume
sync after `requeryFromSystem`, both import callbacks syncing). The device case
in `test-notification-channels.sh` imports a chat through the real sms-ie probe
and asserts `messages_convo_<id>_*` exists **without a single inbound SMS**:
16/0 with the fix, and 15/1 with the three sync points reverted (the imported
chat gets no channel), so it is not vacuous. Note what it does and does not
cover — the device case proves the *import-after-launch* class through the
ViewModel hook; the `MessagesApplication` ordering on the system-import path has
only the JUnit source-order guard, because the emulator cannot seed
`content://sms` (`content insert` exits 0 and stores nothing, same as AOSP-11).

## #339 follow-up: every conversation owns a channel (2026-10-23)

The reporter on Pixel 8 Pro / Android 17 still saw a single "Messages" channel
and asked for one per chat. The shipped design only created
`messages_convo_<id>` once a per-chat sound override was picked, so chats with
no override stayed hidden behind the category channels.

Checked how the apps the reporter named actually behave:

- **Fossify Messages 1.10.1 (F-Droid, installed on `emulator-5554`)** exposes
  exactly one channel: `fossify_messages` / "Received SMS". Its source
  (`ConversationDetailsActivity.createNotificationChannel`) creates a
  `<threadId>` channel only after the user turns on "Custom notifications" for
  that conversation; posting then uses `threadId.toString()` as the channel id.
  So it is opt-in there too, just surfaced on the conversation screen.
- The reporter's expectation (a row per conversation in system settings) is
  therefore a superset of both apps, not a regression fix.

What changed:

- **Every conversation gets its own channel**, created on the first message and
  for the 100 most recent threads at launch (`syncConversationChannels`), titled
  `ContactDetails.listLabel(...)` (group name, contact name, or formatted
  number). Older threads get one the moment they receive a message.
- **The sound is part of the conversation channel id**
  (`messages_convo_<id>_<suffix>`), matching the category channels. Android
  reserves a deleted channel id — recreating it restores the old sound and
  importance — so a selection change must move to a new id; the previous
  variant is deleted. This was caught by `test-notification-sound.sh`: a
  delete-then-recreate on the same id silently kept the old tone.
- **The poster always uses the conversation channel** when the sender has a
  conversation row; the category channel is only the fallback for a sender with
  no row yet.
- **Changing a sound reconciles channels** (`syncNotificationChannels`, IO
  thread) for conversations that already own one, so a long history does not
  dump hundreds of rows into system settings at once. The old sound variant is
  deleted, not edited.
- **Deleting a conversation deletes its channels**; the launch sync also prunes
  channels whose conversation row is gone.
- `NotificationChannels.conversationIdOf` parses the id back for pruning.
- Also fixed while here: the global sound dialog's option rows were not
  clickable — only the radio dot responded, so tapping the label did nothing.
- JUnit: `NotificationCategoryTest` (conversation id wins without an override,
  id round-trip, sound-suffixed ids) and `NotificationChannelWiringTest`
  (target query wiring, launch sync, settings-screen reconciliation, deletion).
- One query decides everything a channel needs: `ConversationChannelTarget`
  (`Repository.conversationChannelTargetBlocking` / `...TargetsBlocking`) carries
  the label parts, member count and override tone, so the poster and both syncs
  cannot label or tone the same chat differently. `categoryFor(target)` is the
  single category decision; the poster no longer resolves it separately.
- The launch sync reads the desired channel id first and returns on a match, so
  a steady-state cold start is one binder read per conversation instead of six
  writes; a tone change is what triggers the delete of the stale variant.
- Scripts: `test-notification-channels.sh` rewritten for the new invariants
  (14/0; **7 FAILs** against the pre-change APK after a rebuild+reinstall, so it
  is not vacuous). `test-notification-sound.sh` updated for conversation
  channels and the new Settings → Advanced settings → Notifications route
  (23/0). Its navigation now uses the `android layout` CLI instead of
  `dump_ui`/`tap_text`: on this AVD `uiautomator dump` started returning
  `rc=137` and every navigation assertion failed while the app was fine. The
  settings list also remembers its scroll position, so the helper scrolls it to
  the top and retries instead of assuming "Advanced settings" is on the first
  screen. `test-notification-wake.sh` channel grep now accepts digits.

Verified on `emulator-5554` (SDK 35) against the rebuilt app: channels 14/0,
sound 23/0, bubbles (#354) 12/0, actions 11/0, dismiss all pass, grouped 18/1
(the pre-existing "number is not 1" badge assertion, identical on the pre-change
APK), `testDebugUnitTest` green.

## Granular notification channels per category and conversation (2026-10-17)

Feature request #339: users want per-chat / per-category control of sound,
vibration and importance. Android only lets an app set those when it creates a
channel and hands them to the user afterwards, so the only real lever is
**distinct channels**. The app previously kept one channel (chosen by the global
sound setting) and deleted every other variant, which is exactly what this
removes.

- **Three category channels**, one per sound selection because a channel's
  sound is fixed once it exists: `messages_direct_*`, `messages_group_*`,
  `messages_unknown_*` (suffixes `default/app/dragon/uf09/uf062/silent`).
  `NotificationCategory.resolve` decides — group wins, then unknown for
  alphanumeric/short-code senders and numbers not in Contacts. Changing a
  category's sound switches to the matching id and deletes the stale variant.
- **Per-conversation override**: a `sound` column on `conversation_notifications`
  (schema **v29**). Setting one creates `messages_convo_<id>`; clearing it deletes
  the channel. Empty means "inherit the category/global sound".
- **Per-category default** in `SettingsStore` (`notificationSoundFor` /
  `setNotificationSoundFor`), surfaced in the new UI's Notification settings
  screen, plus a "Manage in system settings" deep link.
- The old single-channel ids are deleted once the category channels exist
  (soft-deleted by the OS, so dumpsys still lists them with `mDeleted=true`).
- Backup is a raw DB copy, so the new column rides along on export; import reads
  it only when the backup actually has the column (`backupHasColumn`).
- Diagnostics now lists every channel the app created, read from the
  NotificationManager (not re-derived).
- JUnit: `NotificationCategoryTest` (category precedence, stable channel ids,
  no legacy collision) and `NotificationChannelWiringTest` (schema, backup
  import tolerance, poster wiring, every locale defines the new keys).
- Script: `test-notification-channels.sh`. **Verified** on `emulator-5554`
  (SDK 35): 11/11 pass; with `NotificationCategory.resolve` broken back to a
  single category it reports 2 FAILs, so it is not vacuous.
- New strings shipped in all 13 locales (`notification_channel_direct_title`,
  `_group_title`, `_unknown_title`, `_convo_desc`, `contact_notification_sound`,
  `contact_notification_sound_default`, `settings_notif_manage_channels`,
  `settings_notif_manage_channels_subtitle`).

## MMS that arrives with mobile data off: wait for data, then a deferred re-check (2026-10-15)

Follow-up to #328, after @Zokii0's report that an MMS does not fetch when mobile
data is off. MMS requiring data is expected; what was wrong is what the app did
about it.

- **`MMS_ERROR_NO_DATA_NETWORK` (8) and `MMS_ERROR_DATA_DISABLED` (11) fell
  through `MmsRetry.classify()`'s `else` to `MANUAL_RETRY`.** There is no UI to
  retry one, and the state was dropped. They now classify as a new
  `MmsRetry.WAIT_FOR_DATA` that is retryable and, in `MmsDownloader.onComplete`,
  gives the attempt back (`attempt.count = (attempt.count - 1)`) so three data
  outages cannot burn the automatic budget.
- **After `MAX_AUTO_ATTEMPTS` a transient failure was never retried again.**
  `shouldRetryNow()` returned false at the limit and the map entry was never
  removed, so the row was stuck until the process died. Past the budget it now
  retries on the longest cooldown (`MAX_DELAY_MS`); `requestPending()` also
  drops any budget-exhausted entry, so opening the app gives it a fresh one.
- **New deferred re-check (`MmsRecheckScheduler` + `MmsRecheckWorker`).** The
  on-open sweep only runs in the foreground and the in-process retry is a
  `Handler` that dies with the process, so an MMS with data off waited for the
  next open. A unique `OneTimeWorkRequest` with `NetworkType.NOT_REQUIRED` and
  WorkManager exponential backoff (15 min, doubling) now re-runs `requestPending`
  and retries while a row is pending, stopping when nothing is left. **No new
  permission** — option 2 (`registerNetworkCallback` / `ACCESS_NETWORK_STATE`)
  was rejected to keep #332 intact.
- Debug probe `--ei mms_recheck_probe <resultCode>` (MainActivity) hands the
  downloader a synthetic completion, since the real one only comes from the
  non-exported `MmsDownloadReceiver`.
- JUnit: extended `MmsRetryTest` (WAIT_FOR_DATA classification, retryable and
  budget-independent, post-budget cooldown) and new `MmsRecheckSchedulerTest`
  (permission-free, backoff not reset, bounded retry, downloader wiring).
- Script: `test-mms-recheck.sh`. **Verified** on `emulator-5554` (SDK 35): 6/6
  pass; with the classify change reverted it reports 3 FAILs, so it is not
  vacuous. `test-mms-retry.sh` (7/7) and `test-no-network-permission.sh` (4/4)
  still pass.

## "Highlight links" over-rounded in the new UI (2026-10-14)

- **On Link behaviour, "Highlight links" had the group's outer 12dp bottom
  corners while it still sat above "Link open warning".** Its position was
  `if (hideLinks) MIDDLE else LAST`, so with hiding off it rounded like the
  last row. The row always has the warning below it, so it is now
  unconditionally `RowPosition.MIDDLE` — all four corners at the inner 4dp,
  matching "Hide links from messages".
- Corner radii are pixels with no text equivalent, so `SettingsRow` now emits a
  `SettingsRowShape` logcat marker (`title position topStart topEnd bottomStart
  bottomEnd`), the same idea as the chat `BubbleShape` marker. It reads the
  rows' actual `rowCorners(position)`, so it cannot drift from what is drawn.
- `LinkSettingsRowPositionTest` pins the group: three rows, FIRST/MIDDLE/LAST,
  and no `RowPosition.LAST` for the highlight row.
- `test-link-row-corners.sh` opens the page and asserts the three markers —
  fails pre-fix (`Highlight links position=LAST bottomStart=12.0 …`), passes
  after.

## Delay-before-sending picker clipped in the new UI (2026-10-14)

- **The redesigned "Inbox settings → Delay seconds" picker showed only `1s`**
  (plus Cancel); `3s/5s/10s/30s` were missing. Each option row in
  `InboxSettingsScreen`'s delay dialog used `Modifier.fillMaxSize()`, so every
  row claimed the dialog's whole height and all but the first were laid out
  below the window. It is a **single-line** fix: `fillMaxWidth()`.
- The row also regressed two details against the legacy dialog: it was no
  longer `clickable` (only the radio selected) and the
  `settings_choose_delay` hint had been dropped. Both restored; keep the two
  dialogs in step.
- `DelayDialogOptionsTest` pins the option rows to `fillMaxWidth` (and no
  `fillMaxSize`), the option list, the hint, and the row-level click.
- `test-delay-dialog-options.sh` drives the real dialog and asserts every
  option via `android layout` (uiautomator segfaulted on this AVD) — fails on
  the broken APK with 5 missing options, passes after.

## Adding people to an existing group; stale group-test fixes (2026-10-14)

- **Adding people to a group created a second group.** `AddPeopleScreen` always
  called `createGroupFrom`, so adding Dad to "Alex + Bank" produced a separate
  "Alex + Dad" and left the original at two members. `AppViewModel.finishAddPeople`
  now branches: a group gets `repo.addParticipants` (append in place) and keeps
  its id; a 1:1 still starts a new thread. The send path is untouched — it still
  reads `conversation_recipients`, which now has the extra member.
- **The automatic group name now grows with its members.** `ensureGroupTitle`
  recomputes unless a name was typed. A new `conversations.group_title_custom`
  flag (DB v28) records which is which, set by `setGroupTitle`, so a user's name
  survives a later add.
- `addParticipants` already existed and had no callers; it is the append path now.

Test fixes (all pre-existing, unrelated to the feature):
- `test-group-chat.sh` §7/§8 assumed `conversations.address` was unique; the
  migration that dropped it (`dropConversationAddressUnique`) means `insert or
  replace` adds a row, so `make_group` returned a multi-line id and the section
  could never build its group. `make_group` now takes `max(id)`, and §7 leaves a
  single conversation at the address so §8's "open by address" is unambiguous.
- `test-group-create.sh` still expected the "Group name" field that moved to the
  group's page. Rewritten for the current flow: the picker creates a group named
  from its members, lands in the group chat, and the empty group survives leaving.
- `test-group-send-duplicates.sh` tapped the composer via uiautomator (unreliable
  on this AVD) and matched "Send" as a substring — which hit the probe message
  body `GroupSendProbe…`. It now focuses the EditText through the layout dump and
  matches "Send" exactly.

New regression `test-group-add-member.sh`: adding to an existing group keeps one
group, appends the member, grows the auto name, and leaves a typed name alone
(fails pre-fix — a second group is created).

## Group creation outcome, empty groups, multi-select pictures (2026-10-14)

Follow-ups to the #326/#327 batch, from the same tester:

- **Finishing "Add people" landed on the contact details page**, so Back walked
  into the old 1:1. `MainActivity` now opens the *new group's chat*
  (`chatId = newId; navRoute = "chat"`), and Back from there goes to the list.
- **An empty group vanished** from the conversation list. `trashConversationIfEmptySuspend`
  trashed any conversation with no messages/scheduled/draft on leaving the chat;
  a group is a thread the user built on purpose, so `ConversationLiveness.keepAlive`
  now takes `recipientCount` and keeps a conversation with more than one member.
  A 1:1 with nothing in it is still trashed.
- **The gallery was single-select.** Google Messages lets you pick several photos
  in one pass; `ChatScreen` now uses `PickMultipleVisualMedia` (confirm with
  "Add (N)"), de-dupes against what is already staged, and the whole set still
  waits in the composer until Send.

Tests: `ContactDetailsWiringTest.creatingAGroupDropsYouIntoTheNewChat`,
`ConversationLivenessTest` (+2). Regression script
`test-group-add-people-outcome.sh` — lands in the group chat, Back reaches the
list, and an empty group survives leaving its chat. It scrolls the list to the
top first: the list keeps its scroll position across navigation and the new
group is newest. `test-pending-media.sh` was updated to the multi-select flow
and now asserts two staged thumbnails and two sent pictures.

Note for scripts: `uiautomator` on this AVD started failing with
"UiAutomationService already registered" and returning **stale** dumps; the
`android layout` CLI stayed reliable. `test-group-add-people-outcome.sh` uses
the `layout_*` helpers throughout. If a list assertion looks wrong, check the
list is scrolled to the top before believing it.

## Add people from a chat, staged pictures, triage workflow (#325/#326/#327) (2026-10-14)

Three user reports, fixed together on `fix/issues-325-326-327`:

- **#327 "Add people" did nothing.** The chat overflow item was wired to
  `onAddPeople = { /* no-op: MMS group chat, stub */ }`. `ChatScreen` now takes
  an `onAddPeople` callback; `MainActivity` opens the existing `add-people`
  picker for the chat's own conversation (`detailsId = chatId`) and remembers
  where it was opened from (`addPeopleReturn`), so the picker's back returns to
  the chat instead of the contact details. The details path still opens the
  same picker.
- **#326 pictures sent on pick.** The gallery and camera launchers called
  `vm.sendMediaMessage(...)` the moment the picker closed. They now stage the
  `Uri` in a `pendingMedia` list; the composer shows a removable thumbnail strip
  and the send button enables for an attachment with no text. `sendPendingMedia()`
  sends them on Send, with the draft as the first picture's caption. `InputBar`
  gained `hasAttachments` so an empty draft can still be sent with a picture.
- **#325 triage failed every comment.** `crmne/copilot-triage` rejects any
  `reasoning-effort` outside `none/low/default` (`ArgumentError in reasoning_flag`,
  `assessment.rb:834`), and the workflow forwarded `vars.TRIAGE_REASONING_EFFORT`
  bare — an unset repo variable is an empty string, i.e. a *present* input, so it
  overrode the action default. `model`, `reasoning-effort` and `dry-run` now each
  carry a fallback (`|| 'low'`, `|| 'gpt-5.6-luna'`, `|| false`).

Tests: `AddPeopleFromChatWiringTest`, `PendingMediaWiringTest`,
`TriageWorkflowDefaultsTest` pin the wiring; `ContactDetailsWiringTest`'s
Add-people anchor was widened to allow the return-route reset. Regression
scripts: `test-chat-add-people.sh` (fails pre-fix — the menu did nothing),
`test-pending-media.sh` (seeds a MediaStore picture, drives the system picker,
asserts 0 outgoing images while staged then 1 after Send; fails pre-fix),
`test-triage-workflow.sh` (static — the workflow has no runtime path).

Known pre-existing: `test-group-create.sh` fails on Develop unchanged (it still
expects a "Group name" field that `AddPeopleScreen` no longer has); not caused
by this batch.

## Legacy "Swipe actions" master switch (2026-10-14, #331)

`SettingsStore.swipeActionsEnabled` read as a hardcoded `true`, so the legacy
settings toggle was always checked and its writes to the old
`swipe_actions_enabled` key were ignored — the per-direction actions
(`swipe_left_action` / `swipe_right_action`), which the list actually reads, never
changed. It is now a view over that pair: off sets both directions OFF, on
restores the pre-de-per-direction archive/delete pair (honouring legacy reverse).
New `SwipeAction.anyEnabled(left, right)` carries the predicate.

- JUnit: `SwipeActionTest.anyEnabledIsFalseOnlyWhenBothDirectionsAreOff`,
  `theMasterSwitchFollowsTheLegacyPairItWrites`.
- Script: `test-swipe-master-toggle.sh`. Verified on `emulator-5554` (SDK 35): it
  fails on the old `get() = true` code and passes with the fix.
  Note the AVD trap — the row is the last one and its switch sits under the
  gesture inset, so the script taps the switch's own top edge, not the label.

## No-network permission + picture-MMS notification (2026-10-14)

Two fixes on the app branch `fix/332-remove-internet-permission` (based on `Develop`).

### #332 — drop the network permissions (no INTERNET, like Fossify/QUIK)

Between 1.0.27 and 1.0.29 the `:mms` rewrite added a direct-MMSC HTTP client
(`MmscHttpClient`/OkHttp, `MmsNetworkBinding`/ConnectivityManager) whose module
manifest merged `INTERNET`, `ACCESS_NETWORK_STATE` and `CHANGE_NETWORK_STATE`
into the APK — the F-Droid permission diff the reporter saw. It was never wired
in production (only `SystemMmsTransport` is), so the whole direct path and the
three permissions are removed. SMS stays offline and MMS runs through the
platform service, matching Fossify Messages and QUIK, both of which ship MMS
without `INTERNET`.

- Removed `MmscHttpClient`, `MmsNetworkBinding`, `ApnProfile`, `ApnResolver`,
  `MmsRetryScheduler`, `DirectMmscTransport`; trimmed `MmsRequest` to
  `MmsResultCode`; removed `TransportChoice.DIRECT`.
- Dropped the `okhttp` and `androidx.work` deps from `:mms`.
- `ACCESS_NETWORK_STATE` is also merged in by `androidx.work:work-runtime`
  (WorkManager declares it for its network `Constraints`), so the app strips it
  with `tools:node="remove"`. The app never asks for a network constraint —
  `PeriodicBackupScheduler` uses `NetworkType.NOT_REQUIRED` — and WorkManager
  was verified to initialise and run on the emulator without it.
- JUnit: `app/src/test/java/com/anindra/messages/NoNetworkPermissionTest.kt`
  (ignores `tools:node="remove"` entries, since those are not requested).
- Script: `test-no-network-permission.sh` — asserts the **installed** APK
  requests none of the three (and still has the SMS set, so a clean read cannot
  be vacuous). **Verified** on `emulator-5554` (SDK 35): it reported
  `[FAIL] … ACCESS_NETWORK_STATE` before the strip and `4 passed, 0 failed`
  after, so it is not a vacuous pass.

### #328 — picture-only MMS notification is empty

A picture-only MMS is stored with a blank `body`, so the collapsed notification
was blank; the picture also sat behind `content://mms/part/<id>`, which SystemUI
cannot read. `NotificationHelper.show` now labels a blank-body image as
`notif_photo` ("Photo"), attaches the picture as `MessagingStyle` data via the
new `NotificationImage` (copied into the app cache and granted to SystemUI), and
`NotificationHistory.window()` keeps picture lines with blank text. New string
`notif_photo` in the default values and all 12 locale folders.

- JUnit: `NotificationHistoryTest.keepsAPictureLineWithBlankText`.
- Device regression: **blocked** — the only MMS-notification trigger is the
  non-exported `MmsDownloadReceiver`, reached only by a real MMSC download, so
  adb cannot drive it. Needs a test seam (a debug hook) or a manual device check.

## Security-scan cleanup: zip-slip, app-lock auth, overflow (2026-10-12)

The code-scanning page runs CodeQL (`security-and-quality`), Semgrep and Trivy.
Semgrep and Trivy are clean; CodeQL had 20 open alerts. This batch takes the two
security findings and the correctness/dead-code notes (the deprecated-call notes
are left for the `targetSdk 37` migration).

| Alert | Where | Change |
|---|---|---|
| #489 high zipslip | `data/SmsIeReader.kt` | the entry name is reduced to its final component by `File(entry.name).name`, and a bare `..`/`.` is rejected before `File(partsDir, name)` |
| #490 medium insecure-local-authentication | `ui/AppLockVerification.kt` | the prompt is tied to `MessageLockCrypto`'s auth-bound key via a `CryptoObject`, and the returned cipher must pass `proveAuth()` before `Verified` |
| #494 int-multiplication-to-long | `mms/.../AttachmentFitter.kt` | `partCount.toLong() * 512` |
| #491-493 whitespace-precedence | `mms/.../pdu/Wsp.kt` | parenthesise infix `and` before the comparison |
| #80 #81 #496 #498 unused locals | `Repository`, `SettingsScreen`, `LegacySettingsScreen`, `ScheduledMessagesScreen` | dropped |

The zip-slip entry name was already flattened, so #489 was not exploitable on
Android (backslash is not a separator), but CodeQL did not treat
`substringAfterLast('/')` or a `canonicalFile` equality as a sanitizer. The code
now uses `File(entry.name).name` plus a `..` check, which the query's
`DotDotCheckSanitizer` recognises; a local CodeQL run of
`java-security-and-quality` reports **0 errors / 0 warnings** for the touched
alerts (10 notes remain: 7 deprecated-call, left for the SDK 37 migration, and
3 sealed-class `tmp0_other_with_cast` false positives). The staging tests in
`SmsIeReaderStagingTest` pin it (`../../pwned.bin`, a bare `..`).

Root cause for #490: the `BiometricPrompt` callback was applied as a bare
boolean, which a UI-hooking tool can flip. It now runs a real crypto operation
with the authenticated Keystore cipher, the same pattern `ChatScreen` already
uses for message locks. A null cipher stays accepted so an API 29 PIN-only user
is not locked out.

Tests: `SmsIeReaderStagingTest` (+2), `AppLockVerificationWiringTest` (+3, incl.
the verdict table), `BudgetPolicyTest` (+1, fails pre-fix). The source-pinning
regression is `test-codescan-security-cleanup.sh` — fails 9/12 pre-fix, 12/12
after, on `emulator-5554`.

`test-app-lock-verification.sh` needed two harness fixes. "The prompt was
satisfied but App lock was not enabled" was a race: the setting is written
through SharedPreferences, which applies asynchronously, so the script read the
pref before the commit landed — a log from the callback showed
`succeeded cipher=true proof=true` and the pref was `true` a moment later. The
"could not reach the App lock row" sections were the emulator screen sleeping
under the app. The script now wakes the device before navigating and polls for
the expected app-lock state instead of reading once.

## #317 A conversation sent from another app never reaches the list (2026-10-12)

Reporter sends an SMS from Contacts to a number never messaged before; the
message delivers, but the conversation is in no page of the list. Opening the
contact again makes it appear.

| Test | Script |
|---|---|
| `MmsSupportTest` | `test-mms-timestamp-units.sh` |

**The list has no paging.** `conversations()` returns every row with no
`LIMIT`, so "not on any page" cannot mean pagination.

**The real cause was the unit of the timestamp.** The list is
`ORDER BY timestamp DESC`, and two rows on the device held
`1791706107000000` — a date in the year 58000 — so they sorted above everything
else *permanently* and every conversation sent afterwards sat beneath them.

Two opposite unit errors, both from reading a provider date without
normalising:

- `MmsSupport.milliseconds` multiplied every value by 1000. Some carriers store
  the MMS `date` in **milliseconds** already (`content://mms/117` carried
  `date=1791706107000`), so those rows were scaled twice.
- The **SMS** import stored `m.date` raw (the `INSERT INTO messages` in the
  sync path). The SMS provider date is in *seconds*, so 275 imported rows read
  as 1970.

The app treats every timestamp as milliseconds — `TimeFormat` renders them with
`Instant.ofEpochMilli`.

Fixed on both ends: `milliseconds()` is unit-aware (and rejects values outside a
plausible date range rather than storing them), the SMS import normalises, and a
v27 migration heals rows already written.

**The migration crashed the app on the first attempt**, which is the reason to
run it on device: deriving the conversation timestamp from its newest message
yields NULL for a conversation with nothing left, and `timestamp` is NOT NULL.
Both tables are now fixed in place. A second trap sat behind it — scaling
seconds up first pushed them above the floor, so the very next statement divided
them straight back and the migration was a silent no-op. Both are recorded in
the code.

Verified failing on the pre-fix build with 5 red checks, the last of which is
the reported symptom: the new conversation does not reach the top of the list.
Passes 6/6 after.

Still worth asking the reporter: whether conversations showing "Photo" sit at
the very top of their list above everything recent. That is the fingerprint of
this bug.

### #317 follow-up: the contact-name refresh delay (2026-10-12)

The reporter's later comments separate a second symptom from the timestamp bug:
after sending from Contacts the row appears with the **number**, and the saved
name only catches up after 20 minutes to 2 hours. Renaming or deleting a contact
also kept the stale name.

| Test | Script |
|---|---|
| `ContactNameCacheTest` | `test-contact-name-refresh.sh` |
| `ContactRefreshWiringTest` | `test-contact-name-refresh.sh` |

Root cause: the app watched only the SMS/MMS provider (`observeProviderChanges`)
and re-resolved names only from `MainActivity.onResume` behind a 5-minute gate.
A contact edited while Messages was in front (and no SMS/MMS touching the
provider) was invisible until a resume happened to clear the gate.

The in-memory `contactCache` (5-minute TTL) moved to `ContactNameCache`, and a
new `ContactsContract` `ContentObserver` (`observeContactChanges`) drops the
cache and re-runs `refreshContactNames` on a 500 ms debounce. It is registered
from `MessagesApplication` and unconditionally from `onResume` (outside the
gate).

Regression: the script seeds a conversation with a fresh number and no contact,
leaves the app on the list, then inserts and renames the contact underneath it
without ever leaving the screen. Fails 1/3 pre-fix (the two refresh checks red),
passes 3/3 after, on `emulator-5554`.

## Image auto-scroll when picture arrives in open chat (2026-10-11)

A picture row has no height until Coil decodes it, so the scroll that reaches a
newly arrived row lands on the bottom as it was *before* the bitmap existed; the
row then grows downward out of sight. The follow window that fixes this was
keyed only on `conversationId`, so it opened when the chat opened and expired
four seconds later — a picture arriving afterwards found every window closed and
stayed clipped. The follow is now keyed on `newestId`, so each arrival opens its
own window. The two duplicated follow effects were folded into one, and the
redundant `lastVisible` guard went with them.

Tests: `ScrollFollowGuardTest` (5 unit tests).

**No `test-image-auto-scroll.sh`.** One was built and discarded: it delivers a
real picture through the provider (a downloaded `m_type=132` row with a real
part file, imported via the app's own resync) and asserts the decoded bubble
clears the composer. It passes on unfixed code, because on the AVD Coil has the
bitmap within ~1s of the row appearing — there is no zero-height phase for the
race to be lost in. Enlarging the picture 20x changed nothing (identical bounds
before and after). On a real device the load is a network download measured in
seconds, which is what opens the gap this fix closes; that timing cannot be
reproduced against a local provider read. Per the rule that a script which
passes on broken code is worse than no script, the fix ships with the unit test
alone and needs an on-device check before it is trusted.

## Unread badge + stale snippet when a picture arrives in an open chat (2026-10-11)

A received picture while its chat is open left an unread badge of 1 after
going back to the list, and the list line still showed the previous text
instead of "Photo".

Two causes: `receiveMessage` and `importProviderMms` counted the message as
unread unconditionally, so the screen's reactive `markRead` lost the race
against the asynchronous MMS import. And `importProviderMms` never updated
the conversation's snippet, timestamp, or direction.

Fix: `Repository.viewedConversationId` (volatile) is set by ChatScreen on
ON_RESUME and cleared on ON_PAUSE/dispose. Both unread bumps now skip the
front conversation. `importProviderMms` collects affected conversations and
calls `refreshConversationSnippetFor` after the loop.

Tests: `ViewedConversationTest` (4) and `test-unread-while-viewing.sh` (4/0),
`test-mms-snippet.sh` (5/0).

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
| #304 (follow-up) | A shared body arrives readable: Latin-1 mangled text repaired, `sms_body`/`EXTRA_TEXT` read, double decoding | `ShareTextTest` | `test-share-intent-body.sh` |

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

## #304 follow-up: a shared body arrived garbled (2026-10-11)

The reporter confirmed the app now appears in Bank Mellat's share list, so the
first half of #304 was right. Two problems remained, and they turned out to be
different bugs with the same symptom.

The garbled text is **Latin-1 mojibake**: `Ù…Ø±Ù†` is what UTF-8 bytes read one
byte per char look like. The bank app escapes its own URI that way, so the body
it hands over is already damaged, and we forwarded it verbatim — to the composer
and then over the air. Confirmed against the screenshots, where the mangled run
matched byte for byte.

- **`ShareText.repairMojibake`** undoes it, but only when the result is
  unambiguous: pure Latin-1, no non-Latin letter already present, and it turns
  back into text that has one. `Café` stays untouched because `E9` alone is not
  valid UTF-8. A malformed sequence is refused outright rather than replaced
  with U+FFFD, which would swap one wrong body for another.
- **The Latin range has to be `code < 0x0250`**, not `0x41..0x5A || 0xC0..0x24F`.
  `ª` and `º` are letters at `00AA`/`00BA`, below `00C0`, and Persian receipts
  produce both — so the tighter range read mangled text as non-Latin and the
  repair never fired. The unit test caught this on its first run.
- **`sms_body` is now read first.** Every other SMS app checks it before the
  `?body=` query, and the order has to match theirs: an app that fills both
  means the extra. Bank Mellat puts the receipt there, so we were taking the
  URI's damaged copy and ignoring the clean one.
- **`EXTRA_TEXT` is read on every action**, not only `ACTION_SEND` — the bank
  fires `SENDTO`.
- **`percentDecode` decodes twice.** `Uri.decode` undoes one layer, so a body
  escaped twice reached the composer as literal `%D9%85` and was sent as those
  eight characters. The second pass is a no-op unless escapes survive the first.
  `+` is left alone: this is a URI, not an HTML form.
- Consecutive `%XX` escapes decode as **one** character, not one per byte.
  Decoding byte by byte would produce exactly the mojibake being fixed.

- Tests: `ShareTextTest` (15) — query extraction, empty/absent `body`, double
  decoding, the exact `sms_body`-style mangled receipt, `Café`/`Grüße` left
  alone, malformed `%` preserved, `+` untouched.
- Regression: `test-share-intent-body.sh` (new), 7 checks. Verified to **fail**
  on the pre-fix build (**2 passed, 5 failed** — the two passes are the
  no-regression controls), then **7 passed, 0 failed**.

  Two traps in writing it, both of which made the script report a false pass:

  1. **`iconv` cannot produce the mangled string.** This locale rejects the
     Persian bytes it is handed, so it exits with an empty result rather than
     the Latin-1 reading the sender actually sends — and an empty body trivially
     "passes". Built with Python instead.
  2. **An empty composer must not match.** `"" in x` is true for every `x`, so
     the dropped-`sms_body` case read as a pass on the broken build. That check
     is why the pre-fix run is 5 failures and not 3.

  The composer is read from the `EditText` node specifically. Taking the longest
  `text=` instead picks the contact header, which is as long as a short body and
  is on screen whether or not the body arrived.

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


## #347 dynamic-colour feedback round (2026-10-28)

Follow-ups from issue #347 after the first dynamic theme shipped in 1.0.31-rc1.

### What changed

- The Start chat pill is now the accent pair (primary/onPrimary) in every theme —
  seeded and wallpaper — matching Google Messages; the previous
  secondary-container surface read as a grey mismatch under Material You.
- The send button now follows GM behavior: it shrinks and fades to nothing while
  the composer is empty (keeping its layout footprint so the field does not
  jump), and comes back with text or attachments. It stays unclickable while
  empty.
- Selected-message bubbles use the scheme's own primary/onPrimary pair instead
  of two hard-coded blues that never followed the wallpaper.
- Under Dynamic, avatars now take the contact's own palette hue harmonized
  ~25% toward the wallpaper accent, so contacts stay distinguishable while all
  belonging to the wallpaper's palette (the old build painted every avatar the
  same primaryContainer). Glyph ink is picked per contrast (>= 3:1).
- Legacy conversations screen shares the same pill pair via the theme
  extensions; Diagnostics' avatar-rule line reads "Avatar fill: harmonized
  per-contact colour under Dynamic, palette otherwise".

### Tests

- Unit: StartChatPillColorTest (accent pair), DynamicAvatarHarmonizeTest (new:
  distinctness, tone/hue stability, greyscale guard, readability), updated
  AmoledThemeTest, AppearanceOptionsTest, ConversationListWiringTest,
  AvatarThemeResolutionTest anchors. testDebugUnitTest green (1034).
- `scripts/test-347-dynamic-colors.sh` (15): dynamic resolves a non-seeded
  palette in both night modes, both Start chat pairs readable, seeded pairs
  exact, avatar rule text, send button absent empty / back after typing.
  Verified failing on the pre-fix send-button build (revert to always-on
  circle produced 3 failures).
- Freshen-ups: the settings gear coordinate was stale on the 2340px AVD
  (tap 970,143) across test-amoled-theme/test-dynamic-theme/test-motion-system/
  test-start-chat-colours — several were failing to navigate at all.
- `test-start-chat-colours.sh` and `test-avatar-theme-dynamic.sh` re-pinned to
  the accent pair / harmonized rule. 4/5 passing again.
- `test-motion-system.sh` fails 3 (undo, emoji panel, Advanced settings walk) —
  reproduced identically on a stashed baseline; pre-existing on
  fix/354-fullchat-bubble, not from this work.
- The emulator died mid-run once (swiftshader); restart recipe from AGENTS.md
  and carry on. Branch note: another session moved the app repo to
  fix/354-fullchat-bubble mid-run; this work rebases to
  fix/347-dynamic-followups on top of it. That session's uncommitted
  test-chat-pinch-zoom.sh wait_for_chat rework rode along in the submodule
  commit (it could not be committed selectively without unusable -p surgery);
  its content is #354, not #347.
