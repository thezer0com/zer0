# ADR-0106: Extension contexts name Chrome because per-extension is not ours to build, and the browsing UA does not

- **Status:** Accepted, supersedes the per-extension clause of ADR-0081 and extends ADR-0073
- **Date:** 2026-08-11
- **Lock:** `apple/Tests/Zer0ShellTests/ExtensionTests.swift::ExtensionHostTests/theExtensionContextCarriesTheBrowsersUserAgent`, `apple/Tests/Zer0ShellTests/NavigationRoundTripTests.swift::UserAgentTests/theUserAgentNamesNoOtherBrowser`, `apple/Tests/Zer0ShellTests/ExtensionTests.swift::ExtensionHostTests/theExtensionContextNamesChromeButPagesDoNot`

## Context

ADR-0081 closed the last gap ADR-0008 left open: an extension's background
worker, popup and options pages had no product token at all, and Bitwarden's
worker died on the way up sniffing for one. The fix was to give those contexts
the **same** UA every other page carries, by name, from the one constant
ADR-0008 already defined. ADR-0081 §"When to revisit" #2 and ADR-0073
§"When to revisit" #2 both said the same thing about what would happen next:
*if an extension breaks because it is told Safari, handle it per-extension and
in the open, not by widening the string.* This is that conversation, had in
the open, and the conclusion it reached is the one both of those clauses
allowed for and neither of them wanted.

The cost of not-having arrived in two shapes, measured end to end on the
**untouched** store packages on macOS 26.6 / Xcode 26.6:

| Extension | What it asks its own UA for | What it does when the answer is "Safari" |
| --- | --- | --- |
| **1Password 8.12.30.21** (`aeblfdkhhhdcdjpifhhbdiojplfjncoa`) | `navigator.userAgent.indexOf("Chrome") !== -1` | Routes down the **Safari App Extension** path — a different mechanism than `connectNative`/`sendNativeMessage` — and never opens a port. The popup reports `desktopAppState: Disconnected / PortClosed`, `hasEverConnectedToDesktopApp: false`. |
| **Bitwarden 2026.7.0** | ` Chrome/`, ` Safari/`, ` Firefox/`, ` Edg/`, ` OPR/`, ` Vivaldi/`, ` Gecko/` | Throws in `this.device.toString` during worker init. MV3 makes a module-init throw fatal (ADR-0077), so the worker never starts. |

The 1Password line is the harder one. ADR-0105 built the native-messaging host
that extension needs, end to end, and the helper is enrolled. With this
browser telling the extension "I am Safari", the extension never asks for it,
and the host ADR-0105 ships is an answer to a question the extension does not
ask. Captured by
`apple/Tests/Zer0ShellTests/ZZOnePasswordSignInProbe.swift:370-562`.

**Per-extension is not a lever WebKit gives us.** Confirmed against
`WKWebExtensionContext.h` and `WKWebExtensionControllerConfiguration.h` on the
installed SDK:

- `WKWebExtensionContext` exposes no `customUserAgent` and no UA hook. Its
  `webViewConfiguration` accessor is read-only and answers the controller's
  single shared configuration.
- `WKWebExtensionController.Configuration.webViewConfiguration.applicationNameForUserAgent`
  is the one knob, and it reaches **popup + options + background worker + any
  page the extension opens** as one population. There is no handle that names
  only the worker, only one extension, or anything smaller than "every
  extension context in this browser".
- Overriding `navigator.userAgent` from a script injected into the extension's
  own page is the door ADR-0077 already closed: rewriting somebody else's
  signed code is refused, and rewriting ours to lie to theirs is the same
  decision through a friendlier-looking door.

So "do this per-extension, in the open" — the exit both prior ADRs named —
turns out to describe the *intent* and not the *mechanism*. The mechanism is
one knob with one reach, and the question is what that knob should say.

## Decision

**Extension contexts announce a Chrome-compatible token. Pages the person
visits do not.**

`ExtensionHost.configuration(answeredBy:)` in
`apple/Sources/Zer0Shell/ExtensionHost.swift:328` sets
`webViewConfiguration.applicationNameForUserAgent` to a new constant
`HostedWebView.chromeCompatibleUserAgentToken`, defined alongside
`safariUserAgentToken` in `EngineHost.swift`:

```swift
// "Version/<safari> Chrome/<chrome> Safari/605.1.15 zer0/<ours>"
static let chromeCompatibleUserAgentToken: String = {
    "\(safariSignature) \(chromeMarketplaceToken) \(browserToken)"
}()
```

Everything the browsing UA already does is preserved, in the same order:
`Version/` and `Safari/605.1.15` still name the engine we actually run, and
`zer0/` still comes last, the way Edge appends `Edg/` and Vivaldi appends
`Vivaldi/`. What is added is one token in the middle, `Chrome/<version>`,
which is the string the Chrome Web Store's entire population of extensions
tests against. The shape is Brave's, not Edge's: Chrome in the middle rather
than appended, because the extensions that sniff do so with
`indexOf("Chrome")` and never look past it.

**The browsing UA does not change.** `EngineHost` keeps setting
`safariUserAgentToken` on every configuration it builds a view from, and
ADR-0073's refusal stands unchanged for every host a person navigates to. The
Chrome name is added in the one place the cost of not adding it has already
been paid twice, and refused everywhere else.

### Why the Chrome version is a literal, and which one

`safariSignature` reads Safari's version off the installed copy because the
installed copy is on this machine and ages with it. There is no installed
Chrome to read, so `chromeMarketplaceToken` is a literal: a recent stable
`<major>.0.0.0`, chosen because that is the shape the sniffers test against
and because nothing an extension does should depend on the patch level of a
browser this is not. It will rot, the way the `"18.3"` Safari fallback rots,
and the replacement is the same one: edit the literal. The date is in the
file, and the rot is visible in `chromeMarketplaceToken`'s value the moment it
matters.

### What the rewritten lock looks like

`theExtensionContextCarriesTheBrowsersUserAgent` is reshaped rather than
retired. Its first half still loads a fixture that demands the browser's token
in the worker's UA — only the spelling of "the browser's token" changes, from
`safariUserAgentToken` to `chromeCompatibleUserAgentToken`. Its instrument
half, the fixture that demands a token the UA must never carry, moves from
`Chrome/` to a token this browser still refuses everywhere (`Firefox/`).
**Both halves are still the test**: the first proves the worker reads the new
token, the second proves the worker would have been heard if it did not.

## Consequences

**What hurts:**

- **We now claim to be Chrome in one more place, and it is the place closest
  in.** Extension contexts run with whatever permissions ADR-0028 granted
  them, and they are third-party code we did not write. Telling them "Chrome"
  is a more specific lie than telling a website "Safari": the extension will
  reach for `chrome.*` surfaces and for a `connectNative` it expects to behave
  the way Chrome's does, and where WebKit's `WKWebExtension` is a subset of
  Chrome's surface the extension has been given a reason to guess wrong. Where
  that surfaces, ADR-0072's screen will name WebKit for a mismatch this
  browser caused — the same correction ADR-0077 and ADR-0081 already made, on
  the permissions side and the UA side respectively.
- **`zer0/` is still in every extension's reach**, as it has been since
  ADR-0081. Nothing here widens that; nothing here narrows it either.
- **A second UA constant exists, and ADR-0073 said there would be one.** The
  one-UA-everywhere claim ADR-0081 made was true for a day. The split is the
  decision: one UA for browsing, one for extensions, and the difference
  between them is one token defended by one test. The mitigation is that the
  split is structural rather than per-host — there is no host list to maintain
  and no navigation lifetime to get wrong, the two doors ADR-0073 refused to
  build.
- **The Chrome token rots.** Extensions that sniff for a minimum Chrome major
  version will stop being satisfied by `chromeMarketplaceToken` eventually,
  silently, the same way the `"18.3"` Safari fallback stops being satisfying.
  The failure mode is "1Password stopped connecting again" rather than
  anything an assertion catches.
- **The popup and options pages are reached by the same property, and nothing
  here asserts it.** They were the "one no test catches" in ADR-0081 and they
  still are; the worker is the context with an observable failure mode and
  they are not.

**What we get:**

- 1Password's worker reads `Chrome/`, takes the `connectNative` branch, and
  the native host ADR-0105 built stops being orphaned by a string.
- Bitwarden's worker starts on the package as shipped, the way ADR-0081
  already made it start, and keeps starting — because the token
  ADR-0081 added (`Safari/`) is still in `chromeCompatibleUserAgentToken`,
  and the token ADR-0081 refused to add (`Chrome/`) is added here, in the one
  place it was refused for, and named as an exception to the rule rather than
  smuggled past it.
- One Chrome-shaped class of extension loads: every store extension that
  gates on `indexOf("Chrome")` rather than on a specific surface. That is most
  of the marketplace.
- The rule "extension contexts say what the browser says" survives, in a more
  honest shape: the browser tells different populations different things
  because the populations ask different questions, and both answers are on
  this page rather than in someone's memory.

## How this regresses

**"Extensions think we are Chrome now, and so does everything else."** The
tempting path: the new token works, somebody moves it onto
`config.applicationNameForUserAgent` in `EngineHost` rather than only on the
controller's configuration, on the reasoning that one UA everywhere is simpler
and ADR-0073's refusal was about a host list rather than about the string.
`theUserAgentNamesNoOtherBrowser` goes red, by name, on the Chrome token it
has refused since ADR-0073 — and it goes red reading a real page's
`navigator.userAgent`, which is the only instrument that sees this. That lock
is the second half of the split, and the split is the whole decision.

**"1Password stopped connecting again, and the Extensions screen blames
WebKit."** The new constant is removed in a cleanup because it reads as a
second UA policy — exactly the shape ADR-0081 said there would not be, and
exactly the shape a tidying reviewer would want to collapse. The rewritten
`theExtensionContextCarriesTheBrowsersUserAgent` goes red, and goes red
printing the token the worker failed to find. The mitigation is that the
constant lives in `EngineHost.swift` next to `safariUserAgentToken`, so
collapsing the two means deleting a line a comment above this ADR points at.

**"The split silently collapsed and nobody noticed."** The new
`theExtensionContextNamesChromeButPagesDoNot` is the lock for this: it reads
the UA out of a real background worker **and** out of a real page the person
visits, and asserts that the first carries `Chrome/` and the second does not.
Break it on purpose — point the controller back at `safariUserAgentToken` —
and watch it go red. Without that test, the only signal of the collapse is
"Bitwarden died" weeks later, which is exactly the delay ADR-0081 §"How this
regresses" warned about for the first half.

**"An extension was told Chrome and reached for a surface we do not have."**
Not caught by any test here. The cost named in *Consequences* arriving, in the
shape of an extension calling a `chrome.*` method `WKWebExtension` does not
implement and reporting the absence as a bug in us. The honest answer is in
ADR-0072's screen and ADR-0100's namespace work, not in this string.

**"The Chrome version token got too old to fool anybody."** `chromeMarketplaceToken` is a literal that ages. No assertion catches it; the
symptom is an extension that used to load starts refusing, one by one, the
way Safari's frozen `"18.3"` would if it were ever the path taken. The date
this token was last touched is the comment above it, and that is the only
instrument.

## When to revisit

- **When WebKit ships a per-context User-Agent property on
  `WKWebExtensionContext`**, or any handle narrower than the controller's one
  shared configuration. The reason this ADR widens the string — that
  per-extension is not ours to build — goes away, and the honest move is to
  narrow it back: tell each extension only what it asks for, and stop telling
  the ones that do not ask that we are Chrome.
- **When an extension misbehaves because it was told Chrome and got WebKit.**
  The cost named above, arriving. Handle it per-extension and in the open —
  the same exit ADR-0073 and ADR-0081 named — and not by removing the token
  wholesale, which is what would re-orphan ADR-0105.
- **If an extension page starts being sniffed by a host a person navigates
  to.** Today nobody differentiates an extension's popup from a tab, because
  nobody had a reason to; a popup advertising `Chrome/` is the first reason
  somebody could. If that becomes a real sniffing surface, the trade changes.
- **When the Chrome major version in `chromeMarketplaceToken` is old enough
  that extensions start keying past it.** The replacement is to bump the
  literal, the way Safari's fallback would be bumped, and to say so in the
  commit rather than in this file: editing the literal is not a decision, the
  way editing the `"18.3"` fallback was not a decision.
- **When Linux is attempted.** `webkit2gtk` has no `WKWebExtensionController`,
  and whether it has a per-context UA hook is its own question; the rule —
  extension contexts may name what the browsing UA does not, because the
  alternative is the extension not loading — is the part that crosses, and
  the spelling is not.
