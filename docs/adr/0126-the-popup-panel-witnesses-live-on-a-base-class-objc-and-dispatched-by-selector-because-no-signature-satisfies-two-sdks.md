# ADR-0126: The popup panel witnesses live on a base class, @objc and dispatched by selector, because no signature satisfies two SDKs

- **Status:** Accepted
- **Date:** 2026-08-17
- **Lock:** `apple/Tests/Zer0ShellTests/ExtensionTests.swift::ExtensionPopupDialogTests/anExtensionPopupIsAnsweredAndNamed`, `apple/Tests/Zer0ShellTests/PageDialogTests.swift::PageDialogTests/alertBlocksAndThenReleases`, `apple/Tests/Zer0ShellTests/PageDialogTests.swift::PageDialogTests/confirmIsAnsweredByAPersonRatherThanByTheBrowser`, `apple/Tests/Zer0ShellTests/PageDialogTests.swift::PageDialogTests/promptCarriesTheTypedTextHome`, `apple/Tests/Zer0ShellTests/PageDialogTests.swift::PageDialogTests/aFileControlOpensAPickerAndCancellingAnswers`

## Context

The WebKit SDK is not pinned the way the compiler is. Measured on this branch:
two CI rounds on the same Swift 6.2 imported `WKUIDelegate`'s panel
completions two ways — the 26.3 SDK as `@escaping @Sendable`, the 26.6 one as
`@escaping @MainActor @Sendable` (`WK_SWIFT_UI_ACTOR` had reached the blocks).
An earlier fix gated the completion `typealias`s on
`#if compiler(>=6.3)`, which assumed each compiler ships the SDK that agrees
with it. The runner proved otherwise — SDK and compiler vary independently in
the image — and the round the gate got wrong turned the three popup witnesses
into "nearly matches optional requirement" warnings, which `-warnings-as-errors`
fails.

No single signature can win: under witness matching, a completion whose
isolation differs from the requirement's — in either direction — is a
near-match, never a match. So the escapes were measured too, in probes
against a fake clang-imported protocol spelled both ways, compiled
`-swift-version 6 -warnings-as-errors` and then asked through the protocol:

- **in the conforming declaration** — the near-match warning, i.e. the CI
  break;
- **moved to an extension, plain** — compiles with no diagnostic at all, and
  silently loses `@objc`: `responds(to:)` is false and a call through the
  protocol raises nothing. WebKit dispatches `WKUIDelegate` by selector, so
  this is a green build over a dead witness — the trap the compiler's own
  fix-it ("move it to an extension to silence this warning") invites;
- **in that extension with a hand-written `@objc`** — a hard error:
  "Objective-C method … conflicts with optional requirement";
- **on a base class the conformance never sees, with `@objc`** — no
  diagnostic under either spelling, `responds(to:)` true, and the call
  through the protocol lands. The only placement that is both invisible to
  the witness matcher (it reads the conforming declaration and its
  extensions) and visible to the runtime (an inherited `@objc` method sits in
  the class's ObjC method table like any other).

## Decision

`ExtensionPopupDialogDelegate` declares the `WKUIDelegate` conformance and
holds nothing else; the three panel methods, and everything they need, live
on `ExtensionPopupDialogBase`, a plain `NSObject` subclass, each method
`@objc @MainActor`. Neither SDK spelling is ever compared against the
signature; dispatch is by selector and finds them.

The completion `typealias`s in `PageDialogHost.swift` are one spelling now —
`@MainActor @Sendable` — chosen to agree with `PageDialogHandler`, where
every handler already lives, rather than with any one SDK. It says what the
browser means: the completions run on the main actor, which is where WebKit
calls every `WKUIDelegate` method from.

`SitePermissionDelegate`'s four panel witnesses stay where they are, in an
extension, satisfying the requirement by exact match. They are not
spelling-proof the way the popup's three now are — under a mismatched SDK
they compile and are not `@objc` — but the page-dialog tests drive all four
through a real page and a real delegate, so a dead spelling is a red suite
on any machine that runs it, CI included (`check.sh` runs the Swift suite,
ADR-0030). Moving them to a base class would split the delegate's state
between two classes; that price is paid the day a second host forces it, not
before.

> **Superseded by ADR-0127.** That day was the next one. The first green
> build on the mismatched SDK measured the disagreement to be **per method
> rather than per SDK** — `prompt` and the open panel matched, `alert` and
> `confirm` did not, in one build with no diagnostic — so two of these four
> were dead and two were not. The reading this paragraph rests on is
> refuted; all four have moved to `PageDialogDelegateBase`, and the state
> split is paid. The rest of this ADR — the mechanism, the four probed
> placements, and the popup's three witnesses — stands.

## Consequences

- One source file builds green under both measured SDK spellings, under
  `-warnings-as-errors`, on any compiler that can build the tree.
- The `#if compiler(>=6.3)` gate is gone. It discriminated the wrong thing,
  and the lesson generalises: a gate may only key on what actually differs —
  nothing in Swift keys on an imported block's isolation, which is why the
  matching had to be escaped rather than satisfied.
- The popup delegate is two classes now. The empty subclass is the mechanism,
  not ceremony: its declaration is the one place the conformance exists, and
  the base is the one place the panels exist, and the gap between them is
  where both SDK spellings fit.

## How this regresses

The regression this layout exists to prevent is the silent one: a witness
that compiles everywhere and is called nowhere. Two doors were measured:

- Dropping the `@objc` from a base-class method is loud on an exact-match
  SDK — "non-'@objc' method … does not satisfy optional requirement" — but
  under a mismatched SDK it is the silent door again, and the lock is what
  sees it: `anExtensionPopupIsAnsweredAndNamed` drives a real `confirm()`
  through a real popup web view, and a dead selector means the dialog is
  never raised. Broken on purpose (the method renamed so it compiled but was
  unreachable): the test went red on an empty `pageDialogs`; restored, green.
- Reverting the aliases to a single SDK-chosen spelling, or moving the
  witnesses back into the conforming declaration, is caught by the CI build
  on the mismatched spelling and by the four page-dialog locks on any
  spelling: they ask the page what its `alert()`, `confirm()`, `prompt()` and
  file control actually evaluated to, which no signature spelling survives
  faking.

## When to revisit

- A third spelling of these blocks, or `WKUIDelegate` ceasing to be an
  `@objc` protocol, re-measures the premise — selector dispatch is the whole
  mechanism and was verified, not assumed.
- ~~The day a second host's SDK disagrees with the aliases in a way the page
  tests cannot see, `SitePermissionDelegate`'s four witnesses move to this
  same layout, and the state split that was declined here is the cost
  accepted then.~~ **Done, and the condition was wrong.** The page tests saw
  it perfectly well — that is how it was found — and the four moved anyway,
  because a mismatch that takes out two methods out of four and leaves no
  diagnostic is not a spelling this layout should keep surviving by luck
  (ADR-0127).
