# ADR-0103: "Cannot" and "will not" are different sentences, and the permissions that are really ours are answered rather than stated

- **Status:** Accepted
- **Date:** 2026-08-10
- **Lock:** `crates/zer0-core/src/extension_permissions_tests.rs::a_permission_this_browser_declines_reads_as_a_position_rather_than_a_gap`, `crates/zer0-core/src/extension_permissions_tests.rs::a_permission_nobody_has_built_yet_says_yet_and_promises_nothing_more`, `crates/zer0-core/src/extension_permissions_tests.rs::nothing_this_browser_declines_is_also_listed_as_something_it_provides`, `crates/zer0-core/src/extension_permissions_tests.rs::a_declined_permission_is_never_recorded_as_granted`, `crates/zer0-core/src/extension_permissions_tests.rs::the_permissions_zer0_answers_itself_keep_their_switch`, `crates/zer0-core/src/extension_api_tests.rs::an_option_this_browser_will_not_honour_is_refused_by_name`, `crates/zer0-core/src/extension_api_tests.rs::a_search_filtered_by_something_this_browser_cannot_answer_is_refused`, `crates/zer0-core/src/extension_api_tests.rs::an_erase_this_browser_cannot_narrow_removes_nothing`, `crates/zer0-core/src/extension_api_tests.rs::pausing_and_resuming_are_refused_rather_than_answered`, `crates/zer0-core/src/extension_api_tests.rs::a_download_this_browser_never_named_cannot_be_reached_by_number`, `crates/zer0-core/src/extension_api_tests.rs::opening_a_downloaded_file_needs_its_own_permission`, `crates/zer0-core/src/extension_api_tests.rs::only_http_and_https_are_downloaded`, `crates/zer0-core/src/extension_api_tests.rs::a_locked_screen_is_locked_however_recently_anything_was_typed`, `crates/zer0-core/src/extension_api_tests.rs::every_answer_says_either_ok_or_error_and_never_both`, `apple/Tests/Zer0ShellTests/ExtensionApiTests.swift::ExtensionApiTests/anExtensionReallyDownloads`, `apple/Tests/Zer0ShellTests/ExtensionApiTests.swift::ExtensionApiTests/searchAndCancelReachTheSameList`, `apple/Tests/Zer0ShellTests/ExtensionApiTests.swift::ExtensionApiTests/pauseAndResumeAreRefused`, `apple/Tests/Zer0ShellTests/ExtensionApiTests.swift::ExtensionApiTests/aWithheldPermissionIsARefusedCall`, `apple/Tests/Zer0ShellTests/ExtensionApiTests.swift::ExtensionApiTests/idleAnswersOutOfTheSystem`, `apple/Tests/Zer0ShellTests/ExtensionApiTests.swift::ExtensionApiTests/managementDescribesOnlyItself`, `apple/Tests/Zer0ShellTests/InternalPageTests.swift::InternalPageTests/aPageCannotReachTheExtensionApiScheme`, `apple/Tests/Zer0ShellTests/ExtensionCompatTests.swift::ExtensionCompatTests/nothingIsInventedBeyondWhatIsListed`

## Context

ADR-0084 gave every permission WebKit does not implement one sentence:

> ⃠ zer0 cannot provide this — WebKit does not implement it.

On 1Password's row that line appeared six times, and it was the same line under
three completely different facts.

- **`downloads`** — "See your downloads and start new ones". This browser has a
  download subsystem with a name-safety rule, a collision rule, a persisted
  list, pause and resume (ADR-0027, ADR-0101). Nothing about `chrome.downloads`
  was impossible; it was **unbuilt**. The sentence blamed WebKit for our own
  backlog.
- **`management`** — "See, switch off and remove your other extensions". One
  extension disabling another is a thing this browser should refuse *on an
  engine that shipped the API tomorrow*. Calling that a WebKit gap invites the
  next person to close it.
- **`privacy`** — "Change your privacy and security settings". Providing it
  faithfully would mean letting an extension turn a protection off; providing it
  the easy way would mean telling an extension it turned one off while it is
  still on, which is ADR-0077's silent failure aimed at the one subsystem where
  being wrong is expensive.

This is ADR-0084's own defect one level down. ADR-0084 separated *"you did not
grant this"* from *"we do not provide this"*; inside the second half, **"we have
not built it" and "we will not build it" were still wearing one sentence.** A
reader could not tell them apart, and neither could the code: one `Option<String>`
with one constant in it.

### What can actually be reached from a background worker, measured

An extension's background service worker is a hard place to reach. Measured on
macOS 26.6, in a real `WKWebExtensionController`, with a worker granted
`downloads` and `idle`:

| Route | Result |
| --- | --- |
| `WKUserScript` on the controller's `userContentController` | does not reach (ADR-0100) |
| `chrome.runtime.sendNativeMessage` | **`undefined`** |
| `chrome.runtime.connectNative` | **`undefined`** |
| `fetch("http://127.0.0.1:<port>/…")` | `TypeError: Load failed` |
| `fetch("zer0-extension-api://call/…")`, handled on `Configuration.webViewConfiguration` | **reaches the handler** |

The second row is what decides this. Native messaging exists only for a package
that declared `nativeMessaging` — granted it, the same worker answers `function`
and a delegate really is called — so building `chrome.downloads` on it would
serve only packages that asked for something else entirely. Adding
`nativeMessaging` to somebody's manifest at install would put a **Critical**
permission on the consent sheet that the extension never asked for, which is not
a trade this browser gets to make on a person's behalf.

The scheme handler works, and it carries who is asking: the request arrives with
`Origin: webkit-extension://<uuid>`, which is the context's own `baseURL` host.
`Origin` is a forbidden header name in `fetch`, so an extension cannot write it.

### And the question that makes it safe, also measured

ADR-0054 forbids registering a URL scheme handler at all, and the argument is
exact: a registered scheme is reachable from web content, and `WKURLSchemeTask`
carries no frame and no initiator, so the handler cannot tell a page framing it
from a person typing it.

So: is a handler registered on the **extension controller's** configuration
reachable from a page whose view carries that controller? Measured, three ways —
`fetch`, an `<iframe>` and an `<img>`:

| Handler registered on | Handler was asked |
| --- | --- |
| the page's own `WKWebViewConfiguration` (the control) | **yes** — the `<img>` reached it |
| `WKWebExtensionController.Configuration.webViewConfiguration` | **no** — nothing, from any of the three |

The control is not decoration. Without it the negative would be an instrument
that cannot see rather than a scheme that cannot be reached, which AGENTS.md
names as the way this project has already fooled itself.

## Decision

### One sentence became two, and the difference is structural

`PermissionRequest.cannot_provide: Option<String>` became
`not_provided: Option<NotProvided>`, and `NotProvided` is an enum:

| Kind | What the row says |
| --- | --- |
| `NotBuiltYet` | *zer0 does not provide this yet — WebKit does not implement it.* |
| `Declined` | *zer0 will not provide this — one extension does not get to switch off another.* |

**A reader tells them apart by the verb**: *does not … yet* against *will not*.
The debt names the engine, because the engine really is why there is nothing to
build on; the refusal names no engine at all, because the engine has nothing to
do with it. And the refusal carries its own clause per permission, where the debt
has one line for all of them — one fact, one sentence; five positions, five
sentences.

The Extensions screen and the consent sheet draw a different glyph for each and
`switch` over the enum with no `default:`, so a third kind of not-provided breaks
the build rather than borrowing a sentence. `ConsentDecision::allow` refuses
every kind, by asking the one function rather than naming the kinds, so a variant
added later is granted by nobody without anybody having to remember to come back.

**The declined list is consulted before either providing list**, and that is the
decision rather than an ordering detail: a position does not become a gap because
an engine caught up.

### Five refusals, stated

`contentSettings`, `debugger`, `management`, `privacy`, `proxy`. Each with a
clause saying what the position is. `management.getSelf` is not covered by any of
it and does not need to be — it needs no permission in Chrome either, and it
answers out of the extension's own manifest.

### Two permissions stopped being anybody's gap

`downloads`, `downloads.open` and `idle` are answered by zer0 itself, through
`crates/zer0-core/src/extension_api.rs` and a scheme handler in
`apple/Sources/Zer0Shell/ExtensionApiHost.swift`.

`ZER0_PROVIDES` is a **second** list beside `ENGINE_PROVIDES` rather than an
addition to it. That list is a measurement of what Apple's engine installs, and
folding ours into it would make it a measurement of nothing — costing the next
person the one thing it is for, which is re-running the harness on a new macOS
and seeing what changed.

### What `chrome.downloads` does, and what it refuses

`download`, `search`, `cancel`, `erase`, `open` and `show` reach the list the
core already owns and persists. Three rules shape all of them:

**An option this browser will not honour is refused by name.** `filename`,
`saveAs`, `method`, `headers`, `body` and `conflictAction: "overwrite"` each
produce an error naming the option. Accepting `{url, filename}` and quietly
dropping `filename` would put the file somewhere the extension did not ask for
and report success. `conflictAction: "uniquify"` **is** accepted, and only
because it is exactly what this browser does (`report-2.pdf`, ADR-0027).

**A filter `search` cannot answer is refused rather than ignored.** A dropped
filter answers a question nobody asked, and the caller cannot tell that from a
genuinely empty result. `erase` inherits the refusal verbatim and removes
nothing.

**`pause` and `resume` are refused, and they say why.** ADR-0101 made
resumability a fact the *shell* holds, for this run only, in a map bounded at
sixty-four blobs — and `StorableDownload` has no field that could carry it. There
is nothing behind an extension-facing pause that could keep the promise the word
makes, and a pause that stopped the transfer and hoped would lose the person's
bytes.

Two smaller decisions inside it:

- **The id is an integer this browser mints**, not the `DownloadId` string. Chrome
  documents an integer, extensions treat it as one, and the mapping is per-process
  and never written down — an extension's memory of an id does not outlive the
  extension. A number nobody was handed names nothing, so
  `cancel(1)` on a fresh browser refuses rather than cancelling whatever is in
  that slot.
- **`downloads.download` answers when the row exists, not when the request goes
  out.** `startDownload` returns before `WKDownload` has asked where to write, so
  answering there would hand over a number the extension cannot use —
  `download().then(id => cancel(id))`, the most ordinary thing an extension does
  with the answer, would refuse.

### `chrome.idle.queryState`, and nothing else on that namespace

`CGEventSource.secondsSinceLastEventType(.combinedSessionState, …)` plus
`CGSSessionScreenIsLocked`. The shell measures both and interprets neither: a
locked screen is `locked` whatever the input clock says, and the threshold is
clamped to Chrome's documented floor of fifteen seconds so that a caller asking
about one second is not told about a second nothing measured.

`idle.setDetectionInterval` stays **undefined**. It exists only to configure
`onStateChanged`, which never fires, so a setter for it would be a control with
nothing behind it.

### Notifications is not in this ADR, on purpose

`notifications` is the most common fatal permission in the corpus — thirteen of
fifty-nine packages — and it is the one this change deliberately did not take.

Delivering it means `UNUserNotificationCenter`: a usage description in the bundle,
an authorisation request at some moment somebody has to choose, and a decision
about what happens when the person says no. `SiteCapability` has exactly two
cases, `Camera` and `Microphone`, and neither the vocabulary nor the prompt
machinery for "an extension may put a notification on your screen" exists. **That
is a permission decision, not plumbing**, and half-building it is precisely how
an extension ends up notifying somebody with nobody having agreed.

So `notifications` keeps the `NotBuiltYet` sentence, `chrome.notifications` keeps
what ADR-0100 gave it — three event objects, `create` undefined — and the next
person writes their own ADR.

### The rest of `chrome.downloads` and `chrome.idle` stays undefined

`setShelfEnabled`, `setUiOptions`, `acceptDanger`, `getFileIcon`,
`getAutoLockDelay`. ADR-0100's rule holds: a member this browser does not answer
stays `undefined`, so `if (chrome.downloads.getFileIcon)` is an honest question
with an honest answer.

**`pause` and `resume` are the exception, and it is worth naming.** They are
defined and always refuse. ADR-0100's argument for leaving things undefined is
that it keeps an extension's own feature check honest — but that argument is
about members of a namespace *WebKit* owns. This namespace is zer0's, so
`if (chrome.downloads.pause)` would no longer be a question about the engine; it
would be a question about our table. A refusal carrying the browser's reason is
more use to whoever is reading the console than a silence carrying none.

### Measured, on real packages

1Password 8.12.30.21, loaded from disk through this browser's own consent path:

| | Before | After |
| --- | --- | --- |
| rows with a live switch | 11 of 17 | **13 of 17** |
| stated as a gap | `downloads`, `idle`, `notifications`, `offscreen`, `management`, `privacy` | `notifications`, `offscreen` |
| stated as a refusal | — | `management`, `privacy` |

`downloads` and `idle` are the two that moved, and they moved by being built:
its worker starts, `chrome.downloads.download` puts a file on the disk, and
`chrome.idle.queryState` answers about this machine. Simplify Gmail 3.4.8, the
other package on the machine, declares none of these and is unchanged — 4 of 4,
before and after.

End to end, through a real `WKWebExtensionController` with the real
compatibility file: an extension asks for a 64 kB file and the file lands, with
the right name, at the path the core chose; it then finds that download through
`downloads.search({id})` and stops it through `downloads.cancel(id)`, and the row
on the Downloads screen goes to Stopped.

## Consequences

**What hurts:**

- **`chrome.downloads.download` refuses `filename`, and real extensions use it.**
  This is the sharpest cost in the file. An extension that names its file gets an
  error instead of a download, where Chrome would have obliged. The alternative
  was to accept the option and ignore it, and ADR-0027 is the reason that is not
  available: the name is the one part of a download that is security rather than
  bookkeeping.
- **`downloads.onChanged` exists and never fires.** ADR-0100's tier-2 bargain,
  now over a namespace that otherwise works, which makes it more confusing rather
  than less: an extension can start a download, be told its id, and never hear
  that it finished. There is no road from this browser to a suspended service
  worker, and holding a `fetch` open to keep one awake would be this file
  deciding an extension may never be suspended.
- **A new scheme handler exists, and ADR-0054's source rule now has an
  exemption.** One file may name `setURLSchemeHandler`. The exemption is held up
  by a single measurement, and a measurement is a weaker fence than a rule that
  admits nothing.
- **The API id map grows for the life of the process** and is never trimmed. One
  string per download an extension has been told about, bounded in practice by
  the 200-row download memory but not bounded by anything in the code.
- **`ZER0_PROVIDES` is a second list that can drift from what is built.** A key
  added there and nowhere else is a switch that changes nothing — the exact
  defect ADR-0084 removed, reintroduced from a different direction.
- **The sheet got longer.** A refusal's sentence is a clause longer than the
  debt's, and a package asking for two of them adds two wrapped lines to a block
  that was already the tallest thing on the screen.
- **`downloads.open` is Critical and arrives ticked**, because everything this
  browser can explain arrives ticked (ADR-0028). Handing a downloaded file to
  whatever opens that kind of file is a way out of the browser, and the default
  is "yes".

**What we get:**

- Two facts that were one sentence are two sentences, and a third cannot arrive
  wearing either.
- A refusal reads as a position and cannot be closed by somebody helpfully
  implementing it, because closing it means deleting a line from a list called
  `DECLINED` with a reason beside it.
- Two of the six inert rows on 1Password's sheet are live switches over working
  APIs, and the debt that remains is honestly labelled as ours.
- A road into this browser from an extension's own JavaScript that needs no
  permission the extension did not ask for, cannot be reached by a web page, and
  refuses everything it cannot back.

## How this regresses

**"It says zer0 will not provide this, and it works."** WebKit ships
`chrome.management`, somebody re-measures `ENGINE_PROVIDES` and adds the key.
`nothing_this_browser_declines_is_also_listed_as_something_it_provides` goes red
and names it — which is the point: the person is made to open this file rather
than to watch a refusal quietly become a switch.

**"It says 'yet' about something we decided never to do."** The two sentences get
merged back into one, most plausibly by somebody who notices `NotProvided` has
two arms carrying the same-shaped payload and concludes the enum is a `String`
wearing a hat. `a_permission_this_browser_declines_reads_as_a_position_rather_than_a_gap`
asserts the words *and their absence*: no "yet", no "WebKit", in a refusal. Its
counterpart asserts the debt says "yet" and promises nothing else. Break either
by swapping one constant for the other and both go red.

**"My extension said the download started and nothing happened."** Somebody
notices that `answer` returns a `Vec<Action>` and that `EngineCommand` would be
"more direct", and routes a cancel straight at `WKDownload`. The bytes stop and
every screen goes on saying the download is arriving.
`searchAndCancelReachTheSameList` is written through the real engine and asserts
the row reaches `.cancelled`, not that a command was produced.

**"It downloaded the file under the wrong name."** The option checks in
`download` read as pedantry — six string comparisons to refuse things Chrome
supports — and deleting them makes six real extensions start working, wrongly.
`an_option_this_browser_will_not_honour_is_refused_by_name` asserts both halves:
that the error names the option, *and* that nothing started. A version that
refused and downloaded anyway would pass a test that only checked the message.

**"downloads.search returned everything."** A filter nobody implemented is
dropped instead of refused, which is one line and looks like tolerance.
`a_search_filtered_by_something_this_browser_cannot_answer_is_refused` covers it,
and `an_erase_this_browser_cannot_narrow_removes_nothing` covers the version of
the same mistake that deletes the person's download history.

**"Pause stopped my download and I lost 3 GB."** `pause` is implemented as
"cancel and remember", by somebody who reads ADR-0101 and sees that stopping
*is* pausing. It is — for a person, in front of a row that says so, with a Resume
button the core only draws while the blob is held. An extension has none of that.
`pausing_and_resuming_are_refused_rather_than_answered` asserts the refusal, that
nothing was dispatched, and that the transfer is untouched.

**"An extension cancelled the wrong download."** `by_api_id` is simplified to
index the download list directly, which is what the numbers look like they mean.
Then a number handed out in one session names a different row after a restart.
`a_download_this_browser_never_named_cannot_be_reached_by_number` is written from
the *never named* side, which is the half a test of the happy path leaves open.

**"A web page called chrome.downloads."** The scheme handler is moved onto the
page configuration — plausibly by somebody consolidating "the one place we build
configurations" (ADR-0074, which is otherwise right).
`aPageCannotReachTheExtensionApiScheme` is the fence, and **read its two halves
separately**: the control has to pass for the assertion to mean anything, so if
the control ever stops seeing a reach, the test is worthless while still green on
the half anybody reads.

**"The extension got a notification permission nobody granted."** Somebody adds
`notifications.create` to the compatibility file, or `notifications` to
`ZER0_PROVIDES`. `nothingIsInventedBeyondWhatIsListed` names `create` explicitly
and `the_permissions_zer0_answers_itself_keep_their_switch` walks
`ZER0_PROVIDES`, so a key added there without the work behind it shows up as a
switch over nothing.

**And the one no test catches:** the fourth tier in `compat.js` grows a method
that answers out of the file instead of out of the browser. Nothing in the build
refuses it — only the rule at the top of that file does, and rules are wishes.
The nearest thing to a guarantee is that `CALLS` is a table of names that all
resolve to `bridged(…)`, so an entry that does anything else is a different shape
on the page.

## When to revisit

- **When notifications is taken on.** It needs a `SiteCapability`, a prompt, a
  usage description and an answer for "the person said no". That is its own ADR
  and this one is the reason it has not been written.
- **On every macOS release**, with `ZZExtensionApiProbe`. Each of these WebKit
  implements is one `ZER0_PROVIDES` should give back — and the guard in
  `compat.js` already means the engine's own wins, so the reason to re-measure is
  to *delete* entries.
- **If `downloads.download`'s refusal of `filename` turns out to cost real
  extensions.** The answer is not to ignore the option; it is to carry an
  extension-chosen name through `safe_filename` and `destination_in`, which is a
  change to `EngineCommand::StartDownload` and to what ADR-0027 promises.
- **When a second thing wants the extension API channel.** This one is shaped for
  request/response and has no way to push. Anything needing an event to fire in a
  worker — `downloads.onChanged`, `idle.onStateChanged`, notifications — is a
  different mechanism and a different decision.
- **If `WKWebExtensionContext` gains a delegate for these APIs.** Apple
  implementing `chrome.downloads` would make all of this dead weight, and the
  guarded `define` means the file goes quiet on its own; what would not go quiet
  is `ZER0_PROVIDES`, the scheme handler and this record.
- **When a Linux host is attempted.** `ExtensionApiHost` is a statement about how
  one reaches a `WKWebExtension` worker. The core half — what is answered, what is
  refused, and the two sentences — is not, and should cross unchanged.
