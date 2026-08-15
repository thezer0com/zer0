# ADR-0015: One command bar, with the ranking in the core

- **Status:** Accepted, superseded in part by ADR-0019 — the ranking and the
  single bar stand; "every destination becomes a new tab" does not — and in part
  by ADR-0082, which reverses the order: what was typed ranks first
- **Date:** 2026-02-19
- **Lock:** `apple/Tests/Zer0ShellTests/CommandBarFocusTests.swift::CommandBarFocusTests/newTabStartsEmpty`, `apple/Tests/Zer0ShellTests/CommandBarFocusTests.swift::CommandBarFocusTests/openLocationSeedsTheUrl`, `apple/Tests/Zer0ShellTests/CommandBarFocusTests.swift::CommandBarFocusTests/pendingUrlWins`, `crates/zer0-core/src/command_bar.rs::an_open_tab_outranks_history_for_the_same_page`, `crates/zer0-core/src/command_bar.rs::the_fallback_survives_a_full_result_list`, `crates/zer0-core/src/command_bar.rs::a_prefix_match_beats_a_scattered_one`, `crates/zer0-core/src/command_bar.rs::a_shorter_match_beats_a_longer_one`, `crates/zer0-core/src/command_bar.rs::frequently_visited_pages_float_up`, `crates/zer0-core/src/command_bar.rs::a_huge_string_scores_without_overflowing`, `crates/zer0-core/src/command_bar.rs::a_huge_history_entry_does_not_break_ranking`, `apple/Tests/Zer0ShellTests/NavigationRoundTripTests.swift::AirTrafficTests/routeDestinationIsVisibleUpFront`

## Context

In a traditional browser, "I want to go somewhere" is spread across four surfaces:
address bar, search box, tab list and history. The person has to decide *where to
look* before looking. Worse: they open a second copy of a page that is already open
in the next tab over, because the address bar knows nothing about tabs.

And there is a problem that comes before that one. With no permanent address bar
(ADR-0010), "typing an address" **needs** somewhere to happen. It is not a
convenience; it is a requirement.

The project's architecture decision says ranking is behavior, and behavior goes to
the core. Suggestion ranking is the easiest thing for two platforms to disagree
about — and disagreeing here means Enter does different things on the Mac and on
Linux.

## Decision

**⌘T and ⌘L open the same bar.** The only difference is what is already inside:

```swift
/// ⌘T opens the command bar rather than a blank page: you almost always
/// know where you are going.
public func openTab() { openCommandBar(seededWithCurrentURL: false) }

/// ⌘L: same bar, seeded with where you already are so it can be edited.
public func focusCommandBar() { openCommandBar(seededWithCurrentURL: true) }
```

⌘T does not open a blank page. Someone who presses ⌘T almost always already knows
where they are going; handing them an empty page forces one extra step to say what
they already knew.

**The ranking is `command_bar::suggest` in the core**
(`crates/zer0-core/src/command_bar.rs`). The shell receives an ordered list and
draws it. The order:

1. **Open tabs** beat everything — switching beats opening a second copy. A URL
   that is already in a listed tab does not even appear as history.
2. **History**, with a capped frecency bonus (`visit_count.min(20) * 2`),
   deliberately below the match scores: a popular page must not beat a good textual
   match.
3. **The interpretation of what was typed**, always last and always present.
   `let room = limit.saturating_sub(1)` reserves the final slot for it. It is the
   escape hatch: even with zero results, Enter does something.

The fuzzy match rewards start of string, word boundary and contiguous runs — that
is what makes "gh" rank `github.com` above a page containing g...h scattered around.
The run bonus is deliberately weighted **above** the boundary bonus, so "git" in
"github.com" beats "git" in "a-g-i-t-hub".

A title match is worth more than a URL match (`* 3 / 4`), because the title is what
the person reads.

**`MAX_SCAN_CHARS = 1024`** solves two problems with one limit. "View Source"
records `data:text/html,...` URLs of hundreds of kilobytes into history, and pasting
one of those into the bar could overflow the run bonus and bring down the debug
build. On top of that, scanning that on every keystroke is time nobody has.

An empty bar shows recent history, not a search for nothing.

**An empty list is still a screen** (`emptyState` in `CommandBar.swift`): with no
query, it teaches what the bar accepts and shows ↑↓ / ↩ / ⎋; with a query, it says
it found nothing, naming the term. A field floating on its own is not an answer.

**The bar warns before, not after:** if a suggestion would open in another space
because of a routing rule, the space name appears as a chip on the row —
`destinationSpace` — so the person knows where they will land before confirming.

The pointer owns the highlight while it is over the list, so mouse and keyboard
never disagree about what Enter would do. And only keyboard movement scrolls the
list: scrolling on hover would drag the row out from under the pointer, which would
hover the next one, which would scroll again.

## Consequences

**What hurts:**

- **⌘T no longer gives a blank page.** Anyone who uses ⌘T to "open empty space and
  think" lost that. There is neither a new tab page nor a path to one.
- **Every destination becomes a new tab.** `accept` calls `openInNewTab` for
  `openHistory`, `navigate` and `search`. ⌘L, which in an ordinary address bar
  navigates **the current tab**, opens another one here. That diverges from Chrome
  on the most frequent gesture there is, and it piles up tabs without the person
  asking.
- **The URL lives in a modal.** You cannot see the address and the page at the same
  time. A direct consequence of ADR-0010, and it is charged here.
- **Good ranking is invisible; bad ranking is fatal.** Nobody praises the right
  order. One inversion sends the person to the wrong place with Enter — and Enter is
  a reflex, not a decision.
- **1024 characters is an arbitrary cut.** A legitimate title or address longer
  than that stops matching in the tail. Acceptable, but it is a limit chosen without
  field measurement.
- **The list has 8 items and one of them is fixed.** That leaves 7 for tabs plus
  history. With many tabs, history disappears from the list entirely.
- **Ranking in the core costs FFI per keystroke.** `updateSuggestions` calls
  `core.suggest` on every `onChange`. `bench_suggest` (ignored by default) exists
  precisely because this is the surface where latency shows up first.

**What we get:**

- One place to go anywhere. There is no "where do I look for this" decision.
- Switching to an open tab is the default, not a discovery.
- The ranking is identical on every platform, and it is testable without opening a
  window.

## How this regresses

It regresses as result quality, and nobody knows how to report result quality. The
person does not say "the ranking got worse". They say the browser "got dumb", or
they simply stop using the bar and go back to hunting for tabs by eye.

What the person would notice:

- **"It opened a page I already had open, again."** Tabs stopped beating history.
  The person ends up with three `github.com` open and blames themselves.
- **"I typed the whole address and Enter threw me somewhere else."** The
  interpretation of what was typed lost the final slot — `room` computed wrong, or
  the final `push` moved inside an `if`. The test
  `the_fallback_survives_a_full_result_list` exists exactly for this, with the
  message *"the escape hatch must never be crowded out"*.
- **"⌘T opened a blank page."** Somebody "fixes" ⌘T to behave like Chrome. The step
  where the person says where they are going disappears.
- **"⌘L no longer brings the current address."** The person wants to edit the end
  of the URL and finds an empty field. They have to type the whole address again —
  including on an error screen, where the address that failed is the only usable
  thing (`address_bar_text` returns the address that failed exactly for this).
- **"The bar froze while I was typing."** Somebody removes `MAX_SCAN_CHARS`, or
  copies the pattern without the limit. With a large history, every keystroke starts
  scanning everything. And with a big `data:` URL in history, the run bonus
  overflows again — in debug, a panic.
- **"The keyboard hint is gone."** `emptyState` becomes `EmptyView()` "because
  there was nothing to show". The bar starts opening as a field floating in the
  middle of the screen, and nobody discovers that ↑↓ navigate.
- **"It opened in a space I did not expect."** The `destinationSpace` chip
  disappears in a refactor. Routing keeps working; it just stops warning. The person
  finds out later that the tab ended up somewhere else.

**The locks:**

**Correction to the record, not to the decision.** The `Lock:` field used to
name `⌘T opens an empty bar rather than the current URL` and nothing else. That
test is real and it holds what it says — but read the title of this ADR and
then read the seven bullets above it. The title is "One command bar, **with the
ranking in the core**", every failure a person would notice is a ranking
failure, and not one line of ranking was on the field. The tests were all
written; they were listed here, in prose, and by this record's own rule
(`docs/adr/README.md`, Rule 1) a test named in prose and not on the line is not
a lock. They are on the line now. What was decided has not changed.

- `⌘T opens an empty bar rather than the current URL` — pins both halves of the
  decision: ⌘T opens the **bar** (`model.commandBarOpen`) and opens it **empty**.
- `⌘L opens the bar seeded with the current URL` — the symmetric pair.
- `⌘L while loading shows where you are going, not where you were` — seeding with
  the in-flight URL, not the old one.
- `crates/zer0-core/src/command_bar.rs::an_open_tab_outranks_history_for_the_same_page`
  — ranking rule number one, and it also checks that the URL is not offered twice.
- `::the_fallback_survives_a_full_result_list` — the escape hatch, and it is
  unchanged by ADR-0082: the typed interpretation still cannot be crowded out,
  it is simply kept at the top of the list rather than the bottom.
- `::the_typed_interpretation_is_always_offered_last` **is gone from the `Lock:`
  field, because the decision it defended was reversed by ADR-0082.** Its
  replacement is `::the_typed_interpretation_is_always_offered_first`, locked
  there rather than here — a test defending the opposite of what this file
  decided has no business on this file's fence. This is a correction to the
  record made necessary by a superseding ADR, not a change to what was decided
  here; what was decided here is in the sentence above it, and is now false.
- `::a_huge_string_scores_without_overflowing` and
  `::a_huge_history_entry_does_not_break_ranking` — the `data:` URL panic, with an
  explicit regression.
- `::a_prefix_match_beats_a_scattered_one`, `::a_shorter_match_beats_a_longer_one`,
  `::frequently_visited_pages_float_up` — the quality of the ranking itself.
- `apple/Tests/Zer0ShellTests/NavigationRoundTripTests.swift::AirTrafficTests/routeDestinationIsVisibleUpFront`
  — the space chip.

**What has no lock:** keyboard navigation of the list in `CommandBar` (wrap-around
in `move(by:)`, resetting the highlight when results change, scroll following only
keyboard movement). All of that is View `@State` and no test exercises it — it is
the untested half of this decision. To close it, `highlighted`/`keyboardMoves`
would have to leave the `View` for a testable type.

## When to revisit

- If "⌘L always opens a new tab" becomes annoying in real use. It probably needs a
  distinction between navigating here and opening over there (Enter vs ⌘Enter),
  which changes `accept` and not the ranking.
- If the bar stops keeping up with typing on a large history. `bench_suggest`
  already exists for that; the answer is an index in the core, not ranking in the
  shell.
- If the bar gains commands beyond navigation ("close duplicate tabs", "switch
  space"). Then `Suggestion` needs an action case and the ranking needs to know how
  to mix different types.
- If the fixed limit of 8 gets tight. It is a call parameter, not a core constant —
  cheap to change, but it changes the math of `room`.
