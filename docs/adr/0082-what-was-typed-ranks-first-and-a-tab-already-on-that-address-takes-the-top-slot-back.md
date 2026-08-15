# ADR-0082: What was typed ranks first, and a tab already on that address takes the top slot back

- **Status:** Accepted — supersedes the order half of ADR-0015
- **Date:** 2026-08-10
- **Lock:** `crates/zer0-core/src/command_bar.rs::the_typed_interpretation_is_always_offered_first`, `crates/zer0-core/src/command_bar.rs::the_fallback_survives_a_full_result_list`, `crates/zer0-core/src/command_bar.rs::an_address_you_already_have_open_switches_instead_of_opening_a_second_copy`, `crates/zer0-core/src/command_bar.rs::an_address_spelled_two_ways_is_the_page_you_have_open`, `crates/zer0-core/src/command_bar.rs::a_bookmark_outranks_history_and_loses_to_an_open_tab`, `crates/zer0-core/src/command_bar.rs::asking_is_offered_for_anything_typed_and_sits_last`, `crates/zer0-core/src/command_bar.rs::an_empty_bar_offers_no_way_into_chat`

## Context

ADR-0015 put the ranking in the core and decided its order: open tabs, then
bookmarks, then history, then the way into chat, and **the interpretation of
what was typed always last**. Last was where the escape hatch lived — the row
that exists so that Enter always does something, even with no results.

What that produces is a bar where pressing ⌘L, typing an address, and pressing
Enter goes wherever the ranking put its first guess. The person did not ask for
a guess. They typed an address.

This is the same argument ADR-0011 makes about the keyboard, one level up.
Chrome's omnibox puts what you typed on the row Return is already on, and our
audience are Chrome users with that in their fingers. Somebody who presses ⌘T
and types is overwhelmingly saying "go here" or "search this", and a reflex has
no arrow keys in it.

Against that stands ADR-0015's strongest claim, and it is not a small one:

> **"It opened a page I already had open, again."** Tabs stopped beating
> history. The person ends up with three `github.com` open and blames
> themselves.

Ranking the typed interpretation first hands that away by default — you type
`github.com`, you already have it open, and you get a second copy. So the
change is not the reordering on its own. It is the reordering plus the one
exception that keeps the thing the reordering would have cost.

## Decision

**The typed interpretation ranks first. The way into chat ranks last.** The
tiers, in `command_bar::suggest`:

1. **What was typed** — `Navigate` or `Search`, the row Enter is already on.
2. **Open tabs.**
3. **Bookmarks.**
4. **History.**
5. **The way into chat** — offered for anything typed, never for an empty bar.

Nothing between tiers 2 and 4 moved; ADR-0059's ordering stands entire, and so
does every rule about an address being offered once.

**The exception: if what was typed resolves to an address a listed open tab
already holds, that tab takes the top slot.** Typing an address you already
have open switches to it, which is ADR-0015's rule surviving exactly where it
was about to be lost. Typing anything else goes straight where you asked.

The typed row is **moved down, not dropped**. It is still the escape hatch,
and "open it again anyway" is a real thing to want from a bar that just decided
on somebody's behalf. Everything below keeps its order.

### Where the exception lives

In one function, `a_tab_already_on_that_address_takes_the_top_slot`, with one
caller, at the end of `suggest`. That shape is the decision and not an
accident: this is the clause most likely to be reconsidered — the author may
later prefer Chrome's plain behaviour — and reconsidering it should be deleting
a function and its call, not unpicking a ranking.

### What "the same address" means

`PageAnchor::of`, and nothing else. ADR-0060 already had to decide when two
addresses are one page, and its rule is reused here rather than rewritten:

- host case, a trailing slash, a default port and userinfo are punctuation;
- the query string is part of the address;
- `http` is **not** folded into `https`, and `www.` is **not** stripped.

A second normalisation here would mean "the same page" said one thing to the
command bar and another to the conversation about the page the command bar
opened, and the two would drift the first time either grew a clause. That the
comparison is between typed text and an address a navigation *committed* — the
site's own canonicalisation, after its own redirects — is the same footing
ADR-0060 reasoned from.

### The reservation, which did not weaken

`room` was `limit.saturating_sub(2)`: two slots held back, one for the typed row
and one for chat. It is now `limit.saturating_sub(1)`, and the typed row is
pushed into `out` **before** any ranked tier rather than appended after them. So
one reservation covers chat, the other is not arithmetic at all — the row is
already in the list before anything could crowd it out. The counts are
unchanged: a list of eight still holds six ranked rows, and a list of one still
holds the row that always works.

## Consequences

**What hurts:**

- **The first row is now a guess about grammar rather than a match.** `orbit`
  ranks as a web search above the tab called *Orbit* that is open right now.
  That is Chrome's behaviour and it is the trade being made deliberately, but
  the switcher half of this bar got quieter: switching costs one ↓ that it did
  not cost yesterday.
- **`www.` and `http://` open second copies.** Typing `avelino.run` while
  `https://www.avelino.run/` is open does not switch, because nothing is folded
  that the site has not folded itself. This is asserted rather than left to be
  found, in `an_address_spelled_two_ways_is_the_page_you_have_open`, and it is
  the price of having one rule for "the same page" instead of two.
- **A tab crowded off the list cannot take the top slot.** The exception moves a
  row that is already there. With more tabs matching than the list has room for,
  a tab holding the typed address that did not make the cut still yields a second
  copy. Typing a full address scores that tab very high, so this needs several
  tabs scoring higher still — real, and not fixed here.
- **The way into chat is now the row furthest from the finger.** ADR-0049 put
  it directly above the typed interpretation so it sat beside the thing it is an
  alternative to. It is still one keystroke from the bottom of any list, but a
  door at the end of a list of eight is discovered later than a door at the end
  of a list of two.
- **One list now has two rules in it.** "What you typed is first" is learnable in
  a day; "unless you already have it open" is learnable only by noticing. The
  top row changing shape on the last character typed is the moment somebody
  either understands this or finds it uncanny.
- **ADR-0015's cleanest sentence is now false.** "Open tabs beat everything" was
  the kind of rule a person can hold in their head. What replaces it is longer.

**What we get:**

- ⌘L, an address, Enter — and it goes there, which is what every Chrome user
  means by an address bar (ADR-0011).
- The duplicate-tab failure ADR-0015 was written to prevent is still prevented
  for the case it actually happens in: an address you have open and typed out.
- One rule for "the same page" across the whole codebase.
- All of it is still decided in the core, still identical on every platform, and
  still tested without opening a window.

### Which sentences elsewhere in the record are now false

**ADR-0015**, whose status now names this ADR:

- *"The interpretation of what was typed, always last and always present.
  `let room = limit.saturating_sub(1)` reserves the final slot for it."* — it is
  first and always present, and the reservation reads the other way round.
- *"Open tabs beat everything — switching beats opening a second copy."* — true
  only of the address that was typed. Against everything else, tabs are second.
- *"The list has 8 items and one of them is fixed. That leaves 7 for tabs plus
  history."* — two are fixed and have been since ADR-0049; six are left. That
  sentence was already stale and is corrected here rather than in place.

**ADR-0049**: *"The command bar grows `Suggestion::AskChat`, offered for
anything typed and never for an empty bar, sitting directly above the typed
interpretation."* — the first two clauses stand and are locked here; the third
is false. Chat sits last. Its file is untouched, per the precedent ADR-0060 set
for the same situation.

## How this regresses

**"I typed the address and it went somewhere else."** The typed row loses the
top slot — most plausibly because somebody sorts `out` at the end, or moves the
`push` after the tiers to keep the function reading top-to-bottom.
`the_typed_interpretation_is_always_offered_first` asserts it with an empty
browser and again with a tab, a bookmark and a history entry all matching, so a
version that only holds when nothing else does will not pass.

**"It opened a second github.com."** Somebody deletes
`a_tab_already_on_that_address_takes_the_top_slot` — and it will look like a
tidy-up, because it is a small function that reorders a list somebody else
already ranked. That is precisely the shape AGENTS.md names: the dangerous
regression is the one that reads as an improvement.
`an_address_you_already_have_open_switches_instead_of_opening_a_second_copy` is
the fence, and it also checks the typed row is still on the list one row down,
so "fixing" it by suppressing the duplicate row fails too.

**"It switched to the wrong page."** The comparison loosens — somebody strips
`www.`, or folds `http` into `https`, or compares raw strings because
`PageAnchor` is in the chat module and importing it from the command bar looks
odd. `an_address_spelled_two_ways_is_the_page_you_have_open` holds both
directions in one test, and neither half is satisfiable by a rule that is wrong
the other way. Its tab commits to `https://GitHub.com/docs/` deliberately: with
a tab whose address was already in normal form, string equality passed the test
and the lock defended nothing.

**"Enter did nothing."** The reservation arithmetic is re-tightened by somebody
who sees `saturating_sub(1)` next to two escape hatches and assumes it should be
`2`, or who moves the typed `push` into an `if`.
`the_fallback_survives_a_full_result_list` fills the list with twenty matching
history entries and demands the typed row survive, and it is the same test that
held this guarantee before this ADR — the guarantee did not change, only where
in the list it is kept.

**"The chat row moved again."** A new suggestion kind is appended after
`AskChat`, which is the natural place to append, or the `push` drifts up among
the tiers during a refactor.
`asking_is_offered_for_anything_typed_and_sits_last` is written against
`hits.len() - 1` rather than a literal index, so it fails on any list length —
and it asks a second time with a tab, a bookmark and a history entry ranked
under it, because a chat row pushed anywhere in an empty browser still comes
out last. It was green against exactly that mistake until it did.

**"⌘T offered to ask a question about nothing."** The empty bar grows a chat
row, because "offered for anything typed" gets simplified to "always offered".
`an_empty_bar_offers_no_way_into_chat` is unchanged by this ADR and stays.

**And the half no test covers.** Which row the keyboard starts on is `@State`
in `CommandBar`, exactly as ADR-0015 recorded, and this whole decision is worth
nothing if that is not row zero. It was verified by rendering the panel offscreen
under `ZER0_SHOT` and looking: the typed row is first, it carries the highlight
and the `↩ Search` hint, and the chat row is last. That is a photograph, not a
fence — closing it means `highlighted` leaving the `View` for a testable type,
which is the same debt ADR-0015 declared and this ADR does not pay.

## When to revisit

- **If the exception turns out to confuse more than it saves.** The honest exit
  is deleting `a_tab_already_on_that_address_takes_the_top_slot` and its call,
  which leaves Chrome's plain behaviour and one less rule to learn. Take that
  exit only on evidence about the *top row moving*, not on a general dislike of
  special cases.
- **If people start reaching for the bar to switch tabs and finding it slow.**
  The answer then is not to put tabs back on top; it is a gesture that means
  "switch", the way ⌘Return means "over there".
- **If `www.` or `http` duplicates show up in real use.** The fix is in
  `PageAnchor` and it is ADR-0060's decision to reopen, not this one's — and it
  would move what "the same page" means for conversations at the same time,
  which is the point of there being one rule.
- **If the list stops being eight rows.** `room` is derived from `limit` and the
  arithmetic still assumes exactly one fixed row at the bottom.
