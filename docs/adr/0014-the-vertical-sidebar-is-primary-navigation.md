# ADR-0014: The vertical sidebar is the primary navigation, and the system toggle goes

- **Status:** Accepted, and its claim to replace bookmarks superseded by ADR-0059
- **Date:** 2026-02-16
- **Lock:** `apple/Tests/Zer0ShellTests/ShortcutTests.swift::SidebarToggleTests/visibilityRoundTrips`, `apple/Tests/Zer0ShellTests/SourceRuleTests.swift::PageChromeTests/theSystemSidebarToggleStaysRemoved`, `apple/Tests/Zer0ShellTests/SidebarWidthTests.swift::SidebarWidthTests/theSidebarColumnDeclaresItsFloorToTheWindow`, `apple/Tests/Zer0ShellTests/SidebarWidthTests.swift::SidebarWidthTests/theSidebarIsDrawnNoNarrowerThanItsFloor`

## Context

A horizontal tab strip has a structural defect: width is finite and the number of
tabs is not. From the eighth tab on, each tab gets 90px, the title becomes "Goo…",
the favicon becomes the only clue, and the person starts hunting by color. The
horizontal tab strip does not scale, and everyone has known that for ten years.

Vertical scales: each tab takes a row, the title fits, the list scrolls. And the
sidebar is vertical because the *screen* is horizontal — there is width to spare and
height missing. Putting navigation where space is left over and content where it is
scarce is the right trade.

But giving up the horizontal strip means the sidebar stops being an auxiliary panel
and becomes **the** navigation. If it goes away, there is nowhere else to see the
tabs.

## Decision

`BrowserView` is a two-column `NavigationSplitView`. The `Sidebar` is the primary
navigation and organizes tabs into three groups, on Arc's model:

- **Favorites** — global, they follow the person across spaces.
- **Pinned** — they belong to the space.
- **Today** — they expire on their own (`archive_after_ms` in the core).

This replaces bookmarks. There is no favorites manager: whatever you want to keep
moves up a group in the same list where it already is.

Rows are built by hand instead of using `List`. The reason is in the comment: the
selected row has to read as *selected* at a glance, and the system list style does
not go far enough at sidebar size.

Besides the tabs, the sidebar carries:

- **The window's traffic lights.** With no title bar (ADR-0010) they need to live
  somewhere. `Color.clear.frame(height: WindowChrome.height)` at the top is the
  reserved space — and the height matches `WindowChrome` precisely so the page does
  not jump when the sidebar comes and goes.
- **The spaces bar**, at the bottom, near the thumb.

### The native toggle goes

```swift
// The built-in toggle floats loose over the page once there is no
// title bar to sit in. Ours lives in the strip instead.
.toolbar(removing: .sidebarToggle)
```

The system button expects a title bar to live in. Without one it floats loose over
the page content — on top of the Gmail logo, for example. Ours lives in
`WindowChrome`, which is the strip that shows up exactly when the sidebar is not
there.

### `.doubleColumn`, never `.all`

This is the subtlety that already cost one bug, which is why it is recorded in a
comment **and** in a test:

```swift
extension NavigationSplitViewVisibility {
    /// `.all` is for three-column layouts. Using it here does nothing, so
    /// showing the sidebar again would silently fail.
    static func showingSidebar(_ visible: Bool) -> Self {
        visible ? .doubleColumn : .detailOnly
    }
}
```

`.all` is a layout value for **three** columns. In a two-column split it does
nothing — no error, no warning, it is simply ignored. The symptom was: hiding the
sidebar worked, showing it again did not. The model's `Bool` flipped to `true`, the
button looked like it responded, and the sidebar did not come back.

The conversion lives in **one** place (`showingSidebar` / `showsSidebar`), as a
pair of pure functions — which is what makes a SwiftUI layout enum testable.

## Consequences

**What hurts:**

- **The sidebar eats width all the time.** 200–380pt, ideal 260. On a wide-content
  page (spreadsheet, web IDE, video) that is expensive, and it is charged on every
  page just as a toolbar would be — only in the other dimension. ADR-0010 refuses
  permanent horizontal chrome and this one accepts permanent vertical chrome. The
  justification is that the sidebar *does* something the person does not know
  (which tabs exist), and the address bar does not.
- **The width is remembered, and by nobody here.** Measured rather than assumed:
  AppKit autosaves the divider under `NSSplitView.autosaveName`, and SwiftUI
  sets that name for us — so a column dragged wider comes back wider on the next
  launch, with no persistence code in this repository. The catch is what the
  name is made of: SwiftUI builds it out of the *mangled type* of the scene's
  root view, so the real app's key reads
  `…ModifiedContent<…<Zer0Shell.BrowserView, …>…>-1-AppWindow-1,
  SidebarNavigationSplitView`. **Adding or removing any modifier in the browser
  scene changes the key and silently forgets the width.** Pinning a name of our
  own is a decision and belongs in its own ADR, not here.
- **With the sidebar closed there is no tab list.** None. Navigation becomes
  entirely ⌘1..⌘9, ⌃Tab and the command bar. Whoever closes the sidebar to gain
  space loses sight of what is open — and `WindowChrome` only shows the *current*
  tab's title.
- ~~**Nothing drags.**~~ Settled by ADR-0041: rows reorder by drag, between
  groups and between spaces. What remains of the cost is that the sidebar now
  measures its own layout to resolve a drop, and that a drag inside Favorites —
  the one list that spans spaces — can move a tab into another cookie jar.
- **A hand-built row costs manual accessibility.** `.onTapGesture` is invisible to
  the keyboard and to VoiceOver, so every row needs `.focusable()`,
  `.onKeyPress(.return)`, `.accessibilityElement(children: .contain)`, a label and
  traits — all explicit, all easy to forget on the next new row.
- **The close button only on hover.** It reduces visual noise and vanishes for
  anyone not using a mouse. There is `Close Tab` in the context menu and ⌘W, but the
  visible target does not exist until the pointer arrives.
- **Height coupling between two files.** `Sidebar` imports `WindowChrome.height`
  only to reserve equivalent space. Changing one height without the other makes the
  page jump on the transition.
- **Removing the native toggle, we inherit the responsibility.** If `WindowChrome`
  does not appear, or its button breaks, there is no mouse path left to bring the
  sidebar back. Only ⌃S / ⌘B.

**What we get:**

- A readable tab title with 30 tabs open.
- Favorites/Pinned/Today solve "keep this page" without inventing a bookmarks
  manager.
- A single home for the traffic lights and for dragging the window, coherent with
  having no title bar.

## How this regresses

The failure mode of this decision has already happened once, and it is the most
disconcerting there is: **the button responds and nothing changes.**

What the person would notice:

- **"I hid the sidebar and cannot get it back."** That is the `.all` bug. They
  click the `WindowChrome` button, press ⌃S, press it again — the strip is there,
  the button does its click effect, and the sidebar does not come back. There is no
  error, no stuck animation, nothing to photograph for a bug report. The person
  restarts the browser.
- **"The show-sidebar button disappeared."** Somebody removes `WindowChrome` or
  gets its condition wrong (ADR-0010). The `.toolbar(removing: .sidebarToggle)` is
  still there, so there is no system one either. All that is left is ⌃S / ⌘B — and
  mouse users have no path.
- **"That little button over the page is back."** Somebody drops the
  `.toolbar(removing:)`. On Gmail it lands on the logo. It looks like a detail; it
  is exactly the kind of thing that makes the screen stop looking cared for.
- **"The page jumps when the sidebar opens."** The heights of `Sidebar` and
  `WindowChrome` drifted apart. The content jumps a few pixels on every transition.
  Nobody reports it; the interface just starts feeling unstable.
- **"The titles are gone."** The column's width is declared by one modifier on
  one line — `.navigationSplitViewColumnWidth` — and deleting it is neither a
  compile error nor an obvious visual one: SwiftUI's own default for a sidebar
  column is **140pt**, which still looks like a sidebar and leaves about ten
  characters. Rendered side by side, "Hacker N…", "Bauhaus…" and "WKWebVi…" are
  three rows nobody can tell apart, which is this ADR's opening complaint about
  the horizontal strip reproduced in the other dimension —
  `design/sidebar/01-undeclared-140-*.png` against `03-ideal-260-*.png`.
  `theSidebarIsDrawnNoNarrowerThanItsFloor` is what notices, and it reads the
  width of the column that was drawn rather than the number that was asked for.
- **"The selected tab is not obvious anymore."** Somebody swaps the hand-built rows
  for a `List` "to simplify". It passes every test. The sidebar ends up with 30 rows
  of equal weight and the person loses track of where they are.
- **"It got hard to find the right tab."** The three groups become one in a
  refactor, and Favorites stops being global. Data behavior, navigation symptom.

**The lock** (`hiding and showing round-trips through the split view's
visibility`) pins exactly what broke:

```swift
#expect(NavigationSplitViewVisibility.showingSidebar(true) == .doubleColumn)
#expect(NavigationSplitViewVisibility.showingSidebar(false) == .detailOnly)
#expect(NavigationSplitViewVisibility.showingSidebar(true).showsSidebar)
#expect(!NavigationSplitViewVisibility.showingSidebar(false).showsSidebar)
```

Swapping `.doubleColumn` for `.all` goes red on the first line. And the round trip
(`showingSidebar` → `showsSidebar`) is what guarantees the binding does not lose
state on the way back.

Complemented by
`apple/Tests/Zer0ShellTests/ShortcutTests.swift::toggling twice returns to where it started`
and `::toggling the sidebar is a shell concern and stays one` — that last one pins
that sidebar visibility is *appearance*, lives in `BrowserModel.sidebarVisible`
and does not leak into the core.

**What has no lock:** that **some** mouse path exists to reopen the sidebar when
it is closed — which is the state where having no path is fatal.

*Factual correction: this also said the removal of the native toggle had no
lock, and that a deleted `.toolbar(removing: .sidebarToggle)` would compile and
pass everything. True when written. A source scan now fails the build if that
line goes missing, and it is named on the `Lock:` line.*

*Second correction, and it is the one this decision rests on. The width — the
whole reason a vertical list beats a strip — was three literals at a call site
with nothing reading them back, so a report that the floor "was not being
honoured" had no instrument to answer it. It has one now, and the answer is
measured rather than reasoned: the floor reaches AppKit as
`NSSplitViewItem.minimumThickness` and **is** honoured. Dragging the divider to
40pt clamps at the floor; so does a saved width below it on the next launch;
resizing the window from 1600pt down to 500pt and back leaves the column where
it was, as does hiding and showing the sidebar eight times. The numbers now
live in `Sidebar.Metrics` beside the rows they are a floor for.*

## When to revisit

- If sidebar width shows up as a real complaint. The likely answer is
  auto-hide/overlay, not going back to the horizontal strip.
- ~~If the lack of drag-and-drop becomes frequent friction.~~ Revisited, and
  answered by ADR-0041.
- When a Linux shell exists. `NavigationSplitViewVisibility` is a SwiftUI type; the
  `showingSidebar`/`showsSidebar` pair is the boundary that survives, the enum is
  not.
- If the number of groups grows past three. Then it becomes a list of lists and
  needs collapsing, and the current design does not hold up.
- If Apple ships a native toggle that behaves without a title bar. Then
  `.toolbar(removing:)` goes away and we hand the button back to the system.
