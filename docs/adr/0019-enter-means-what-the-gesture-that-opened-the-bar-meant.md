# ADR-0019: Enter means what the gesture that opened the bar meant

- **Status:** Accepted
- **Date:** 2026-03-02
- **Lock:** `crates/zer0-core/src/command_bar.rs::open_location_navigates_the_tab_you_are_looking_at`, `crates/zer0-core/src/command_bar.rs::open_location_does_not_pile_up_tabs`, `crates/zer0-core/src/command_bar.rs::open_location_with_nothing_open_opens_a_tab`, `crates/zer0-core/src/command_bar.rs::picking_an_open_tab_switches_to_it_either_way`, `crates/zer0-core/src/command_bar.rs::new_tab_leaves_the_page_you_are_on_alone`, `apple/Tests/Zer0ShellTests/CommandBarFocusTests.swift::CommandBarDestinationTests/openLocationNavigatesHere`

## Context

ADR-0015 unified ⌘T and ⌘L into one command bar and put the ranking in the
core. That part holds and is not in question here.

What it also did, without arguing for it, was make every destination open a new
tab. ADR-0015 listed the cost in its own consequences — "⌘L, which in an
ordinary address bar navigates the current tab, opens another one here; it
diverges from Chrome on the most frequent gesture of all" — and shipped anyway.

That put two accepted decisions in direct contradiction. ADR-0011 says the
shortcuts are Chrome's, because our audience are Chrome users and a shortcut
already in someone's fingers has to do what those fingers expect. ⌘L is the
single most-used shortcut in a browser. Diverging there is not a quirk, it is
the loudest possible place to be surprising.

The failure mode is not a bug report. It is someone pressing ⌘L thirty times an
hour, ending the afternoon with forty tabs they did not ask for, and concluding
that this browser is exhausting. Nobody files that.

ADR-0015 predicted this revisit almost exactly, including where the change
would land: "Enter vs ⌘Enter, which changes `accept` and not the ranking".

## Decision

The bar carries the intent of the gesture that opened it, and Enter honours it.

- **⌘L navigates the tab you are on.** It seeds with the current URL, selected,
  so typing replaces it.
- **⌘T opens a new tab.** The bar starts empty.
- **⌘Return, or ⌘-click, overrides** — the standard escape hatch out of an
  address bar, in the direction people actually want it (this one, but new).
- **Picking an existing tab always activates that tab**, whichever gesture
  opened the bar. Switching to something already open is never a request for a
  second copy of it.
- **⌘L with nothing open falls back to opening a tab.** Enter that does nothing
  is the one outcome nobody wants, and "there is no current tab" is not the
  person's problem to solve.

The intent is a core type, `CommandBarIntent`, and what it means is a core
function: `accept(browser, intent, suggestion) -> Action`. The shell carries the
intent and hands it back; it does not interpret it. Neither match has a wildcard
arm, so a new intent or a new kind of suggestion breaks the build rather than
falling through to whatever the last case happened to be.

Seeding follows from the same intent rather than a separate flag, so one concept
drives both what is in the bar and what Enter does with it. Two flags that must
agree eventually disagree.

## Consequences

**One bar now does two things, and that is a real cost.** ADR-0015's cleanest
claim was that there is one surface with one behaviour. There is still one
surface, but its behaviour depends on invisible state — which key opened it.
Someone who opens the bar with ⌘L, changes their mind, and wants a new tab has
to know about ⌘Return. We mitigate with a hint row that names the live binding,
but a hint is weaker than an interface that cannot be misread.

**The escape hatch is not locked by a test.** ⌘Return needs a key window and a
real event loop, which the Swift suite does not drive. What is locked is
everything behind it: the core opens a tab when asked to override. If ⌘Return
misbehaves it will be the SwiftUI key-equivalent registration, and no test will
catch it. This is a real gap, named rather than hidden.

**We are now more Chrome-like, which cuts both ways.** The whole premise of this
browser is that the Arc-style model is better. Every place we converge on
Chrome, we trade distinctiveness for familiarity. That trade is right for the
most frequent gesture in the product and wrong as a general policy — a browser
that resolves every disagreement in Chrome's favour is a worse Chrome.

**Ephemeral-tab flows lost their accidental engine.** Opening a tab per
destination produced a pile of "Today" tabs that auto-archiving then cleaned up.
That was never designed, but anything downstream that assumed it must now stand
on its own.

## How this regresses

Someone simplifies `accept` back to a single path — most plausibly while adding
a new suggestion kind, where handling one intent looks like less work than two —
and ⌘L quietly starts opening tabs again.

The symptom is not an error. It is tab count climbing through the day, and the
sense that the browser hoards. By the time anyone connects that feeling to a
keystroke, weeks have passed.

`open_location_does_not_pile_up_tabs` is the one that screams: it drives the
whole reducer and asserts the tab count did not move. The others pin the
individual paths.

## When to revisit

If ⌘L navigating the current tab turns out to lose work — someone on a page they
wanted, who typed over it and cannot get back cheaply. Back exists, but a
navigation that destroys context is worse than one that does not.

The fix then is not to undo this. It is to make the current tab cheap to
preserve: a modifier that promotes to a new tab, better surfaced than ⌘Return is
today, or treating "typed over a loaded page" as something back should undo in
one press.

Not before: for that to be the answer, the complaint has to be about losing a
page, not about the shape of the model.
