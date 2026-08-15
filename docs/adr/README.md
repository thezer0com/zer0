# Decision record

This directory holds the decisions that shape `zer0` — one file per decision,
numbered, never renumbered.

An ADR is not documentation of how the code works; the code already does that,
and better. An ADR records **why the code is this way and not the other way**,
written at the moment there was still a choice. Six months later the reasoning
is gone and only the artefact remains, and someone — very reasonably — undoes
it. That is what this directory exists to prevent.

Two rules hold the whole thing up. Everything else is formatting.

## Rule 1 — every ADR names its lock

The `Lock:` field names the test that goes red if the decision is undone.

An ADR without a test is an intention. An ADR with a test is a lock. The
difference is not rhetorical: an intention survives exactly as long as everyone
who read it remembers it, and a lock survives a refactor by a stranger at
11pm.

```markdown
- **Lock:** `crates/zer0-core/src/shortcuts.rs::every_command_is_still_reachable_where_control_is_primary`
```

`./scripts/adr-check.sh` resolves every lock on every run: the file must exist,
and the test name must really be in it. A lock pointing at a test that was
renamed away fails the gate. That is the point — it is exactly the moment the
record started lying, and the only moment anyone can still cheaply fix it.

Three shapes are accepted:

| Shape | Example |
| --- | --- |
| Rust test function | `crates/zer0-core/src/store_tests.rs::a_save_without_a_quit_reads_as_a_crash` |
| Swift suite + method | `apple/Tests/Zer0ShellTests/ShortcutTests.swift::ShortcutTests/everyBoundCommandIsHandled` |
| Shell function in a gate script | `scripts/adr-check.sh::resolve_lock` |

### The named test has to be one that runs

A lock naming an `#[ignore]`d Rust test, or a Swift test — or suite — carrying
`.disabled(…)`, is refused. Both leave the name in the file, which is all the
checker needs to say "the test is really there", and neither ever executes.

This is not a corner. Every screenshot harness in `apple/Tests` is
`.disabled(if: ZER0_SHOT == nil)` on purpose, because a harness that runs by
default starves the timing tests. So the most inviting-looking test names in the
repo are attached to tests that never run, and a lock pointing at one would read
as the strongest kind of cover while defending nothing at all.

### A decision can have more than one lock

If the regression fence is the `Lock:` field, it has to hold the whole fence.
Several tests defending one decision are listed **comma-separated, each in its
own backticks**, on the one `Lock:` line:

```markdown
- **Lock:** `crates/zer0-core/src/store_tests.rs::a_save_without_a_quit_reads_as_a_crash`, `apple/Tests/Zer0ShellTests/SettingsTests.swift::SessionPersistenceTests/crashDoesNotCostTheSession`
```

That separator is a contract with `adr-check.sh`: only what sits inside
backticks is read as a lock, the commas are punctuation, and **every item is
resolved individually**. One broken lock in a list of four fails the gate and
names which one.

If a test that guards the decision is named in the prose of the ADR but not on
the `Lock:` line, it is not a lock. Move it onto the line.

### Swift locks name the suite and the method, never the sentence

A lock used to be allowed to name the phrase inside `@Test("...")`. It is not
any more. Rewording that phrase is a change with no behavioural meaning, and it
turned the build red — which taught exactly the wrong reflex, because the
cheapest way to get green again is to edit the record.

`adr-check.sh` refuses the shape and prints the replacement it found:

```
error: docs/adr/0011-…: lock "the Chrome shortcuts a switcher already has in
their fingers" names a test by the phrase inside `@Test("...")`.
  Write it as:
      `apple/Tests/Zer0ShellTests/ShortcutTests.swift::ChromeParityTests/chromeBindings`
```

### When there is no test, say so

Some decisions cannot be locked by a test. "We build WebKit from source" is
not something a unit test observes. "There is no `default:` in this switch" is
enforced by the compiler, and a test cannot watch a compiler refuse to compile.

For those, the field declares the debt in as many words:

```markdown
- **Lock:** none — debt
```

This is honest, and it is **not** an error. `adr-check.sh` prints the debt count
on every run, green or red:

```
==> adr: 20 ADRs, 6 without a lock (debt)
```

A number you see every day gets paid down. A number behind a flag does not.
Declaring debt is always allowed; hiding it by pointing the lock at a test that
does not really cover the decision is the one thing that is not.

## Rule 2 — an accepted ADR is not edited

Once a decision is accepted, its file stops changing. When the decision changes,
you write a **new** ADR that supersedes the old one, and the old one gets its
status swapped:

```markdown
- **Status:** Superseded by ADR-XXXX
```

Not because the old file is precious, but because a record you can edit is a
record that only ever shows the present — which is the one thing you can already
read off the code. The value is in the disagreement between what we thought then
and what we know now. Editing in place deletes exactly that.

`adr-check.sh` checks that a superseding pointer names an ADR that exists, so
the chain stays followable.

Fixing a typo is fine. Changing what was decided is a new ADR.

Between those two sits the case that actually comes up: **a fact we got wrong.**
Not a changed decision — a claim that was never true. ADR-0005 asserted that a
WebKit built with `WK_RELOCATABLE_FRAMEWORKS=YES` would have `@rpath` install
names; measuring it showed that it does not. The decision it supports did not
move an inch.

Correct those in place, and **say that you did**, in the file, where the wrong
claim was. A superseding ADR for a measurement error would bury the decision
under bookkeeping, and silently swapping the sentence would let the next person
make the same wrong inference from the same evidence. The test is simple: if
someone acted on the old sentence, would they have decided differently, or
merely been misinformed? Misinformed is an edit. Decided differently is a new
ADR.

## Format

```markdown
# ADR-0001: Affirmative title

- **Status:** Accepted | In progress — … | Superseded by ADR-XXXX | Revoked
- **Date:** 2026-08-08
- **Lock:** `path/file.rs::test_name`   (or `none — debt`)

## Context
## Decision
## Consequences
## How this regresses
## When to revisit
```

The title states what was decided, affirmatively — "WebKit is the engine, not
Chromium", not "Engine choice". You should be able to read the index and know
what this project believes without opening a file.

### Status is a prefix, not an enum

The line must **start** with one of `Accepted`, `In progress`, `Superseded by`
or `Revoked`. Everything after that is free text, and it is meant to be used:

```markdown
- **Status:** Accepted, and already partly superseded by ADR-0005
- **Status:** In progress — decided, partly implemented, **not validated**
```

"Partly superseded" is a real thing that happens to a decision, and a taxonomy
clean enough to exclude it would be buying tidiness with information. Whatever
the wording, any `ADR-XXXX` named in the line must exist — that check does not
depend on the sentence around it.

All five sections are mandatory and none may be empty. The two that are easy to
skip are the two that pay:

- **How this regresses** — describe the failure in terms of what a *person*
  would notice, not what a stack trace would say. This is where you find out
  whether the lock you named actually covers the decision.
- **When to revisit** — the conditions under which this should be reopened.
  A decision with no exit condition is a belief.

## Numbering

**Take the next free number. That is the whole rule.**

Numbers are never reused, including by revoked ADRs — a dead number is cheaper
than a broken cross-reference.

The record started with themed ranges — architecture at 0001, UX at 0010,
extensions at 0020, and so on. That lasted less than a day. UX filled its ten
slots, the eleventh UX decision landed in the extensions range, and two ADRs
written in parallel took the same number and broke the cross-references of both.

The ranges were solving a problem the record does not have. Nobody finds an ADR
by guessing its number; they grep the titles or read the index. What the ranges
did buy was a hard cap on how many decisions each area is allowed to have, which
is a strange thing to want and an unpleasant thing to discover from a collision.

The numbers below 0050 still cluster by theme, because that is when they were
written. That is history, not a scheme — do not extend it. A number is the order
a decision was taken, and the topic lives in the title, where it is readable.

## The index

The index is **generated**, never written by hand:

```sh
./scripts/adr-check.sh --index
```

It prints a markdown table of every ADR — number, title, status — read straight
from the files. A hand-maintained list is wrong the moment a file is renamed,
and an index that lies is worse than no index, which is roughly the argument of
ADR-0018.

## Checking

```sh
./scripts/adr-check.sh
```

Runs as part of `./scripts/check.sh`, so it is already green before anything
is called done. On its own it verifies that every ADR has all five sections
non-empty, has a `Lock:` field, has locks that resolve to tests that run, has a
unique number matching its title, and does not point at a superseding ADR that
was never written.

### And the checker is checked

```sh
./scripts/adr-fixtures.sh
```

Everything above rests on one script, and a script that has stopped catching
things looks exactly like one that works — both exit zero. So `adr-check.sh` has
fixtures of its own, in `scripts/adr-fixtures/`: one directory per refusal it can
make, each holding an ADR that is valid but for the single flaw it is named
after, plus `cases/valid`, which it must accept. Each one asserts the refusal
*and the reason given for it*.

Weaken the checker — the shortest version being `resolve_lock() { return 0; }` —
and fourteen fixtures go red by name while `docs/adr` reports a clean run. That
run happens first in `check.sh`, before the record is checked, because a verdict
from an unverified checker is not worth reading.

The fixtures sit outside `docs/adr/` deliberately: a broken ADR is the one thing
the real record must never contain, and `adr-check.sh` run normally never sees
them.
