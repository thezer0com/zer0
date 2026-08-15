# ADR-0090: The empty chat screen names its page and hands over the first question

- **Status:** Accepted
- **Date:** 2026-08-10
- **Lock:** `apple/Tests/Zer0ShellTests/ChatPageTests.swift::ChatPageTests/theEmptyScreenOffersAWayIn`, `apple/Tests/Zer0ShellTests/ChatPageTests.swift::ChatPageTests/aShortenedAddressIsReadableAndNeverPercentEncoded`, `apple/Tests/Zer0ShellTests/ChatPageTests.swift::ChatPageTests/aSiteIsNamedWithoutTheWwwNobodyReads`

## Context

The verdict on this screen, twice, was that it is ugly and unfriendly, against a
bar stated exactly: **we have to be friendlier than using the AI clients
directly.**

That bar has one honest answer and the screen was not giving it. Anybody can
open a tab on somebody else's website and get a field and a cursor. The only
reason to open this instead is that it knows the page you are looking at — and
the empty state was displaying that advantage in its ugliest possible form and
then doing nothing with it.

ADR-0070 and ADR-0076 fixed the structure of this page and neither is undone
here: the transcript is bottom-anchored, the composer is a card that travels,
the question is a pill and the answer is prose. What was left is what a person
actually meets.

**1. A percent-encoded URL was body copy.** The sentence under the greeting read:

> zer0 reads
> chromewebstore.google.com/detail/1password-%E2%80%93-password-mana/aeblfdkhhhdcdjpifhhbdiojplfjncoa
> to answer, and at no other moment

Three wrapped lines, on the emptiest screen in the browser, and `%E2%80%93` is
an en dash. Nobody reads a percent-encoded path and nobody recognises a page by
one either. The browser was holding the page's **title**, its **favicon** and
its **site** the whole time — the three things a person actually recognises a
page by — and printing the one thing they do not.

**2. The screen offered nothing.** This is the moment the browser knows what you
are looking at, and it asked you to type into a blank field. That is precisely
the experience of the thing it has to be friendlier than.

**3. The composer read as a disabled form field.** A grey slab with a scrollbar
artifact down its right edge and the model's name as a caption in the corner.

**4. The cluster was drawn for a component and placed in a window.** In a
1340-point window the greeting took about twelve per cent of the width. The
column itself is not the defect — 450 points is eighty characters of the type
the reply is set in, measured twice (ADR-0070, ADR-0076) — but the biggest
thing on an otherwise empty screen was twenty-six points, because that is the
top of the macOS text-style scale and there is nothing above it.

## Decision

**The empty screen names the page in the way a person recognises one, and hands
over the first question.**

### The page is a picture, a name and a site — never an address

A capsule above the greeting: the favicon `SiteBadge` already resolves through
`badge(for: Conversation)` (ADR-0083), the page's title, and the site. It is the
glyph slot of §9's empty-state pattern, filled with the one thing this screen
has that no website has.

The title comes from `Zer0::conversation_page_title`, which answers from a tab
showing the page, else from the last capture *of that exact page*, and `None`
when neither has ever said. It is never derived from the address: a title is the
page's own claim about itself and a hostname is not one (ADR-0018). With no
title, the site stands alone.

The sentence under the greeting keeps its whole job — *what is read and when* —
and stops naming the page, because the line above names it better. "zer0 reads
it to answer, and at no other moment."

`shortPage` decodes the path. It is display-only, the host is taken separately
and never decoded, and the exact address is on the tooltip here and verbatim on
`ThreadList` — so the usual objection to a decoded address, that it can be
dressed up to look like somewhere else, has nothing to work with.

### Three questions, pressable, that send

`startingPoints(pageWillBeRead:)`. Somebody who has never used this feature
learns what it is for by pressing one, which no amount of explanatory copy
achieves. Air Traffic and the command bar already teach by pre-filling a form
(§9); here the form is a conversation, so the first step is a question.

Two rules hold them honest:

- **They claim nothing about what the page says.** Each is a question a person
  might ask about anything in front of them — not a summary we are pretending to
  already have. The page has not been read and will not be until one is pressed.
- **None is offered when nothing will be read.** A thread whose page is closed
  reads nothing for the next question, and the screen says so two lines up. A
  chip saying "Summarise this page" under that sentence is one screen
  contradicting itself in the same breath.

They are copy, so they are in the shell: the words a person reads are the half
of AGENTS.md's split that follows the platform and the language. What a thread
is **called** is the other half and went to the core (ADR-0088), because two
shells disagreeing about that is two names for one conversation.

A starting point does not touch the draft. It is almost always empty — these are
only on screen before the first exchange — and discarding something somebody had
begun typing in order to send them a different question would be the interface
deciding what they meant.

`Wrap` is a `Layout` rather than a hard-coded arrangement: three pills fit one
line in the window this browser is used in and take two or three in the
narrowest it opens at, and neither is a number worth writing down.

### The composer is a surface, not a material

`.regularMaterial` blurs what is behind it, and behind this card there is
nothing but the canvas — so it resolved to its own flat tint, and the field
somebody is being invited to write in was a grey slab in the middle of an empty
page. It is now the page's own surface lifted off it by a hairline and a shadow,
which is what paper on a desk looks like and what a material there never could.
`DesignSystem.VisualEffect` makes the same argument for the command bar and
arrives at the opposite answer, because there really is a page behind that one.

### The greeting is a size the scale does not have

`Design.Text.greetingSize` is 40 points, reached through `.greetingType()`,
which is a `ViewModifier` holding `@ScaledMetric(relativeTo: .largeTitle)` — so
it still answers to the system's text size, is still written once, and is still
in `DesignSystem.swift` rather than at a call site. It is the one number in the
type scale and §12's refusal of raw point sizes is not what it breaks:
`Text.FieldSize` is the exception that really does stop following the text size,
and this one does not.

Forty rather than more, and the ceiling is the *narrow* window rather than the
wide one: at forty, "Ask about this page." is about 360 points, which still fits
on one line inside the 450-point column in the smallest window the app opens at.
Bigger is bigger in one window and two wrapped lines in the other.

Two more, both small and both visible:

- **`.scrollIndicators(.never)`.** A `TextEditor` is an `NSTextView` in a scroll
  view, and on a four-line field with two lines in it macOS still parked a grey
  bar down the right edge. That one artifact is most of what made the card read
  as a disabled control.
- **The model is a chip.** It has been a bare word in the corner through two
  rounds of this screen — ten-point monospace, which read as debug output, then
  a plain label, which read as a caption. Neither said the thing that matters,
  which is that it can be pressed. `modelThatWillAnswer(_:)` is still the one
  door and is untouched (ADR-0070); only its clothes changed.

## Consequences

- **The screen is taller.** Identity, greeting, sentence, card, three pills. In
  a 1340-point window that is the point — it was a small cluster drawn for a
  component and dropped into a window — and in the narrowest window the app
  opens at it is the thing to watch, which is why the harness photographs both.
- **A page nobody has opened has no title**, so a thread revisited a week later
  shows its site alone. That is honest and it is a visible difference between
  two threads on the same screen; the alternative was inventing a name out of
  the address.
- **The starting points are three English sentences in the shell.** A second
  shell will write its own, and a localisation will translate them. That is the
  cost of putting copy where copy belongs, and it is the same cost every other
  sentence in this shell already carries.
- **`Zer0::conversation_page_title` is a new FFI call on a drawing path.** It is
  a lookup over the tabs of one space, made once per draw of an empty
  conversation, and empty conversations have nothing else to draw.
- **`Wrap` is the first `Layout` in the shell.** It is forty lines and it is
  general; the next thing that wants to wrap should use it rather than write a
  second one.
- **`elevation(_:)` now flattens what it lifts, and that changes every panel in
  the shell.** Found here and not designed here: SwiftUI's `.shadow` is not a
  shadow cast by a panel, it is a style that reaches every leaf underneath it,
  so the card was casting one shadow for itself and one behind every piece of
  text on it. The chip had a halo half again its own size in the light-mode
  render, and the placeholder sat in its own grey haze. `compositingGroup()`
  before the shadow is the fix and it belongs at the one door rather than at
  this call site — the other seven panels have the same defect and none of them
  asked for it. It is the kind of thing only a photograph finds.

## What the photographs showed that is not decided here

**Every wide shot of this page carries a second, faint copy of one of its own
rows.** On a transcript it is the composer, drawn near the top of the window as
well as at the bottom; on the empty screen it is the subject bar, drawn at the
bottom as well as at the top. The narrow shots are clean. This was found by
looking, it is not subtle in dark mode, and it is written down here because the
next person to photograph this page will see it and needs to know what has
already been ruled out.

Bisected, one probe each, all at 1340 × 1960:

| Changed | Ghost |
|---|---|
| `.motion(.entrance, value: hasTranscript)` removed | still there |
| `.elevation(…)` removed from the composer | still there |
| `TextEditor` replaced by a `Text` | still there |
| a second `cacheDisplay` after the first | still there |
| `setNeedsDisplay` + `displayIfNeeded` before capture | still there |
| run loop advanced 0.4s past the curve | still there |
| `.frame(maxHeight: .infinity)` on the scroll view | still there |
| **`.defaultScrollAnchor(.bottom)` removed** | **gone** |

So it is the scroll anchor with content shorter than the viewport, which is
ADR-0076's decision and its lock, and it predates everything here — the empty
screen's version of it is on a screen this ADR did not change. The copy is not a
translated duplicate: its internal spacing differs from the real one's
(placeholder to chip, 49pt against 75pt), so it is a row from a *different layout
pass* being drawn alongside the current one.

**What is not established is whether it reaches the running application**, and
that is the honest state of it. Every instrument here is `NSHostingView` +
`cacheDisplay` on a window that never reaches a display, which AGENTS.md already
records as an instrument that lies in the other direction. Nothing was changed to
chase it: undoing the scroll anchor would restore a worse defect that ADR-0076
measured at fifteen hundred points of void, and that decision is not this one's
to reverse. Declared, with the bisection above so nobody spends the same hour.

## How this regresses

**"There is a URL in the middle of my sentence again."** The address is put back
into `emptyMessage`, most plausibly because the identity capsule is truncated on
a narrow window and adding the address back looks like restoring information.
`aShortenedAddressIsReadableAndNeverPercentEncoded` does not catch that one — it
catches the *other* half, the encoding, which is what made the sentence
unreadable rather than merely long. The capsule's own truncation is a shape and
is watched in `ZZChatPageShots` at both window sizes. Declared: the sentence
having no address is not locked, and the honest fence for it would be a test
that renders the empty state and reads its text.

**"It offered to summarise a page it had already said it would not read."**
`startingPoints` loses its guard — the parameter reads as redundant next to a
greeting that already varies, and dropping it makes the function a constant.
`theEmptyScreenOffersAWayIn` asserts the empty case by name.

**"It told me what the page said before reading it."** A starting point is
reworded into a claim — "Here is what this page argues" — because it reads more
confidently. Nothing mechanical catches this and it is the most damaging
regression on the list, because it is ADR-0018 broken in the one place the
product is judged. The doc comment on `startingPoints` says it in as many words
and that is the whole of the fence. Declared debt.

**"The composer is a grey box again."** `.regularMaterial` comes back, because
every other floating panel in the shell is a material and this one looking
different reads as an oversight. It is not: the others float over something.

**"The scroller is back."** `.scrollIndicators(.never)` is deleted as a
no-op — it looks like one, because on a field with one line in it there is
nothing to scroll and nothing to see.

## When to revisit

- **When a starting point can be about what kind of page it is** — a pull
  request, a paper, a video. That would be genuinely specific rather than
  generally applicable, and it needs the core to decide what kind of thing an
  address is, which is a decision two platforms could not disagree about and so
  is not this file's.
- **If a model becomes something you pick per conversation.** ADR-0070 already
  names this; the chip is now the right shape for it and would stop opening
  Settings and start opening a menu.
- **If the empty state acquires a fourth block.** Identity, greeting, sentence,
  field, offer is already five things on a screen whose argument is that it is
  mostly empty. The next addition should replace one.
- **When `Wrap` has a second caller.** Then it belongs in `DesignSystem.swift`
  with the other shared shapes rather than at the bottom of a page.
