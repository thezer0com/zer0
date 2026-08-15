# ADR-0061: ⌘D keeps the page and ⇧⌘D keeps the tab

- **Status:** Accepted
- **Date:** 2026-07-02
- **Lock:** `crates/zer0-core/src/shortcuts.rs::command_d_keeps_the_page_and_shift_command_d_keeps_the_tab`, `crates/zer0-core/src/shortcuts.rs::the_chrome_shortcuts_our_users_already_know_are_all_there`, `apple/Tests/Zer0ShellTests/ShortcutTests.swift::ChromeParityTests/chromeBindings`

## Context

ADR-0011 decided that `zer0`'s shortcuts are Chrome's shortcuts, and it named
exactly one deliberate divergence:

> `⌘D` deserves a note: in Chrome it is "bookmark this page", here it is
> `TogglePinTab`. Not the same verb, but the same *gesture* — "keep this page"
> — in the data model `zer0` actually has (ADR-0014: pinned/favorite instead of
> bookmarks).

Read that sentence again with the emphasis where the argument actually is: **in
the data model `zer0` actually has.** The divergence was never argued as being
better. It was argued as being the closest available thing, given that there
were no bookmarks. ADR-0011 then listed the price it was paying, in its own
words:

> **⌘D means something else.** Anyone expecting a bookmark will pin the tab. It
> is the divergence most likely to produce real surprise, and it is accepted
> knowingly.

and again, in the regression section:

> **⌘D "made the tab disappear"** — in the head of someone coming from Chrome,
> bookmarking does not move the tab. Here it moves to another group in the
> sidebar.

and then it wrote down the exit condition, which is the sentence this ADR is
answering:

> If ⌘D causes repeated confusion in real use. Bookmark and pin may need to be
> separate things — and then it is ADR-0014 that changes, not this one.

ADR-0059 makes them separate things. The premise the divergence rested on is
gone.

## Decision

| Chord | Command | Why |
|---|---|---|
| ⌘D | `AddBookmark` | What it is in Chrome, for a concept this browser now has |
| ⇧⌘D | `TogglePinTab` | No Chrome analogue, so it takes an invented chord |
| ⇧⌘B | `ToggleBookmarks` | Chrome's show/hide bookmarks bar, for the shelf that answers the same question |

**This is a return to ADR-0011's rule, not a break from it.** The rule is
"Chrome wherever Chrome has an opinion; invent only where Chrome has no
concept". Chrome has an opinion about ⌘D. Until this week we had no concept for
it to attach to, so the chord was lent to the nearest neighbour. Now we do, and
the loan is repaid.

Pinning takes ⇧⌘D by the same rule read the other way: it is the thing Chrome
has no concept of, so it gets an invented chord rather than a borrowed one.
Shift for "the other one" is the pattern this keymap already runs on — ⌘G/⇧⌘G,
⌘R/⇧⌘R, ⌘\\/⇧⌘\\ — and ⇧⌘D in Chrome is Bookmark All Tabs, a command this
browser does not have.

⇧⌘B is Chrome's bookmarks-bar toggle and lands on the closest thing we have to
one. ⌘B keeps the sidebar it lives inside; Shift makes it the shelf.

### Why this is worth changing an accepted chord at all

Changing an established shortcut is the one thing ADR-0011 forbids, and the
prohibition is right: muscle memory does not get retrained, it gets betrayed.
So the exception has to be argued rather than assumed.

**Nobody has ⌘D-means-pin in their fingers.** The audience is Chrome users,
stated as such in ADR-0011's first line. What their hands hold is ⌘D-means-
bookmark. This browser is pre-1.0, and the population that has built the other
reflex is approximately the person who wrote it.

**The current binding is the more destructive of the two.** Chrome's ⌘D changes
nothing on screen — it files something and gets out of the way. Ours moves the
tab into another sidebar group, which is a visible change to the list the
browser is navigated by, produced by a key the person pressed expecting nothing
to move. ADR-0011 predicted that as "⌘D made the tab disappear" and it is
right.

**Leaving it would make the new feature the second-class one.** A browser with
bookmarks where ⌘D does not bookmark would need the person to learn a chord
*for the thing whose chord they already know*, in order to preserve a chord
they never asked for.

### What this does not change

ADR-0011 stands. Its rule is not amended, its table is not replaced, and every
other binding in it is untouched. Only the ⌘D row moves, and it moves *towards*
Chrome. ADR-0011's status line records that, in the shape `docs/adr/README.md`
provides for exactly this ("Status is a prefix, not an enum"; "partly
superseded is a real thing that happens to a decision").

## Consequences

**What hurts:**

- **⌘D on an already-kept page now does nothing visible except open a panel.**
  Chrome's does the same, so the expectation matches, but somebody who had
  built the pin reflex loses it and will pin a tab by accident until ⇧⌘D lands.
- **Pinning got a worse chord.** ⇧⌘D is a two-hand shape for a one-hand action
  people do daily in an Arc-shaped browser. That is the real cost, and it is
  paid so that the chord nobody has to learn stays the one nobody has to learn.
- **A rebound ⌘D from an older session survives the change.** Only the *delta*
  from defaults is stored (ADR-0011), so anybody who had explicitly bound ⌘D to
  something keeps their binding — which is correct and also means they will not
  see this change at all.
- **Arc disagrees.** ADR-0011 noted Arc puts pin on ⌘D and took comfort from
  it. We are diverging from Arc to converge on Chrome, and Chrome is who the
  first line of ADR-0011 says the audience is.
- **One more thing to undo if bookmarks are ever removed.** Two ADRs would have
  to move together.

**What we get:**

- The divergence ADR-0011 called "most likely to produce real surprise" is
  gone, on the day the reason for it expired.
- Pin lands where ADR-0011's own rule says an invented command belongs.
- ⌘D, ⇧⌘D and ⇧⌘B all survive the collapse to Control, so the Linux shell needs
  no bindings of its own for any of them.

## How this regresses

It regresses through the finger, and ADR-0011 already described the shape:
**the person presses and something else happens.** Nobody files an issue about
that.

- **"⌘D pinned my tab again."** Somebody restores the old binding during a
  merge or a refactor, most likely by taking `Chord::primary("d")` back for
  `TogglePinTab` because the diff looked like a mistake. Now the chord that
  files a page moves it instead, and the person's kept-page list silently stops
  growing.
- **"Pinning stopped working."** ⇧⌘D is dropped rather than moved — `rebind`
  used where `bind` was meant, which ADR-0011 records as having already
  happened once to ⌘[. Pinning is then reachable only by dragging a row, and
  half the people who used it conclude the feature went away.
- **"⌘D does nothing on this page."** Not a regression in the keymap at all:
  it is a tab with nothing committed, where `SaveBookmark` deliberately refuses
  (ADR-0059). It reads as a broken shortcut unless the panel says otherwise,
  which is why the panel exists.
- **"⇧⌘B does nothing."** The shelf is toggled but the sidebar it lives in is
  shut, so the state changes and the screen does not — the exact failure
  ADR-0014 spent a section on. `showBookmarkShelf` opens the sidebar first for
  that reason, and a "simplification" to `bookmarksVisible.toggle()` would
  bring it straight back.

**The locks**, in the two halves ADR-0011 established, because the failure has
two halves:

- Which key a command is on:
  `command_d_keeps_the_page_and_shift_command_d_keeps_the_tab` asserts both
  chords, in both directions, and in their collapsed form as well — so neither
  can be taken without the other's absence being named. It is joined by
  `the_chrome_shortcuts_our_users_already_know_are_all_there`, which now walks
  ⌘D as one of the Chrome bindings rather than as an exception to them, and by
  `ChromeParityTests/chromeBindings` on the Swift side, which is the test that
  used to assert the opposite and had to be changed for this decision to land.
- Whether the press arrives: `KeyPressTests/everyDefaultChordIsReachable`
  already walks every default chord through a real key press, so a new binding
  that is in the table and unreachable fails there without this ADR having to
  name it twice.

**What has no lock:** that ⇧⌘B opens the sidebar before showing the shelf. The
keymap test proves the chord resolves; nothing proves the shelf becomes
visible when the sidebar was shut, which is precisely the state where getting
it wrong is invisible.

## When to revisit

- **If pinning on ⇧⌘D is felt as friction in daily use.** Pin is the more
  frequent action in an Arc-shaped browser even if it is the less familiar one,
  and if that shows, the answer is a second chord for pin — not taking ⌘D back.
- **If Chrome ever moves ⌘D.** Case by case, as ADR-0011 says: align, or
  diverge with a comment, never drift.
- **If bookmarks are removed or folded back into pinned tabs.** Then this ADR
  and ADR-0059 are reverted together, and ⌘D goes back to `TogglePinTab` with
  ADR-0011's original argument restored — which would at that point be true
  again.
