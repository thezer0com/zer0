# ADR-0042: A split is two tabs shown together, not one tab with two pages

- **Status:** Accepted
- **Date:** 2026-04-27
- **Lock:** `crates/zer0-core/src/reducer_tests.rs::splitting_pairs_the_active_tab_with_the_next_one`, `crates/zer0-core/src/reducer_tests.rs::closing_one_side_gives_the_other_the_whole_area`, `crates/zer0-core/src/reducer_tests.rs::going_to_a_third_tab_puts_the_split_away`, `crates/zer0-core/src/store_tests.rs::a_split_comes_back_as_a_split`, `crates/zer0-core/src/shortcuts.rs::the_split_bindings_are_ours_and_step_on_nobody`, `apple/Tests/Zer0ShellTests/SplitTests.swift::SplitTests/focusMovesByKeyboard`, `apple/Tests/Zer0ShellTests/SplitTests.swift::SplitPersistenceTests/splitSurvivesRelaunch`

## Context

Reading documentation while writing code, a diff next to the issue that
explains it, a video beside the notes you are taking from it. Every one of
those is two pages at once, and a browser that can only show one turns them
into ⌃Tab pressed four hundred times a day. It is the gesture that makes Arc
feel like a workspace rather than a stack, and we did not have it.

The layout is the easy part. The question that decides everything downstream is
what a split *is*:

- **One tab holding two pages.** The sidebar keeps one row. Closing that row
  takes both pages. The session stores one thing.
- **Two tabs shown together.** The sidebar keeps two rows. Closing one leaves
  the other. The session stores a pairing.

Whichever we chose, four things had to agree with it: the sidebar, which
ADR-0014 makes the only place tabs are visible; the session, which ADR-0017
promises comes back whole; `WKWebExtensionTab`, which ADR-0020 puts at the
centre of extension support and which assumes exactly one page per tab; and the
keyboard, because there is one of those and now two places for it to go.

## Decision

**A split is two tabs displayed side by side. It is a property of the space,
not of a tab.**

The deciding argument is not taste, it is duplication. Everything a second page
needs — its own address, pending address, title, history, zoom, mute, audio
state, load state, last error, last-active time — is everything `Tab` already
holds. A tab carrying a second page would need a second copy of all thirteen
fields, which is a second `Tab` wearing a different name. Two tabs shown
together buys the whole feature for one optional field:

```rust
pub struct Split {
    pub leading: TabId,
    pub trailing: TabId,
    /// The leading pane's share of the width.
    pub ratio: f64,
}
```

hung on `Space`, because a space is the workspace: leave it, come back, and the
pair you left is still there.

### There is no `focused` field

The focused pane is `Browser::active_tab`, full stop. That is already what ⌘L,
⌘F, ⌘R, ⌘W, zoom and mute aim at, so every existing command targets the focused
side without a line of new plumbing. A second notion of focus would be a second
thing to keep in step, and it would drift — the day they disagree, ⌘R reloads
the pane you are not looking at.

The invariant that makes this work lives in one place, `set_active_tab`:

> **A split is only live while the active tab is one of its panes.**

Going anywhere else — a sidebar click, ⌘1, ⌃Tab, a routed URL — puts the split
away. That is what keeps the sidebar's marked row always on screen. It is
enforced at the one door every activation goes through rather than at each
caller, because a rule you have to remember at five call sites is a rule with
four bugs in it.

### What the sidebar shows

Both panes are rows, because both tabs exist. The focused one wears the
selection colour at full strength; the companion wears the same colour at a
third of it, plus a quiet `rectangle.split.2x1` where its close button would be
on hover. One picture, not two.

### What the session restores

`splits` is a table of its own — `(space_id, leading, trailing, ratio)` — and
that is a decision rather than tidiness. The schema is created with
`CREATE TABLE IF NOT EXISTS` and there is no migration step, so a column added
to `spaces` would simply never appear on a database that already exists. Every
read and write of `spaces` would then fail on exactly the machines with a
session to lose, and by ADR-0017 a failed read detaches the store. A new table
appears on old and new databases alike.

`Browser::restore` throws out a split naming a tab that is gone, a tab from
another space, or the same tab twice, in the same pass that already repairs tab
order and parents.

### What an extension sees, which is a compromise

**Two ordinary tabs, exactly one of them `isSelected`: the focused pane.**

`WKWebExtensionTab` has no way to say "visible, beside another one". There is
no property for it and no notification for it. The choice was between reporting
both panes as active — which breaks every popup, because `tabs.query({active:
true})` would return two and the extension would act on whichever came first —
and reporting the companion as an ordinary non-active tab.

We report the companion as non-active. A `browserAction` popup therefore acts
on the pane with the keyboard, which is right. The cost is that an extension
assuming *not active ⇒ not visible* is wrong about the companion: something
that pauses video in background tabs will pause a video you are watching. Every
tiling browser on `WKWebExtension`'s model has the same hole, and the
alternative is worse.

Both panes stay in `tabs(for:)` and keep their index, and moving the keyboard
across the split emits `FocusWebView`, which the shell already turns into
`didActivateTab` — so an extension is told when focus crosses, it is just never
told there are two pages up.

### The shortcuts

Chrome has no split, so ADR-0011 gave us nothing to copy and we had to choose:

| Chord | Command | Why |
| --- | --- | --- |
| `⌘\` / `Ctrl+\` | `ToggleSplitView` | Split Editor in VS Code, on both platforms |
| `⇧⌘\` / `Ctrl+Shift+\` | `FocusOtherPane` | Same key, Shift for "the other one" |

`\` was unbound. Both chords are written against `primary` with no `control`
component, so neither is stranded when `primary` and `control` collapse into
one key off Apple — the failure mode ADR-0012 exists to catch, and the reason
`ToggleSidebar` needs two bindings and these need one. Shift-for-the-other-one
is the pattern ⌘G/⇧⌘G and ⌘R/⇧⌘R already set in this keymap.

### Entering a split that has nothing to pair with

⌘\ in a space with one tab opens a second tab and puts the keyboard in it,
because asking for two panes and being handed one is the browser ignoring you.
The shell then opens the command bar pointed at that pane — the same thing ⌘T
does, for the same reason — and a pane still empty after that says so rather
than sitting as half a window of white.

### One view draws one page and two

`PageStack` renders both cases. That is not tidiness either — it is what makes
the transition possible. If the split had its own view, SwiftUI would swap one
view for another and cross-fade, and the page you were reading would appear to
teleport into a half-width column. With one view the leading pane is the same
view before and after, so its width animates from the whole window to its
share, and only the divider and the second pane are inserted — which is what
their `.move(edge: .trailing)` transition is for. The margin around the pair
animates in from zero for the same reason.

### What stayed in the shell

The corner radius, the gutter, the hairline that marks the focused pane, the
shadow that lifts it, the spring the second pane arrives on, and the divider's
look. `clampSplitRatio` is exported from the core as a free function so the
drag consults the same rule mid-flight that the reducer applies on release:
what you see while dragging is what you get when you let go.

## Consequences

**What hurts:**

- **⌃Tab dismisses the split.** It activates a tab that is not a pane, so the
  invariant fires. It is consistent and it will still surprise someone who
  expected ⌃Tab to walk between panes. The alternative — overloading ⌃Tab
  inside a split — would make one of the two best-known chords in the browser
  mean two things depending on state.
- **An extension can be wrong about the companion.** Stated above, and it has
  no fix inside `WKWebExtension` as it stands.
- **Two panes is the ceiling.** `Split` names exactly two tabs. Arc goes to
  four. Going past two means `leading`/`trailing` becomes a `Vec`, which
  touches the model, the schema, the reducer and the layout.
- **A pane is a `WKWebView` at half width doing full work.** Two live pages
  render, script and play video at once. Nothing throttles the unfocused one,
  and the split makes it much easier to sit with two heavy pages open.
- **Clicking into a pane is a mouse-down monitor.** A web view swallows the
  click before SwiftUI sees it, so the window is asked what it hit and the
  answer compared by view identity. It is the same technique the sidebar uses
  to catch Escape mid-drag, and it is still a monitor living outside the view
  hierarchy.
- **The divider's position is core state.** It is not appearance — it is a
  value the person set and the session promises to bring back — but it does
  mean a drag ends in a reducer dispatch and a full snapshot rebuild.
- **A split spanning spaces is refused rather than explained.** "Open in Split"
  is absent from the menu for a tab in another space; nothing says why. A
  favorite is the case that will hit it, since favorites are listed everywhere
  and belong to one cookie jar.

**What we get:**

- One meaning of "tab", for the sidebar, the session and `chrome.tabs` alike.
- Closing one side is `CloseTab`, which already existed and now hands the area
  to the survivor because `successor_of` prefers the companion.
- The whole feature is one optional field on `Space`, four actions and one
  table.
- The pages are reparented, not rebuilt: entering a split does not reload what
  you were reading.

## How this regresses

The failure mode worth fearing here is not a crash. It is **the browser holding
two disagreeing pictures of itself.**

What a person would notice:

- **"The sidebar highlights one tab and I can see two pages."** The companion
  row loses its treatment in a refactor of `background(isActive:…)`. Nothing
  errors. The person stops trusting the sidebar to say what is open, which is
  the one job ADR-0014 gave it.
- **"The highlighted tab is not on screen."** The invariant in `set_active_tab`
  is moved to the callers and one caller is missed. The sidebar marks a row,
  the window shows two other pages, and there is no way to work out which one
  ⌘R is about to reload.
- **"I closed the right-hand page and it jumped to a tab I did not have open."**
  `successor_of` loses its split branch and falls back to the next row in the
  sidebar — a tab that was not on screen a moment ago.
- **"My split came back as two normal tabs."** The `splits` table stops being
  written, or `Browser::restore` gets stricter and drops a pair it should have
  kept. Every page is there and the arrangement is gone, which is the part that
  took thought.
- **"Everyone's session stopped saving after the update."** The one that costs
  the most: somebody moves the split onto `spaces` as three columns. It works
  perfectly on a fresh database and fails on every database that already
  exists, and by ADR-0017 a read failure detaches the store — so the browser
  runs, saves nothing, and the only warning is a banner that can be dismissed.
- **"The page reloads every time I split."** `PageArea` stops handing back the
  engine's existing `WKWebView` and builds one. Forms lose their contents,
  videos restart, and it looks like a network stall rather than a bug.
- **"⌘\ does nothing on Linux."** Somebody adds a `control: true` sibling
  binding for comfort on the Mac and it wins the collapsed chord. That is the
  ADR-0012 failure exactly, and
  `every_command_is_still_reachable_where_control_is_primary` catches it.
- **"I dragged the divider and one side vanished."** `clampSplitRatio` is
  inlined in the shell, then changed in one of the two places. The narrow pane
  goes to zero width and the divider that would fix it is at the very edge of
  the window.

**The locks:**

- `splitting_pairs_the_active_tab_with_the_next_one` — the pair is formed, and
  the keyboard stays with the page already in hand.
- `closing_one_side_gives_the_other_the_whole_area` — asserts the survivor
  takes focus *and* that the ordinary sidebar successor does not.
- `going_to_a_third_tab_puts_the_split_away` — the invariant that keeps the
  sidebar and the window telling the same story.
- `a_split_comes_back_as_a_split` — the pair and the divider survive a round
  trip through SQLite.
- `the_split_bindings_are_ours_and_step_on_nobody` — both chords resolve, and
  both still resolve once `primary` and `control` collapse.
- `SplitTests/focusMovesByKeyboard` — ⇧⌘\ crosses and comes back without
  dismissing.
- `SplitPersistenceTests/splitSurvivesRelaunch` — a real file, a second
  `BrowserModel`, the pair and the ratio still there and both panes holding
  live views.

Alongside them, in `reducer_tests.rs`:
`splitting_again_puts_the_pair_away`,
`splitting_with_nothing_to_pair_with_opens_the_second_pane`,
`a_named_tab_can_be_brought_in_beside_the_current_one`,
`a_tab_from_another_space_cannot_be_brought_into_the_split`,
`the_keyboard_crosses_the_split_without_touching_the_mouse`,
`leaving_a_space_and_coming_back_finds_the_split_where_it_was`,
`dragging_a_pane_into_another_space_ends_the_split`,
`the_divider_cannot_be_dragged_past_either_edge`,
`a_split_restored_with_a_missing_pane_is_dropped`; and on the Swift side
`SplitTests/panesKeepTheirLiveViews` and
`SplitTests/extensionsSeeBothPanesAsTabs`.

**What has no lock:** everything visual. That the second pane *slides* in, that
the focused pane is legible at a glance, that the divider is grabbable, that
the empty pane looks like a product screen rather than a gap. Tests cover
behaviour, not pixels (`CLAUDE.md`), and no test in this repository has ever
looked at the screen. This decision is behaviour-complete and appearance-
unverified, and that is worth writing down rather than glossing.

Also unlocked: that the split stays a property of the space rather than
migrating onto `Tab` the first time somebody wants a third pane.

## When to revisit

- **If two panes stops being enough.** Arc allows four. The change is
  `leading`/`trailing` becoming an ordered `Vec<TabId>` with ratios between
  them, plus a schema that is a row per pane rather than a row per space.
- **If ⌃Tab dismissing a split turns out to be the thing people complain
  about.** The answer is probably that ⌃Tab walks the panes while a split is up
  and the tabs otherwise, and that is a state-dependent shortcut, which is why
  it was not the first answer.
- **When `WKWebExtension` grows a way to say "visible".** The compromise above
  is a limitation of the framework, not a preference, and it should be undone
  the day it stops being one.
- **If two live panes show up as a battery or memory complaint.** Throttling
  the unfocused pane is the obvious move and would be the first time this
  browser treats one open page as less important than another.
- **When the Linux shell exists.** `Split` and `clamp_split_ratio` cross
  unchanged; the divider, the elevation and the slide are written again.
- **If the mouse-down monitor proves flaky.** The fallback is to have the
  engine host report first-responder changes as a fact, the way it already
  reports titles and navigation.
