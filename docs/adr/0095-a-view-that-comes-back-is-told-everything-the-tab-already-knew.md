# ADR-0095: A view that comes back is told everything the tab already knew, at one door

- **Status:** Accepted
- **Date:** 2026-08-10
- **Lock:** `crates/zer0-core/src/reducer_tests.rs::a_restored_tab_is_drawn_at_the_zoom_it_was_left_at`, `crates/zer0-core/src/reducer_tests.rs::a_restored_tab_at_the_ordinary_size_is_told_nothing`, `crates/zer0-core/src/reducer_tests.rs::a_rebuilt_view_keeps_the_zoom_and_the_mute_the_tab_already_had`

## Context

Page zoom in this browser was reported as missing. It is not, and the correction
matters because it changes what the defect is: ⌘+, ⌘− and ⌘0 are bound in the
core, `BrowserModel.perform` handles all three, `Action::SetTabZoom` clamps and
stores, `EngineCommand::SetZoom` reaches `webView.pageZoom`, `zoom_factor` is a
column in `session.sqlite`, and `ShortcutTests/zoomWorks` has been green
throughout. `KeyPress.chords` even carries the Shift-discounting rule that makes
⌘+ arrive at all.

What was broken is narrower and worse:

**A tab restored at 150% came back with the core saying 1.5 and the page drawn
at 1.0.** `rehydrate` builds a view per tab, loads the address and emits
`SetMuted` for a muted tab — and nothing at all for zoom. The value was
persisted correctly, restored into the model correctly, and never pushed at the
engine.

That is precisely the shape ADR-0018 forbids, in the least visible place: the
interface holds a number, the screen contradicts it, and every test that asked
what the core remembered was green. `⌘0` "resets" to a value the page was
already at; `⌘+` steps from 1.5 to 1.6 and the page jumps from 1.0 to 1.6.

The same gap existed through a second door. `rebuild_view` — which runs when a
Space's profile changes — restored neither the mute nor the zoom, so changing a
Space's user agent silently unmuted every tab in it and reset the type size.

A smaller finding beside it: **⌘= was unbound.** `+` and `=` are one physical
key, and on every layout it types `=` unshifted, so `Chord::primary("+")` is
really ⇧⌘=. Somebody pressing ⌘ and the key beside backspace — which is what the
chord is in every browser — got nothing.

## Decision

**Everything a fresh view has to be told to look like the tab it is for is
emitted from one function, and both restore paths call it.**

`restore_view_state(session, tab)` is that door. `rehydrate` and `rebuild_view`
call it; nothing else spells out what a view needs to be told. A rule enforced
at two call sites has one bug waiting, and this one had already happened at
both.

It emits only what differs from the engine's own default, so an ordinary tab
costs nothing at launch. The comparison is against `Tab::DEFAULT_ZOOM` rather
than a literal `1.0`, because the value being compared to is *the engine's
default* — a second literal elsewhere would be free to disagree with it.

**Zoom stays per tab, and is not moved to per site.** Chrome and Safari remember
per origin, it is what makes a site with tiny type permanently usable, and it is
the better product decision — but it is a different decision, and taking it in
passing would be wrong three times over. It is a **stored preference**, which
means somewhere for it to live: per Space, since a Space is an identity
(ADR-0007), never for an ephemeral one (ADR-0023), keyed by the canonical origin
every other per-origin decision here uses, and revocable from a screen that does
not exist yet. It also needs an answer for what a tab's own zoom means once the
site has one, which is a real interaction and not an implementation detail. None
of that is a one-line change, and the current behaviour is not a bug — it is a
smaller correct thing. The restore gap was the bug.

`allowsMagnification` stays off, unchanged, for the reason ADR-0074 gives: a
pinch would be a second zoom factor fighting the core's, and the core would not
know the page had moved.

**⌘= is bound to `ZoomIn` beside ⌘+.** Both, rather than one replacing the
other: a press arrives as whichever glyph the layout produced, `KeyPress.chords`
offers both spellings, and binding the pair is what makes either press land
without the shell deciding which one was meant. The menu still advertises ⌘+,
which is what every other browser prints and what `advertisedChord` picks by
taking the first binding.

## Consequences

**What hurts:**

- **Zoom is still per tab**, so a site with unreadable type is re-zoomed on
  every visit. This is the thing people will ask for, and this ADR explicitly
  declines to give it in passing.
- **Two chords for one command**, so the keymap has an entry whose only purpose
  is a keyboard-layout detail. Anybody reading the table will wonder.
- **`restore_view_state` is a list that has to stay complete.** It is one door
  rather than two, which is better, and it is still a list somebody has to
  remember to extend when a fourth piece of per-tab state appears. Nothing makes
  a new field on `Tab` break it.
- **Restoring the zoom means a visible reflow at launch** on a tab that was
  zoomed: the view is built at 1.0 and told otherwise a moment later.

**What we get:**

- The number the interface holds is the number on the screen.
- Changing a Space's user agent stops silently unmuting its tabs.
- ⌘= does what it does in every other browser.
- One place to add the next thing a restored view needs to know.

## How this regresses

**"My zoom keeps resetting when I restart."** The `SetZoom` is dropped from
`restore_view_state`, most plausibly by somebody who checks that `zoom_factor`
is restored — it is — and concludes the command is redundant.
`a_restored_tab_is_drawn_at_the_zoom_it_was_left_at` asserts on the command
rather than on the model, which is the whole point: the model was always right.

**"Every launch sends a command per tab."** The `!= DEFAULT_ZOOM` guard is
dropped for simplicity. `a_restored_tab_at_the_ordinary_size_is_told_nothing`.

**"Changing my space's user agent unmuted everything."** `restore_view_state`
stops being called from `rebuild_view`, or the two paths are re-inlined so they
can drift again. `a_rebuilt_view_keeps_the_zoom_and_the_mute_the_tab_already_had`
asserts both, from the action that really triggers the rebuild.

**"⌘= stopped working."** Somebody removes the binding as a duplicate. **No
lock** — `chromeBindings` checks the chords Chrome has, and Chrome's table
carries ⌘+ rather than ⌘=. The honest fence would be a test that a press of the
`=` key resolves to `ZoomIn` through `KeyPress.chords`, which is the shape
ADR-0012's replacement lock already uses for everything else. Declared debt.

## When to revisit

- **When zoom per site is worth doing properly**, which is soon: it is the
  behaviour people expect and the current one will read as a bug for as long as
  it lasts. The work is the storage decision, not the plumbing.
- **If a fourth piece of per-tab state appears** and somebody has to remember
  `restore_view_state`. That is the moment to make it derived from the tab
  rather than written out — a `Tab` that produced its own restore commands could
  not forget one.
- **If `allowsMagnification` is reconsidered.** ADR-0074 is the decision; the
  only thing that would change it is WebKit reporting the resulting factor back,
  so the core could stay the one that knows.
