# ADR-0071: The core reads a reply and the shell sets it as prose

- **Status:** Accepted
- **Date:** 2026-08-04
- **Lock:** `crates/zer0-core/src/prose_tests.rs::every_block_a_reply_uses_comes_back_as_its_own_kind`, `crates/zer0-core/src/prose_tests.rs::an_unterminated_fence_is_a_code_block_from_the_moment_it_opens`, `crates/zer0-core/src/prose_tests.rs::a_reply_never_loses_a_block_it_had_already_shown`, `crates/zer0-core/src/prose_tests.rs::no_outliner_dialect_is_interpreted`, `crates/zer0-core/src/prose_tests.rs::only_an_address_a_browser_can_follow_comes_back_as_a_link`, `crates/zer0-core/src/prose_tests.rs::nesting_thousands_deep_does_not_take_the_process_down`, `crates/zer0-core/src/prose_tests.rs::a_reply_is_cheap_enough_to_re_read_on_every_delta`, `apple/Tests/Zer0ShellTests/ChatProseTests.swift::ChatProseTests/aLinkOpensInZer0`, `apple/Tests/Zer0ShellTests/ChatProseTests.swift::ChatProseTests/aSettledReplyIsNotReadAgain`, `apple/Tests/Zer0ShellTests/ChatProseTests.swift::ChatProseTests/anUnterminatedFenceReachesTheShellAsCode`, `apple/Tests/Zer0ShellTests/SourceRuleTests.swift::VocabularyExhaustivenessTests/noSwitchOverTheVocabularyCarriesADefault`

## Context

A model replies in Markdown. `ChatPage` drew it with `Text(message.text)`, so a
reply reading

> **Copita / tulipa** — the classic Brazilian pour
> - narrow at the lip
> - wide at the bowl

arrived on screen with the asterisks and the hyphens in it, mid-sentence. Every
model this browser can be pointed at emits Markdown; none of them was being
read. It was the largest visual defect on the chat page and it was visible on
the first reply anyone ever saw.

Three things made it more than an afternoon's work.

**The text streams.** A reply arrives as dozens of deltas and the view is
re-evaluated on every one — for every message in the transcript, not just the
one arriving. Whatever reads the Markdown runs at that rate.

**Half-written Markdown is the normal case.** Part way through a reply there is
an unclosed ``` fence, a lone `**`, a list marker with nothing after it. A
renderer that flips a paragraph between "prose" and "code block" as the closing
fence lands makes the answer strobe while somebody is reading it. That is a
worse defect than the one being fixed, because it happens *during* the moment
the product is being judged.

**Somebody is going to select it.** Copying an answer out is the most common
thing anyone does with one.

## Decision

**The core reads the Markdown. The shell sets the result as prose.**

`crates/zer0-core/src/prose.rs` turns a reply into `Vec<ProseBlock>` and
`ChatProse.swift` draws them. Nothing about *what* `**x**` means is decided on
the Swift side; everything about how it looks is.

### Why the parse is core

The tie-breaker in AGENTS.md, in one direction only: *if two platforms could
reasonably disagree about it, it belongs in the shell; if they could not, it
belongs in the core.* No two platforms reasonably disagree about whether `**x**`
is bold, where a list item ends, or that a fence opens a code block. CommonMark
settled all of it, and a Swift parser would mean the Linux shell writes a second
one — after which the two drift, and the drift shows up as a reply that reads
differently on two machines with no line of code saying why.

It is the same call ADR-0016 made about `NavigationErrorKind`: *the number
belongs to the platform and the meaning does not.*

### What crosses the FFI

A **flat** list, not a tree. Markdown nests; `ProseBlock` carries `indent` (list
levels) and `quoted` (block-quote depth) instead, so a list item holding a
paragraph and a fence arrives as three blocks in a row. Two reasons, and the
second is the one that decided it:

- A renderer walks a list rather than recursing, which is what a `ForEach` wants.
- uniffi carries records and enums. A self-referential enum would need every
  host language to spell recursion the way Swift spells `indirect`, and the flat
  form crosses unchanged.

`ProseKind` is an enum with data — `Paragraph`, `Heading`, `Item`, `Code`,
`Rule` — rather than a record with a `kind` string beside seven fields that are
empty most of the time, so a sixth kind cannot be added without the shell's
switch failing to compile. `ProseKind` was added to the vocabulary
`VocabularyExhaustivenessTests` scans, which is what refuses the `default:`
somebody would otherwise reach for.

Runs carry facts, not fonts: `bold`, `italic`, `code`, `struck`, `link`. Whether
bold is a heavier weight or a different colour is the shell's.

### comrak, with almost nothing switched on

`comrak = { version = "0.54.0", default-features = false }`, behind a `prose`
crate feature that `ffi` turns on. BSD-2-Clause, which our MIT accommodates.
`default-features = false` because the defaults pull in `cli` (clap,
shell-words, xdg) and `syntect-onig`, and oniguruma is a C regex engine with no
business inside a browser. What is left is thirteen crates of pure Rust.

Two extensions are on and each was argued rather than taken as a set:

- **strikethrough**, because `~~x~~` is a claim about the text that survives
  into any renderer.
- **autolinks**, because a bare `https://…` in a reply is an address, and asking
  somebody to select and copy it is a chore rather than a decision.

Everything else is off, and three of those are decisions rather than defaults:

- **Tables.** There is no honest way to set one in a 600-point column yet: a
  `Grid` of `Text`s selects per cell, overflows with no answer, and a table
  half-drawn mid-stream — a row of `|---|---|` becoming a header — is the worst
  strobe in the set. And the failure mode is mild: an unrendered table still
  reads as rows, where an unrendered `**bold**` does not.
- **Tasklists**, because `[ ]` reads as `[ ]`.
- **Wikilinks**, because `[[foo]]` must stay six characters.

**No outliner dialect.** `[[page]]`, `#tag`, `key:: value`, `((blk-1234))` and
`:emoji:` are not Markdown and are not interpreted. A model that replied with
`[[foo]]` wrote those six characters and we draw those six characters; reaching
for content behind a reference that does not exist is repair-by-guessing, which
AGENTS.md refuses.

### What a reply that has not finished arriving looks like

**Nothing special, and that is the decision.** CommonMark already answers it the
way a reader wants, so the anti-strobe behaviour is not a special case bolted on
— it is the spec, and the tests are what say we noticed:

- An **unterminated fence** is a code block that runs to the end of the input.
  So a fence is a panel from the moment it opens, and text does not sit as prose
  for four seconds and then snap into monospace.
- A **lone `**`** has no closing delimiter, so it is text. It becomes bold when
  the closer arrives, and until then it is the two characters the model sent.
  Pre-bolding on the guess that a closer is coming would also bold the `*` in
  `2 * 3 * 4`.
- A **marker with nothing after it** is an item with nothing in it, and is
  emitted as one, so the bullet appears when the bullet is typed rather than
  when its words do. This one needed a look-ahead in the walk and is the only
  place streaming cost the parser anything.

The property underneath all three is stated as a test rather than as a
paragraph: for every prefix of a reply, every block that had already settled
comes back as the same kind. A parser that re-read earlier text differently as
more arrived is a page that re-flows under a reader.

### What it costs

Measured, on this machine, over a 7 KB reply — the size of a long answer:

| | per read |
|---|---|
| `prose::blocks`, release | **0.14 – 0.21 ms** |
| `prose::blocks`, debug | **1.6 – 1.8 ms** |

A range rather than a number because the machine was compiling at the same time;
`a_reply_is_cheap_enough_to_re_read_on_every_delta` prints the figure on every
run and fails only at ten milliseconds, which is loose enough that only a change
of *order* trips it. At thirty deltas a second the release figure is well under
1% of a core and the debug one about 5%. The FFI hop is a `Vec<ProseBlock>` of plain records; runs are
coalesced in the walk precisely because comrak splits text at every delimiter it
considered and rejected, and each surviving run is a string allocated and
carried.

The cost that actually needed fixing was never the reply arriving — it was the
twenty that were not. A transcript re-evaluates every message's body when any
one of them changes, so `ChatProse` keeps a one-entry memo on the exact text.
With it, one reply is read per delta. Without it, all of them are.

### What the shell decides

The type ladder, the rhythm, the indentation, the code panel and the rails, all
in `ChatProse.swift` and all checked by looking (`ZZChatProseShots`). Two of
them are worth writing down because they were arguments:

- **Two heading steps, not six.** `#`/`##` at `.title3` semibold, `###` and
  below at `.headline`. A reply is a passage inside a page, not a page, so its
  headline must not open louder than the pane's own empty state
  (`Design.Text.emptyTitle`); and models reach for `##` and `###`
  interchangeably, so a six-step ladder would assert a structure the source does
  not have (ADR-0018).
- **A fenced block wraps rather than scrolling.** A horizontal scroll view
  inside a transcript that already scrolls hides the end of a long line behind a
  gesture nobody is told about, and a line of an answer you cannot see is worse
  than one that wrapped.

**A link in a reply opens in zer0.** `Text` renders a link and hands the click
to the environment's `openURL`, whose default is the *system* browser — so
without this, clicking a link inside zer0 launches Safari. `ChatProse` installs
an action that opens a tab instead. And the address is filtered in the core: a
run carries a link only if it is an absolute `http` or `https` address, so
`javascript:`, `file:` and `zer0:` keep their words and lose their click. An
image contributes its alt text and never an address to fetch, because a reply
that could load a remote image could also report that it had been read.

## Consequences

**Selection is per block, not continuous, and that is a limit rather than a
choice.** `.textSelection(.enabled)` makes each `Text` its own selectable region
and SwiftUI publishes no way to join them. Within a block — a whole paragraph, a
whole code listing — selection is ordinary and complete. Dragging from a
paragraph through a list into a fence is not.

This is stated rather than worked around because both workarounds are worse than
the limit. Collapsing the reply into one `Text` would take away the code panel,
the list indentation and the rails, which is the entire job. Hosting an
`NSTextView` would buy continuous selection and give up the design system,
Dynamic Type and both themes. If a reply needs to be copied whole, the thing to
build is a copy action, not a cleverer selection.

**And it has not been observed either way, because the harness cannot see it.**
Two attempts, both written down because the second is a trap worth naming. A
probe that synthesised a drag over an offscreen `NSHostingView` and then asked
the responder chain to copy came back with `false` and an empty pasteboard —
uninformative on its own, since nothing had shown the rig could capture *any*
selection. Adding that control made it worse: a synthesised `mouseDown` puts
AppKit into its own event-tracking loop, no further events ever arrive offscreen,
and the test process hangs rather than answering. The probe was deleted; a
harness that can hang the suite is worse than no measurement.

So the instrument is blind here, the way `cacheDisplay` is blind to
transform-based animation (AGENTS.md: *establish that your instrument can see it
happening*), and the paragraph above rests on the API's shape rather than on
frames. **It is the one claim in this ADR that has not been looked at**, and the
way to look at it is a running window and a mouse, not `apple/Tests`.

**A third-party parser is now in the core.** Thirteen crates, no C, one feature
flag. It is the first dependency in `zer0-core` that reads *content* rather than
a format we defined, which is a different exposure from `zip` or `toml_edit`:
comrak is fed text a model wrote, on every delta. What bounds it is that
CommonMark parsing produces no I/O and no execution, the walk over its output is
iterative, and `MAX_MESSAGE_BYTES` already caps what can arrive.

**The blocks are appearance-shaped, and that is admitted.** `indent` and
`quoted` are structure, but the reason `Item` exists as its own kind — rather
than a list being a block containing blocks — is that a flat list is what a
renderer wants. A different shell could reasonably want the tree. If one ever
does, the answer is a second function, not a second parser.

## How this regresses

Each decision below was undone on purpose and the named test watched go red
before it was written down. What that established, one at a time: dropping an
unclosed fence took `an_unterminated_fence_is_a_code_block_from_the_moment_it_opens`
and `a_fence_that_never_closes_over_a_long_reply_stays_one_block` with it;
switching on comrak's wikilinks took `no_outliner_dialect_is_interpreted`;
letting any scheme through took
`only_an_address_a_browser_can_follow_comes_back_as_a_link`; and making the
marker wait for its words took `a_marker_with_nothing_after_it_is_already_a_list_item`.

On the Swift side: deleting the memo's early return took `aSettledReplyIsNotReadAgain`
and `anArrivingReplyIsReadOncePerDelta` (51 reads for one text, 114 for 38
deltas); making `ChatProse.open` a no-op took `aLinkOpensInZer0`; and putting a
`default:` in the switch over `ProseKind` took
`noSwitchOverTheVocabularyCarriesADefault`, naming the file and the line.

**Somebody moves the parse back to Swift**, because crossing the FFI thirty
times a second looks wasteful in a profile. It is 137 µs against a 16 ms frame,
and the cost that mattered was the memo, not the hop. What goes red: nothing —
which is why it is written here. The symptom is a reply that renders one way on
macOS and another way on Linux a year later, and by then nobody remembers there
were two parsers.

**Somebody deletes the memo** in `ChatProse`, reasoning that SwiftUI already
diffs view values. `aSettledReplyIsNotReadAgain` is what goes red. The failure
it prevents has no visual symptom at all: same pixels, same words, and a
twenty-message conversation doing twenty times the work per delta of the
twenty-first.

**Somebody "fixes" the unclosed fence.** Rendering a half-arrived fence as prose
until its closer lands is the tidier-looking behaviour and reads as more
correct — it is, after all, not yet a valid code block.
`an_unterminated_fence_is_a_code_block_from_the_moment_it_opens` asserts the
property over *every prefix* of a reply rather than at one cut, because a single
cut is the check somebody satisfies by accident.

**Somebody enables another comrak extension** — tables, most likely, and it is
the obvious improvement. The trap is that the walk carries an
`#[expect(clippy::wildcard_enum_match_arm)]` over `NodeValue`, justified by the
extensions being off: switch tasklists on and `TaskItem` falls into that
wildcard, and every task item silently loses its marker. Enabling an extension
means reading the walk, not just the options.

**Somebody adds a sixth `ProseKind` and forgets the shell.** The Swift switch
fails to compile, and `noSwitchOverTheVocabularyCarriesADefault` refuses the
`default:` that would make the build green again while the new block rendered as
nothing.

**Somebody widens what counts as a link**, to be helpful about `mailto:` or a
relative address. `only_an_address_a_browser_can_follow_comes_back_as_a_link`
goes red. The reply is a boundary and a model can write any six characters it
likes.

## When to revisit

- **Tables, when there is a shape for one.** The parse is one boolean away; the
  rendering is the open question. Reopen when there is an answer for a table
  wider than the column that does not hide content behind a gesture — and
  before that, `a_table_is_left_as_the_rows_that_were_typed` is what says the
  decision was made rather than missed.
- **Selection, when somebody has looked at it in a running window.** If a drag
  really does cross blocks on a current macOS, the *Consequences* paragraph is
  wrong and should be corrected in place. If it does not, the copy action named
  there is the work.
- **A second shell.** The moment a Linux host draws a reply, `ProseBlock` is
  either enough for it or it is not, and the answer decides whether the flat
  shape stays. That is the first real test of this split.
- **A measured frame drop on a long conversation.** The numbers above are one
  machine and one 7 KB reply. If a hundred-message transcript with three long
  replies drops frames, the fix named in advance is how often the shell asks —
  coalescing deltas — not moving the parser.
