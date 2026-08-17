# ADR-0008: The User-Agent carries Safari's signature, and our token comes after

- **Status:** Accepted
- **Date:** 2026-01-29
- **Lock:** `apple/Tests/Zer0ShellTests/NavigationRoundTripTests.swift::UserAgentTests/ourTokenComesLast`

## Context

A `WKWebView` inside a third-party app produces a User-Agent that ends in
`(KHTML, like Gecko)` and **carries no browser token at all**. Big sites read
that as "unsupported browser". Google is the case cited in the code, and it is
not the only one.

Which means: WebKit's default is a UA that gets the browser treated by the web
as if it were not a browser.

## Decision

`config.applicationNameForUserAgent` gets Safari's signature followed by our
token, in that order (`apple/Sources/Zer0Shell/EngineHost.swift`):

```swift
static let safariUserAgentToken: String = { "\(safariSignature) \(browserToken)" }()
// "Version/18.3 Safari/605.1.15 zer0/0.1.0"
```

Three choices inside that:

- **The order is not a detail.** `zer0/` comes **after** `Safari/`, the way Edge
  appends `Edg/` and Vivaldi appends `Vivaldi/`. Putting our token first, or in
  place of Safari's token, breaks exactly the sniffing this exists to satisfy.
  We name ourselves *after* the signature, never in place of it.
- **The Safari version is read from the installed copy**
  (`Bundle(path: "/Applications/Safari.app")`), with `"18.3"` as a fallback, so
  it ages along with the system instead of freezing at whatever was current when
  the code was written. The `Safari/605.1.15` suffix is fixed, because that is
  what the sniffers look for.
- **A Space's profile beats the default.** If a Space sets
  `profile.user_agent`, it becomes `webView.customUserAgent` and replaces
  everything — the half of isolation the cookie jar does not cover (ADR-0007).

*Amended 2026-08-16: the composition itself moved to the core
(`crates/zer0-core/src/ua.rs`); the shell now reads the installed Safari's
version and applies the string it gets back — ADR-0119. Nothing about the
decision above changed, only where it is spelled.*

## Consequences

- **We lie by omission, and the lie is going to get expensive.** Sites decide
  what to serve by reading this token: they see "Safari" and send code written
  for Safari. That is exactly what we want **while** we render with the system
  WebKit. The day ADR-0005 delivers a WebKit of our own, newer or carrying a
  patch of ours, the UA will be claiming something that stopped being true — and
  the failure mode is a site serving a workaround for a Safari bug our build
  does not have, or withholding a feature our build supports.
- **On a machine with no Safari, the version freezes.** The `"18.3"` fallback is
  a literal in the code: it does not age, it rots. Nobody is told when that path
  is taken.
- **`zer0/x.y.z` makes us traceable, and the small user base makes it worse.** A
  rare token in the UA is a strong fingerprinting signal — the fewer people use
  `zer0`, the more identifiable the ones who do. It is the direct trade for the
  benefit of being recognized as a real browser, and it is bad for privacy.
- **It is a race that never ends.** Safari's signature is a moving target: Apple
  can change the format, and sniffers change what they look for. That is
  recurring maintenance, not configuration.

## How this regresses

The symptom takes two shapes, and both show up in the product before they show
up in the code:

1. **The token disappears.** Google and friends go back to serving the degraded
   "unsupported browser" page. Happens if someone strips
   `applicationNameForUserAgent` thinking it is surplus.
2. **The order flips.** Someone decides it looks better for the browser to
   announce itself first — `zer0/0.1.0 Version/18.3 Safari/605.1.15` — and
   sniffing breaks partially and erratically, site by site, because each one
   rolls its own heuristic.

`ourTokenComesLast` screams in the second case, and it screams measuring what
matters: it loads a real page, reads `navigator.userAgent` from inside WebKit
and asserts that the position of `zer0/` is greater than that of `Safari/`. It
is not an assertion about a constant in Swift, it is about the UA the page sees.

`userAgentCarriesABrowserToken` covers the first case, requiring `Safari/` in
the real UA. `signatureIsDerivedFromTheSystem` covers a third, slower symptom —
someone swapping the read of Safari's bundle for a fixed string — by asserting
that the signature follows the installed copy.

## When to revisit

One trigger, named: **when a WebKit of ours starts running in the bundle**
(ADR-0005 leaving "in progress"). At that point Safari's signature stops
describing what we are running, and the question becomes whether we keep
carrying it for compatibility — knowing it is a false claim — or whether the
`zer0` token starts carrying the engine's real version.

Beyond that, revisit when a site that matters breaks because of the UA. Not
before: touching this speculatively trades a known problem for an unknown one.
