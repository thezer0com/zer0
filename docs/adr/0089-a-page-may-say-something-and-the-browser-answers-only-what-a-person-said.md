# ADR-0089: A page may say something, and the browser answers only what a person said

- **Status:** Accepted
- **Date:** 2026-08-10
- **Lock:** `crates/zer0-core/src/page_dialogs_tests.rs::a_page_that_asks_is_asked_about_and_told_nothing_until_somebody_answers`, `crates/zer0-core/src/page_dialogs_tests.rs::cancelling_still_answers_the_page`, `crates/zer0-core/src/page_dialogs_tests.rs::typing_nothing_is_not_the_same_as_cancelling`, `crates/zer0-core/src/page_dialogs_tests.rs::choosing_no_files_is_a_cancel_rather_than_an_empty_selection`, `crates/zer0-core/src/page_dialogs_tests.rs::a_second_answer_to_the_same_question_calls_nothing`, `crates/zer0-core/src/page_dialogs_tests.rs::an_answer_nobody_could_have_given_in_the_time_changes_nothing`, `crates/zer0-core/src/page_dialogs_tests.rs::a_cancel_is_never_too_soon`, `crates/zer0-core/src/page_dialogs_tests.rs::a_file_picker_answered_quickly_still_answers`, `crates/zer0-core/src/page_dialogs_tests.rs::two_windows_each_showing_a_question_each_get_theirs`, `crates/zer0-core/src/page_dialogs_tests.rs::a_page_you_are_not_looking_at_waits_rather_than_interrupting_or_being_answered`, `crates/zer0-core/src/page_dialogs_tests.rs::a_question_that_waited_arrives_when_you_look_at_the_tab`, `crates/zer0-core/src/page_dialogs_tests.rs::a_pane_of_a_split_is_a_page_you_are_looking_at`, `crates/zer0-core/src/page_dialogs_tests.rs::a_question_is_addressed_to_the_window_its_tab_is_in`, `crates/zer0-core/src/page_dialogs_tests.rs::a_second_question_from_one_tab_is_cancelled_rather_than_stacked`, `crates/zer0-core/src/page_dialogs_tests.rs::the_offer_to_stop_a_page_appears_once_it_has_interrupted_twice`, `crates/zer0-core/src/page_dialogs_tests.rs::a_page_told_to_stop_is_cancelled_without_being_shown`, `crates/zer0-core/src/page_dialogs_tests.rs::a_silenced_page_is_heard_again_once_the_tab_goes_somewhere_else`, `crates/zer0-core/src/page_dialogs_tests.rs::a_tab_that_closes_mid_question_does_not_leave_the_page_waiting_forever`, `crates/zer0-core/src/page_dialogs_tests.rs::closing_a_space_answers_every_page_its_tabs_were_asking`, `crates/zer0-core/src/page_dialogs_tests.rs::closing_a_window_answers_every_page_its_tabs_were_asking`, `crates/zer0-core/src/page_dialogs_tests.rs::navigating_away_answers_the_question_the_old_page_was_asking`, `crates/zer0-core/src/page_dialogs_tests.rs::an_internationalised_host_is_named_by_the_spelling_that_cannot_be_faked`, `crates/zer0-core/src/page_dialogs_tests.rs::a_page_with_no_address_of_its_own_says_so_rather_than_leaving_the_line_blank`, `crates/zer0-core/src/page_dialogs_tests.rs::a_page_that_writes_a_book_is_cut_and_the_panel_knows_it_was`, `crates/zer0-core/src/page_dialogs_tests.rs::what_a_file_control_allows_is_carried_exactly_as_the_engine_reported_it`, `apple/Tests/Zer0ShellTests/PageDialogTests.swift::PageDialogTests/confirmIsAnsweredByAPersonRatherThanByTheBrowser`, `apple/Tests/Zer0ShellTests/PageDialogTests.swift::PageDialogTests/cancellingAnswersThePage`, `apple/Tests/Zer0ShellTests/PageDialogTests.swift::PageDialogTests/promptCarriesTheTypedTextHome`, `apple/Tests/Zer0ShellTests/PageDialogTests.swift::PageDialogTests/alertBlocksAndThenReleases`, `apple/Tests/Zer0ShellTests/PageDialogTests.swift::PageDialogTests/aFileControlOpensAPickerAndCancellingAnswers`, `apple/Tests/Zer0ShellTests/PageDialogTests.swift::PageDialogTests/anEmptyPickIsACancel`, `apple/Tests/Zer0ShellTests/PageDialogTests.swift::PageDialogTests/multipleAndDirectoryAreCarried`, `apple/Tests/Zer0ShellTests/PageDialogTests.swift::PageDialogTests/aPickedFileArrivesInTheControl`, `apple/Tests/Zer0ShellTests/PageDialogTests.swift::PageDialogTests/aClosingTabStillAnswers`, `apple/Tests/Zer0ShellTests/PageDialogTests.swift::PageDialogTests/aPanelIsOfferedOnlyToItsOwnWindow`, `apple/Tests/Zer0ShellTests/PageDialogTests.swift::PageDialogSourceRuleTests/theSitesWordsAreDrawnVerbatimAndInOnePlace`, `apple/Tests/Zer0ShellTests/PageDialogTests.swift::PageDialogSourceRuleTests/theIdentityLineComesFromTheCore`

## Context

Four `WKUIDelegate` methods were unimplemented, and ADR-0086 had already
enumerated them. This is the entry leaving that list.

**Measured before anything was built**, by driving a real `WKWebView` inside a
real `BrowserModel` over `http://127.0.0.1`, with exactly the delegate the shell
sets:

| the page calls | what it evaluated to | what a person saw |
| --- | --- | --- |
| `alert('…')` | returned in **94 ms** | nothing at all |
| `confirm('delete this?')` | **`false`** | nothing, and the answer was Cancel |
| `prompt('your name?', 'ada')` | **`null`** | nothing, and the answer was Cancel |
| clicking `<input type="file">` | — | no panel, no `change` event, `files.length` 0 |

The file control was checked on an **ordinary web page**, not inside an
extension popup, because the report that started this was an extension's "Import
preferences" button and the interesting question was whether the defect was
larger than that. It is: `window.attachedSheet` was `nil`, `NSApp.modalWindow`
was `nil`, and the page's own `change` listener never fired.

**The instrument was established before the absence was believed.** A probe
`WKUIDelegate` that *does* implement `runOpenPanelWith` was attached to the same
view, the same element was clicked again, and it fired exactly once — so the
click really does reach the delegate, and "nothing happened" is the shell's
answer rather than the harness missing it. `AGENTS.md` requires that; it is also
the difference between this finding and the two an earlier agent manufactured.

### What the SDK actually exposes for a file control

`WKOpenPanelParameters` carries **two** properties and nothing else:
`allowsMultipleSelection` and `allowsDirectories`. Measured against real
controls: an ordinary `<input type="file">` reports `false, false`;
`<input multiple>` reports `true, false`; `<input webkitdirectory>` reports
**`false, true`** — not `true, true`, which is what "a directory holds many
files" suggests, which is what a first pass at this recorded, and which a test
caught. One directory is one selection.

**There is no `accept`.** Grepping every public WebKit header for a type filter
on the open panel returns nothing. Two underscored selectors do exist —
`_allowedFileExtensions` and `_acceptedMIMETypes` both answer `responds(to:)` —
and they are SPI, which ADR-0001 refuses and ADR-0067 confines to one file.
So this browser cannot narrow the panel by type, and the decision is to **not
pretend to**: a filter derived from a guess hides the file somebody came to pick,
which is the repair-that-guesses `AGENTS.md` warns about, in the one place where
the person cannot see what was hidden.

### `confirm()` is the sharp one, and it is sharp in a direction that will turn

Today a page asking "delete this?" is silently told no, which fails safe. The
day a page phrases it as "keep my changes?" the same silence answers wrongly, and
nothing anywhere would say so. A silent wrong answer is worse than no answer;
that is the whole reason this is not a cosmetic gap.

## Decision

**A page may say something. The core decides who is asked, when, and what is
said about who is talking. The shell draws it, and the site's words are visibly
the site's.**

`crates/zer0-core/src/page_dialogs.rs` holds it. One vocabulary for all four,
because they arrive on one protocol and share one lifecycle, and four
independently invented seams is how four panels end up looking like four
products.

### The invariant, restated from ADR-0056 because it is worse here

**Every request is answered exactly once**, and it is structural on both sides
rather than careful. `PageDialogLedger.answer` **removes before it calls**, so a
handler cannot be called twice even if an answer somehow arrives twice; and
`answer_pending_for` in the reducer is the one door a tab goes away through, so
closing a tab, closing its window and closing its space all answer without any
of the three knowing about page dialogs. Navigating away answers too, at the
commit.

A `getUserMedia` promise nobody settles is a page that spins; an `alert()` nobody
answers is a page that has **stopped** — the call is synchronous and the script
does not move. It is the same failure the authentication work names as the worst
in its own change, one delegate along: a dropped handler produces no `didFinish`,
no `didFail` and no timeout, only a rectangle that never becomes anything.
**WebKit agrees**: a completion block released without having been called raises
`NSInternalInconsistencyException` naming the delegate method and takes the
process down, which is how the suite found the settle-window bug below.

One more trap, recorded because it costs hours and looks like something else: a
`WKUIDelegate` method whose completion handler parameter is missing `@MainActor`
is **a different selector**. Swift compiles it, WebKit never calls it, and it
reads exactly as "the delegate is not being invoked". All four here carry
`@escaping @MainActor @Sendable`, and the proof that the selectors are right is
that real pages drive them in `PageDialogTests` rather than that they compile.

### A background tab waits. It does not interrupt, and it is not answered

This is the decision the rest hangs off, and both halves matter.

A panel belongs to **a tab**, is drawn on **the window that tab is in**, and
appears only while that tab is one that window is showing. A background tab's
question is *held* — the page is blocked, which is what `alert()` means — and
arrives when you look at the tab.

Answering a background tab immediately was the obvious alternative and it is the
defect this ADR exists to end, committed in the name of fixing it. Holding is
also what Chrome does, and it costs nothing: the page was going to be blocked
either way.

`is_on_screen` is deliberately **not** `site_permissions::is_visible`. That one
asks about the key window only and refuses everything else, which is right for a
camera — an answer nobody is looking at should fail closed. A page dialog cannot
fail closed and stay honest, so this asks per window: a second window's front tab
is on somebody's screen even when the keyboard is in the first. The two
functions are named against each other in the source so the difference reads as
a decision rather than as drift. *(The camera sheet's own window scoping is a
separate, pre-existing gap; see When to revisit.)*

### The site's words are visibly the site's

The threat is a page writing in the browser's voice — "your password has
expired", in our type, on a panel we drew. Four things, and three of them are
structural rather than a rule somebody has to remember:

1. **`SiteWords` is the only path a page's string takes to the screen.** It draws
   `Text(verbatim:)`, never `Text(_:)` — the second parses markdown at runtime,
   so `**Sign in**` would arrive bold and `[here](…)` would arrive as a link. It
   is recessed, selectable and never weighted or tinted, so it is visibly a
   different material from everything else on the sheet.
   `theSitesWordsAreDrawnVerbatimAndInOnePlace` counts the reads of
   `dialog.message` and fails on a second one.
2. **The identity line is always there and is the core's spelling.** The origin
   is `site_permissions::canonical_origin` — the same function the camera sheet
   is keyed by, so an internationalised host arrives as punycode and a string of
   Cyrillic that draws as `apple.com` shows as `xn--80ak6aa92e.com`. The shell
   never splits an origin; `PageDialogSpeaker::Site` carries the host as its own
   field, and `theIdentityLineComesFromTheCore` refuses `://` in the sheet.
3. **A page with no origin says so rather than leaving the line blank.**
   `file://`, `data:` and a sandboxed frame get
   `PageDialogSpeaker::Nameless`, whose sentence is the core's. A panel whose
   identity line is *sometimes absent* has a blank a spoof can stand in. The
   note deliberately does not quote the scheme it saw, which would hand a
   hostile page a place to write.
4. **The page's text is capped at 2,000 characters, and the cut is said out
   loud.** An ellipsis is indistinguishable from the page's own; a sentence is
   not. `MESSAGE_LIMIT` is exported so the sheet's wording cannot name a
   different number from the one the core cuts at.

### Return is bound here and is not on the camera sheet

ADR-0056 gives its sheet no key equivalents, and the argument it gives is
specific: *both answers are written down and both change what the browser does
from now on*. Nothing here is recorded. Every browser binds Return to OK on an
`alert()`, and `AGENTS.md` says a shortcut already in someone's fingers does what
those fingers expect.

**What that costs is paid by the same settle window.** OK is dead for
`PROMPT_SETTLE_MS`, the core ignores an answer inside it, and both sides read
the *same* constant through the *same* `answered_too_soon`. A page picks the
moment it interrupts, so the Return that lands first is the one that was already
on its way down when it did — and two modal panels a page can summon, one
guarded against that and one not, is a gap with nothing but luck in it.

**Cancel and Escape are live from the first frame**, which is where this parts
company with ADR-0056 a second time. That sheet gates both buttons because both
of its answers are recorded. Cancel here commits nothing — it is the same answer
a closing tab, a silenced page and a crashed window all give — so the gate goes
on the committing side only, and Escape and the button beside it cannot
disagree for half a second with one of them winning by accident.

**And the window does not reach the file picker at all.** That panel is the
system's own modal window with its own focus; nobody can type into a page and
into an open panel at the same time, so there is no keystroke to defend against.
This was got wrong first: with the window applied uniformly, a picker closed
inside half a second was silently ignored, the page stayed frozen on a control
somebody had already cancelled, and the process **aborted** at teardown with
`NSInternalInconsistencyException: Completion handler passed to
webView:runOpenPanelWithParameters: was not called`. `guarded_by_the_settle_window`
is one function naming both exclusions, and it matches on kind and answer
exhaustively so a fifth panel has to be decided about rather than inherited.

### The way out of a page in a loop, and it is in this change

A page can call `alert()` forever. From the **second** interruption since the
tab last navigated, the panel carries "Stop this page opening more messages" —
not the first, because a checkbox on the first alert a site ever shows is the
browser calling it hostile before it has done anything.

Ticking it cancels everything else that page asks until the tab navigates. That
is a silent answer, and it is the one silent answer this ADR permits, because it
is the answer *they gave*: the control states its consequence underneath itself,
in the present tense, the way `ExtensionConsentSheet`'s footer does. It rides on
the answer rather than arriving as an action of its own, so ticking the box and
pressing Cancel in one gesture lands as one thing — two actions leave a window
in which the page asks again.

### The file control is on this seam and is not drawn here

The panel is `NSOpenPanel`, put up by `FilePanelPresenter` as a sheet on the
window holding the tab's own web view — `webView.window`, the same route
`DownloadHost` takes for the save panel. What the core owns is the gate, the
holding and the one answer; what the panel owns is choosing files, which is not
a thing a browser should draw for itself.

Four details, and what was verified about each:

- **`multiple`** → `allowsMultipleSelection`. Measured through a real control.
- **`webkitdirectory`** → `canChooseDirectories`, and `canChooseFiles` goes
  *false* with it: a control that asked for a directory is not answered by a
  file. Measured, an ordinary control reports `allowsDirectories == false`, so
  this is the control's own question rather than a guess about what it meant.
- **`accept`** → not exposed. No filter, and no pretence of one. Above.
- **Cancel** → `completionHandler(nil)`, through the same ledger as everything
  else. This is the line the upload button depends on: a handler not called on
  Cancel leaves the page's promise unsettled forever and the control dead until
  the tab is reloaded. **WebKit enforces it**, which was not known when this
  started: a completion block released without being called raises
  `NSInternalInconsistencyException` naming the delegate method, and the process
  goes down. So the invariant is not only ours.
- **Picking nothing** → a cancel, not an empty selection. An empty list handed
  to a file control reads as "clear what was there".

`presented` is a set of request numbers rather than a boolean, because the core
hands the same dialog back on every snapshot until it is answered — which is
what keeps the drawn sheet honest and would otherwise put a second picker up on
every dispatch.

**How the panel is run is a closure, and that is a measurement rather than a
taste.** An `NSOpenPanel` presented from inside `runOpenPanelWith` — which is
inside WebKit's message handling, with the web process waiting on the far end —
never comes back in a process that has no `NSApplication.run`: the suite hung
indefinitely, twice, before and after deferring the presentation by a run-loop
turn. Driven from the real app the same `beginSheetModal` `DownloadHost` already
uses for the save panel works. So `FilePanelRunner` is the seam: everything the
browser *decides* about the panel is a value, asserted; what AppKit then draws
from that value is verified by running the browser and looking. That split is
stated here because the alternative — a test that presents nothing and claims to
cover the picker — is the kind of green-looking evidence ADR-0075 warns about.

### Nothing here is written down

`Session::page_dialogs` is not persisted and there is nowhere it could be. A
page frozen inside `alert()` in a previous run is not on the other end of that
call now, and the engine holds no handler to answer.

## Consequences

**Uploading a file works, on every site.** That is the change most people will
notice and none of them will describe as a feature.

**`confirm()` stops answering for you**, which means some pages that used to
"work" now stop and wait. That is the point, and it will read as a regression to
anybody who had learned to live with the old behaviour on one particular site.

**A page can hold a tab.** `alert()` in a loop blocks that tab until it is
answered or silenced. The tab is still closeable, the other tabs are untouched,
and the way out is on the panel from the second one — but a page you leave in
the background with a question outstanding stays stopped until you come back to
it. That is `alert()`'s own contract and not something this adds.

**Two ledgers, not one.** `SitePermissionLedger` and `PageDialogLedger` hold
different kinds of handler, and a map that held either would need a discriminant
anyway. They are answered at the same door when a tab goes.

**The camera sheet's window scoping is now visibly the odd one out.**
`snapshot.site_permission_prompt` carries no window, so with two windows open a
camera prompt is offered by both. Pre-existing, untouched here, named below.

## How this regresses

**Somebody answers a background tab instead of holding it.** It is one line, it
removes a whole state, and it reads as a simplification — the camera gate does
exactly that and is right to. It is also the original defect wearing a fix's
clothes. `a_page_you_are_not_looking_at_waits_rather_than_interrupting_or_being_answered`
asserts *both* halves: nothing is drawn, and nothing is answered.

**Somebody draws the page's message with `Text(_:)`.** It looks identical in
every test message anybody would write, because none of them contain markdown.
The day one contains `**` the browser renders a site's emphasis in its own type
on its own panel. `theSitesWordsAreDrawnVerbatimAndInOnePlace` reads the source,
because no assertion can watch a string not being parsed.

**Somebody puts the page's words in the title.** The most natural tidy-up on
this sheet — Chrome's dialog leads with them — and it is the whole spoof. The
same scan counts the reads of `dialog.message`; a second one fails it.

**Somebody splits the origin in the shell.** `origin.split("://")` to get a host
for the sentence is two lines and looks like nothing. It is a second
implementation of `host_of`, and the day the two disagree a panel names a site
that is not the one talking. `theIdentityLineComesFromTheCore` refuses the
spellings.

**Somebody drops the settle window** because it makes the OK button feel
sticky, or because "the camera sheet needs it and an alert does not". Broken on
purpose: `an_answer_nobody_could_have_given_in_the_time_changes_nothing` went
red with the answer reaching the page.

**Somebody returns early from a gate branch without answering.** The page hangs
with nothing on screen and no error, on some other day, in some other file. Six
tests cover the paths a request can leave by — cancel, close, navigate, a second
question, a silenced page, a tab already gone — and
`aClosingTabStillAnswers` asserts the ledger is *empty* afterwards, because "the
handler was called" is only half the claim.

**Somebody hands an empty file list to a control instead of a cancel.** It looks
equivalent and it is not: an empty list reads as "clear what was there".
`choosing_no_files_is_a_cancel_rather_than_an_empty_selection` holds it in the
core, where both hosts inherit it.

**Somebody adds a fifth `WKUIDelegate` method and does not implement it.** That
is ADR-0086's whole subject and this ADR does not close it. What it does close
is the four: `SitePermissionDelegate`'s header now says that every optional on
the protocol is implemented, at the place a reader will look.

## When to revisit

- **When the camera sheet is scoped to a window.** `SitePermissionPrompt`
  carries no `window` and `BrowserView` presents it unfiltered, so two windows
  both offer to answer. That is a pre-existing defect of ADR-0056, it is the
  same shape this ADR solved for page dialogs, and it should be fixed by giving
  that prompt a window rather than by widening this one.
- **When `is_visible` and `is_on_screen` should become one function.** They
  answer deliberately different questions today. If the camera gate is ever
  widened to per-window, the two collapse and there should be one.
- **If WebKit exposes the `accept` list publicly.** Then filtering is *backed*
  and showing it becomes mandatory rather than forbidden, the way ADR-0018 says
  a match count would.
- **When an extension's own popup gets these four.** The report that started
  this was an extension's "Import preferences" button, and the fix here does
  **not** reach it: `WKWebExtensionAction.popupPopover` builds its own web view
  inside WebKit and nothing in this shell sets a `uiDelegate` on it, so a file
  control in a popup is still answered by whatever WebKit's default is. Stated
  as unverified rather than measured — it needs an installed extension with a
  file control in its popup — and it belongs with the extension work rather than
  here.
- **When a page dialog should carry the tab's own marker.** A background tab
  holding a question is frozen with nothing in the sidebar saying so; you find
  out by visiting it. That is a real gap in "anything in flight has feedback"
  and it is a sidebar decision, not this one.
- **If holding turns out to be wrong for one of the four.** The file control is
  the candidate: WebKit requires user activation to open one, so a held file
  picker should be nearly unreachable, and if it turns out to be reachable in
  practice the honest answer may be to cancel it rather than to hold it.
- **When a Linux host is attempted.** `webkit2gtk` signals all four through
  `script-dialog` and `run-file-chooser`, which return a boolean rather than
  taking a completion handler — the core's half ports unchanged, and whatever
  replaces `PageDialogLedger` has to keep "exactly one answer per request" true.
