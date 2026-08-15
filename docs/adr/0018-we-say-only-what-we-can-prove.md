# ADR-0018: We say only what we can prove

- **Status:** Accepted
- **Date:** 2026-02-27
- **Lock:** none — debt

## Context

Every find-in-page bar in existence shows "3 of 17". It is the standard, it is what
the person expects, and it is nice to draw.

`WKFindConfiguration` does not give you that. `WKFindResult` reports
**`matchFound`** — a boolean — and nothing else. No total, no index, no position.

Faced with that there are three ways out, and two of them are traps:

1. **Make it up.** Inject JavaScript that counts occurrences in the DOM and show
   that number next to a navigation WebKit is driving on its own. The number exists,
   it looks right, and it disagrees with what the browser is doing. On a page with an
   iframe, shadow DOM or virtualized content, it disagrees a lot.
2. **Leave the space empty.** Do not lie, but do not say anything either. The person
   types, WebKit takes half a second on a long page, and the bar sits still. Still is
   indistinguishable from broken.
3. **Say exactly what is known.** Which is what this ADR decides.

This is not about the find bar. It is about **how the interface speaks**, and the
find bar is where the rule shows up most naked.

## Decision

**The interface only asserts what the layer beneath it can back up.** Where the data
does not exist, it does not fill the space with a plausible number: it says what it
knows, or it says it does not know yet.

The comment in `apple/Sources/Zer0Shell/FindBar.swift` is the rule written down:

> What the bar can honestly say. `WKFindConfiguration` reports a hit or a miss
> and nothing else, so there is no match count here and none is invented to fill
> the space.

The state is a closed enum of five cases, and each one corresponds to a fact:

| State | Fact | What shows |
|---|---|---|
| `idle` | there is no query | nothing |
| `pending` | the query changed; this one has not been searched yet | `↩ to search` |
| `searching` | WebKit is answering | spinner |
| `found` | `matchFound == true` | ✓ Found |
| `notFound` | `matchFound == false` | No matches (red) |

Two of those cases exist only so the bar does not lie by omission:

- **`searching`** exists because WebKit answers asynchronously, and "a bar that says
  nothing while it waits looks broken on a long page" (comment in `PageActions.swift`).
  The absence of an answer is a fact, and it has a representation.
- **`pending`** exists because of `searchedFor`: without it, a "No matches" from the
  previous term would sit next to freshly typed text. The state would be true about a
  question nobody is asking anymore. `guard searchedFor == query else { return
  .pending }` is the bar saying "what you are reading is not about what you just
  typed".

The same principle shows up elsewhere:

- **Navigation errors** (ADR-0016): `unknown` is the only case that displays the
  engine's message, and the comment says why — the category is the shell **admitting**
  it does not recognize the failure, and in that case what the engine said beats a
  guess.
- **The session warning** (ADR-0017): the UI says "nothing is being saved" because it
  is true, instead of letting the person assume they are protected.
- **Tooltips** (`FindBar.tooltip`, `Sidebar.tip`): they read the live keymap instead
  of writing the chord by hand, "so rebinding a shortcut does not leave a lie behind
  in the tooltip". A tooltip with a hard-coded shortcut is an assertion with an expiry
  date.
- **`Close Space…`**: the dialog says how many tabs go with it ("All 7 tabs open in
  it close too"), not "Are you sure?". The comment: *"Says what is actually about to
  be lost. 'Are you sure?' is not a warning, it is a speed bump."*
- **A disabled menu item instead of an ignored one**: `Close Space…` is `.disabled`
  when there is only one space, "rather than letting the core silently ignore it keeps
  the menu honest". A control that accepts a click and does nothing is a lie of
  affordance.

## Consequences

**What hurts:**

- **The find bar is objectively less informative than any competitor's.** "Found"
  against "3 of 17" is a real loss of useful information, not just of ornament. Not
  knowing how many occurrences exist changes the decision to keep looking or refine the
  term. This is the direct cost and there is no consolation for it.
- **It will look unfinished.** Someone opening ⌘F for the first time will assume the
  count "has not been implemented yet". The decision not to lie looks like
  incompleteness, and there is no way to signal the difference in the UI itself.
- **`pending` is a state competitors do not have.** `↩ to search` is a new concept for
  anyone expecting incremental search. Honest, and still a step to learn.
- **The rule is expensive to keep.** Every new surface demands the question "what
  backs this up?", and the lazy answer (show the plausible value) is always faster to
  write.
- **Honesty can become an excuse not to investigate.** "The API does not give it" is
  true of `WKFindConfiguration` today, but it is also the sentence that stops someone
  from looking for a better path. The rule is about not *inventing*, not about
  accepting the first limitation you hit.
- **`found` defaults to `true`.** `lastSearchFound` initializes to `true`. It only
  fails to leak because `status` filters on `query.isEmpty` and on `searchedFor`. It is
  correct by composition, not by construction — a default that asserts success with no
  search behind it.

**What we get:**

- When the interface asserts something, you can trust it. That compounds: it holds
  for everything it says afterwards.
- Waiting and "I have not asked yet" are real states, so no screen sits still without
  an explanation.
- Tooltips and dialogs do not expire, because they read the source instead of
  repeating what it used to say.

## How this regresses

This is the only ADR in the set whose regression makes the interface look **better**.
Adding "3 of 17" is a change everybody praises in the PR. No test goes red, the screen
looks more like Chrome, and the number is wrong on any page with an iframe.

The damage does not show up on the day of the change. It shows up months later, when
the person notices the number does not match what ⌘G walks through, and starts to
**distrust everything the bar says**. And from then on they distrust the rest of the
interface too. Trust is not lost one surface at a time. It is lost whole.

What the person would notice:

- **"The counter says 17 but I only went through 4."** JavaScript counting the DOM
  while WebKit navigates by another criterion. On a page with an iframe or virtualized
  content, the divergence is large and constant.
- **"It says no matches, but it is highlighted on screen."** `searchedFor` disappeared
  in a refactor, and the previous term's status is sitting next to the new text.
- **"Everything vanishes while I type."** The `searching` case was removed "because it
  is fast". On a long page the bar blinks and goes mute for half a second. The person
  assumes the search did not take and types it again.
- **"The tooltip says ⌘G but I changed it to another key."** Somebody writes the chord
  by hand instead of calling `model.chord(for:)`. The assertion was true when it was
  written and nobody notices when it stops being.
- **"It asked 'are you sure?' and I lost seven tabs."** The close-space dialog goes
  generic. The person confirms by reflex — which is what "are you sure?" trains — and
  finds out afterwards what was inside.
- **"I clicked and nothing happened."** Somebody removes the `.disabled` from
  `Close Space…` and lets the core ignore it silently. An enabled control that does
  nothing is the same lie in another shape.

**No lock.** `FindBar.Status` is a `private enum` inside a `View`. No test touches it.
The find tests that do exist
(`apple/Tests/Zer0ShellTests/ShortcutTests.swift::find remembers the query so ⌘G can repeat it`
and `::closing find puts the bar away`) cover `PageFinder`, not what the bar **says**.

To lock it, in order of cost/benefit:

1. **Extract `Status` and the `status` function out of the `View`** (into its own
   type or `PageFinder`), and test the whole transition table: empty query → `idle`;
   new query not yet searched → `pending`; `isSearching` → `searching`; `matchFound`
   true/false → `found`/`notFound`. It is the test that prevents the stale "No matches"
   next to new text.
2. **A test asserting that no `Status` case carries a number.** It sounds strange as a
   test and it is exactly this ADR's invariant: assert that the rendered label contains
   no digit.
3. **`lastSearchFound` initializing to `false`**, or not being a loose boolean — a
   default that asserts success is the kind of thing that only fails to leak by
   accident.
4. **The tooltip reading the keymap**: a test that `tooltip(_:_:)` changes after a
   `rebind` would close the version of this rule that shows up in `FindBar` and
   `Sidebar`.
5. **The close-space dialog**: `closeSpaceWarning` is a `private var` in a `View` and
   has three branches (0, 1, n tabs). Extracted, it is a three-line test.

Until that exists, this is the easiest decision in the whole set to revert — and the
one nobody will notice being reverted.

## When to revisit

- If WebKit exposes a real occurrence count. Then "3 of 17" is **backed** and showing
  it becomes mandatory rather than forbidden. The rule does not change; what changes is
  what can be proven.
- If the missing count becomes a recurring complaint. The answer is not to invent the
  number: it is to measure what it costs to have a count that **drives** the navigation
  (our own find, with a real position), and then the number is true because we own it.
- Whenever a new surface shows a count, a percentage, a time remaining or a security
  status. The question is the same: what backs that number, and what does it say when
  the source does not know?
- If this ADR starts getting cited to justify not showing information we **could**
  obtain. Then it has become an excuse and needs rewriting.
