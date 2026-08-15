# ADR-0041: A drag previews, the core decides the order, and crossing a space says so instead of asking

- **Status:** Accepted
- **Date:** 2026-04-23
- **Lock:** `crates/zer0-core/src/reducer_tests.rs::a_drag_reorders_a_tab_inside_its_group`, `crates/zer0-core/src/reducer_tests.rs::a_drop_at_the_end_of_a_group_stays_inside_that_group`, `crates/zer0-core/src/reducer_tests.rs::a_drop_on_a_space_that_is_gone_leaves_the_tab_untouched`, `apple/Tests/Zer0ShellTests/TabDragTests.swift::TabDragTests/dropReorders`, `apple/Tests/Zer0ShellTests/TabDragTests.swift::TabDragTests/dropCrossesSpaces`

## Context

ADR-0014 made the vertical sidebar the primary navigation and then listed, under
what hurts: **"Nothing drags."** Every browser with a tab strip has reordered by
drag for fifteen years. Its absence is not a missing feature, it is a broken
expectation — the kind of thing that sends someone quietly back to Chrome
without ever filing a bug.

Two things stood in the way, and neither is about gestures.

**The unit is wrong.** `Action::MoveTab` takes an index into a space's
`tab_order`. The sidebar does not show `tab_order`; it shows three filtered
lists — Favorites, Pinned, Today (ADR-0014). "The third row of Today" is not
the third entry of `tab_order`, and the translation between them depends on
what else is in the space. A view that computes that index is a view deciding
behaviour, which ADR-0002 does not allow.

**Drag-and-drop invites the shell to lie.** The usual implementation reorders a
local array on drop, then sends the change onward. For a moment the list is
whatever the view decided — and when the two disagree, the row reappears where
it was half a second later. That is not a rendering bug, it is a second source
of truth.

There is also a cost that is specific to this browser. A drop can cross a
space, and per ADR-0007 a web view cannot change data store, so crossing means
the view is destroyed and rebuilt — the page comes back, its back/forward
history does not.

## Decision

### The drop is stated in the sidebar's own units

`Action::MoveTabToGroup { tab, space, kind, before }`. The shell says which
group the tab was let go in and which row it was let go **above**; `before:
None` is the end of that group. The reducer turns that into an index and moves
the tab.

An anchor rather than an index, because an anchor is unambiguous under removal:
`move_tab` lifts the tab out before it puts it back, so an index computed from
the list you can see is off by one for every downward drag. "Above this row" is
the same statement before and after the lift.

It reuses the one move path. `MoveTab` and `MoveTabToGroup` both end in
`relocate`, which is the only thing that calls `Browser::move_tab` and the only
thing that decides a rebuild is due. A second move path is how the context menu
and the drag would start disagreeing about what a move is.

Landing in a different group also changes `kind` — that is what dropping a tab
under "Pinned" means, and it is one action, not a move followed by a pin. The
kind is applied **after** the move succeeds, so a drop that is refused cannot
pin a tab that never went anywhere.

The end of a group is the end of the *group*, not of the space: a tab appended
to Favorites lands after the last favorite rather than after everything.
`⌃Tab` and `⌘1..⌘9` walk `tab_order`, and a group scattered through it makes
both feel random.

### The shell previews and never commits

Everything the sidebar holds during a drag — the lifted row, the insertion
line, the lit space chip — is preview. It reorders nothing. On release it sends
one action and renders the snapshot that comes back. There is no local array to
disagree with the core, so there is nothing to snap back from.

### The drop target is legible before release

An insertion line where the tab will land, not a highlight on the row under the
pointer. A highlighted row leaves the person guessing between "above this" and
"below this", which is the one question a drop has to have answered before they
commit.

Mid-drag all three headings appear, empty or not, each empty one carrying a
drop well. Dropping a tab under "Pinned" is how anyone would expect to pin one,
and a heading that is not on screen cannot be aimed at.

### Crossing a space says where it is going. It does not ask

A drop that leaves the space draws the destination's name on the insertion
line, and a space chip under the pointer lights, rings and lifts. No dialog.

Four reasons, in order of weight:

1. **A confirmation lands after the commitment, which is the wrong end.** The
   whole value of an insertion line is that it answers "where does this go"
   *before* release. A sheet that appears afterwards has arrived too late to
   inform anything and can only interrupt.
2. **The cost is bounded and not destructive.** The tab survives, the URL
   survives, the page reloads. What goes is back/forward history. Compare
   "Close Space…", which does ask (ADR-0014) because it destroys tabs with no
   undo. Asking for both flattens the difference between them, and a warning
   that fires for everything stops being read.
3. **The same move already exists without a dialog.** "Move to Space" in the
   context menu has always been silent. A dialog on only one of the two paths
   would make the browser disagree with itself about how serious the operation
   is.
4. **A modal in the middle of a direct-manipulation gesture breaks the
   metaphor.** You are holding something. Being asked a question with the mouse
   button still down is not a thing physical objects do.

### The gesture is ours, not the system's

A `DragGesture`, not `onDrag`/`onDrop`. On macOS a list is scrolled with the
wheel, not by dragging, so nothing competes with the scroll view — and owning
the gesture is what makes a live insertion line, an edge that scrolls, and an
Esc that cancels possible at all. Esc closes, always (`CLAUDE.md`), including a
drag still under the pointer; it is caught with a local event monitor because a
key press only reaches a view that has focus, and during a drag focus is
wherever the pointer left it.

## Consequences

**What hurts:**

- **The sidebar now measures itself.** Every row and every space chip reports
  its frame through `onGeometryChange`, and the drop is resolved from those
  numbers. Layout is now load-bearing for a behaviour, which it was not before.
- **A lazy list keeps stale frames.** Rows scrolled out of view leave their last
  known geometry behind, so resolution filters to what is inside the list's
  visible rect. Get that filter wrong and the line lands somewhere nobody can
  see.
- **A drag inside Favorites can change a space.** Favorites is global, so the
  list interleaves spaces, so landing above a row from another space *is*
  landing in that space. It is coherent with what is on screen and it is still
  a surprise the first time; the destination pill on the line is the whole
  mitigation.
- **Crossing a space costs history with no warning and no undo.** That is the
  decision above, and it is the part of it that will hurt someone.
- **Two states can now be lit.** The list has a slot and the space bar has a
  chip, and they must never both be shown. That is one `if` away from a drag
  that claims two destinations at once.
- **`⌘1..⌘9` moved under the person's hands.** Reordering is the point, but the
  numeric shortcuts follow the order, so a tidy-up silently rebinds them.

**What we get:**

- The tab strip behaves the way tab strips have behaved since 2011.
- Pinning has an obvious gesture instead of only a context-menu item.
- Moving between spaces is direct rather than a two-level menu.
- The core still owns the order, so the list cannot be wrong even briefly.

## How this regresses

The failure mode of a drag-and-drop implementation is famous, and it is what
the "preview only" half of this decision exists to prevent.

- **"The tab jumps back to where it was."** Someone adds a local `@State` array
  of tabs "so the animation is smoother", reorders it on drop, and sends the
  action afterwards. It looks perfect and then the snapshot arrives and
  overrules it. Intermittent, unreproducible in a test, and reported as
  "sometimes the drag doesn't work".
- **"Everything is one row off."** Someone replaces the anchor with an index
  taken from the visible list. Upward drags are right, downward drags land one
  short, because the dragged row was still being counted.
- **"Pinning a tab lost my place."** Someone computes the end of a group as the
  end of `tab_order`. Favorites, Pinned and Today interleave, `⌃Tab` starts
  wandering between groups, and nobody connects it to the drag.
- **"I dragged a tab and lost the page's history."** A cross-space drop that
  neither drew the destination name nor lit the chip. The move worked exactly
  as designed, and it still reads as data loss.
- **"The line lands on the first row instead of above it."** The insertion line
  and its destination pill go back into an `HStack`. The pill is the taller
  view, so the stack takes the pill's height and the 2pt line is centred
  against *it* — half a row below where it was asked to be, drawn across the
  first row of the section. Only shows up when the drop crosses a space, which
  is the one case where the line is carrying a name, so a same-space drag looks
  perfect and the bug hides behind the rarer gesture.
- **"The section heading disappeared while I was dragging."** The lifted row
  covers it, which is correct — it is a floating layer and floating layers
  cover things. The trap is the fix: redrawing the heading on top of the card
  trades a covered heading for two strings blended into each other, and a
  translucent card does the same. Both are worse than the thing they fix,
  because a covered heading is at least still legible where it is not covered.
  The card is opaque, it wins the z-order against everything except the line,
  and it does not move out of anything's way — an offset that changes with what
  is underneath is a card that swims against the cursor.
- **"Esc doesn't cancel the drag."** Someone swaps the event monitor for
  `.onKeyPress(.escape)` because a monitor looks heavy-handed. It compiles, it
  passes, and it does nothing — the row does not have focus during a drag.
- **"I can't drag past the bottom of the window."** Autoscroll removed, or its
  margin measured against the wrong rect. The list is only reorderable as far
  as the window is tall, which is invisible until someone has thirty tabs.
- **"Dropping on Pinned does nothing."** The empty-section wells stop being
  rendered mid-drag, so the only way to pin by drag is to already have a pinned
  tab to aim at.

**The locks** hold the two halves separately. `a_drag_reorders_a_tab_inside_its_group`
and `a_drop_at_the_end_of_a_group_stays_inside_that_group` pin the translation
from "group and anchor" into an order — the second one goes red the moment
someone appends to the space instead of to the group.
`a_drop_on_a_space_that_is_gone_leaves_the_tab_untouched` pins that a refused
drop cannot leave a kind behind. On the Swift side `dropReorders` pins that the
order the sidebar shows is the one the core returned, and `dropCrossesSpaces`
that a drag really does move a tab between cookie jars.

**What has no lock:** everything about how it *feels*. That the insertion line
is a line and not a highlight, that the lifted row follows the pointer, that
the space chip lights, that Esc cancels, that the edge scrolls. Those are
appearance and gesture, they are tested by looking, and every one of them can
be deleted without a single test going red.

## When to revisit

- If dragging is wanted between windows. A `DragGesture` stops at the window
  edge; that is the point where `NSItemProvider` and a declared type identifier
  become worth the loss of control.
- If someone loses real history to a cross-space drop and says so. The answer is
  probably an undo, not a dialog — the objection to asking is the timing, and
  undo has the right timing.
- If the sidebar grows a fourth group. Section resolution is nearest-band, which
  is fine for three and gets vague as the bands get thinner.
- When a Linux shell exists. `MoveTabToGroup` is the part that survives;
  `DragGesture`, `onGeometryChange` and `NSEvent` are all SwiftUI and AppKit.
- If the tab list ever gets deep enough to need real virtualisation. Resolution
  reads frames of rows that exist, and a list that keeps only a handful alive
  would need the geometry computed rather than measured.
