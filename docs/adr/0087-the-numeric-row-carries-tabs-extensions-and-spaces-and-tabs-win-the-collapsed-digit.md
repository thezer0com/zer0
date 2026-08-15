# ADR-0087: The numeric row carries tabs, extensions and spaces, and tabs win the collapsed digit

- **Status:** Accepted
- **Date:** 2026-08-10
- **Lock:** `crates/zer0-core/src/shortcuts.rs::every_digit_switches_to_a_space`, `crates/zer0-core/src/shortcuts.rs::tabs_win_the_collapsed_digit_and_spaces_keep_their_own_way_in`, `crates/zer0-core/src/shortcuts.rs::every_command_is_still_reachable_where_control_is_primary`, `crates/zer0-core/src/shortcuts.rs::no_default_chord_is_bound_twice`, `crates/zer0-core/src/shortcuts.rs::viewing_source_keeps_the_chord_the_rest_of_the_world_presses`, `crates/zer0-core/src/reducer_tests.rs::a_digit_goes_straight_to_the_space_in_that_position`, `crates/zer0-core/src/reducer_tests.rs::a_digit_past_the_last_space_moves_nobody`, `apple/Tests/Zer0ShellTests/ShortcutTests.swift::KeyPressTests/theNumericRowHasThreeTenants`, `apple/Tests/Zer0ShellTests/ShortcutTests.swift::KeyPressTests/everyDefaultChordIsReachable`, `apple/Tests/Zer0ShellTests/ShortcutTests.swift::ShortcutTests/selectSpaceByNumber`

## Context

A space is this browser's top-level division — its own cookie jar, its own
tabs, its own routing (ADR-0007, ADR-0014) — and until now there was no
keyboard route to a *named* one at all. ⌥⌘↑ and ⌥⌘↓ step, which is a scan and
not a destination: three spaces away is three presses and a look at the screen
to check you stopped in the right place. The only way to say "that one" was to
point at a chip at the bottom of the sidebar.

The numeric row already had two tenants and they were designed as one sentence:
**⌘1–⌘9 selects a tab** (ADR-0011, Chrome's) and **⇧⌘1–⇧⌘9 runs the nth pinned
extension** (ADR-0068, deliberately "one Shift away from ⌘n… one sentence to
learn rather than nine chords to memorise"). ⌃1–⌃9 for spaces is the third
term, and the three read together: the same digits, one modifier apart, for the
three things a number can mean here — the page in front of you, the tool you
point at it, the place you are in.

**And that is exactly what makes it not free.** Bindings are written against a
`primary` modifier — Command on Apple, Control everywhere else (ADR-0012). Off
Apple **⌃1 and ⌘1 are the same physical chord.** Space-switching and tab
selection collapse onto each other, one of them silently stops working, and it
does not error — it just never fires. It is the ⌃S / ⌘S collision one row of
the keyboard along.

## Decision

### ⌃1–⌃9 go to a space, and tabs win the collapsed digit

`UiCommand::SelectSpace { index }` joins `SelectTab` and `RunPinnedExtension`,
1-based over the chips in the order the sidebar draws them.

The tie-break is written into the default the way ADR-0012 wrote its own:

> **Tabs win Ctrl+n**, because Ctrl+1–Ctrl+9 is Chrome's tab selection on Linux
> and Windows and it is in the finger already. Nobody, anywhere, has ever
> pressed a key to reach a space.

Which is the same shape as *Save wins Ctrl+S*: the collapsed chord goes to the
command a person arrives already knowing, and the loser gets a second chord
that survives everywhere.

**Spaces get ⌥⌘1–⌥⌘9 as that second chord.** It collapses to Ctrl+Alt+n, which
belongs to nothing, and ⌥⌘ is already where this keymap keeps what Chrome has
no name for — ⌥⌘N makes a space, ⌥⌘↑/↓ step between them, ⌥⌘I and ⌥⌘L are
there for the same reason. Going straight to a space is the same family rather
than a new one. On the Mac both paths exist; off Apple there is one, and this
is it.

Mechanically, the tie-break is **the order of two `bindings.push` calls**.
`command_for_collapsed` gives a collapsed chord to the first binding that
claims it, so `SelectTab` is pushed before `SelectSpace` within each digit. That
is a decision wearing the disguise of list order, and the comment in
`with_defaults` says so.

### What the menus print, and where the chord is found

`chord_for` returns the **first** binding, so a command with two chords
advertises one and hides the other. Both new pairs are ordered deliberately:

| Command | Printed | Hidden | Why that way round |
|---|---|---|---|
| `SelectSpace { n }` | ⌃n | ⌥⌘n | ⌃n is what was asked for and what works on the platform that exists |
| `ViewSource` | ⌥⌘U | ⌘U | ⌥⌘U is Chrome-on-Mac's and Safari's, exactly as ⌥⌘I is for the inspector |

There is **no menu item for a numbered space**, and that is consistent rather
than an omission: there is none for ⌘1 or for ⇧⌘1 either, and nine items in the
Navigate menu would bury the two that are about the page. So discovery is where
the thing being reached already is:

- **The space chip carries its chord in its tooltip**, read off the keymap and
  not written as "⌃3", so rebinding does not leave a lie behind. The tenth chip
  onwards prints nothing rather than a chord that does not work — the same rule
  ADR-0068 set for the tenth extension button.
- **Settings › Shortcuts** lists every command with *every* chord bound to it,
  so ⌃3 and ⌥⌘3 appear side by side there with no work: the pane groups the
  core's flat binding list by command.

### Why the index is resolved in the core

`Action::SelectSpaceByIndex { index }` sits beside `SelectTabByIndex`. Which
space is the third one, and what a digit past the end does, are not things two
platforms could reasonably disagree about, so by the project's own tie-breaker
they are the core's. It is also ADR-0068's rule about the extension row: the
list the shell draws and the list the chords count through have to be the same
list, or ⌃3 goes somewhere nothing on screen points at.

**The ninth slot is the ninth space, not "the last one".** ⌘9 means the last
tab because Chrome, Safari, Firefox and Edge all taught that and the finger
arrives with it. Nothing taught anything about a space, so clamping would be
inventing a rule whose only effect is putting somebody in a place they did not
name. An index past the end does nothing, silently — the chips are on screen
and visibly number fewer than what was pressed.

### View Source gets ⌘U

Found in the same pass and fixed for the same reason the inspector took a
second chord. `ViewSource` was on ⌥⌘U alone, which collapses to Ctrl+Alt+U —
nobody's. Chrome, Firefox and Edge all publish Ctrl+U everywhere that is not a
Mac. So ⌘U is bound as a second chord: unspent on a Mac, and off Apple it
lands on exactly the chord the rest of the world presses.

This is the failure mode `every_command_is_still_reachable_where_control_is_primary`
cannot see. `ViewSource` passed it the whole time, because it *won* its own
collapsed chord — a chord no Linux finger will ever press.

## Consequences

**What hurts:**

- **⌃n is a Mac-only spelling, and the menu prints it.** On Linux the Navigate
  menu would advertise a chord that selects a tab. It is the same debt ADR-0012
  accepted for ⌃S versus ⌘B, now nine times over, and it stays theoretical only
  until a Linux shell exists.
- **Eighteen more bindings in the default keymap**, which is a third of it
  spent on three numbered families. The Shortcuts pane in Settings is now
  twenty-seven rows of "Select Tab 4", "Extension 4", "Select Space 4" before
  it says anything else.
- **⌃1–⌃9 were free keys and are not any more.** Anything wanting a bare
  Control chord on a Mac now has nine fewer to take.
- **Two chords for one command, twice more.** Every such pair is a thing
  somebody can tidy away for looking duplicated, and ⌘U and ⌥⌘n are exactly the
  ones that look most redundant on the machine of whoever is reading.
- **The tie-break lives in `push` order.** It is commented, it is tested, and
  it is still three lines that can be reordered by someone making a loop read
  more nicely.
- **A space reached by ⌃3 is written down; one reached by ⌥⌘↓ is not.**
  `selectSpaceByIndex` is structural in `BrowserModel.isStructural` beside
  `activateSpace`, because naming a destination is what clicking a chip does.
  `cycleSpace` is not, and has never been. That split is defensible — a scan is
  not a destination — and it is a split, and a crash straight after ⌥⌘↓ still
  comes back in the space you left.

**What we get:**

- A space is reachable by name from the keyboard, which is the top-level
  division of the whole browser and previously required a pointer.
- One sentence covers three families: ⌘n the tab, ⇧⌘n the extension, ⌃n the
  space.
- The Linux collapse is decided rather than discovered, with the losing command
  given a path that survives — and the decision is pinned by a test that fails
  by naming which side won.
- View Source works on the chord the non-Mac world presses.

## How this regresses

**"⌃3 opens the third tab."** Somebody reorders the three pushes in the digit
loop — grouping them by command, which reads tidier — and `SelectSpace` now
claims the collapsed digit. On a Mac **nothing changes at all**, so it survives
review, ships, and off Apple every ⌘1–⌘9 stops selecting a tab. That is the
regression this ADR is mostly about, and
`tabs_win_the_collapsed_digit_and_spaces_keep_their_own_way_in` is what fails,
digit by digit, naming which one.

**"⌥⌘4 looks redundant, it is the same as ⌃4."** It is deleted for tidiness.
`every_command_is_still_reachable_where_control_is_primary` then names
`SelectSpace` in its orphan list — this is precisely the `⌘B` case, and it is
the reason that function exists.

**"⌃9 should go to the last space."** Somebody makes it symmetric with ⌘9
because the asymmetry looks like an oversight. Nobody notices until the person
with three spaces presses ⌃9 aiming past the end and is moved. `a_digit_past_the_last_space_moves_nobody`
is the fence, and it checks 0 and `u32::MAX` alongside, because "past the end"
and "nonsense" arrive by the same door.

**"The chips filter and the chords do not."** The sidebar starts drawing only
some spaces — hiding ephemeral ones, say — while `SelectSpaceByIndex` keeps
counting `spaces()`. Every chip after the hidden one answers to its
neighbour's digit and nothing on screen looks wrong. This is ADR-0068's
off-by-one, and there is **no test for it here**: the fence is that both sides
read `spaces()`, which is a fact about the code rather than an assertion. Real
debt, stated.

**"The tooltip prints ⌃3 as a string."** Somebody writes the glyph into the
`.help` instead of reading the keymap, and it stops being true the moment
anybody rebinds anything. Nothing goes red — a tooltip needs a rendered view to
observe, and this one is not photographed. Also debt.

**And the quiet one: ⌘U goes away.** It reads as a duplicate of ⌥⌘U on the
machine of whoever is looking, and removing it makes View Source Mac-only again
while every reachability test stays green — because ⌥⌘U wins its own collapsed
chord. `viewing_source_keeps_the_chord_the_rest_of_the_world_presses` is the
only thing that fails, and it fails on the collapsed assertion specifically.

## When to revisit

- **When the Linux shell exists.** Both the collapse model and the menu-prints-
  the-first-chord behaviour are hypotheses until a runtime confronts them, and
  this ADR doubles the surface ADR-0012 already flagged.
- **If somebody wants to reorder the space chips.** The digits count through
  `spaces()`, so reordering re-points every chord — the same property that
  makes ⇧⌘1 stable in ADR-0068, and the same cost.
- **If a tenth space becomes normal.** Nine is the row; the answer at ten is
  probably not a tenth chord.
- **If `chord_for` returning the first binding keeps being the wrong answer.**
  This is now the fourth command whose menu chord is decided by list order
  (`ToggleSidebar`, `ToggleDevTools`, `ViewSource`, `SelectSpace`). At some
  point an explicit "primary chord" beats a convention about `Vec` order,
  which is what ADR-0012 already predicted.
