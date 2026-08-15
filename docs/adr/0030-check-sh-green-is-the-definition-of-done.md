# ADR-0030: `./scripts/check.sh` green is the definition of done

- **Status:** Accepted
- **Date:** 2026-04-06
- **Lock:** none — debt

## Context

"Done" is the most expensive word in a codebase, because everyone means
something slightly different by it. It compiles. The tests I wrote pass. It
works on my machine. I ran the Rust side and assumed the Swift side was fine.

`zer0` is two languages joined by a generated FFI boundary. That geometry makes
partial verification especially seductive and especially wrong: the core is
where behaviour is decided, the shell is where it is observed, and a change that
satisfies one of them while breaking the other is the normal case, not the
exotic one. `cargo test` passing tells you nothing about whether the Swift shell
still compiles against the bindings that change produced.

There was already a shared script. What was missing was the commitment that it
is *the* answer, rather than one of several ways to feel confident.

## Decision

**A change is done when `./scripts/check.sh` exits zero, and not before.** Not
"the tests pass", not "it builds" — that one script, all the way through.

What it runs today, in order:

1. `cargo fmt --all --check` — formatting is not a matter of taste here, it is
   a matter of not having diffs about whitespace.
2. `cargo clippy --all-targets --all-features -- -D warnings` — a warning is a
   failure. There is no tier of "known warnings" to learn to ignore.
3. `cargo test --all-features` — the core's behaviour.
4. On macOS only: `./apple/scripts/build-core.sh`, then `swift build` and
   `swift test` from `apple/`.

Two properties of that list matter more than its contents:

**It is one command, not a checklist.** A checklist is a thing people execute
partially under time pressure. A single command is a thing people either ran or
did not.

**The Swift half is skipped by platform, not by choice.** The `uname` guard
exists so Linux CI can still run the core, which is the half that is portable.
It is not a way to opt out of the Swift tests on a Mac.

New verification goes *into* this script. A check that lives in someone's shell
history is not a check, and a check that only CI runs is a check you discover
you failed after you thought you were finished.

## Consequences

**What it costs:**

- **The gate is only as fast as its slowest step, and everyone pays it.** The
  Swift build dominates. As it grows, the cost of confirming a one-line change
  in the core grows with it, and the pressure to run "just `cargo test`" grows
  with that.
- **You cannot fully verify a change on Linux.** Off macOS the script skips
  steps 4 onward and still exits zero. It reports green while having checked
  half the system. This is deliberate, and it is also a way to be wrong.
- **Every new check makes the gate slower for every change, forever.** There is
  no mechanism here for "run only what this diff could have broken". Adding a
  check is cheap to write and permanently expensive to run.
- **A flaky check would poison the rule.** The rule survives only while green
  means something. One test that fails 1-in-20 teaches everyone to re-run
  rather than to read, and the day it fails for real nobody will notice.

**What it buys:**

- One word, one meaning. "Done" stops being a matter of interpretation.
- The FFI boundary is checked on every change rather than at integration time,
  which is when a bindings mismatch is cheapest to find.
- The rule is quotable in a review without being a personal criticism: not
  "I don't trust this", but "check.sh".

## How this regresses

Not with an argument. Nobody proposes lowering the bar; it lowers itself.

- **The gate gets slow and people stop running it.** They run `cargo test`,
  which is fast and covers the half they were thinking about. The Swift half
  breaks, and it breaks for whoever pulls next rather than for whoever broke it.
- **A step gets commented out "just for now".** Almost always clippy, almost
  always during a refactor that produces forty warnings at once. The comment
  says it comes back on Monday. The `-D warnings` never returns, and warnings
  become scenery.
- **The Linux skip quietly becomes the normal path.** Work happens in a
  container because it is faster. The script exits zero every time. Nobody is
  lying, and nothing Swift has been checked in weeks.
- **A check is added to CI instead of here.** It runs, it catches things, and it
  catches them twenty minutes after the author moved on. The script stops being
  the definition and becomes a subset of it.
- **A flaky test gets a retry instead of a fix.** Green stops being a fact and
  becomes a probability, and the rule quietly means nothing.

**No lock.** This is debt, and it is the honest kind: there is no test in this
repo asserting what `check.sh` runs. Writing one is possible — a test could
parse the script and assert that `cargo clippy` appears with `-D warnings`, that
`swift test` appears — but a test that greps a shell script for substrings locks
the *spelling* of the gate, not its strictness. It would go red on a harmless
rewrite and stay green on a `|| true` appended to a line. Until there is a check
that observes strictness rather than text, this ADR is held by nothing but the
habit it describes.

What partially covers it in practice: CI runs the same script, so the Linux-skip
failure mode is caught for the core. Nothing covers the Swift half except a
person on a Mac.

## When to revisit

- When the gate crosses the threshold where people visibly stop running it
  before pushing. That is a real signal, and the answer is a fast path plus a
  full path — not a shorter definition of done.
- When a Linux shell exists. The `uname` guard stops being "skip the part that
  cannot run here" and starts being "skip a whole supported platform", which is
  a different and much worse thing.
- If a check ever needs to be flaky-tolerant. That is the moment to delete it
  instead, because a gate with a known-unreliable step is a gate nobody reads.
- If per-change selection becomes worth building. It is a real answer to the
  cost, and it trades a guarantee for a heuristic — worth doing consciously,
  not by drift.
