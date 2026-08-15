# ADR-0001: WebKit is the engine, not Chromium

- **Status:** Accepted, and its refusal of SPI narrowed by ADR-0067
- **Date:** 2026-01-03
- **Lock:** none — debt

## Context

Every "alternative" browser you can name today is Chromium wearing a different
coat. When Google changes the extension platform, everyone finds out alongside
their users: Vivaldi said so in plain words when Manifest V3 landed — how they
would deal with the restriction "depends on how Google implements it".

The argument that used to end this conversation was extensions. It expired in
March 2025: `WKWebExtension` has been public API since macOS 15.4, loads
Manifest V2 and V3, and covers `declarativeNetRequest`, `webRequest`,
`scripting`, `tabs`, `cookies`, `storage` and `nativeMessaging`.

Power draw and battery are not a footnote either. On the Mac, WebKit is the
engine Apple tunes for Apple hardware, and it is the only engine a small project
can adopt without inheriting Google's product decisions or taking on a fork
nobody can maintain.

## Decision

`zer0` renders with WebKit. There is no Chromium path — not in parallel, not as
a fallback. The engine host is the only layer that knows which engine runs
(`apple/Sources/Zer0Shell/EngineHost.swift`), and it speaks `WKWebView`.

## Consequences

The cost is API coverage. Chromium exposes surface WebKit does not, and that
shows up in concrete places:

- **Not every extension will work.** `WKWebExtension` implements a large slice
  of the API, not all of it. Blockers and utilities should run; anything leaning
  on `chrome.debugger` or the devtools APIs will not.
- **Experimental feature flags are out of reach.** WebKit has per-feature
  toggles, but only through SPI (`_WKFeature`, `WKPreferences._features`,
  `_setEnabled:forFeature:`), all underscored. There is no public equivalent.
  We decided not to use SPI, so a feature behind a flag simply does not exist
  for us. **ADR-0067 narrowed this sentence**: it still holds for feature flags,
  and it is no longer the rule for SPI in general. One exception exists — the
  Web Inspector, which has no public way to open — and it is confined to one
  file and reached by runtime lookup rather than linked.
- **Trivial things have no public API.** Muting a page's audio is one:
  `EngineHost.swift` injects JavaScript
  (`document.querySelectorAll('video,audio')...`) and reapplies it after every
  navigation, because there is no other way. On Chromium this would be a
  property.
- **Web compatibility is Safari's.** A bug that only shows up on a site tested
  against Blink reaches us as a user complaint, not as a failing test. We have
  no way to see it coming.
- **Android has no path.** There is no maintained WebKit port for Android; the
  system only offers a Chromium WebView. The realistic targets are macOS, iOS,
  iPadOS, Linux and Windows.

In exchange: engine security patches arrive through the macOS update rather than
through our release (see ADR-0004, and what ADR-0005 does to that), and we do
not feed the Blink monopoly.

## How this regresses

The symptom is an `import` that should not exist: anything under
`apple/Sources/Zer0Shell/` pulling in a second engine, or a new `EngineCommand`
in `crates/zer0-core/src/protocol.rs` that only makes sense on Chromium
(`chrome.debugger`, CDP, DevTools Protocol). A second, subtler symptom: reaching
for underscored SPI to unlock a feature — the build passes and Apple's next
point update breaks the app with no warning.

No test screams for the engine itself. There is no possible test for "we picked
an engine": what would be testable is the absence of SPI, and that is a source
lint, not a behavior test.

**Corrected 2026-08-10:** this paragraph used to end *"A `grep` for `_WK` and
`_features` under `apple/Sources/` inside `scripts/check.sh` would cover half
the risk, and it does not exist."* It exists now, as
`SpiContainmentTests/noShellSourceOutsideTheOneFileSpellsAnSpi`, written when
ADR-0067 took the one exception. It is stricter than the sentence asked for —
string literals are read, so a selector reached through the Objective-C runtime
is caught, and `WebInspector.swift` is the only file allowed to match. The other
half of the risk, the choice of engine, is still uncovered and still debt.

## When to revisit

Two triggers, both named:

1. `WKWebExtension` falling far enough behind that the main blockers stop
   loading, or Apple closing or freezing the public extension API.
2. A platform target landing on the roadmap where no maintained WebKit exists
   (Android is the known case) and that target becoming mandatory rather than
   desirable.

Outside those two, never.
