# ADR-0101: A stopped download carries on only while something still holds what that would take, and a page that prints is a page you are looking at

- **Status:** Accepted
- **Date:** 2026-08-10
- **Lock:** `crates/zer0-core/src/download_reducer_tests.rs::resuming_keeps_the_entry_and_the_bytes_that_already_arrived`, `crates/zer0-core/src/download_reducer_tests.rs::a_download_nobody_kept_resume_data_for_cannot_be_resumed`, `crates/zer0-core/src/download_reducer_tests.rs::a_download_whose_resume_data_went_away_stops_offering_to_carry_on`, `crates/zer0-core/src/download_reducer_tests.rs::only_a_stopped_and_unfinished_download_can_be_marked_resumable`, `crates/zer0-core/src/download_reducer_tests.rs::resuming_something_still_arriving_would_open_a_second_connection_so_it_does_not`, `crates/zer0-core/src/download_reducer_tests.rs::stopping_a_download_yourself_can_still_be_carried_on_from`, `crates/zer0-core/src/download_reducer_tests.rs::a_download_does_not_come_back_offering_to_carry_on`, `crates/zer0-core/src/page_dialogs_tests.rs::a_page_may_print_the_page_you_are_looking_at`, `crates/zer0-core/src/page_dialogs_tests.rs::a_page_you_are_not_looking_at_does_not_print_itself`, `crates/zer0-core/src/page_dialogs_tests.rs::a_pane_of_a_split_may_print_itself`, `crates/zer0-core/src/page_dialogs_tests.rs::a_tab_that_is_gone_prints_nothing`, `apple/Tests/Zer0ShellTests/DownloadEndToEndTests.swift::DownloadResumeTests/aDroppedConnectionIsCarriedOnFromWhereItStopped`, `apple/Tests/Zer0ShellTests/DownloadEndToEndTests.swift::DownloadResumeTests/stoppingAndCarryingOnLandsTheWholeFileOnce`, `apple/Tests/Zer0ShellTests/DownloadEndToEndTests.swift::DownloadResumeTests/aServerThatCannotBeResumedFromNeverOffersIt`, `apple/Tests/Zer0ShellTests/DownloadEndToEndTests.swift::DownloadResumeTests/aSaveRowInTheContextMenuLandsAFile`, `apple/Tests/Zer0ShellTests/PagePrintTests.swift::PagePrintTests/windowPrintIsReplacedAndReachesTheBrowser`, `apple/Tests/Zer0ShellTests/PagePrintTests.swift::PagePrintTests/printingAPageInNoWindowOpensNothing`, `apple/Tests/Zer0ShellTests/PagePrintTests.swift::PagePrintTests/printingATabWithNoPageOpensNothing`, `apple/Tests/Zer0ShellTests/PagePrintTests.swift::PagePrintTests/attachingTwiceOverOneControllerIsNotACrash`

## Context

Three defects, measured rather than reported, and the last two turn out to be
one feature.

**Resume data was thrown away.** `DownloadHost` implemented
`download(_:didFailWithError:resumeData:)` with the third parameter spelled `_`.
So a 4 GB file that died at 80% on a hotel connection could only ever be started
again from zero, and pause did not exist, because pause is resume with a person
pressing the button.

**`window.print()` reached nothing.** Measured on a real `WKWebView` carrying
exactly the delegates this shell sets: `typeof window.print` is `function`,
calling it returns immediately, and afterwards `NSApp.modalWindow` and the
window's `attachedSheet` are both `nil`. **The instrument was established
first** — `alert()` on the same view reached a `WKUIDelegate` we do implement —
so that is WebKit's answer rather than the harness missing it. This is ADR-0086's
shape exactly: an optional the public API never offers, whose absence is
invisible from inside the code.

**And ⌘P had a repair that guessed.** `printPage` ran
`runModal(for: webView.window ?? NSWindow())`. A freshly constructed `NSWindow`
is never ordered in, so on a page with no window the print panel opened on a
window nobody can see and nobody can dismiss — the browser waiting on an answer
to a question it never asked.

### What WebKit really does, measured

A standalone probe drove a real `WKWebView` against a local server that sends
`Content-Length`, `Accept-Ranges`, `ETag` and honours `Range`:

| what was done | what came back |
| --- | --- |
| `WKDownload.cancel { data in }` after 256 kB of 5 MB | **6,585 bytes** of resume data; 256 kB on disk |
| `resumeDownload(fromResumeData:)` with it | the server saw `Range: bytes=262144-`, the file finished at exactly 5 MB, every byte correct |
| the same resumed download | `decideDestinationUsing` was **never called** |
| a server that dropped the connection at 300 kB | `NSURLErrorDomain -1005`, and **6,421 bytes** of resume data |

Two of those change the design. The destination is inside the blob, so a resume
has nowhere for a second opinion about where the file goes to enter. And the
dropped connection — the case this feature is *for* — really does produce resume
data, so this is not a feature that only works when you press Stop yourself.

### The trap this feature is made of

`resumeData` is opaque, server-dependent, and stops working the moment the
process that made it goes away. A Resume button that usually fails is worse than
no Resume button at all — ADR-0018, and ADR-0027 already said in as many words
that *"there is no honest way to promise a download survives ⌘Q"*.

## Decision

### Resume is offered only while the host is holding the blob, and the answer dies with the process

**When it is offered:** a download that stopped, has not finished, and for which
`DownloadHost` is holding resume data *right now*, in this run of the
application. Nothing else, ever.

That is honest because it is the literal truth of what would happen if the
button were pressed. It is not a policy anybody has to remember, because:

- **The blob lives in the shell**, in `DownloadHost.resumeData`, and is never
  written anywhere.
- **The core's `Download.resumable` is only ever set by the host saying so**, via
  `Action::DownloadResumability`. The core cannot work it out from the byte
  counts and does not try.
- **`StorableDownload` has no field for it.** That is the guarantee rather than a
  rule: a row read back from disk cannot claim to be resumable, because there is
  nothing in the shape it was stored in that could carry the claim. Adding one
  is not a line-change, it is a schema change, in a type whose doc comment says
  what it is for.

The `false` direction matters as much as the `true` one, and it is why
`DownloadResumability` carries a boolean rather than being a bare "it can". The
host says `false` when the engine handed over nothing, when a blob falls off the
end of its bound, and when a resume it was asked for could not be started. A row
that stopped being resumable goes back to offering Try Again in the same breath.

### Stopping *is* pausing, so there is no paused state

`WKDownload.cancel` hands back the blob. So Stop on a running download already
keeps everything a resume needs, and a stopped-and-resumable download would do
nothing a paused one would do differently. A fifth `DownloadState` would be a
distinction with no behaviour behind it, and every `switch` in two languages
would have grown an arm to say so.

The row already reads correctly: *"You stopped this one. The part that arrived is
still on disk."* — with **Resume** beside it.

### Resume and Try Again are one slot

They are the same intent, so offering both would make somebody choose between two
words for it. Which appears is the core's answer, and it turns back into Try
Again the moment carrying on stops being possible. The glyphs differ for the same
reason: `arrow.clockwise` says "again, from the start", and drawing a resume that
way would say the progress behind it is about to be thrown away.

The resumed transfer keeps the download's **id**, and the record is kept rather
than replaced — unlike a retry, which removes the row and starts a new one. The
partial file is on disk under that row's name; a fresh id would put a second row
over the same file with the first one's byte count frozen beside it.

### `window.print()` is the page's function, replaced, and the core decides

Safari's route is `_webView:printFrame:`, which is SPI. ADR-0067 confined SPI to
one file and said in as many words that it is not a precedent for a second, so
this is done with public API: a `WKUserScript` replaces `window.print` with one
that posts a message, and `Action::PageAskedToPrint` is where the request is
answered.

Two of those are decisions rather than mechanics:

**The page world, necessarily.** Every other script this browser injects runs in
a content world of its own precisely so its channel is out of the page's reach.
This one cannot: a named world shares the DOM and not the globals, so a
`window.print` replaced there is simply not the function the page calls. The
channel is therefore reachable as `window.webkit.messageHandlers.zer0Print` — and
what it grants is exactly what `window.print()` grants, to exactly the same
caller, through exactly the same gate. There is nothing here to escalate to.

**The main frame only.** A cross-origin subframe — an advert — calling `print()`
would otherwise put a panel over the page somebody is reading on behalf of a
document they never chose. The cost is that a subframe's `window.print()` still
does nothing, which is the same nothing it does today.

### A page may print the page you are looking at, and nothing else

`page_dialogs::is_on_screen` is the one answer to "can somebody see this tab",
and printing asks it because printing is the same kind of caller as `alert()`: a
page asking for a modal on a window. Sharing it rather than writing a second one
is the point — two answers to that question would drift, and only one of them
would ever be tested.

**Refused rather than held**, and that is where this parts company with ADR-0089.
An `alert()` blocks the script until it is answered, so holding it costs nothing
and gives the person their panel when they look at the tab. `window.print()`
returns straight away here — nothing is waiting on it — so a panel that surfaced
minutes later when the tab happened to come forward would be a modal with no
cause anybody could name.

### ⌘P does not come through the core, and printing has one door

`EngineHost.printPage` is the single place a print panel is ever opened. ⌘P calls
it directly, because a person pressing a key on the window in front of them has
already answered the question the gate exists to ask; the page-initiated road
goes through the core and arrives at the same function. The gate sits on the road
with the untrusted caller on it.

`printPage` now refuses twice instead of repairing once. No window: there is no
sheet without one, and `NSWindow()` was a repair that guessed. A sheet already
attached: AppKit queues a second one rather than refusing it, and a print panel
that surfaces later under whatever is on screen by then is the same unexplained
modal the paragraph above rejects. It reports which happened rather than saying
so, the arrangement `toggleDevTools` already has.

### The context menu's own save rows already worked

Measured through the shell before anything was changed: choosing the browser's
own **Download Linked File** row lands the file on disk. ADR-0091 replaced the
engine's two dead rows with ones routed through `EngineCommand::StartDownload`,
and that road was already connected. What was missing was a test that says so —
the previous coverage proved the *rules* about names and collisions and proved
nothing about whether the row reaches them.

## Consequences

**What this costs:**

- **A Resume button that disappears overnight.** Stop a download, quit, come
  back: the row says "Stopped when zer0 quit" and offers Try Again. Somebody will
  read that as the feature being broken, and it is the feature being honest.
- **A bound with an edge.** Sixty-four stopped downloads keep their blobs; the
  sixty-fifth pushes the oldest out and that row silently goes back to Try Again.
  Nothing tells the person why the word changed.
- **`window.webkit.messageHandlers.zer0Print` is visible to every page.** It is
  the first channel this browser exposes in the page world. It grants nothing the
  page did not already have, and it is still a name in a namespace pages can
  enumerate, which is a thing a fingerprint can read.
- **A subframe still cannot print.** So can a page that shadows `window.print`
  before our script runs — although at `.atDocumentStart` there is nothing of the
  page's yet to do it.
- **`window.print()` does not block the script.** In every other browser the call
  does not return until the panel is dismissed. Ours returns immediately, and a
  page that prints and then immediately changes what is on screen will print the
  wrong thing. There is no public API that would let us do otherwise.
- **A background tab's print request vanishes with no trace.** Correct, and
  indistinguishable from the browser being broken, from the page's side.
- **⌘P on a window with a sheet up does nothing at all.** Silent, and the person
  pressed a key.
- **Two more `Action` variants and two more `EngineCommand` variants**, each of
  which has to be listed in four exhaustive switches in the shell.

**What we get:**

- A 4 GB file on a bad connection can be finished. Measured end to end: dropped
  at 300 kB, resumed, the whole file on disk and every byte correct.
- Pause and resume, with no paused state and no new vocabulary.
- No screen anywhere claims a download can be carried on from unless something is
  holding what that would take, at that moment.
- `window.print()` works, on public API, with the same rule about who may
  interrupt whom that every other page-raised modal already obeys.
- No print panel can open on a window nobody can see.

## How this regresses

**"Resume did nothing."** The most likely route is somebody deciding the boolean
on `DownloadResumability` is redundant — the host only ever calls it when it has
data, so why say `false`? Then a blob evicted by the bound, or spent by a resume
that failed to start, leaves a button that spends nothing.
`a_download_whose_resume_data_went_away_stops_offering_to_carry_on` is written
from the `false` side for that reason, and
`aServerThatCannotBeResumedFromNeverOffersIt` holds the same line through a real
server that sends no validator.

**"My download restarted from zero and I lost an hour."** Somebody notices that
`ResumeDownload` and `RetryDownload` end at the same URL and unifies them.
`resuming_keeps_the_entry_and_the_bytes_that_already_arrived` asserts the byte
count and the row count as well as the command, because a version that removed
the row and started again would produce a plausible-looking `StartDownload` and
pass any test that only checked "something happened".

**"There are two rows for one file."** The resumed download was adopted under a
fresh `UUID`, which is what `adopt` does for every other download and what a
reader would assume. The same test holds `downloads.all().len() == 1`, and
`stoppingAndCarryingOnLandsTheWholeFileOnce` holds it through WebKit, where the
second row would also be writing to the same path.

**"Resume came back after a restart and failed."** Somebody adds `resumable` to
`StorableDownload` because the two types otherwise look like duplicates of each
other. `a_download_does_not_come_back_offering_to_carry_on` sets the flag *past*
the reducer on purpose — the reducer refuses to set it on a running download, and
the two states that can carry it are never written down at all — so the question
reaches the store rather than being answered by the reducer's own guard.

**"A page I could not see printed itself over what I was reading."** The
`is_on_screen` call reads like a needless check on a request the page just made.
`a_page_you_are_not_looking_at_does_not_print_itself` is written from a second
tab, and `a_pane_of_a_split_may_print_itself` is its counterpart, so nobody
closes the hole by narrowing the rule to the active tab and quietly breaking
split view.

**"⌘P opened a panel I cannot dismiss."** `NSWindow()` comes back, as the
obvious way to satisfy a non-optional parameter.
`printingAPageInNoWindowOpensNothing` is the fence, and it asserts the refusal
rather than the panel — a test that waited for a panel on an invisible window
would hang, which is exactly how this defect stayed invisible.

**"`window.print()` went back to doing nothing."** The user script is one line to
delete and reads as an oddity next to the four scripts that run in worlds of
their own. `windowPrintIsReplacedAndReachesTheBrowser` asks a view built by the
model what `String(window.print)` says, so it goes red on a view that never got
the script as well as on a script that stopped being attached — and it is the
half a test of the channel alone would leave uncovered.

**"The browser crashed and no test failed."** The channel is attached per view,
and a pop-up is handed the opener's configuration **object for object** — the
same `WKUserContentController` (ADR-0075). `add(_:name:)` under a name that
already exists raises `NSInvalidArgumentException`, which Swift cannot catch, so
it takes the process down rather than reddening anything. This happened: the
first version of this change attached per view, and the crash read to three
agents as concurrency between them. `attachingTwiceOverOneControllerIsNotACrash`
is the fence, and it is written as two views over one configuration rather than
as a pop-up. Read its two halves separately: the duplicate **script** goes red,
and the duplicate **handler** cannot — an ObjC exception is not something Swift
can catch, so removing that guard kills the runner instead of failing the test.
Reaching the assertions at all is the coverage there is.

The same sentence applies to anything else added in `HostedWebView.init`: an
adopted view runs that initialiser too, over state it did not create.

**What the print lock does not ask.** `printingAPageInNoWindowOpensNothing`
proves the refusal — `printPage` answers `false` — and it cannot prove that no
panel appeared, because a test able to see an app-modal panel is a test that
never returns. Sabotaged into returning `true` it goes red, so the assertion is
load-bearing; sabotaged back into `runModal(for: NSWindow())` it would **hang**
rather than fail, which is the same outage wearing a different colour. Anyone
touching this should know that the difference between "red" and "never finished"
is the difference between the two versions of this bug.

**And the one nothing catches:** the injected script is ordinary JavaScript in
the page's own world. A page that replaces `window.print` after us gets its own
function back, and there is no test that could tell that apart from a page that
simply never calls it.

## When to revisit

- **When WebKit publishes a print delegate.** Take it the same day: the script
  goes, the channel goes, and `window.print()` starts blocking the page the way
  it does everywhere else. This ADR's whole shape is a workaround for its
  absence.
- **When somebody asks why Resume vanished overnight.** The answer is not to
  persist the blob — it will not work tomorrow — it is to say so on the row, and
  that is a copy decision this ADR did not take.
- **If the sixty-four-blob bound is ever reached in the wild.** That would mean
  somebody stopped sixty-four downloads in one session without finishing any, and
  the answer is probably to bound by age rather than by count.
- **When a second channel wants the page world.** This is the first, and the
  argument for it is that the capability it exposes is one the page already had.
  A second one that cannot say that sentence is a different decision and needs
  its own record.
- **If `window.print()` returning immediately turns out to matter.** Print
  stylesheets that rely on `beforeprint`/`afterprint` and on the call blocking
  are the case to look for. Nothing public would fix it, so the honest answer
  might be to say what is not supported rather than to approximate it.
