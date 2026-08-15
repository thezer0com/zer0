# ADR-0012: The keymap lives in the core and is written against a `primary` modifier

- **Status:** Accepted
- **Date:** 2026-02-10
- **Lock:** `crates/zer0-core/src/shortcuts.rs::every_command_is_still_reachable_where_control_is_primary`, `crates/zer0-core/src/shortcuts.rs::save_wins_the_collision_and_the_sidebar_keeps_its_own_way_in`, `crates/zer0-core/src/shortcuts.rs::on_apple_control_and_command_stay_different_keys`, `crates/zer0-core/src/shortcuts.rs::primary_and_control_are_not_the_same_modifier`, `crates/zer0-core/src/shortcuts.rs::no_default_chord_is_bound_twice`, `apple/Tests/Zer0ShellTests/ShortcutTests.swift::KeyPressTests/everyDefaultChordIsReachable`, `apple/Tests/Zer0ShellTests/ShortcutTests.swift::ShortcutTests/modifiersAreNotConfused`

## Context

A shortcut is behavior, not appearance. By the project's rule, behavior goes to
the core.

The reason is not architectural purism, it is experience: a shortcut defined in
the macOS shell is a shortcut the Linux shell will get subtly wrong. It will not
get everything wrong — it will get *one* wrong. And the day ⌘/Ctrl+G does
something different on Linux and on macOS, we no longer have a browser, we have two
that look alike.

The concrete problem: on Apple, Command and Control are **different** keys.
Everywhere else, the main modifier *is* Control. A keymap that speaks "Command"
does not translate; one that speaks "Control" breaks on the Mac.

## Decision

**The whole keymap lives in `crates/zer0-core/src/shortcuts.rs`.** The shell does
not know which shortcut does what. `apple/Sources/Zer0Shell/Shortcuts.swift` only
translates `Chord` → `KeyboardShortcut`/`EventModifiers` and supplies menu names
(which are *copy*, and copy is localized per platform).

`Modifiers` has four fields, and two of them are the whole decision:

```rust
pub struct Modifiers {
    pub primary: bool,   // Command on Apple, Control everywhere else
    pub shift: bool,
    pub alt: bool,
    pub control: bool,   // literal Control — on Apple, a different key
}
```

Bindings are written against `primary`. ⌘T and Ctrl+T are not two bindings to keep
in sync: they are the same binding, rendered by each shell.

`control` exists separately because on Apple it is a real key and some shortcuts
use it (⌃Tab for next tab, ⌃S for the sidebar).

### The concrete case: ⌘S, ⌃S and the ⌘B fallback

This is why detection machinery exists instead of just a convention.

1. **⌘S is Save Page.** Chrome has it, the finger already knows (ADR-0011). We do
   not touch it.
2. **⌃S is the sidebar toggle.** Chrome has no vertical tab strip, so this
   shortcut is ours. On the Mac ⌃S is free and comfortable.
3. **And then Linux breaks.** Off Apple, `primary` *is* Control. ⌃S and ⌘S
   collapse into the same physical chord. One of the two becomes unreachable — and
   the worst part is that it does not error, it simply never fires.

The tie-break rule is written into the default: **Save wins**, because that is
what a Linux user expects from Ctrl+S. And the sidebar gets a path that does not
collide:

```rust
Binding {
    // Off Apple, Control *is* primary, so ⌃S would collide with
    // Save. This is the binding that works everywhere.
    chord: Chord::primary("b"),
    command: ToggleSidebar,
},
```

**⌘B / Ctrl+B is the universal fallback for the sidebar toggle.** On the Mac both
paths exist; on Linux there is one, and this is it.

### The function that detects the collision

`Keymap::unreachable_when_control_is_primary()` returns the commands left with no
path at all once `primary` and `control` collapse. It rests on two pieces:

- `collapsed(chord)` — the shape of the chord in a world where `primary ||
  control` is one thing;
- `command_for_collapsed(chord)` — who *wins* that collapsed shape, which is the
  first in the list, exactly as it would be at runtime.

A command is reachable if **some** of its chords wins its own collapsed shape.
`ToggleSidebar` loses with ⌃S and wins with ⌘B, so it passes. If ⌘B disappears,
`ToggleSidebar` shows up in the orphan list and the test goes red.

## Consequences

**What hurts:**

- **A chord that is comfortable on the Mac can be forbidden by Linux.** ⌃S is good
  on the Mac, but it forced a second binding to exist. Every shortcut with
  `control: true` carries that tax.
- **Commands with two chords have menus that lie by omission.** `chord_for` returns
  the **first** binding in the list. `ToggleSidebar` shows ⌃S in the Mac menu and
  ⌘B stays invisible. Declaration order in `with_defaults` became a UI decision
  without looking like one.

  **Factual correction.** This originally read "it works and nobody finds it".
  That was false when written, and the way it was false matters more than the
  sentence. There was no key handler in the shell at all: the menu item was the
  only path from a chord to a command, so a second chord was never registered
  with AppKit. ⌘B did not merely go unnoticed — it did nothing, and so did ⌘[,
  ⌘], ⌥⌘← and ⌥⌘→, along with every command that had no menu item (⌘S, ⌘P, ⌘F,
  ⌘G, ⇧⌘G, ⌘D, ⇧⌘M, ⇧⌘, , ⌥⌘I, ⌥⌘U, Esc, ⌘1–⌘9).

  The keymap was right the whole time and the tests agreed with it, because the
  tests exercised the table. Nothing tested that a key press arrives. The lock
  is now `apple/Tests/Zer0ShellTests/ShortcutTests.swift::every chord in the
  keymap reaches its command from a real key press`, whose helper carries a
  measured keycode table rather than echoing the chord back at itself — the
  first attempt did echo it, and passed while the browser stayed broken.
- **It costs one FFI crossing to draw a menu.** Every `CommandMenuItem` calls
  `core.chordForCommand`. It is cheap today, but it couples rendering to IPC.
- **The shell cannot have its own shortcut.** Anything new needs a new case in
  `UiCommand`, in the store's `command_to_row`/`command_from_row`, and in the
  `switch` of `perform` — which has no `default:` on purpose. Intentional friction,
  but friction.
- **The detection is static, it is not the Linux runtime.**
  `command_for_collapsed` models how we *think* it will collapse. If the Linux
  shell resolves conflicts differently (last-wins instead of first-wins), the test
  passes and the browser gets it wrong. There is no Linux shell today to confront
  that assumption.
- **`bind` lets the keymap reach a state the test does not cover.** The test runs
  over `with_defaults`. Someone who rebinds can strand themselves on Linux, and
  nothing warns them.

**What we get:**

- One keymap, one set of defaults, every platform.
- The most expensive divergence between platforms — which key is the main modifier
  — becomes a `bool` and a test, instead of becoming a field bug.
- The Linux port is a new host, not a rewrite of behavior.

## How this regresses

This one regresses in the quietest way there is: **it works perfectly on the
machine of whoever wrote it.**

What the person would notice:

- **On Linux, the sidebar does not open.** They press Ctrl+S expecting the panel
  and the browser opens the save-file dialog. They close the dialog. Try again.
  Dialog again. There is no error message, no log, nothing to report beyond "the
  sidebar does not open" — and on the developer's Mac it opens.
- **A shortcut becomes "works sometimes".** Two commands on the same chord make
  the behavior depend on list order. `bind` and `rebind` already take the chord
  away from its previous owner for exactly this reason, but a direct
  `bindings.push` in a refactor undoes the protection.
- **The Mac menu shows ⌃S and somebody "cleans up" ⌘B for looking duplicated.** It
  looks redundant, it is the only path that survives on Linux. That is the most
  likely regression in this entire ADR.
- **Somebody "simplifies" `Modifiers` by merging `primary` and `control`.** Every
  macOS test that does not look at ⌃Tab passes. ⌃Tab and ⌘Tab become the same
  chord, and switching tabs starts fighting the operating system's switcher.
- **The keymap migrates to the shell "because it is UI".** Each shell gets its
  own. The divergence shows up nowhere until the second host exists, and then it is
  a rewrite.

**The locks**, all of them now on the `Lock:` line:

**Correction to the record, not to the decision.** The `Lock:` field used to
name only `every_command_is_still_reachable_where_control_is_primary`. The six
tests listed below it were named here, in prose, and by this record's own rule
(`docs/adr/README.md`, Rule 1) a test named in prose and not on the line is not
a lock. That mattered more than bookkeeping here: the one test on the line
reads the keymap *table*, and the failure this ADR documents two paragraphs
above — every second chord, and every command with no menu item, doing nothing
— left it green from the first day to the last. The test that would have caught
it was written, named in this file as "the lock is now", and never moved onto
the field. It is on it now. Nothing about the decision changed.

- `every_command_is_still_reachable_where_control_is_primary` — fails by naming the
  orphaned commands (`no way to reach: [ToggleSidebar]`).
- `save_wins_the_collision_and_the_sidebar_keeps_its_own_way_in` — pins the
  *tie-break rule*: collapsed Ctrl+S is `SavePage`, and ⌘B still reaches
  `ToggleSidebar`. It is the test that breaks if someone inverts the priority "to
  make the sidebar easier".
- `on_apple_control_and_command_stay_different_keys` and
  `primary_and_control_are_not_the_same_modifier` — prevent merging the two fields.
- `no_default_chord_is_bound_twice` — prevents "works sometimes".
- `apple/Tests/Zer0ShellTests/ShortcutTests.swift::KeyPressTests/everyDefaultChordIsReachable`
  — the one that observes a *press* rather than the table. Every other lock on
  this line is satisfied by a keymap that is complete, correct and unreachable,
  which is the state this decision was actually found in.
- `apple/Tests/Zer0ShellTests/ShortcutTests.swift::ShortcutTests/modifiersAreNotConfused`
  — proves the translation in the Apple shell does not undo the model.

**What still has no lock:** that the keymap keeps *living in the core*. No test
prevents a hard-coded `.keyboardShortcut("k", modifiers: .command)` in a `View`.
And there is no stranding check over **custom** keymaps — only over the defaults.

## When to revisit

- When the Linux shell actually exists. `command_for_collapsed` is a hypothesis
  until it is confronted with a runtime.
- If a platform shows up where neither Command nor Control is the main modifier.
  `primary` still serves; it is the translation table that grows.
- If `chord_for` returns the wrong chord for the menu often. Then we need an
  explicit "primary chord" concept instead of "first in the list".
- If the per-menu-item FFI cost shows up in a profile. The way out is caching the
  keymap in the shell, not moving it there.
