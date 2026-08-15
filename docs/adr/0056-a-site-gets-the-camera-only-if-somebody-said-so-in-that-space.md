# ADR-0056: A site gets the camera only if somebody said so, in that space

- **Status:** Accepted
- **Date:** 2026-06-16
- **Lock:** `crates/zer0-core/src/site_permissions_tests.rs::nothing_is_granted_until_somebody_answers`, `crates/zer0-core/src/site_permissions_tests.rs::an_answer_arriving_faster_than_a_person_could_give_it_is_ignored`, `crates/zer0-core/src/site_permissions_tests.rs::a_second_request_for_something_already_refused_is_answered_without_asking`, `crates/zer0-core/src/site_permissions_tests.rs::a_dismissed_question_is_not_asked_again_until_the_page_changes`, `crates/zer0-core/src/site_permissions_tests.rs::a_page_you_are_not_looking_at_is_refused_without_a_dialog`, `crates/zer0-core/src/site_permissions_tests.rs::a_second_question_is_refused_rather_than_stacked`, `crates/zer0-core/src/site_permissions_tests.rs::the_shapes_that_are_not_origins_are_all_refused`, `crates/zer0-core/src/site_permissions_tests.rs::an_internationalised_host_is_keyed_by_the_spelling_that_cannot_be_faked`, `crates/zer0-core/src/site_permissions_tests.rs::an_answer_given_in_one_space_does_not_follow_you_into_another`, `crates/zer0-core/src/site_permissions_tests.rs::closing_a_space_takes_its_answers_with_it`, `crates/zer0-core/src/site_permissions_tests.rs::revoking_reaches_every_tab_that_is_on_the_site`, `crates/zer0-core/src/site_permissions_tests.rs::a_camera_is_described_by_what_it_costs_you_not_by_its_name`, `crates/zer0-core/src/site_permissions_tests.rs::a_frame_asking_from_inside_someone_elses_page_says_so`, `crates/zer0-core/src/site_permissions_tests.rs::closing_a_tab_answers_the_question_it_was_asking`, `crates/zer0-core/src/site_permissions_tests.rs::refusing_one_half_of_a_pair_refuses_the_pair`, `crates/zer0-core/src/store_tests.rs::a_site_refused_a_camera_stays_refused_across_a_relaunch`, `crates/zer0-core/src/store_tests.rs::an_answer_given_in_an_ephemeral_space_is_never_written_down`, `crates/zer0-core/src/store_tests.rs::an_answer_given_in_one_space_comes_back_belonging_to_that_space`, `crates/zer0-core/src/store_tests.rs::a_row_naming_a_capability_this_build_does_not_know_is_dropped_rather_than_repaired`, `apple/Tests/Zer0ShellTests/SitePermissionTests.swift::SitePermissionTests/nothingIsGrantedWithoutAnAnswer`, `apple/Tests/Zer0ShellTests/SitePermissionTests.swift::SitePermissionTests/aSecondRequestForSomethingRefusedIsAnsweredWithoutAsking`, `apple/Tests/Zer0ShellTests/SitePermissionTests.swift::SitePermissionTests/aClosingTabStillAnswers`, `apple/Tests/Zer0ShellTests/SitePermissionTests.swift::SitePermissionTests/revokingReachesTheEngine`, `apple/Tests/Zer0ShellTests/SitePermissionTests.swift::SitePermissionTests/refusalsSurviveARelaunch`, `apple/Tests/Zer0ShellTests/SitePermissionTests.swift::SitePermissionTests/anEphemeralSpacePersistsNothing`, `apple/Tests/Zer0ShellTests/SitePermissionTests.swift::SitePermissionTests/aBackgroundTabIsRefusedWithoutADialog`, `apple/Tests/Zer0ShellTests/SitePermissionTests.swift::SitePermissionSheetRuleTests/theSheetHasNoKeyEquivalents`, `apple/Tests/Zer0ShellTests/SitePermissionTests.swift::SitePermissionSheetRuleTests/theSettleWindowIsNotWrittenHere`

## Context

Before this, `zer0` had no site permission handling at all. Not a weak one — an
absent one: there were zero occurrences of any media-capture delegate in the
repository. `HostedWebView` set `navigationDelegate` and never set
`uiDelegate`.

The header says what that meant. `WKUIDelegate.h`: *"If not implemented, the
result is the same as calling the decisionHandler with
`WKPermissionDecisionPrompt`."* So a site asking for the camera got WebKit's own
dialog. Nobody chose that. Nothing was written down, so there was no answer to
survive a relaunch and no screen anywhere that could tell you what a site held
or take it back. In a browser that is not a missing feature, it is a privacy
decision taken by omission — and it is the one decision in the product with a
live video feed on the other end of it.

There was a second, sharper failure sitting behind the first. The bundle's
`Info.plist` carried no `NSCameraUsageDescription` and no
`NSMicrophoneUsageDescription`. On macOS, a process that begins capture without
those keys is **terminated by TCC** — not refused, not given an error the page
can catch: the application disappears. So the state of things was that the
consent screen was Apple's, and saying yes to it crashed the browser.

### What the SDK actually surfaces

Established by reading `WebKit.framework/Headers` on the installed macOS 26 SDK,
not from recollection. The entire public site-permission surface is:

- **`webView(_:requestMediaCapturePermissionFor:initiatedByFrame:type:decisionHandler:)`**
  — macOS 12+, with `WKMediaCaptureType` carrying `.camera`, `.microphone` and
  `.cameraAndMicrophone`, answered with a `WKPermissionDecision` of `.grant`,
  `.deny` or `.prompt`.
- **`requestDeviceOrientationAndMotionPermissionForOrigin:`** — present in the
  header and marked `API_UNAVAILABLE(macos)`.

That is the whole list. Grepping every public header for `geolocation`,
`notification`, `displayCapture`, `screenCapture`, `clipboard`,
`speechRecognition`, `midi` and `webAuthn` returns nothing but the extension
API's own permission vocabulary and some comments. So:

- **Geolocation has no hook.** `WKWebView` routes it through CoreLocation at the
  process level. With no location usage description in the bundle, the app is
  not authorised, and `navigator.geolocation` calls the page's error callback.
  That is a refusal, it is the right answer, and it is not one we chose or can
  vary per site.
- **Notifications, `getDisplayMedia`, clipboard read, MIDI and WebXR** are
  either unimplemented in `WKWebView` or gated behind SPI. There is no delegate
  to implement and nothing to ask about.

Chrome's permission model has around a dozen entries. Ours has two, and the
honest statement is that the other ten are not decisions we get to make on this
engine. Building a general permission framework for capabilities that can never
arrive would be a vocabulary asserting things the browser cannot do (ADR-0018).

### Why this is not ADR-0028 with a different noun

ADR-0028 solved a structurally similar problem for extensions, and its
vocabulary discipline carries over directly. One thing does not.

**An extension dialog arrives at the end of a gesture somebody made.** They went
to a store page, they pressed Add, and the sheet is the answer to that. **A site
permission prompt is triggered by the page, at a moment the page chooses.** It
can land mid-sentence. It can land one frame after a click aimed at something
else. It can land again immediately after being refused. That is a
click-through machine, and a well-written dialog is not a defence against one —
it is the surface the machine operates on.

## Decision

**Nothing is granted that nobody approved; almost nothing is even asked about;
and every answer belongs to one Space.**

Five parts.

### The words and the rules are both behaviour, so both are in the core

`crates/zer0-core/src/site_permissions.rs` holds the vocabulary — `<all_urls>`
became *"Read and change everything you do on every site"* in ADR-0028, and
`getUserMedia` becomes *"Let meet.example see through your camera"*, with a
detail line saying it can watch and record for as long as the page is open. It
deliberately does **not** claim a recording light: whether one comes on is a
property of the hardware, and an external webcam may have none (ADR-0018).

It also holds `gate`, which is the part that actually protects anybody. Most
requests never produce a prompt, and every silent answer is a refusal:

- **An origin nobody could read.** A `file://` page, a `data:` URL, a sandboxed
  frame: each reports an origin that is empty or shared with every other
  document of its shape, so a grant to one is a grant to all of them.
- **A tab you are not looking at.** A background tab that can raise a sheet is a
  background tab that can steal an answer aimed at the page in front.
- **Something already refused.** No second dialog, ever, until the answer is
  changed in Settings.
- **Something dismissed in this tab since it last navigated.**
- **Anything arriving while a prompt is up.** Refused, not queued: a queue of
  permission dialogs is the same machine with a waiting room.

### The scope of a grant is (space, origin, capability), and the Space is the argument

Per origin is obvious. Per Space is the decision.

ADR-0007 makes a Space a cookie jar, and a cookie jar is an identity:
`meet.google.com` in Work is your work account, and in Personal it is not. A
camera grant is a grant to *whoever you are on that site*, and in this browser
who you are is a function of which Space you are in. Letting the grant cross
that line would put a hole in the identity boundary the whole product rests on,
and open it for the single most invasive thing a page can ask for.

It also falls out of what a Space *is*. Closing one deletes its jar with no undo
(ADR-0007). A grant that outlived that deletion would be an approval belonging
to an account that no longer exists, sitting there for the next Space to inherit
by reusing a name.

The counter-argument is real and we are choosing against it: the same site gets
asked twice, once per Space, and somebody who lives in three Spaces answers
three times. That is the cost. Over-asking costs a click; under-asking costs a
recording. And the sheet says which Space it is answering for, in the core's own
words, because "per site" is what everybody expects and it is not what this
does.

The origin is canonicalised in the core: lowercased scheme, `http` and `https`
only, default ports dropped so `https://x` and `https://x:443` are one key, and
the host taken through the URL parser — which means an internationalised domain
is keyed by its punycode, so `xn--80ak6aa92e.com` cannot hide behind a string of
Cyrillic that draws as `apple.com`.

**A request from an embedded frame is keyed to the frame, not the page.** An
advert asking for the camera inside a site you trust gets a sheet naming the
advert, plus a sentence saying which page it was inside. Granting the page
around it would hand a camera to a site nobody was asked about.

### Designed against click-through

Five things, and each is a rule rather than a piece of copy.

1. **`PROMPT_SETTLE_MS`.** An answer arriving less than half a second after the
   prompt went up is **ignored** — not converted to a refusal, which a page
   could then force by racing. This is the keystroke that was already on its way
   down when the sheet took the keyboard. The core enforces it; the sheet
   disables both buttons for the same interval, read from `promptSettleMs()`
   rather than written out, so the two cannot disagree.
2. **Neither button carries a key.** No `.defaultAction` on Allow, and no
   `.cancelAction` on Don't Allow. This is a deliberate departure from
   `ExtensionConsentSheet`, from every other sheet in this shell, and from the
   rule in `AGENTS.md` that says Enter confirms — and the departure is the
   point. That rule is written for a screen somebody opened. Both answers here
   are written down and both change what the browser does from now on, and the
   page picked the moment. A key equivalent on a permanent answer is a
   keystroke aimed at a text field landing on a camera.
3. **Escape is bound, and it gives the transient answer.** The page is told no,
   nothing is recorded, and it cannot ask again in that tab until the tab
   navigates. Closing a window is not an instruction (the same sentence
   `ExtensionsView.cancelDecision` already runs on), but it has to cost the page
   something or Escape becomes a key you hold down while a loop asks again.
4. **A refusal stops the asking.** Permanently, per Space, reversible only from
   Settings.
5. **One question at a time, from the tab you are looking at.** Above.

The clock for all of this is the shell's, arriving on the action, because
`Action::Tick` moves the core's clock once a minute and the window is half a
second. That is the same seam `default_consent_decision(decided_at_ms:)`
already uses.

### What a refused site sees

`WKPermissionDecisionDeny`, which WebKit turns into the `getUserMedia` promise
rejecting with `NotAllowedError` — the exact error every site's fallback path is
already written for. It arrives immediately, so a page that is going to degrade
degrades now rather than after a timeout.

The property that makes this true is not the decision value, it is that **every
request is answered exactly once.** A `getUserMedia` promise settles when the
handler runs and never otherwise, so a handler dropped on the floor is a page
that spins forever with no error and nothing on screen — worse than any
refusal. So the handlers live on `EngineHost` rather than on the per-tab
delegate that received them, a tab closing mid-question emits the refusal
*before* `DestroyWebView`, and `SitePermissionLedger.answer` removes before it
calls so nothing can be answered twice.

### Revocation reaches the engine

`Settings › Privacy` lists every answer, refusals included — a refusal you
cannot see is a refusal you cannot undo, and blocking a site by accident on a
sheet you did not expect is precisely the mistake this pane exists to be
findable after. Each row offers Allow, Block, and a control that forgets the
answer entirely so the site is asked again; those are different things to want.

Blocking or forgetting emits `EngineCommand::StopCapture` for every tab in that
Space whose committed address is that origin, and the host calls
`setCameraCaptureState(.none)` / `setMicrophoneCaptureState(.none)`. Answering
the *next* request with a refusal would not be enough: a page that already holds
a stream keeps it until something takes it away, and a row reading "blocked"
over a camera that is on is the exact shape of lie ADR-0028 exists to end.

### Where it is persisted

`Session::site_permissions`, through `StorableSession` (ADR-0045), into schema 9
and a `site_permissions` table of its own. Denials are stored rather than
inferred, so absence keeps meaning "nobody was asked".

**An ephemeral Space persists nothing, including a grant.** The filter is in
`StorableSession::project`, above every backend, for the reason that module
exists: a store cannot write a rule it was never handed. A grant is only worth
having *because* it is remembered, so remembering one from a Space that promised
to remember nothing is not a smaller version of the promise — it is the promise
broken.

## Consequences

**What hurts:**

- **The same site is asked once per Space**, and somebody who keeps Work,
  Personal and a throwaway will answer three times for the same video call. This
  is the deliberate cost of the scope decision and it is the thing people will
  complain about first.
- **An ephemeral Space asks every single time.** Nothing it answers is written
  down, so a throwaway Space used for one long call re-asks on every relaunch.
  Correct, and irritating.
- **Two capabilities is the whole feature.** Somebody will read "site
  permissions" and look for geolocation and notifications, and there is nothing
  there — not because we skipped them but because `WKWebView` has no hook. The
  Privacy pane says "Camera and microphone" rather than "Site permissions" so
  the absence does not read as a gap.
- **The prompt is one tier, and everything on it is the serious one.** With two
  capabilities there is no honest second rank; `ExtensionConsentSheet`'s
  five-tier grammar has nothing to rank here. If a third capability ever
  arrives, that judgement has to be made rather than inherited.
- **Half a second of dead buttons.** Nobody reading the sheet will notice, and
  somebody testing it will, and it will read as a bug until they find this file.
- **Blocking a site by accident is one click and is permanent.** The pane is the
  only way back, and nothing on the page tells you it was blocked — the site
  sees `NotAllowedError` and shows whatever it shows, which for most sites is
  "check your browser settings" pointing at Chrome's UI.
- **The prompt claims exactly one Space's name and no more.** A grant made
  before a Space was renamed still applies; the sheet's sentence is about the
  Space it is asking for and cannot say anything about answers given elsewhere.
- **Schema 9.** An older build reads the file, ignores the table entirely, and
  is back to letting WebKit decide.
- **The delegate is a `WKUIDelegate` and it answers one method.** JavaScript
  alerts, confirms, prompts and the file open panel are all on the same protocol
  and are deliberately left unimplemented, so WebKit's defaults are exactly what
  they were. That includes the file open panel, which on macOS means an
  unimplemented delegate behaves as Cancel — a pre-existing defect this change
  neither causes nor fixes, and one worth its own work.

**What we get:**

- Nothing is granted that nobody answered, and a page cannot answer for you by
  choosing when to ask.
- A refusal survives a relaunch, which is the only thing that makes a dialog
  worth reading twice.
- What a site holds is visible on a screen and revocable from it, and revoking
  reaches WebKit.
- Work and Personal cannot answer for each other, which is the promise Spaces
  already make about cookies extended to the one thing that is worse than a
  cookie.
- The browser stops crashing when a page starts capture, which it would have
  done on the first grant.
- All of it — the words, the ranking, the gate, the scope, what persists — is
  testable without a window and ports to Linux unchanged. What does not port is
  about thirty lines of `SitePermissionHost.swift`.

## How this regresses

**"It stopped asking and just let the site in."** Somebody adds a convenience
path that records a grant without a prompt, or `gate` starts answering `Allow`
for an undecided origin. `nothing_is_granted_until_somebody_answers` is the
fence, and `nothingIsGrantedWithoutAnAnswer` holds the same line from the Swift
side against the real engine ledger.

**"I pressed Return and it turned my camera on."** `.defaultAction` gets added
to the sheet, which will look like a bug fix — every other sheet in this shell
has one, and a sheet where Return does nothing reads as broken.
`theSheetHasNoKeyEquivalents` reads the source, because the rule is an
*absence* and no assertion can watch one. `an_answer_arriving_faster_than_a_person_could_give_it_is_ignored`
is the second lock on the same failure, one layer down.

**"A background tab put a dialog in my face."** The visibility check is dropped
because it looked like defensive programming, or "the active tab" is loosened to
"a tab". `a_page_you_are_not_looking_at_is_refused_without_a_dialog` and
`aBackgroundTabIsRefusedWithoutADialog` are what go red, and
`a_pane_of_a_split_is_a_page_you_are_looking_at` is the one that keeps the fix
from being "refuse everything but `active_tab`".

**"A site I blocked asked me again."** The ledger stops being consulted before
the prompt is raised, or a refusal is stored as an absence "because absence is
tidier". `a_second_request_for_something_already_refused_is_answered_without_asking`
covers the live path and `a_site_refused_a_camera_stays_refused_across_a_relaunch`
covers the one that only shows up tomorrow.

**"My work camera grant showed up in my personal space."** The `space` field is
dropped from the key during a refactor that notices two of the three columns are
enough to find a row. `an_answer_given_in_one_space_does_not_follow_you_into_another`
and `an_answer_given_in_one_space_comes_back_belonging_to_that_space` hold both
ends of it.

**"The incognito space remembered."** The projection filter is moved into the
backend, or dropped because `Session` already holds the truth.
`an_answer_given_in_an_ephemeral_space_is_never_written_down` is the fence, and
it is a store round trip rather than a projection assertion on purpose.

**"I turned it off and the camera light stayed on."** `SetSitePermission` stops
emitting `StopCapture` — which looks completely correct, because the ledger is
right and the row repaints. `revoking_reaches_every_tab_that_is_on_the_site`
asserts on the command, and `revokingReachesTheEngine` asserts against a real
`WKWebView`.

**"A page hung forever with no error."** Somebody returns early from a gate
branch without emitting an answer, or the handler map moves onto the per-tab
delegate so a closing tab drops it. `closing_a_tab_answers_the_question_it_was_asking`
and `aClosingTabStillAnswers` are the two, and the second also asserts the
ledger is empty afterwards — "the handler was called" is only half the claim.

**"It let a `file://` page have the camera."** `canonical_origin` is loosened to
be "more forgiving" about schemes. `the_shapes_that_are_not_origins_are_all_refused`
lists seven shapes and refuses all of them.

**And the one no test catches:** the sentence drifting from a consequence back
into a name. Nothing goes red when *"Let meet.example see through your camera"*
becomes *"meet.example wants to use your camera"*, and the second is Chrome's
wording, which has never stopped anybody.
`a_camera_is_described_by_what_it_costs_you_not_by_its_name` pins that one
string, and nothing pins the next one somebody writes.

## When to revisit

- **When `WKWebView` gains a delegate for anything else.** Geolocation and
  notifications are the two people will ask for. The ledger, the scope, the
  gate and the sheet all take a new capability without changing shape; what
  needs deciding is whether one-tier risk grammar survives contact with
  something less severe than a live camera feed.
- **When display capture becomes public API.** `getDisplayMedia` is the one
  missing capability that is *worse* than the two we have — it is not the
  browser, it is whatever is on the screen — and it needs its own sentence
  rather than a reuse of the camera's.
- **If asking once per Space turns out to be the thing people hate.** The
  alternative is a per-origin grant with a per-Space override, which is a more
  complicated model with a worse failure mode, and it should not be reached for
  before the simple one has annoyed somebody real.
- **When the JavaScript dialogs are done.** They are on the same delegate, they
  are currently WebKit's defaults, and `runOpenPanelWithParameters` being
  unimplemented means file upload does not work on macOS at all. That is a
  separate decision and it should be written down as one.
- **When a Linux host is attempted.** `webkit2gtk` signals permission requests
  through `permission-request` with a `WebKitUserMediaPermissionRequest`, which
  is a different shape from a decision handler — the core's half ports
  unchanged, and whatever replaces `SitePermissionLedger` has to keep "exactly
  one answer per request" true.
