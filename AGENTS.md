# zer0

A WebKit browser with a Rust core and a native shell per platform.

This file is traps to avoid, not a map to follow. It is short on purpose:
measured evidence says instruction files help when they carry rules and hurt
when they carry description. `README.md` describes the project; `DESIGN.md`
holds the visual system; `docs/adr/` holds every decision and the test that
defends it. Do not restate them here.

## The premise that governs everything

**The person building `zer0` is a UI/UX person.** Experience and looks are not
finishing touches, they are the product. A browser that works but grates is not
done, it is broken.

In practice: **if it is obvious, do it.** A field that opens has the cursor in
it. Text opened for editing arrives selected. Esc closes, Enter confirms. A
shortcut already in someone's fingers does what those fingers expect. Anything
in flight has feedback. A destructive state warns before, not after.

Working well is not enough — the target is someone stopping for a second and
thinking "that is gorgeous". Hierarchy before reading; space as an ingredient
rather than leftovers; motion that explains where something came from; system
materials, not grey rectangles; the empty state treated as a product screen.
`DESIGN.md` is the system.

## Where a decision lives

**The Rust core decides. The shell renders and decides nothing.** The core does
not know what a `WKWebView` is.

The tie-breaker, in one direction only: **if two platforms could reasonably
disagree about it, it belongs in the shell; if they could not, it belongs in the
core.** Ranking, keymap, lifecycle, what is stored — core. Colour, spacing,
animation, which key types which glyph — shell.

This is why behaviour can be tested without opening a window, and why Linux will
be a new host rather than a rewrite.

## Not introducing a regression

Six things this project learned the expensive way. Each is a pattern, not a
style preference.

**A guarantee is structural or it is not a guarantee.** A rule saying "do not
write X" is a wish; a type with no field for X is a guarantee. `StorableSession`
cannot express an ephemeral space's pages. `ProviderEndpoint` has no field a
token fits in. The motion curves are `fileprivate` so only the spellings that
read Reduce Motion compile. Reach for this before reaching for a comment.

**The dangerous regression is the one that reads as an improvement.** Twelve
ADRs name the reviewer's motive: the tidier-looking code, the obvious
performance win, the redundant second pass, the missing match count someone
helpfully adds. When you simplify something, check whether the complexity was
load-bearing — and if it was, say so in the comment so the next person does not
try again.

**Put the rule at the one door.** A rule enforced at N call sites has N−1 bugs
waiting. Find the single place everything converges and put it there; if there
is no such place, making one is the work.

**Refuse rather than repair, and fail closed.** When a caller named something
that does not exist, refuse. Fall back only when the thing was incidental to
what they asked for. A repair that guesses is a bug with a delay on it.

**Say only what you can prove.** No invented match count, no progress bar over
an unknown length, no "secure" where you mean "no error yet". This applies to
shapes and motion, not just numbers: a determinate bar drawn over an
indeterminate fact is the same lie.

**Treat every boundary as hostile, including your own files.** Disk, network,
extensions, MCP servers, and the config someone hand-edited.

## Locks

Every decision that matters goes in `docs/adr/` and names the test that defends
it. `./scripts/adr-check.sh` proves the test exists. **It cannot prove the test
covers the decision, and that gap has already cost this project real bugs.**

So, when you write or move a lock:

- **Break the decision on purpose and watch the named test go red.** A lock
  nobody has seen fail is a lock nobody should trust.
- **Ask what question the test does not ask.** The keymap lock proved a chord
  was in the table while ~20 shortcuts did nothing, because nothing asked
  whether a press arrives. Its replacement proved a press arrives, and stayed
  green while every press acted on the wrong window.
- Copy the test's name exactly. Paraphrasing it is the most common way to
  invent a lock that resolves against nothing.

`none — debt` is honest and is counted on every run. A lock pointing at the
wrong test is worse than declared debt, because it buys confidence.

## Verifying

`./scripts/check.sh` green is the definition of done. It runs fmt, clippy, the
Rust suite, `adr-check`, and the Swift suite. **There is no smaller definition**
— running `cargo test` alone skips the decision record and the entire shell.

**Interface is verified by looking.** Most of this interface's defects were
found by rendering a real view offscreen and inspecting the pixels, and none of
them were catchable by an assertion. `NSHostingView` + `cacheDisplay`;
`ImageRenderer` mangles materials. Harnesses live in `apple/Tests` behind
`ZER0_SHOT=1`.

**Instruments lie.** `cacheDisplay` photographs transform-based animation as
motionless — it reported five working animations as dead. Before concluding
something does not happen, establish that your instrument can see it happening.

**Measure rather than reason.** A WebKit build was estimated at 100 GB and
measured at 34. Contrast, frame positions, byte counts: measure. And when you
report, separate what you measured from what you read.

**A shared symptom is not a shared cause, and the comfortable explanation is
the one to distrust.** One afternoon the test process died four times. Every
time the answer looked obvious — the machine was loaded, several people were
writing the tree at once — and every time it was a real and *different* bug: an
isolation assumption asserted from a background queue, a script message handler
added twice because a pop-up shares its opener's content controller, a web view
outliving the model that owned it, a panic on the launch path. "It was the
concurrency" explained all four and was true of none. An explanation that
covers every symptom equally is usually covering for not having looked.

## Working rules

- Tests cover behaviour, not pixels — but focus, order and selection **are**
  behaviour and get tests.
- No `default:` or `_ =>` in a switch over a command or an action. A new
  variant must break the build until it earns behaviour.
- A comment explains *why*. The *what* is the code.
- **Everything in this repository is in English** — code, comments, docs, ADRs,
  file names. Conversation with the author is in Portuguese; nothing that lands
  in the repo is.
- Never `git commit` or `git push`. Prepare the change; the author commits.
- Simple beats clever. Deleting code beats writing it. Solve the problem in
  front of you, not the one you can imagine.

## When you find something wrong

Say it plainly and keep working. A defect named in one sentence is worth more
than a paragraph of hedging.

If you disagree with a rule here, **argue against the principle rather than
ignoring the rule** — that has already produced a better answer than the
instruction did, more than once.

Correct a factual error in place and say that you corrected it. Change a
decision by writing a new ADR that supersedes the old one. The test: would
someone acting on the old sentence have *decided differently*, or merely been
*misinformed*? Misinformed is an edit. Decided differently is a new ADR.
