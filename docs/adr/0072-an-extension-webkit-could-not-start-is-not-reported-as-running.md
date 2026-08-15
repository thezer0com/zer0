# ADR-0072: An extension WebKit could not start is not reported as running

- **Status:** Accepted
- **Date:** 2026-08-05
- **Lock:** `apple/Tests/Zer0ShellTests/ExtensionTests.swift::ExtensionHostTests/onlyADeadBackgroundIsCalledBroken`, `apple/Tests/Zer0ShellTests/ExtensionTests.swift::ExtensionHostTests/noBackgroundIsNotABrokenBackground`, `apple/Tests/Zer0ShellTests/ExtensionTests.swift::ExtensionStatusTests/aBrokenBackgroundIsNotCalledRunning`, `apple/Tests/Zer0ShellTests/ExtensionTests.swift::ExtensionStatusTests/aWorkingExtensionStillReadsAsRunning`

## Context

1Password installs, its button appears on the row, pressing it opens a popover,
and the popover spins forever. Nothing anywhere says why. The Extensions screen
says **"Running with all 15 permissions it asked for."**

Two candidates were named for that spinner, and the second one is the answer.
Everything below was measured against the real package
(`aeblfdkhhhdcdjpifhhbdiojplfjncoa`, 1Password 8.12.30.21) loaded into a real
`WKWebExtensionController`, not reasoned about.

**The background service worker never starts.** `controller.load` succeeds and
returns no error. Some seconds later `WKWebExtensionContext.errors` gains one
entry — `WKWebExtensionContextErrorDomain 6`,
`backgroundContentFailedToLoad` — and that is the only place it is ever
mentioned. There is no delegate callback for it. `loadBackgroundContent`'s
completion handler was *never called at all* in the failing case, so it cannot
be the signal either.

**On which API.** Stubbing the namespaces `WKWebExtension` does not implement
and re-running turns the load green; removing the stubs one at a time puts it
red again on exactly one of them, `chrome.notifications`. Measured missing from
the extension's own JS context: `offscreen`, `privacy`, `management`, `idle`,
`downloads`, `notifications`, `cookies`. Only `notifications` is fatal here.

**Corrected in place, 2026-08-10.** This paragraph went on to say that the
candidate which got the blame first — a native-messaging call we never answer —
"is never reached", on the strength of a count that stayed at zero with both
delegate methods implemented purely to count. **The count was right and the
conclusion was wrong: nothing had been pressed.** Re-measured against the same
package with ADR-0100's compatibility file in place, so the worker comes up
clean (`context.errors` empty): the worker starting reaches for nothing at all,
and thirty seconds of idling produces zero attempts — but the *first press of
the button* produces two, and both are the port form rather than
`sendNativeMessage`:

```
connectUsingMessagePort -> com.1password.1password
connectUsingMessagePort -> com.1password.1password7
```

Refuse both and the extension opens `app/app.html#/page/migration` for itself,
which renders "Migration in progress" and nothing else. Someone acting on the
old sentence would have *decided differently* — they would have concluded there
is nothing on the other side of a native messaging implementation to talk to,
when in fact the extension asks the moment anybody uses it. What that does not
change is the paragraph below, which is the reason this ADR does not implement
it.

**And native messaging would not have helped.** WebKit does expose it —
`WKWebExtensionMessagePort`, `WKWebExtensionPermissionNativeMessaging`, and two
`WKWebExtensionControllerDelegate` methods we implement neither of — so the
protocol is buildable. It is the wrong end of the problem. Speaking Chrome's
native messaging framing directly to 1Password's own host binary, from a
process that is not an allowlisted browser, gets this back:

```json
{"type":"BrowserVerificationFailed","content":"UnknownBrowser"}
{"browser_state":{"type":"Untrusted","content":{"id":"com.apple.swift-frontend"}}}
```

That base64 is `com.apple.swift-frontend` — it identified the calling process
and refused it by identity. That much is measured here.

**And it refuses zer0 by name too, 2026-08-10.** The obvious objection to the
paragraph above is that it was spoken by a bare test binary, and that a request
carrying zer0's own identity might be attributed differently. Measured: an app
bundle whose `CFBundleIdentifier` is `run.avelino.zer0`, ad-hoc signed, spawning
`1Password-BrowserSupport` with Chrome's framing and
`chrome-extension://aeblfdkhhhdcdjpifhhbdiojplfjncoa/` in argv, gets

```json
{"type":"NotificationModern","content":{"content":{"type":"BrowserVerificationFailed","content":"UnknownBrowser"},"browser_state":{"type":"Unknown"}}}
```

and then the pipe closes. It refuses before answering anything.

**Corrected in place, 2026-08-11: the measurement above was right and what was
read into it was wrong.** *"Ad-hoc signed"* is the whole of that refusal, and
the paragraph below — which goes on to conclude from a hardcoded browser list
that "a correctly signed zer0 with no enrolment lands in `UnsupportedBrowser` /
`DoesNotMatchTeam`", and that native messaging "does not unlock this
extension" — is not true. Signed with a real Developer-ID-class identity, zer0
is accepted by 1Password's own enrolment: `browsers.other-trusted-apps` carries
`com.thezer0.zer0` with a `SecRequirement` pinned to its Team ID. Somebody
acting on the old sentence would have *decided differently* — three of us
concluded this link was a commercial dead end and stopped — so the sentence is
corrected here and the decision that follows from the correction is ADR-0105,
which implements native messaging. Nothing in *this* ADR's decision moves: an
extension WebKit could not start is still not reported as running.

**Reaching it "through WebKit" cannot change that, and it is worth saying why
rather than measuring it again.** WebKit never spawns a native host.
`connectUsingMessagePort` is a callback *into this process* carrying a port and
the identifier the extension asked for; whatever execs the helper is zer0's own
child either way. The identity the helper inspects is the same in both cases,
which is why the bare-binary reading above generalises rather than being an
artefact of the instrument.

*Read* out of the binary rather than measured, and consistent with it: a
hardcoded list of 27 browser bundle IDs paired with 7 vendor Team IDs, the
`SecRequirement` format strings built from them, and imports of
`SecCodeCopyGuestWithAttributes` and `SecCodeCheckValidity`. Alongside them,
`NmAuthorizePartnerBrowser` and a `StoredBrowserProperties` carrying an
`enrollmentUuid` — an enrolment route for browsers not on the list, which is a
commercial conversation with AgileBits rather than an engineering task. A
correctly signed zer0 with no enrolment lands in `UnsupportedBrowser` /
`DoesNotMatchTeam`. **Implementing native messaging is a
feature worth having for other things and it does not unlock this extension**,
which is why it is not in this ADR at all.

So: the extension is unfixable from here, on two independent counts. What is
ours is that the browser said it was running.

## Decision

**`ExtensionHost.backgroundContentFailed(_:)` is the one door**, and the screens
read WebKit's verdict before the core's.

Three parts, and each is doing a different job.

### The fact is read from WebKit, every time, in the shell

`context.errors` is asked as the row draws, matched on WebKit's *named* case
rather than on the sentence it prints — the sentence is display text and may be
reworded in a point release, the case is API. Nothing is cached, for the reason
nothing about an action is cached (ADR-0020): the list is WebKit's and it
changes without us.

It lives in the shell and not the core because it is exactly the tie-breaker
`AGENTS.md` states. Which `chrome.*` namespaces exist is a property of the
engine; `webkit2gtk` will have a different set, a different error and a
different way of reporting it. What *"not running"* means is the core's and is
unchanged.

### The correction only ever moves the answer downward

`ExtensionStatus.of(standing:backgroundFailed:)` takes the core's answer and one
platform fact. `backgroundFailed` is checked first and can only turn a `running`
into a not-running; it never invents a grant, never contradicts
`grantedNothing`, and never claims an extension is fine.

This is a function at file scope rather than a method on the view, and that is
not tidiness. As a `private func` reading `@Environment` the only way to find
out what a row said was to render one and photograph it — and this state arrives
*seconds after* the row is first drawn, which is the state a screenshot is least
likely to catch.

### The row is asked again when WebKit changes its mind

`WKWebExtensionContext.errorsDidUpdateNotification` bumps
`extensionActionRevision`. Without it the correct sentence exists and nobody
ever sees it: every screen is drawn once, before WebKit has found out, and never
asked again.

### The press goes where the explanation is

An extension whose background content never started has nothing behind its
button. Asking WebKit for the popup anyway is how the reported defect happens.
So the press opens the Extensions screen, which now carries the sentence, and
the tooltip says it *before* the press rather than after. The corner of the
button carries a warning mark in place of the badge — a count from a process
that never ran is not a count.

## Consequences

**What hurts:**

- **We refuse a popup we have not proved is broken.** What is proved is that the
  worker died. An extension whose popup is entirely self-contained would still
  work and no longer opens. That is a real cost, taken because a popover that
  spins forever and says nothing is the worse of the two, and because this
  browser already refuses to *pin* a not-running extension for the same stated
  reason — "its button would do nothing". Being inconsistent about it was the
  bug.
- **The sentence names WebKit, which is not a thing a person can act on.** It is
  what we can prove. "This extension uses an API WebKit does not implement" is
  the likely diagnosis and is not something the browser can establish for any
  particular extension, so it is not said.
- **A pinned broken extension keeps its place on the row.** Which extensions are
  pinned is the core's answer and the core cannot see this, so the button stays
  where ⇧⌘1..⇧⌘9 count it. Quietly dropping it would move every chord after it.
- **One more thing read on every draw.** `context.errors` is a copied array and
  it is asked for once per row per pass.
- **It is right about the shape and cannot name the cause.** WebKit reports one
  error for every way a worker can fail to come up. A syntax error, a missing
  file and an unimplemented API are one sentence here.

**What we get:**

- The browser stops vouching for something it has no evidence for.
- The gesture that produced a silent forever-spinner produces an explanation.
- One place that knows what "not running" means on this platform, read by both
  screens that need it.

## How this regresses

**"It says everything is fine and the extension does nothing."** Somebody moves
the `backgroundFailed` check below the `switch` — it reads more naturally there,
as a special case after the ordinary ones — and `running` wins again.
`aBrokenBackgroundIsNotCalledRunning` is the lock and it is the one worth
breaking on purpose.

**"Every extension I have suddenly says it is broken."** The error match is
loosened to *any* entry in `context.errors`, because the specific case looks
like an unnecessary detail. `WKWebExtensionContextErrorNoBackgroundContent` is
the entry most extensions in the browser will carry, and
`noBackgroundIsNotABrokenBackground` is what goes red.

**"The one broken extension is fine and a working one is marked."**
`onlyADeadBackgroundIsCalledBroken` loads both in one host and reads both at the
same instant. The half that matters is the second `#expect`: the first one alone
stays green against `backgroundContentFailed` hardcoded to `true`.

**"It only ever says this after I reopen the window."** The notification
observer is removed as dead code — nothing in the shell posts it, and it is not
obvious that WebKit does. Nothing goes red. This is declared debt, not a lock:
the observer's effect is a redraw, and no test here watches for one.

**And the one no test catches:** somebody reads this ADR, sees that WebKit
supports native messaging, and implements it expecting 1Password to come back.
The measurement above is the answer, and it is in this file rather than in an
assertion because nothing in CI may depend on 1Password being installed.

## When to revisit

- **When `WKWebExtension` implements `chrome.notifications`.** That is the one
  that kills this particular extension today, and it is a WebKit release note
  away. The detection here stays right; what changes is how often anyone sees
  it.
- **If refusing the popup turns out to cost a real extension.** The exit
  condition is a report of an extension whose popup worked and now does not.
  The replacement is to open the popup and put the warning beside it, which is
  more UI than this was worth before there was a case for it.
- **If native messaging is built** — for password managers generally, or for
  developer tooling, both of which are real reasons. It is `connectUsingMessagePort`
  and `sendMessage:toApplicationWithIdentifier:`, the manifest lookup in
  `NativeMessagingHosts`, a `4`-byte little-endian length prefix and a
  subprocess. It would not change a line of this ADR. Two things to know before
  starting: no installer has ever placed a host manifest for zer0, so the
  directories to read are a decision of their own and Chrome's is the wrong
  answer — running a program another browser registered is not consent for this
  one (ADR-0028); and `nativeMessaging` means "start programs on this Mac",
  which is close to the top of what a person can be asked to grant.
- **Not for this extension, though — and this line is now wrong; see the
  correction in Context and ADR-0105.** Measured 2026-08-10: 1Password has an
  account-only route that needs no host at all, chosen by its own code exactly
  when the desktop app is absent — the welcome page's sign-in button resolves to
  `https://start.1password.com/signin/?auth-only=1`, and its `b5.js` content
  script already reaches that page in this browser
  (`document.body.dataset.b5xBuildNumber` is set). What stops it here is ours
  and is nothing to do with native messaging: an extension cannot open one of
  its own pages in this browser at all. That gap is enumerated in ADR-0086.
- When Linux is attempted. `webkit2gtk` reports extension errors differently and
  may not report this one at all; the sentence and the rule that it only moves
  downward cross unchanged, the reading of `context.errors` does not.
