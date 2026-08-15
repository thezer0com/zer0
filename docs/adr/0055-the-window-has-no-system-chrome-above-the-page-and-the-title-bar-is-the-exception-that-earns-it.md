# ADR-0055: The window has no system chrome above the page, and the title bar is the exception that earns it

- **Status:** Accepted
- **Date:** 2026-06-12
- **Lock:** `apple/Tests/Zer0ShellTests/WindowTopTests.swift::WindowTopTests/theSystemReservesNoMoreAboveThePageThanTheStripDoes`, `apple/Tests/Zer0ShellTests/WindowTopTests.swift::WindowTopTests/theBrowserWindowCarriesNoToolbar`, `apple/Tests/Zer0ShellTests/WindowTopTests.swift::WindowTopTests/theTrafficLightsAndTheWindowsOwnControlsSurvive`, `apple/Tests/Zer0ShellTests/WindowTopTests.swift::WindowTopTests/aToolbarPutBackAfterwardsIsTakenAwayAgain`, `apple/Tests/Zer0ShellTests/WindowTopTests.swift::WindowTopTests/theWindowThatHostsPagesClaimsItsOwnTop`

## Context

ADR-0010 decides that nothing sits over the page permanently and that the page
starts at the top of the window. ADR-0047 decides that the 38pt strip which
appears when the sidebar is away takes the page's own colour, so that a dark
site does not get a white band welded above it.

Both were true in the source and false on the screen. On macOS 26 the window
showed a white band, `(251, 251, 252)`, across the top 38pt of every page.

The band was not ours, and proving that took two controls run against the real
running window:

- `WindowChrome`'s surface was forced to **pure magenta, unconditionally**. The
  top 38pt still measured `(251, 251, 252)`.
- A plain `NSView` with a **green layer** was inserted at the identical rect.
  Also invisible.

So the paint was fine and something was on top of it. What was on top was a
`NSTitlebarContainerView` — a *sibling* of the SwiftUI hosting view, composited
after it, holding a live `NSToolbarView` → `NSGlassContainerView`. Our strip sat
entirely inside it and was covered. It read as 38pt rather than the container's
full height only because the `WKWebView`'s remote layer composites above that
chrome from 38pt down.

`NavigationSplitView` puts an `NSToolbar` on the window whether or not anything
is in it. That is where the second half of the defect came from as well:
`.toolbar(removing: .sidebarToggle)` **does not remove it on this SDK**, so an
`NSToolbarItemViewer` / `NSToolbarPlatterView` / `NSGlassEffectView` sat at
x = 100…148, directly over our own toggle at x = 98 — two buttons stacked, the
system's on top, which is the glass circle in the bug report.

Everything upstream was correct and verified in the running app: the page
reported `#1A1A2E`, the core produced `Tab.tint`, the view took the tinted
branch.

**What did not work, and is not worth trying again**:
`.scrollEdgeEffectHidden(true, for: .top)` on the detail column and on the split
view; `.toolbar(.hidden, for: .windowToolbar)`; `.toolbarBackground(.hidden,
for: .windowToolbar)`; hiding the `NSScrollPocket` at runtime.
`NSScrollView.topEdgeEffect` does not exist in the installed SDK.
`.windowStyle(.hiddenTitleBar)` was already applied the whole time and is not
enough on its own: it makes the title bar transparent, and the toolbar is not
the title bar.

## Decision

**The browser window carries no `NSToolbar`, and the title bar stays.**

`NSWindow.claimTheTopForThePage()` (`apple/Sources/Zer0Shell/WindowTop.swift`)
takes the toolbar off the window, and asserts the three flags `.hiddenTitleBar`
is supposed to give us — `.fullSizeContentView`, `titlebarAppearsTransparent`,
`titleVisibility == .hidden` — rather than trusting that a declarative modifier
delivered them.

### The title bar is not the thing to remove

It would be simpler to drop `.titled` and be done. That takes the traffic
lights, and they are the system's: people expect them where they are, in the
shape the system draws, answering to the system's own hover and full-screen
behaviour. It also takes dragging, full screen, macOS tiling and the resize
affordances, all of which hang off the same style mask.

Transparent and unlabelled, the title bar paints nothing —
`NSTitlebarBackgroundView` is hidden by the flag — and reserves about 28pt,
which is *inside* the 38pt `WindowChrome` already draws. It costs nothing and
carries four things we would otherwise have to reimplement badly. **The toolbar
is what was drawing; the title bar is what was working.**

### It is claimed at the door that already knows

`browserWindow(_:)` is the one modifier that says "this window hosts pages"
(ADR-0053), applied exactly once. `BrowserWindowTag`, the view it plants, is
therefore where the top is claimed. There is no second place to forget, and a
window that is not the browser — Settings, About — keeps standard macOS chrome,
which is what it should have.

### The claim has to be kept, not made once

SwiftUI installs the split view's toolbar *after* the hosting view is in the
window, and puts it back as the sidebar comes and goes — which is exactly the
moment `WindowChrome` appears. So `WindowTopKeeper` re-claims on
`NSWindow.didUpdateNotification`, which fires after every one of those. The work
behind that hook is a nil check.

### What is measured, and why it is that

The lock measures `frame.height − contentLayoutRect.height`: the height the
system is holding above the content. With the toolbar it is **66**; with the
bare title bar it is **32**; `WindowChrome.height` is **38**. The invariant is
that the system never reserves more than our own strip, which is ADR-0010's real
claim stated in a number for the first time.

It is not measured in pixels, and that is a finding rather than a shortcut. See
below.

## Consequences

- The page starts at the top of the window, which is what ADR-0010 always said
  and what was not true.
- The tint reaches the screen, which is what ADR-0047 always said and what was
  not true.
- The duplicate sidebar toggle is gone, because the toolbar it lived on is gone.
  `.toolbar(removing: .sidebarToggle)` stays on `BrowserView` as a statement of
  intent — and because `PageChromeTests/theSystemSidebarToggleStaysRemoved`
  requires it — but it is no longer what is doing the work, and it never was.
- The window is configured from AppKit rather than declared in SwiftUI. That is
  a cost: it is a second place window state comes from, and it is imperative.
  The alternative is a declarative modifier that does not do what it says on
  this SDK, which is worse than a line of AppKit that does.
- **`didUpdateNotification` fires often.** The handler is a nil check on a
  property, so the cost is real but negligible. If it ever is not, the fix is a
  narrower hook, not a single call at launch — a single call is the version that
  was already tried and lost to SwiftUI reinstalling the toolbar.
- **No pixel lock is possible in this process, and every instrument says the
  defect is absent.** `cacheDisplay` over the frame view reports the strip's own
  colour whether the toolbar is there or not; so does `CALayer.render(in:)`.
  Both were run against a strip forced to pure magenta and both reported
  magenta in the state where the screen showed white.
  `CGWindowListCreateImage` is unavailable in the macOS 26 SDK, and
  ScreenCaptureKit wants a permission and an unlocked screen. This is the
  "instruments lie" rule from `AGENTS.md` in its sharpest form so far: the two
  instruments this suite reaches for first are both blind to this exact defect,
  which is part of why it survived.

### The manual check, for when there is a screen

The automated lock measures geometry. The thing a person actually complains
about is a colour, and confirming that colour takes an unlocked screen:

1. `./scripts/build.sh`
2. Back up `~/Library/Application Support/<bundle id>/session.sqlite*`
   (the bundle id, per ADR-0109). A `HOME` override does not isolate the
   session on this machine —
   `NSSearchPathForDirectoriesInDomains` reads the user record, not the
   environment — and neither `open --env` nor `LSEnvironment` passes variables
   here, so a launched instance writes to the real session file.
3. Open a page that states a dark colour and hide the sidebar (⌃S).
4. `screencapture -l<windowid>` and read the pixels in the top 38pt. The bar is
   the page's own colour rather than `(251, 251, 252)`.
5. Force `WindowChrome`'s surface to an unmistakable colour, confirm *that*
   reaches the screen, then put the real colour back. That is what separates
   "it should work now" from "I saw it".

## How this regresses

- **The toolbar comes back and nobody notices**, because the symptom is a band
  that looks like every other browser's. `theSystemReservesNoMoreAboveThePage…`
  is the one that goes red, at 66 against 38.
- **Somebody removes `.titled` to "really" get rid of the chrome.** The band
  goes and so do the traffic lights, dragging, full screen and tiling.
  `theTrafficLightsAndTheWindowsOwnControlsSurvive` is that lock, and it is the
  only one in this file that stays green when the fix is broken — because it
  guards the opposite mistake.
- **The keeper is reduced to a single call at launch**, on the reasonable-
  looking grounds that claiming the top on every window update is wasteful. The
  band then returns the first time the sidebar is toggled.
  `aToolbarPutBackAfterwardsIsTakenAwayAgain` covers it.
- **The claim is moved off `browserWindow(_:)`** into `BrowserView` or the app
  entry point, at which point a second browser window can be born with the band
  on. `theWindowThatHostsPagesClaimsItsOwnTop` covers it.
- **The lock is rewritten to build a borderless window**, because that is what
  every other view test in the suite does and it is quicker. A borderless window
  has no title bar container, so there is nothing to cover the strip and nothing
  left to measure. The harness asserts its own precondition — that the unfixed
  window really does reserve more than 38pt — for exactly this reason.

## When to revisit

- **If SwiftUI gains a modifier that actually removes the window's toolbar.**
  Then the AppKit call is dead weight and the declaration should win. The test
  is behavioural, not spelling-based, so it will hold across the swap.
- **When there is a second host (Linux).** None of this exists there: the
  reason the title bar survives is that macOS puts the traffic lights in it.
  A host that draws its own decorations needs a different answer, and the same
  measurement — how much does the system hold above the content — is the one to
  ask it.
- **If the traffic lights ever need more than 38pt.** The lock says the system's
  reservation fits inside `WindowChrome.height`. If a future macOS makes the
  title bar taller than the strip, the honest fix is a taller strip, not a
  looser assertion.
- **If macOS stops compositing the title bar container over the content view.**
  Then the toolbar could stay and only its background would need silencing,
  which would be a smaller change than this one.
