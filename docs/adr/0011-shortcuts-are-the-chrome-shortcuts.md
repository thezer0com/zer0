# ADR-0011: The shortcuts are Chrome's shortcuts

- **Status:** Accepted, and its ⌘D row superseded by ADR-0061
- **Date:** 2026-02-06
- **Lock:** `apple/Tests/Zer0ShellTests/ShortcutTests.swift::ChromeParityTests/chromeBindings`, `apple/Tests/Zer0ShellTests/ShortcutTests.swift::KeyPressTests/everyDefaultChordIsReachable`, `crates/zer0-core/src/shortcuts.rs::the_chrome_shortcuts_our_users_already_know_are_all_there`, `crates/zer0-core/src/shortcuts.rs::escape_stops_a_load_the_way_it_does_in_chrome`, `crates/zer0-core/src/shortcuts.rs::every_digit_selects_a_tab`, `crates/zer0-core/src/shortcuts.rs::a_command_can_have_more_than_one_chord`

## Context

`zer0`'s audience is Chrome users. Not browser users in the abstract: Chrome
users, with years of ⌘T, ⌘W, ⌘L, ⌘R in their fingers.

A keyboard shortcut is not a feature, it is muscle memory. Nobody *decides* to
press ⌘W — the hand goes. When the result is not what was expected, the cost is
not "learning another shortcut": it is a wrong action already executed, sometimes
destructive, followed by permanent distrust of the keyboard. After that the person
starts looking before pressing, and then we have lost the whole thing.

The code says it without hedging, in `crates/zer0-core/src/shortcuts.rs`:

> Deliberately close to what Safari and Chrome already do. A browser that
> invents its own shortcuts for going back is a browser people fight.

## Decision

The default keymap (`Keymap::with_defaults`) reproduces Chrome wherever Chrome has
an opinion:

| Chord | Command |
|---|---|
| ⌘T / ⌘W / ⇧⌘T | `NewTab` / `CloseTab` / `ReopenClosedTab` |
| ⌘L | `OpenLocation` |
| ⌘R / ⇧⌘R | `Reload` / `ReloadIgnoringCache` |
| ⌘S / ⌘P | `SavePage` / `PrintPage` |
| ⌘F / ⌘G / ⇧⌘G | `FindInPage` / `FindNext` / `FindPrevious` |
| ⌘Y / ⌘, | `ShowHistory` / `ShowSettings` |
| ⌘D | `TogglePinTab` |
| ⌘+ / ⌘- / ⌘0 | zoom |
| ⌘1..⌘8, ⌘9 | `SelectTab { index }`, 9 = the last one |
| ⌃Tab / ⇧⌃Tab | `NextTab` / `PreviousTab` |
| ⌘← / ⌘→ and ⌘[ / ⌘] | `Back` / `Forward` |
| Esc | `StopLoading` |

A command can have more than one chord. `Back` answers to ⌘← **and** ⌘[ because
both are muscle memory for different people, and there is no reason to choose on
their behalf.

**We only invent a shortcut where Chrome does not have the concept**, and even
then we follow the logic of what already exists:

- `ToggleSidebar` — Chrome has no vertical tab strip. ⌃S on Apple (see ADR-0012
  for why it is not ⌘S: ⌘S is Save, and Save wins).
- `NewSpace` / `NextSpace` / `PreviousSpace` — Chrome has no spaces. The horizontal
  arrows are already Chrome's tab switcher (⌥⌘←/→), so spaces get the vertical
  ones: tabs move sideways, spaces move up and down. It matches the sidebar being
  vertical.

`⌘D` deserves a note: in Chrome it is "bookmark this page", here it is
`TogglePinTab`. Not the same verb, but the same *gesture* — "keep this page" — in
the data model `zer0` actually has (ADR-0014: pinned/favorite instead of
bookmarks).

## Consequences

**What hurts:**

- **We inherit Chrome's bad decisions along with the good ones.** ⌘W closes the
  tab without asking, and it is the classic origin of lost work. Copying Chrome
  means copying that too. The mitigation is `shouldConfirmClosingWindow`, which
  only covers closing the *window*, not the tab.
- **We are hostage to someone else's changes.** If Chrome changes a binding,
  either we fall out of line or we follow behind — and changing an established
  shortcut is the exact thing this ADR forbids.
- **⌘D means something else.** Anyone expecting a bookmark will pin the tab. It is
  the divergence most likely to produce real surprise, and it is accepted
  knowingly.
- **It closes off design space.** Several good chords are unavailable because
  Chrome already spent them. ⌘S is Save Page — something almost nobody does — and
  because of that the sidebar toggle, used ten times a day, had to go to ⌃S and ⌘B.
- **A new feature with no Chrome analogue has no obvious home.** Spaces already
  took ⌥⌘↑/↓ by elimination. The next one will be worse.

**What we get:**

- Migration cost close to zero at the keyboard, which is where the person spends
  the day.
- Divergence becomes an explicit decision: if it is not Chrome, there is a comment
  in the code saying why.
- The keymap is reconfigurable (`bind`, `rebind`, `unbind`, `reset`), and only the
  *delta* goes to disk — so changing a default later reaches everyone who never
  rebound it.

## How this regresses

It regresses through the finger, and the symptom is always the same: **the person
presses and something else happens.** Nobody files an issue about that. The person
presses, gets startled, undoes it if they can, and switches to the mouse. We see a
drop in keyboard use, not a bug.

What the person would notice:

- **⌘S saved the page instead of opening the sidebar** (or worse, the inverse: ⌘S
  hid the sidebar and the save never happened). That is the ADR-0012 collision and
  it is the most likely one.
- **⌘D "made the tab disappear"** — in the head of someone coming from Chrome,
  bookmarking does not move the tab. Here it moves to another group in the sidebar.
- **⌘9 went to the ninth tab instead of the last one.** The `for index in 1..=9`
  loop produces `SelectTab { index: 9 }`; the "9 = the last one" semantics live in
  `selectTabByIndex` in the core. Somebody touches the reducer, 9 becomes a
  literal, and only people with more than nine tabs notice.
- **⌘[ stopped working.** Somebody uses `rebind` instead of `bind` during a
  refactor, and `Back`'s second chord silently disappears. Half the users notice
  nothing; the other half think "going back broke sometimes".
- **⇧⌘T stopped reopening.** `ReopenClosedTab` depends on `closed_tabs` in the
  core. If the list stops being fed, the shortcut responds and does nothing — which
  is the worst failure mode there is: no error, no feedback, and the person presses
  three times thinking it did not register.

**The locks**, and they come in two halves because the regression above has two
halves — *which* key a command is on, and whether pressing that key arrives.

- `the Chrome shortcuts a switcher already has in their fingers` walks 14
  command/chord pairs and fails by naming which command is on the wrong key.
  That is the first half. On the Rust side it is joined by
  `the_chrome_shortcuts_our_users_already_know_are_all_there`,
  `escape_stops_a_load_the_way_it_does_in_chrome`, `every_digit_selects_a_tab`
  and `a_command_can_have_more_than_one_chord` — that last one is what keeps ⌘[
  from evaporating.
- `every chord in the keymap reaches its command from a real key press` is the
  second half, and until it went on this line the second half had no lock at
  all. Every test above reads the keymap; none of them presses anything. "⌘[
  stopped working", four bullets up, is precisely a chord that is still in the
  table and no longer arrives, and it happened — ⌘[, ⌘], ⌥⌘← and ⌥⌘→ all did
  nothing while every table test stayed green (ADR-0012 records the whole
  list). A fence that cannot fail on the failure it describes is not a fence.

**Correction to the record, not to the decision.** The four Rust tests above
were named in this paragraph and not on the `Lock:` field, which by
`docs/adr/README.md` Rule 1 means they were not locks. They are on the field
now, along with the key-press test. What was decided has not changed.

**What still has no test:** the "⌘9 = last tab" semantics. The table proves ⌘9
fires `SelectTab { index: 9 }`, not that 9 means the last one.

## When to revisit

- If the audience stops being mostly Chrome users. Then the reference changes.
- If a Chrome default changes. Case by case: align, or diverge with a comment,
  never let it happen without someone deciding.
- If ⌘D causes repeated confusion in real use. Bookmark and pin may need to be
  separate things — and then it is ADR-0014 that changes, not this one.
- When a Linux shell exists and Chrome's keymap on Linux gets consulted directly.
  See ADR-0012: the `primary` model was built for that.
