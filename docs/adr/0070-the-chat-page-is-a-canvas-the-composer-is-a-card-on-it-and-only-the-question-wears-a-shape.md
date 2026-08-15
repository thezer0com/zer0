# ADR-0070: The chat page is a canvas, the composer is a card on it, and only the question wears a shape

- **Status:** Accepted
- **Date:** 2026-08-03
- **Lock:** `apple/Tests/Zer0ShellTests/ChatPageTests.swift::ChatPageTests/theModelNamedIsTheOneTheRequestWillUse`, `apple/Tests/Zer0ShellTests/ChatPageTests.swift::ChatPageTests/nothingSetUpNamesNoModel`, `apple/Tests/Zer0ShellTests/ChatPageTests.swift::ChatPageTests/theSlotIsStopForEveryWayAnAnswerCanBeInFlight`, `apple/Tests/Zer0ShellTests/ChatPageTests.swift::ChatPageTests/everyStateThatDidNotFinishSaysSo`

## Context

`ChatPage` was assembled correctly and read badly. Every claim it made was
true — ADR-0018 is honoured line by line — and the screen was still one nobody
would want to look at. Five things, each defensible on its own and wrong
together:

1. **The composer was a bar welded to the bottom edge**: a full-bleed strip on
   `Surface.recessed` with a rule along the top. That is the shape a window has
   when the transcript is the product and the field is the price of using it.
2. **The empty screen was `EmptyState(icon: "sparkles", …)`** — a list saying it
   has no rows, on the screen most people meet first and most often, with the
   field they came to use pinned to the far edge of the window.
3. **Every message carried a rail and an SF Symbol in a 26pt gutter.** The
   reasoning behind it was right — "no bubbles: a browser is a reading surface,
   and two columns of rounded rectangles is a chat application pasted into one" —
   and the thing it produced was a debug view: `person.fill` and `sparkles`
   stacked down the left of a page whose whole argument is that it is for
   reading.
4. **Nothing on the screen said which model was answering.** The most
   consequential fact about a conversation was readable only from a settings
   pane two windows away.
5. **The measure was wrong, and the file said it was right.** `chatColumn` was
   680 with a comment claiming "about ninety characters at the body size". The
   reply is set in `Design.Text.detail`, which is `.callout` — 12pt, average
   advance 5.61pt over a paragraph of ordinary English. 680 is **121
   characters**. The ninety would have been true at `.title2` and at no size
   anything on that page is set in.

The bar this is measured against is a chat screen that is a mostly empty canvas:
a large greeting, the composer directly under it, the reply as prose, and a lot
of white.

## Decision

**The page is a canvas. The composer is a card that floats on it. Only the
question wears a shape.**

- **The composer floats and travels.** Rounded at `Radius.large`, on
  `.regularMaterial`, hairline `Palette.rule` border, `Elevation.resting`, with
  `Space.loose` of room on every side. It sits in the middle of the canvas while
  there is nothing to read and moves to the bottom when a transcript appears —
  one view, one `@State`, one cursor, animated on `Curve.entrance`. It is not
  two composers swapped over: that would be a cut, and it would take the
  half-typed question with it.
- **The empty screen is a greeting, not an empty state.** One line in
  `Design.Text.greeting` — the only serif in the shell — with the sentence that
  says what will and will not be read under it, and the composer beneath that.
  No glyph. `EmptyState` is deliberately not used: it owns the canvas it is
  dropped into, which is incompatible with the composer being the same view
  before and after the first question.
- **A question is a quiet pill against the right edge; an answer is prose with
  no ornament at all.** This refines the no-bubbles argument rather than
  reversing it. Two columns of rounded rectangles is still wrong. One side
  wearing a shape is what makes a transcript scannable — you find your own
  questions by their outline, and everything between two of them is the answer —
  while leaving the thing actually being read unornamented. `Metrics.askInset`
  keeps blank to the left of every question, so a pasted paragraph does not run
  the full measure and lose the asymmetry.
- **The composer names the model that will answer**, read through
  `modelThatWillAnswer(_:)` — the same function `ConfiguredChatHost.resolved()`
  builds the request from. It is the provider's own name for its own model,
  never a vendor this shell knows: the core does not name one (ADR-0051). With
  nothing configured it says so and opens Settings, because a blank is a claim
  too.
- **The measure is 450**, which is eighty characters of the type the reply is
  set in, and seventy-five of `.body` if it ever moves there. Eighty rather than
  the classical sixty-six because a reply carries fenced code and tables. The
  transcript takes `Metrics.leading` of extra line spacing: the system's line
  height for `.callout` is 15pt on a 12pt face, set for a label in a row rather
  than for a paragraph read to the end of.
- **The rhythm is two gaps, not one.** `Space.section` before a question,
  `Space.loose` before anything answering it, so one exchange reads as one
  block.
- **Escape stops an answer.** The Stop button has promised `⎋` in its tooltip
  since it was written and nothing implemented it; the key reached the core,
  where it means "stop loading this page". It is now claimed by the composer
  **only while there is an answer to stop**, and passed on otherwise.

Two things found on the way and fixed, neither of them cosmetic:

- **`ChatPage` had no observable dependency that changes when a reply arrives.**
  Every question it asks about a thread is a function call into the core, and a
  function call is not something the observation system can invalidate. The page
  redrew only when whatever hosted it happened to redraw. `BrowserModel`
  now carries `conversationRevision`, bumped once per dispatch, and the page
  reads it. Reading `snapshot` instead is the obvious fix and was measured not
  to work: a chat message changes no tab, no space and no download, so the new
  snapshot compares equal and nothing is invalidated.
- **`ToolResultRow` had a heading added.** The wrench in the gutter was the only
  thing saying what that block was; without a gutter, a monospaced card in the
  middle of a conversation could be a tool's answer, a quotation, or something
  the model wrote.

## Consequences

- The chat page no longer uses `EmptyState`, which every other empty screen in
  the shell does. §9 of `DESIGN.md` is updated to say so and why, so the next
  person does not "fix" it back.
- `Design.Text.greeting` adds a second display-sized token and a serif to a
  shell that had neither. `display`'s comment claimed it was the only thing
  above `.title2`; that claim is corrected in place.
- 450 is 230 points narrower than what was there. On a wide window the page is
  mostly margin. That is the intended result and the reason the greeting works
  at all.
- The measure is shared with `ThreadList` and the subject bar, so both narrowed
  too. That is deliberate and pre-existing: a different measure per screen reads
  as the content jumping sideways between them.
- The reply is still set in `Design.Text.detail`, a token whose stated job is
  "the descriptive line under a label or a title". It is the wrong token for the
  main content of a reading surface, and it is **not** changed here: the font is
  set inside `ChatProse`, which is being written by somebody else, and
  `Design.Text.detail` is shared with every settings pane in the browser.
  Declared, not fixed.
- `MessageRow` became internal so the harness can render the four states a
  message can end in. `interrupted` only ever arrives from a session restored
  after a crash and cannot be staged through the model.

## How this regresses

Each of these is something a person would see, and the first four are what the
lock is pointed at.

- **The footer names a model the answer did not come from.** Somebody
  reimplements `defaultModel ?? models.first` at the view instead of calling
  the one function, the file changes shape, and the two drift. Nothing looks
  wrong: a plausible model id sits in the composer and the reply comes from
  another one. Only comparing two outputs would show it.
- **The composer offers Send while an answer is arriving.** `conversationIsBusy`
  loses the tool clause or the `awaitingPage` clause — both look redundant, and
  neither is — and the one slot shows the wrong control at the one moment it
  matters. Pressing it sends a second question into a thread that is mid-reply.
- **An answer that stopped reads as an answer that finished.** A branch of
  `messageNotice` is deleted, or two of them are given the same sentence. Text
  simply stops on the page, exactly as it does when a model finishes early, and
  the reader is told nothing — or is told the wrong one of four different facts.
- **The composer cuts to the bottom instead of travelling**, because somebody
  splits it into a centred one and a docked one. The cursor and the half-typed
  question go with it. `ZZChatPageShots::theComposerTravels` sees this, and it
  is a harness rather than a lock: it runs only under `ZER0_SHOT=1`.
- **The reply stops appearing a word at a time.** `conversationRevision` is
  deleted as an unused counter — nothing reads it but one discarded expression —
  and the page goes back to redrawing whenever its host does. This has no test
  and is written down as debt below.
- **The measure creeps back up**, because a narrow column looks like wasted
  window. Every step of that is an improvement in isolation.

## When to revisit

- **If `ChatProse` settles on `.body` for the reply.** 450 is 75 characters
  there, still inside the band, but the leading was measured against `.callout`
  and should be measured again.
- **If a model becomes something you pick per conversation.** The footer is a
  label that opens Settings because there is nothing here to pick from; the
  moment the core can carry a per-thread model, it should become a control.
- **If the transcript grows a second ornamented side** — a name, an avatar, a
  timestamp per turn. That is the shape this decision is holding the line
  against, and if it is ever right, this ADR is what has to be argued with.
- **If `BrowserSnapshot` ever carries a conversation revision of its own.**
  `conversationRevision` exists only because it does not, and a counter in the
  shell standing in for a fact the core could state is worth deleting the day
  the core states it.
