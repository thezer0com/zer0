# ADR-0065: A tab belongs to one window, and a private window is a window onto an ephemeral space

- **Status:** Accepted
- **Date:** 2026-07-16
- **Lock:** `crates/zer0-core/src/reducer_tests.rs::a_new_window_opens_onto_the_space_you_were_in_with_a_tab_to_type_in`, `crates/zer0-core/src/reducer_tests.rs::a_private_window_opens_onto_an_ephemeral_space_of_its_own`, `crates/zer0-core/src/reducer_tests.rs::closing_a_private_window_takes_its_cookie_jar_with_it`, `crates/zer0-core/src/reducer_tests.rs::a_command_acts_on_the_window_that_is_in_front_and_not_the_one_behind`, `crates/zer0-core/src/reducer_tests.rs::the_last_window_refuses_to_close`, `crates/zer0-core/src/reducer_tests.rs::a_split_is_only_a_split_in_the_window_holding_both_panes`, `crates/zer0-core/src/storable_tests.rs::a_private_window_hands_a_backend_no_window_at_all`, `crates/zer0-core/src/storable_tests.rs::an_ordinary_window_is_still_written_down_with_where_it_was_looking`, `crates/zer0-core/src/store_tests.rs::which_window_held_what_survives_a_relaunch`, `crates/zer0-core/src/store_tests.rs::a_session_written_before_windows_comes_back_in_one_window`, `apple/Tests/Zer0ShellTests/ShortcutTests.swift::SeveralWindowTests/theSweepHoldsForTwoWindows`, `apple/Tests/Zer0ShellTests/ShortcutTests.swift::SeveralWindowTests/commandsFollowThePress`, `apple/Tests/Zer0ShellTests/ShortcutTests.swift::SeveralWindowTests/aPrivateWindowPersistsNothing`, `apple/Tests/Zer0ShellTests/ShortcutTests.swift::SeveralWindowTests/sessionRestoreKeepsWindows`, `apple/Tests/Zer0ShellTests/ShortcutTests.swift::SeveralWindowTests/theLastWindowFallsThroughToTheSystem`

## Context

There was only ever one browser window. ⌘N did nothing, ⇧⌘W did not exist, and
⇧⌘N — which every browser on this platform reserves for a private window —
created a Space.

Two accepted decisions already named this as their limit. ADR-0053's "When to
revisit" says the browser-window marker registers **one** window, and that
several of them make `frontmost` and `browserWindow` stop being distinguishable
in the way that decision assumes. ADR-0055 puts the claim on the top of the
window in the same marker, so a second window inherits it or is born with a
white band across the page.

The core had no window at all. `Browser` held one `active_space` and one
`active_tab`; `WindowRole` answered `.browser` or `.auxiliary`; the SQLite
schema stored the active space and the active tab as two singleton rows in
`meta`. Every one of those is a sentence with "the window" in it.

Three questions had to be answered before any of it could be built, and the
third is the one that decided the shape.

**What does ⌘N contain?** It cannot create a Space. A Space is a cookie jar
(ADR-0007), so a window on a new Space is a window where you are logged out of
everything — a private window nobody asked for, on the chord that has meant
"another window like this one" since Netscape. So ⌘N shows a Space that another
window is already showing.

**What is a private window?** An ephemeral Space *already is* this browser's
private mode: its own jar, no history, nothing on disk (ADR-0007, ADR-0023).
A second notion of privacy would be a second set of promises to keep, in a
second set of places, and the two would drift the first time somebody added a
feature that writes something down.

**What can two windows share?** They have to share a Space, because ⌘N says so.
They cannot share a tab: a `WKWebView` is one `NSView` and an `NSView` has one
superview, so the same tab in two windows is the same page being yanked out of
the first the moment the second draws it. That is a platform fact, not a
preference, and it is the fact the model is built on.

## Decision

**A tab belongs to exactly one window. A Space belongs to none.**

`Tab.window: WindowId` — one field, so the state that would let a page be in two
places cannot be written down. `Window { id, active_space, active_tab }` holds
where a window is looking and nothing else; `Browser` holds `windows` and a
`key_window`.

### ⌘N is another window onto the Space you are in, with one new tab

Same Space, therefore the same cookie jar, the same logins, the same rules. One
tab rather than none, because a window with nothing in it is a dead end you have
to press something else to escape — the same reason a new Space is seeded with a
tab.

### ⇧⌘N is a window onto a fresh ephemeral Space

`Action::OpenWindow { onto: WindowContents::NewPrivateSpace { .. } }` creates the
Space **and** the window in one dispatch, and the Space is ephemeral from the
instant it exists.

`Action::CreateSpace` gained an `ephemeral` flag for the same reason. Without it
the only way to make a private Space is create-then-`SetSpaceProfile`, and in
between those two dispatches the engine host has already been handed a
persistent `data_store_id` and turned it into a real directory. Flipping the
flag afterwards rebuilds the views onto a non-persistent store and leaves that
directory on disk with nothing pointing at it — a cookie jar unreachable from
the interface, which is precisely the leak ADR-0007 deletes jars to avoid.

Closing a private window closes the Space with it, jar and all, so it does not
leave an empty Space in everyone's sidebar saying somebody browsed privately.

### ⇧⌘W closes the window; the last one refuses

`remove_window` refuses to close the last window for the same reason
`remove_space` refuses the last Space: a browser with nowhere to draw a page is
not a state worth representing.

A refusal is not the same as nothing happening, though, and a chord that does
nothing is worse than one that does the ordinary thing. So ⇧⌘W over the last
window falls through to `performClose:` — the platform's own close, which asks
the window first, animates the way every other Mac window does, and takes the
app with it. What happens when the last window closes stays
`applicationShouldTerminate`'s decision (ADR-0017), not this one's.

The other direction is covered too: a window closed on the platform's side —
the red button, the Window menu, that fallthrough — tells the core, or the core
would keep a window full of live tabs that nobody can see.

### The window is named at the door, and nowhere else

This is the part that keeps the change small. Every reducer arm that does not
name a window reads `Browser::active_space()` / `active_tab()`, and those now
resolve **through `key_window`**. So the whole of multi-window dispatch is one
line at the one place every press already goes through: `handleKeyDown` sends
`Action::FocusWindow` for the window the press came from, then runs the command.
`windowDidBecomeKey` sends the same thing for a click.

The alternative was a window parameter on forty actions, forty call sites able
to pass the wrong one, and a rule enforced N times.

### What a window is, and what an `NSWindow` is

Which windows exist, what is in each, which is in front, and what a relaunch
restores are all behaviour, and all in the core. `NSWindow`, its size, its
position and the animation it opens with are the shell's. The core emits
`EngineCommand::OpenBrowserWindow` / `CloseBrowserWindow`; the shell materialises
a scene and the marker claims the identity the core queued.

### Session restore keeps which window held what

`StorableSession` grew `windows` and `key_window`; the schema grew a `windows`
table and a `tab_windows` table. Tables and not columns: this schema is created
with `CREATE TABLE IF NOT EXISTS` and has no migration step, so a column added
to `tabs` would never appear on a database that already exists and every read of
`tabs` would fail on exactly the machines with a session worth keeping.

A file with no windows in it — one written by the build before this — is
repaired rather than refused: every tab lands in one window. The pages are what
somebody kept; which window they were in is incidental to that.

### A private window is not written down, structurally

`StorableWindow::project` returns `None` for a window with no stored tabs. An
ephemeral Space hands a backend no tabs at all (ADR-0023), so a private window
has nothing to build an entry from. **There is no branch testing for "private".**
The window is absent because its pages are, which is the same shape as the rule
it inherits.

## Consequences

**A Space shown in two windows shows different tabs in each.** The sidebar lists
the Space's tabs filtered to this window. Two people would describe that
differently — "my tabs are split across windows" versus "each window has its own
tabs" — and only the second is true.

**Naming a tab moves it here.** ⌘1, a command-bar result and a routed URL all
mean "show me this, in front of me", and `set_active_tab` brings the tab into the
key window. That is the only honest answer when one view cannot be in two
windows, but it means a page can leave the window behind you when you go looking
for it by name. Cycling (⌃Tab), numbering (⌘1–9) and reopening an internal page
are all scoped to the window precisely so that only an explicit act does this.

**A Space has one split.** ADR-0042 puts the split on the Space so that leaving
and coming back finds the pair still there. Two windows on one Space therefore
share one `Option<Split>`, and `split_in` shows it only to the window holding
both panes — so the second window sees no split rather than two empty panes. If
both windows want a split in the same Space, the second overwrites the first.
Declared, not solved.

**⌘N and ⇧⌘N cross into auxiliary windows.** They are `opensItsOwnWindow` under
ADR-0053's rule, because a window arriving in front of you is exactly what you
pressed for. This means ADR-0053's sweep no longer gets to assert "nothing about
the browser changed" once at the end — two of the chords are supposed to change
it. The lock now reads the browser before each press and asserts per chord,
which is a stronger question than the one it replaced.

**⇧⌘N was `NewSpace` and is not any more.** Spaces moved to ⌥⌘N, where this
keymap already keeps the things Chrome has no name for (⌥⌘I, ⌥⌘U, ⌥⌘L). Anyone
with ⇧⌘N in their fingers for "new space" has to relearn it; everyone else has
had ⇧⌘N in their fingers for "private window" for fifteen years.

**Extensions see windows now.** `WKWebExtensionWindow` exists so an extension can
tell windows apart, and one instance standing for all of them told every
extension that ⌘N had never happened. There is one adapter per core window,
`openWindowsFor` returns all of them, `focusedWindowFor` returns the key one, and
`isPrivate` is read off *that window's* Space — it used to be read off the
browser's active Space, so an ordinary window reported itself private whenever
some other window was showing an ephemeral one.

**`didCloseTab(_:windowIsClosing:)` is no longer hardcoded `false`.** With ⇧⌘W it
is a real distinction, and an extension told that ten tabs closed one by one runs
its bookkeeping ten times over a window that is gone.

**An ephemeral Space still survives a quit as an empty Space.** That is ADR-0023
working as written — the Space is stored, its pages never are — and it means
quitting with a private window open leaves a Space row behind. Closing the window
first removes it entirely. This is inherited, not introduced, and it is the one
place the private-window promise leans on a habit rather than on a type.

**The counter that opens a scene is a shell mechanism, and it is ugly.**
`WindowGroup` gives no way to hand a value to the view that will host a window,
so the core's id is queued and claimed by the first marker to land in a window
without one. It is correct because windows open one at a time; it would not be
if two ever opened in the same run loop turn.

## How this regresses

**A command acts on the window nobody is looking at.** The whole failure mode of
ADR-0053, one dimension along, and it is silent by construction: a tab closes, a
page reloads, a zoom changes — in a window behind another one. Nobody reports it
as a bug; they report that the browser "did something weird", weeks later,
without a reproduction.

The path there is short and it looks like a cleanup. Somebody notices
`focusWindow` is sent on every key press and decides it is wasteful; or writes a
new `WindowRole` case and lets it carry no identity; or moves the `FocusWindow`
dispatch out of `handleKeyDown` into `perform`, which handles a key press and
misses a menu click. `theSweepHoldsForTwoWindows` presses **every chord in the
keymap** over the window that is not in front and asserts the other window's
tab, tab list and zoom are untouched; `commandsFollowThePress` is the narrow
version of the reported symptom.

**A new reducer arm reads the space's tabs where it means the window's.**
`tabs_in` and `tabs_in_window` are one character apart and only one of them is
right for anything a person can see. Three arms already had to be corrected
during this change — ⌃Tab, ⌘1–9 and reopening an internal page all stepped onto a
tab another window was showing, and `set_active_tab` then pulled that page across
the screen. The sweep is what caught all three.

**A private window becomes writable.** Most plausibly by someone adding a field
to `StorableWindow` — a title, a frame, a "was private" flag — or by making the
projection keep every window "for completeness". `a_private_window_hands_a_backend_no_window_at_all`
fails, and `an_ordinary_window_is_still_written_down_with_where_it_was_looking`
is the other half of the pair: the easy way to pass the first is to stop writing
windows down at all.

**⇧⌘N loses its `ephemeral`.** Someone tidies `OpenWindow` into
`CreateSpace` + `SetSpaceProfile`, because two smaller actions look better than
one that does two things. A persistent store is created and orphaned every time
somebody opens a private window, and nothing is visibly wrong.
`a_private_window_opens_onto_an_ephemeral_space_of_its_own` asserts the profile
handed to the host with the *first* `CreateWebView`, not the profile afterwards,
for exactly this.

**A `window_id` column is added to `tabs`.** It reads as the obvious shape and it
is the one this schema forbids: no migration step means the column never appears
on a database that already exists, every read fails there, and by ADR-0017 a
failed read detaches the store — so everyone with a session loses it and nobody
in the office sees it happen.

**Session restore pours everything into one window.** The lock is
`which_window_held_what_survives_a_relaunch`; its counterpart
`a_session_written_before_windows_comes_back_in_one_window` guards the opposite
mistake, where somebody makes a missing window row fatal and an older file stops
loading at all.

## When to revisit

- **When a window can show something that is not a Space** — a devtools window, a
  picture-in-picture, a profile switcher. `Window.active_space` is not optional
  today, and making it so is a decision rather than a refactor.
- **When two windows both want a split in one Space.** The honest fix is moving
  `Split` off the Space and onto the window, which costs ADR-0042's "leave it and
  come back and the pair is still there" and needs a decision of its own.
- **When the interface gets an ephemeral indicator.** A private window is the
  obvious place for one, and it is the missing half of ADR-0023's complaint that
  nothing on screen says what is not being recorded.
- **When there is a second host (Linux).** `WindowId` and `Window` say nothing
  about `NSWindow`, which is the bet; what is untested is whether a host that
  draws its own decorations wants the same lifecycle, and whether "the key
  window" means the same thing under a compositor that has no such notion.
- **If two windows can ever open in the same run loop turn.** The queue the shell
  claims identities from is ordered and assumes they cannot. Restoring three
  windows at launch would be that case, and today the restored windows are drawn
  by scenes that already exist rather than opened one by one.
