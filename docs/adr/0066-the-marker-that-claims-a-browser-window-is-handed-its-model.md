# ADR-0066: The marker that claims a browser window is handed its model

- **Status:** Accepted
- **Date:** 2026-07-20
- **Lock:** `apple/Tests/Zer0ShellTests/WindowClaimTests.swift::BrowserWindowClaimTests/theMarkerClaimsItsWindowWhateverTheEnvironmentDoes`, `apple/Tests/Zer0ShellTests/WindowClaimTests.swift::BrowserWindowClaimTests/theModelReachesTheMarkerWithNoEnvironmentInTheChain`, `apple/Tests/Zer0ShellTests/WindowClaimTests.swift::BrowserWindowClaimTests/theModifierPlantsAMarkerThatClaimsTheTopOfTheWindow`

## Context

`browserWindow()` is the one modifier that says "this window hosts pages"
(ADR-0055, ADR-0065). It works by planting an `NSViewRepresentable` in a
`background`, because a marker has to be a real `NSView` to find out which
`NSWindow` it landed in, and it has to draw nothing and take no clicks.

The marker read its `BrowserModel` out of the environment. That is wrong in a
way SwiftUI does not warn about: **a `background` is a sibling of the view it
sits behind, not a descendant of it.** So in

```swift
BrowserView()
    .environment(model)
    .browserWindow()
```

the model is attached to `BrowserView`, and the marker — attached beside the
whole of `BrowserView().environment(model)` — is outside it. It looks up
`BrowserModel`, finds nothing, and `@Environment(_:)` for an `Observable` does
not return `nil` when it finds nothing. It traps:

```
SwiftUICore/Environment+Objects.swift:34: Fatal error:
No Observable object of type BrowserModel found.
```

on the first layout pass, before any window is on screen. The app died at
launch — "zer0 quit unexpectedly" — and the Swift suite stayed green through all
of it.

It stayed green for a reason worth naming, because it is the reusable part.
`ShortcutTests` and `WindowTopTests` both cover the marker: they construct
`BrowserWindowTag` directly and add it to a view. Neither of them applies
`browserWindow()`. **Everything the modifier does — the `background`, the
`NSViewRepresentable`, the environment lookup inside it — was covered by
nothing**, and the two suites that look like they cover it are exactly why
nobody noticed.

The first fix was to move `.environment(model)` below `.browserWindow()`, where
it does reach the marker, with a comment explaining the ordering. That works,
and it is a wish: it lives as long as the next person to touch that chain
remembers to read the comment before reordering two adjacent modifiers, which
is the single most innocent-looking edit in the file.

## Decision

**`browserWindow(_ model: BrowserModel)` takes the model as an argument.** The
marker stores it. Nothing inside a `background` reads the environment.

The ordering rule disappears rather than being documented, which is the point:
`.environment(model)` may now sit anywhere in the chain, or nowhere, and the
window is claimed either way. There is no lookup left that can fail, so there is
no failure mode left to remember — the compiler asks for the model at the one
call site that has one.

This is the same move as `StorableSession` having no field for an ephemeral
space's pages, applied to a view modifier: a guarantee is structural or it is
not a guarantee.

The locks go through the modifier, not around it. `WindowClaimTests` hosts
`browserWindow(_:)` in a real `NSHostingView` in a real `NSWindow` and asserts
the window ends up in the registry — and the first of them deliberately puts
`.environment(model)` in the position that used to be fatal, so the arrangement
that killed the app is the arrangement under test.

## Consequences

**A launch failure now has a test that can see it.** Not every launch failure —
this covers the browser window's own root chain — but the specific class that
took the app down, where a modifier is applied in a position that makes its own
dependency unreachable, is reachable from the suite now.

**`browserWindow(_:)` cannot be applied without a model.** Which is a small cost
paid at exactly one call site, and it is what removes the failure.

**The marker holds a strong reference to the model for as long as the view
exists.** `BrowserWindowTag` keeps it `weak`, as it always did; the
representable is a value that lives as long as the scene, and the scene owns the
model anyway.

**Restoring the environment lookup does not fail politely.** The lock traps and
takes the test process with it, the same way it took the app. That is honest —
it is the real failure mode — but it means the red is a signal 5 rather than a
neat assertion, and the message in the log is the SwiftUI fatal error.

## How this regresses

**Someone tidies the argument away.** `.browserWindow()` reads better than
`.browserWindow(model)`, the environment is right there, and the model is
already in it two modifiers down. That edit compiles the moment the
`@Environment` line goes back, and the app stops launching. The locks are what
stands between that edit and a release.

**Another modifier of ours starts using a `background` and reads the
environment from it.** This ADR is about one marker, but the trap is about
`background` — and `overlay` has the same shape. Anything planted beside a view
rather than inside it gets what it needs handed to it.

**A test is written that builds `BrowserWindowTag` by hand and looks like
coverage.** That is precisely what was there. A test that does not go through
`browserWindow(_:)` does not cover `browserWindow(_:)`, however much of the same
class it touches.

**Somebody concludes from a locked screen that the app does not open.** Not a
regression in the code, but it cost a session: with the screen locked
(`CGSSessionScreenIsLocked`), no app can activate, a newly created window is not
on the console's active space, and `screencapture` returns the lock screen —
which reads exactly like "the window was never created". `NSApp.windows` and
`CGWindowListCopyWindowInfo` both show the window in that state, and are the
instruments to use. Before concluding that something does not happen, establish
that the instrument can see it happening.

## When to revisit

If SwiftUI gains a way for a `background` to inherit the environment of the view
it decorates, the lookup stops being unreachable and the argument becomes
redundant. It would still be the safer spelling, so the bar for changing back is
not "it would work now" — it is a reason the argument itself costs something.

If the marker ever needs more than the model, this is the moment to ask whether
it should be a parameter object rather than a growing argument list; the answer
does not change the decision, only its shape.
