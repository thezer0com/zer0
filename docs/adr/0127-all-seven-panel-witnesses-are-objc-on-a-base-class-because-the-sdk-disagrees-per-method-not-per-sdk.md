# ADR-0127: All seven panel witnesses are `@objc` on a base class, because the SDK disagrees per method rather than per SDK

- **Status:** Accepted
- **Date:** 2026-08-17
- **Supersedes:** ADR-0126's decision to leave `SitePermissionDelegate`'s four panel witnesses in an extension
- **Lock:** `apple/Tests/Zer0ShellTests/PageDialogTests.swift::PageDialogTests/alertBlocksAndThenReleases`, `apple/Tests/Zer0ShellTests/PageDialogTests.swift::PageDialogTests/confirmIsAnsweredByAPersonRatherThanByTheBrowser`, `apple/Tests/Zer0ShellTests/PageDialogTests.swift::PageDialogTests/promptCarriesTheTypedTextHome`, `apple/Tests/Zer0ShellTests/PageDialogTests.swift::PageDialogTests/aFileControlOpensAPickerAndCancellingAnswers`, `apple/Tests/Zer0ShellTests/PageDialogTests.swift::PageDialogTests/aPanelIsOfferedOnlyToItsOwnWindow`

## Context

ADR-0126 moved the popup's three panel witnesses onto a base class and left
`SitePermissionDelegate`'s four in an extension, on the reading that the two
measured SDK spellings differ **per SDK**: 26.3 without `WK_SWIFT_UI_ACTOR`,
26.6 with it. Under that reading an extension witness is safe as long as some
test drives it through a real page, because a whole SDK either matches the
aliases or does not, and a whole-file mismatch is a whole-suite failure nobody
can miss.

The first green build on the mismatched SDK measured otherwise. Xcode 26.3 /
macOS SDK 26.2, Swift 6.2.4, `-warnings-as-errors`, no diagnostic anywhere in
the build — and then, in one run of `PageDialogTests`:

| what the page called | witness | result |
| --- | --- | --- |
| `prompt('q?', 'ada')` | extension | called, green |
| `<input type="file">` | extension | called, green (four cases) |
| `alert('x')` | extension | **never called**, red |
| `confirm('q?')` | extension | **never called**, red (three cases) |

Four of the five red cases were `alert` and `confirm`; every green case was
`prompt` or the file control. The camera's own witness, which sits *in* the
conforming declaration with the same `@MainActor` spelling, compiled without a
"nearly matches" warning in the same build.

So the disagreement is **per method**, not per SDK: one header carries
`WK_SWIFT_UI_ACTOR` on some of these blocks and not others, and which ones
moves between releases. That refutes the premise the extension placement was
left standing on. It also means the safety net ADR-0126 relied on is thinner
than it read: the mismatch does not fail a file, it fails whichever handful of
methods that SDK happens to spell the other way, silently, with `alert()`
drawing nothing and `confirm()` answering `false` for nobody — the exact state
ADR-0089 was written to end.

The mechanism was re-measured locally rather than assumed, on the SDK that
*does* match, by making one base-class method unreachable without changing
anything else (the Swift argument label altered so no selector WebKit sends
resolves):

- the build stayed green with no diagnostic of any kind;
- `alertBlocksAndThenReleases` and `aPanelIsOfferedOnlyToItsOwnWindow` went
  red on an empty `pageDialogs`, after 90 s each — the same two failures, at
  the same two assertions, that CI reported for `alert`;
- restored, both green in 6.4 s.

## Decision

**All seven panel witnesses live on a base class, `@objc`, and are reached by
selector.** The popup's three stay on `ExtensionPopupDialogBase`. The page's
four move to `PageDialogDelegateBase`, a plain `@MainActor NSObject` that
`SitePermissionDelegate` inherits; the conformance to `WKUIDelegate` stays on
`SitePermissionDelegate` and never sees them.

`tab`, `dialogs` and `emit` move to the base with the methods that read them.
That is the state split ADR-0126 declined to pay, paid: `PopupHost`'s two
witnesses and the camera's read the same three properties through the
inheritance, unchanged.

The open panel carries an explicit selector,
`@objc(webView:runOpenPanelWithParameters:initiatedByFrame:completionHandler:)`.
It is the one of the seven whose Objective-C name Swift cannot infer —
WebKit's Swift label is `runOpenPanelWith` and its selector says
`runOpenPanelWithParameters:` — and an inferred selector nothing ever sends is
the same dead witness by another route.

`reported(_:)` becomes the free function `reportedOrigin(_:)`, for the reason
`raisePageDialog` is one: two classes now read a `WKSecurityOrigin`, and an
origin read two ways is two answers to "is this the same site".

## Consequences

- No signature in this shell is ever compared against a WebKit header's
  spelling of these blocks. A future SDK that moves `WK_SWIFT_UI_ACTOR` onto
  or off any of the seven changes nothing.
- The completion aliases keep saying what the browser means rather than what
  any SDK says — they are now the only spelling in the tree, with nothing left
  that has to agree with them.
- `SitePermissionDelegate` is a subclass rather than a root class. The base
  holds the three properties the panels need and nothing else; what decides
  anything is still in the core.
- One placement rule instead of two. ADR-0126's asymmetry — three witnesses
  proof against spelling, four not — was a per-SDK reading of a per-method
  fact, and asymmetries justified by a refuted premise are how the next person
  puts a witness back in an extension.

## How this regresses

The regression is the silent one, and it has now happened once: a witness that
compiles everywhere, is called nowhere, and is invisible until a test drives a
real page.

- **Dropping the `@objc`** from a base-class method is loud on an SDK that
  matches — "non-'@objc' method … does not satisfy optional requirement",
  measured on this tree, which also establishes that the witness matcher does
  read inherited members. On an SDK that does not match it is silent again,
  and the five locks are what see it.
- **Moving any of the seven back into a conforming declaration or its
  extension** fails on the mismatched SDK either loudly (the "nearly matches"
  warning, which `-warnings-as-errors` fails) or silently (the extension case,
  which is this ADR). Both land on the locks: each drives a real page over a
  real origin and reads what `alert()`, `confirm()`, `prompt()` and a file
  control actually evaluated to.
- **An inferred selector on the open panel** is caught by
  `aFileControlOpensAPickerAndCancellingAnswers`, which asks the page what its
  control received rather than whether a method exists.

## When to revisit

- `WKUIDelegate` ceasing to be an `@objc` protocol removes the mechanism
  entirely; selector dispatch is the whole of it and was verified, not
  assumed.
- A WebKit release that pins these blocks' isolation across SDKs — the same
  spelling on every method, guaranteed rather than observed — would make plain
  witness matching safe again. It would also make this layout harmless, so the
  bar for undoing it is a measured guarantee, not a run that happened to be
  green.
- A second host whose delegate needs state the base cannot hold re-opens the
  split, not the placement.
