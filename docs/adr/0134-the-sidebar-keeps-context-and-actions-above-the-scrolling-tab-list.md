# ADR-0134: The sidebar keeps context and actions above the scrolling tab list

- **Status:** Accepted, superseding only the sidebar composition clauses of ADR-0014 and ADR-0068
- **Date:** 2026-09-02
- **Lock:** `apple/Tests/Zer0ShellTests/SidebarLayoutTests.swift::SidebarLayoutTests/theSpacesRowSitsAboveTheTabList`, `apple/Tests/Zer0ShellTests/SidebarLayoutTests.swift::SidebarLayoutTests/theSpacesRowSharesTheWindowStripWithoutCoveringTheTrafficLights`, `apple/Tests/Zer0ShellTests/SidebarLayoutTests.swift::SidebarLayoutTests/theSpacesRowOccupiesTheActualTitledWindowStrip`, `apple/Tests/Zer0ShellTests/SidebarLayoutTests.swift::SidebarLayoutTests/thePrimaryActionStaysBetweenSpacesAndTheTabList`, `apple/Tests/Zer0ShellTests/SidebarLayoutTests.swift::SidebarLayoutTests/anOverflowingListScrollsAndTheHeaderHoldsStill`, `apple/Tests/Zer0ShellTests/SidebarLayoutTests.swift::SidebarLayoutTests/theExtensionRailKeepsTwoTargetsAndScrollsTheRest`

## Context

ADR-0014 put spaces below the tab list so the places read before the controls.
ADR-0068 then placed extension buttons beside those chips, producing two rows of
furniture under the list. Each decision was reasonable in isolation; together
they made the current context and the primary action the first things lost when
somebody scanned from the top, and the lower edge accumulated unrelated jobs.

A long tab list exposed the structural cost. Spaces, New Tab and extension
buttons are controls over the list, not more list content. If they share the
list's vertical scroll, the controls needed to navigate or create a destination
leave the viewport precisely when the list is hardest to navigate.

## Decision

The sidebar has a fixed header in this order: the horizontally scrolling spaces
row, one action row with New Tab leading and pinned extension buttons trailing,
then a hairline. The tab list below is the sidebar's primary vertical scroll
owner.

This supersedes ADR-0014 only where it placed spaces under the list, and
ADR-0068 only where it placed extension buttons in their own bottom row. Their
behavioural decisions remain: spaces are primary navigation; extension buttons
live where the sidebar's controls live, remain conditional, preserve core-owned
order and keyboard numbering, and move to `WindowChrome` when the sidebar is
hidden.

The conditional kept-pages shelf and Space Lens stay below the scrolling list.
When expanded past its 220pt ceiling, Kept owns a bounded secondary scroll
region; Space Lens does not scroll.

**Factual correction, 2026-09-02:** Kept already had that bounded `ScrollView`
when this record was accepted. Calling the tab list the only vertical scroll
owner was incorrect; the decision is that the primary list scrolls independently
of its fixed header, not that a conditional shelf may never scroll its own rows.

## Consequences

Spaces establish context before the tabs inside that context. New Tab remains
reachable with an empty or overflowing list, and extensions consume horizontal
room in an existing action row instead of permanent vertical room of their own.
There is one predictable answer to a vertical wheel or trackpad gesture: the tab
list moves and its controls do not. A gesture over an expanded, overflowing Kept
shelf moves only that bounded shelf.

The action row can become horizontally crowded when many extensions are pinned.
At the minimum supported width it keeps New Tab legible, the first two pinned
buttons usable, and the unread indicator visible; additional pinned buttons
remain reachable through the row's horizontal scroll. That pressure stays local
to the row rather than adding another strip or letting the fixed header scroll
away.

## How this regresses

The spaces row or action row is moved below the tab list because bottom controls
look familiar, and somebody with enough tabs must scroll back to recover the
context switcher or New Tab. Or one outer `ScrollView` is wrapped around the
whole sidebar because it is shorter code, and the header disappears with the
first rows. The locks assert the titlebar occupancy, the order of both header
rows, and the independent movement of an overflowing list. At the exact action
row floor, `theExtensionRailKeepsTwoTargetsAndScrollsTheRest` also drives three
pinned actions to the far edge while a hidden extension has unread work, then
clicks the unread target. It goes red if overflow clips or the fixed affordance
disappears.

## When to revisit

Revisit if the pinned extension buttons cannot remain usable in the shared
action row at the minimum supported sidebar width, or if a future sidebar adds
another persistent independently scrollable content region without Kept's
explicitly bounded, conditional job. A desire for a tidier implementation or a
familiar bottom toolbar is not enough.
