# ADR-0076: A conversation stacks up from the composer, and a screen is photographed at the window it is used in

- **Status:** Accepted
- **Date:** 2026-08-09
- **Lock:** `apple/Tests/Zer0ShellTests/SourceRuleTests.swift::TranscriptAnchorTests/theTranscriptKeepsItsBottomAnchor`

## Context

ADR-0070 redesigned this page the day before this one was written. Every part of
it was defensible and the screen was ugly in the running application, and the
reason is worth more than the fix: **it was verified at the width of its own
text column.**

`ZZChatPageShots` photographed everything at 900 × 620. The text column is 450.
At that size a two-turn exchange nearly fills the viewport, the composer sits
just under it, and a rule across the top of the window is about twice the width
of the row beneath it. Nothing looks wrong because nothing has room to.

The window this browser is used in is around 1600 × 2000, which is about
1340 × 1960 of page once the sidebar and the title bar have taken theirs. Four
things that are invisible at 900 × 620 and decide the screen at 1340 × 1960:

1. **A `ScrollView` top-aligns content shorter than its viewport.** Measured on
   the two-turn exchange: the last reply ended 257 points from the top and the
   composer began at 1825, so roughly **1570 points of nothing** sat between the
   answer somebody had just read and the field they answer it in. This is the
   structural defect and the other three are small beside it.
2. **The subject bar's rule was full-bleed** — 1340 points of hairline under a
   450-point row, on an otherwise empty page. At 900 it reads as a header band;
   at 1340 it reads as a line somebody left behind.
3. **The page-context row was a filled card** carrying a sentence, the page
   title and its address in monospace — three lines and a fill, which made the
   heaviest object in every exchange the note that the browser had done the
   ordinary thing it says it does.
4. **The model name was set in `Design.Text.mono`**, ten-point monospace in the
   bottom-left corner of the composer, which reads as debug output left in the
   build rather than as a control.

The measure itself was re-measured before anything was changed to it, because
the whole of ADR-0070's column argument rests on one number. `NSFont` on this
machine, averaged over a paragraph of ordinary English:

| style | size | avg advance | 450pt | 680pt |
|---|---|---|---|---|
| `.callout` (`Design.Text.detail`) | 12.00 | 5.577 | **80.7 chars** | 121.9 chars |
| `.body` | 13.00 | 5.966 | 75.4 chars | 114.0 chars |

ADR-0070 is right. 450 is eighty characters of the type the reply is set in, and
680 really was a hundred and twenty-one. **The column was not the defect**, and
this ADR changes nothing about it.

## Decision

**A conversation stacks up from the composer. The empty room belongs above the
first message, not below the last.**

`.defaultScrollAnchor(.bottom)` on the transcript. One line, and it is not the
same job as the `scrollTo(last, anchor: .bottom)` a few lines above it: that one
moves a scroll offset while a reply streams, and a transcript shorter than its
viewport has no offset to move. They agree, so neither fights the other.

This is what a conversation is — what you just read next to what you are
answering it with — and it is also what converts a wide window from a fault into
margin. A 450-point column against the top edge of a 1960-point window is a
ribbon in an ocean. The same column with its ink resting on the composer is a
page with a wide margin, which is what a prose measure looks like in a wide
window and is the result ADR-0070 intended.

**The composer still travels**, from the middle of an empty canvas to the bottom
when a transcript appears. That decision is ADR-0070's and is untouched; the
empty state is unchanged.

Three things made quiet, none of which ADR-0070 decided:

- **The subject bar's rule stops where the column stops.** On the same vertical
  as the transcript and the composer, so the page has one left edge and one
  right edge rather than a rule belonging to nothing.
- **The page-context row is a line, not a card.** A glyph and `Read
  <shortened address>`, in `Design.Text.label`, secondary, no fill, with the
  exact address on the tooltip and verbatim on `ThreadList`. It says the one
  thing nothing else says — *this address was read, and the answers below start
  from it* — and the core emits one per page a thread is told about, so it can
  disagree with the subject bar, and the disagreement is the point of it. The
  page that could not be read keeps its whole sentence, because that one changes
  what the answer below is worth (ADR-0018).
- **The model's name is set as a label.** `Design.Text.mono` is for a string
  somebody compares to another string or retypes into a bug report. A model name
  is neither; it is the label on a control that opens Settings, and it is set
  like one. `modelThatWillAnswer(_:)` is still the one door and is untouched.

**And the harness photographs the window rather than the view.** Every scenario
in `ZZChatPageShots` is now taken at two sizes and the file name says which:
`wide` (1340 × 1960, the window the author uses) and `narrow` (600 × 520, the
smallest the app will open at). A page that is good at only one of them is not
done.

Two gaps in the harness were found by the same rule and closed:

- Three cases pinned their own size — 900 × 760 and 900 × 480 — and so were
  exempt from the suite's window even after it changed. They are not any more.
- **Nothing in the suite had ever rendered a `pageContext` message.** Every
  staged thread was about no page, so the card that dominated the screen had
  only ever been looked at by reading its source. `aThreadAnchoredToAPage` stages
  the real path: the core asks for the page, the host answers, the question goes
  out.

## Consequences

- `shortPage(_:)` moves out of `ChatPage` to file scope so the subject bar and
  the page-context line spell one address one way. Two spellings would have
  drifted into two different-looking addresses on one screen.
- The page-context row no longer shows the page's *title*. One line has room for
  one of them, and the address is what was fetched where the title is the page's
  own claim about itself. The tooltip carries the exact address; `ThreadList`
  carries it verbatim and unshortened.
- The comment in `ChatPage` that said the whole address is "on every
  page-context row in the transcript" was true and is not any more. It was
  moved to `shortPage(_:)` and corrected there rather than left to be
  discovered.
- **`Design.Text.detail` is still the reply's type, and it is still the wrong
  token for the main content of a reading surface.** ADR-0070 declared this and
  it is not paid here either: the font is set inside `ChatProse.swift`, and
  `Design.Text.detail` is shared with every settings pane, so paying it is a new
  token rather than an edit. The arithmetic above says what it would cost —
  a reply at `.body` wants a 477-point column to stay at eighty characters, 27
  points wider than today. Declared, not fixed.
- The suite is now twenty-two page shots instead of eleven and takes about twice
  as long. It is gated behind `ZER0_SHOT=1` and costs a default run nothing.

## How this regresses

- **Somebody deletes `.defaultScrollAnchor(.bottom)`**, because a `scrollTo`
  with `anchor: .bottom` sits eight lines above it and the two read as the same
  intent. They are not, and the difference only shows on a thread shorter than
  the window — which is every thread's first minute, on a large display, which
  is the moment the product is judged.
  `theTranscriptKeepsItsBottomAnchor` is what goes red, and it was watched going
  red before this was written: replacing the modifier with `.scrollDisabled(false)`
  fails it by name and prints the point count.
- **The harness goes back to one comfortable size.** Two sizes doubles the
  images and half of them look the same, so the obvious tidy is to keep the one
  that renders fastest. That is the exact mistake this ADR exists because of,
  and it has no lock: `ZZ*` cases are `.disabled` and cannot be locks
  (`docs/adr/README.md`). Written down as debt.
- **The page-context line grows back into a card**, one honest addition at a
  time: the title, then the address on its own line so it can be selected, then
  a fill to group the three. Each step is better than the one before it and the
  end of the road is what was there yesterday.
- **The rule goes full-bleed again**, because a hairline that stops in the middle
  of a window looks unfinished in a screenshot cropped to the column.

## When to revisit

- **When the reply stops being set in `Design.Text.detail`.** That is the one
  change that would move the column, and the number to move it to is measured
  above rather than left to be guessed at again.
- **If the composer ever stops being the bottom of the page** — a second field,
  a docked panel, anything under it. The anchor is aimed at the composer, and
  "stacks up from the composer" is only true while the composer is the floor.
- **When a harness can be a lock.** The thing this ADR actually decided is where
  ink lands, and what defends it is a scan for a string. If `check.sh` ever
  grows a way to run a harness and assert on the frame it produced — a bounded
  set, not the whole `ZZ` suite — the pixel measurement in
  `theComposerTravels` is the shape to copy, and this lock should be replaced by
  one that measures the void instead of spelling it.
- **If `NavigationSplitView` stops taking ~260 points.** The two window sizes are
  the page, not the window, and they were derived by subtracting the sidebar. A
  different sidebar means different numbers.
