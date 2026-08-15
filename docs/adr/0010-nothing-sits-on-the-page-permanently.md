# ADR-0010: Nothing sits on top of the page all the time

- **Status:** Accepted; the height claim superseded in part by ADR-0055, and
  "`WindowChrome` is not a toolbar" superseded by ADR-0068
- **Date:** 2026-02-03
- **Lock:** `apple/Tests/Zer0ShellTests/SourceRuleTests.swift::PageChromeTests/browserViewGrowsNoToolbar`

## Context

Every mainstream browser reserves 60 to 100pt at the top of every window: title
bar, toolbar, address bar, bookmarks bar. That space is charged on every page, in
every session, forever.

What the address bar shows most of the time is the address of the page the person
just opened on purpose. They already know where they are. The cost is permanent;
the value is occasional.

The governing question: what in that strip pays for itself on every page? Honest
answer: almost nothing. You want the address when you are about to edit it. You
read the title in Command-Tab. Back and forward have a shortcut and a trackpad
gesture.

## Decision

`BrowserView` (`apple/Sources/Zer0Shell/BrowserView.swift`) is a
`NavigationSplitView` with a sidebar and the page, no resident address bar, and
as little as the platform allows between the top of the window and the content.

*Factual correction, and the way it was wrong is the whole story. This said
"**nothing** between the top of the window and the content. No `.toolbar` with
items, no title bar." Both halves were false. There **is** a title bar and there
has to be — the traffic lights live in it, and it reserves about 28pt while
painting nothing. And there **was** a `.toolbar`: not one of ours, but the empty
`NSToolbar` that `NavigationSplitView` installs regardless. "No `.toolbar` with
items" was true and beside the point — the empty one grew the container to 66pt
and covered the strip we were painting. `window.toolbar = nil` is what closes it,
and ADR-0055 records that.*

The address is invoked: ⌘L opens the command bar with the current URL already
inside, editable (ADR-0015). It leaves the screen when it is done.

Three things, and only three, have a license to take space above or over the page:

1. **`WindowChrome`** — a 38pt strip that only exists **when the sidebar is
   hidden**. ~~It is not a toolbar: it is where the window's traffic lights live and
   where you grab the window to drag it, since there is no title bar.~~ With the
   sidebar open the sidebar plays that role, and the strip is gone.

   **"It is not a toolbar" is superseded by ADR-0068**, and only that sentence:
   the 38pt, the condition and the rest of the clause stand. The strip now also
   carries the pinned extension buttons, in the reservation that was balancing
   the centred title and drawing nothing, so its height is unchanged. What
   replaces the sentence is a rule with an edge on it — **`WindowChrome` may
   hold a control if and only if the sidebar holds that same control** — which
   is what still keeps the favicon, the blocking badge and the padlock out.
2. **`loadingBar`** — 2pt of linear progress, only while the page loads. The
   comment in the code is explicit: "the only thing allowed to sit on top of a
   page, and only while loading".
3. **Ephemeral overlays** — find bar, command bar, install banner, session
   warning. All conditional, all with a way out.

`WindowChrome` shows the tab title in `.caption` `.tertiary`, centered,
`maxWidth: 340`. It is the least that is still readable, at a weight that does not
compete with the page.

## Consequences

**What hurts:**

- **You cannot read the URL without an action.** Checking whether a link led to
  the right domain — before typing a password, say — takes ⌘L. That is worse than
  Chrome, and it is worse exactly at the moment you are suspicious. It is the most
  expensive cost of this decision and it has no good mitigation today.
- **There is no visible HTTPS/padlock indicator.** No permanent surface says
  whether the connection is secure. A certificate error gets the whole screen
  (ADR-0016), but the absence of an error is not a claim of safety.
- **Copying the URL needed its own command.** `copyCurrentURL()` exists in
  `BrowserModel` only because there is no field to select and copy from. A
  permanent bar would have given that for free.
- **It breaks the expectation of anyone arriving from Chrome.** The first reaction
  to a browser with no address bar is "where is it". There is a learning cost that
  polish does not remove, only habit does.
- **Two top geometries to maintain.** With sidebar and without sidebar are
  different layouts. Every overlay anchored to the top has to add
  `WindowChrome.height` conditionally — and `findBar` and `sessionWarning` do
  exactly that. It is a class of alignment bug a fixed bar would not have.
- **The sidebar's height and `WindowChrome`'s have to match.** `Sidebar` reserves
  `Color.clear.frame(height: WindowChrome.height)` at the top just so the page does
  not jump when the sidebar appears. Invisible coupling between two files.

**What we get:**

- 38 to 90pt of usable height back on every page.
- The page is the interface. No frame competing with the content for attention.
- With no toolbar, the question "which button goes here" never comes up — which is
  how a browser toolbar becomes a junk drawer of features.

## How this regresses

It regresses without anyone filing a bug, because the symptom is the screen
getting *fuller*, and a fuller screen looks "more complete" until someone measures
it.

What the person would notice:

- **The page moved down.** They open the browser and the content starts lower than
  it used to. Nobody complains about this in words; the person just feels there is
  "less on screen" and cannot say why.
- **A strip showed up and never leaves.** Somebody needs to show the favicon, or
  the blocking status, or the extension icon, and adds "just one item" to a
  `.toolbar`. The second item arrives two weeks later. *Still exactly right, and
  ADR-0068 did not spend it: extension buttons went into the sidebar, which costs
  the page nothing, and into `WindowChrome` under a rule that admits nothing this
  sentence names. A `.toolbar` over the page is as forbidden as it was.*
- **`WindowChrome` stops being conditional.** The `if !model.sidebarVisible` falls
  out in a refactor and the strip is always there. With the sidebar open there are
  now two stacked chrome strips, and the page loses 38pt without a single test
  going red.
- **The loading bar becomes a status bar.** The 2pt `loadingBar` gets text, then
  gets height, then loses its `!tab.loadingComplete` condition. The path from "2pt
  conditional" to "24pt permanent" is always incremental.

**No lock.** Today a `.toolbar { ... }` added to `BrowserView` compiles, runs and
passes the whole suite. Locking this would take:

1. A test over `BrowserView` asserting that `detail` holds nothing beyond the
   conditional `WindowChrome` and the `content` — impossible to inspect today
   without instrumenting the SwiftUI hierarchy.
2. A cheap, practical alternative: a test asserting that `WindowChrome` is only
   built when `sidebarVisible == false`, by extracting that condition into a
   testable property on `BrowserModel` (`showsWindowChrome`) instead of leaving it
   inline in `body`.
3. ~~A height test: with the sidebar visible, the sum of chrome above the content is~~
   **Superseded by ADR-0055.** The invariant named here is unattainable: the
   system reserves ~28–32pt for the traffic lights in every state. The instinct
   was right and the number was impossible. The measurable claim is that it stays
   under the strip's own height, and that is now locked. What follows is the
   original wording:

   A height test: with the sidebar visible, the sum of chrome above the content is
   zero. That is the real invariant of this decision, and it is the one nobody is
   measuring.

Until that exists, this decision is held up by code review and nothing else.

## When to revisit

- If evidence shows that the missing origin/HTTPS indicator is leading someone to
  type credentials into the wrong site. Security beats density, no argument.
- When there is a second host (Linux). `WindowChrome` exists because macOS puts
  the traffic lights in the window; another windowing system may not need it, and
  then the conditional changes shape.
- If the cost of "I cannot see the URL" shows up repeatedly in real use. The way
  out is not bringing the bar back: it is making ⌘L cheaper, or giving a domain
  peek in `WindowChrome`.
- If a feature arrives that demands permanent presence (PDF reader, translation,
  profile). The test is always the same: does it pay for itself on *every* page?
