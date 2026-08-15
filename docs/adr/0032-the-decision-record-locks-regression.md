# ADR-0032: The decision record locks regression, and checks itself

- **Status:** Accepted
- **Date:** 2026-04-13
- **Lock:** `scripts/adr-fixtures.sh::expect_rejected`, `scripts/adr-fixtures.sh::expect_accepted`

## Context

There were eighteen ADRs in this directory before there was anything checking
them. They were well written and completely inert.

That is the normal fate of a decision record. It is written with real care,
during the week the decisions are being made, and then the code moves. Tests get
renamed. Files get split. A decision gets quietly reversed by a refactor that
nobody connected to the paragraph explaining why it was that way. Six months
later the directory is a museum: every file still argues confidently for a
world that no longer exists, and nobody trusts it enough to read it, and because
nobody reads it nobody notices it is wrong.

The failure is not that ADRs go stale. It is that **staleness is invisible**.
A prose file has no failing state. It cannot go red.

Meanwhile the project already had the mechanism that would fix this, applied
everywhere except here: `./scripts/check.sh` is the definition of done
(ADR-0030), and every UX behaviour worth keeping has a test that breaks when it
is undone. The record was the one artefact exempt from its own standard.

## Decision

**The decision record is subject to the same gate as the code.**
`scripts/adr-check.sh` runs inside `scripts/check.sh`, and it fails the build.

Concretely, it enforces two things and reports a third.

**It enforces that every ADR names a lock.** The `Lock:` field names the test
that goes red if the decision is undone, and the checker *resolves* it: the file
must exist, and the test name must really be in it. A lock pointing at a test
that was renamed away is a decision that is no longer defended, and the moment
that becomes true is the moment it is cheapest to fix. Four shapes are accepted,
because four exist — Rust `fn`, Swift `Suite/method`, Swift `@Test` display
name, and a shell function in a gate script.

**It enforces the shape of the record.** Five mandatory sections, none empty; a
unique number that matches the title; a `Superseded by ADR-XXXX` status that
names an ADR that was actually written. Each of these is a way the record can
start lying while still reading fine.

**It reports debt without failing on it.** `none — debt` is a legitimate value,
and the count prints on every run:

```
==> adr: 20 ADRs, 6 without a lock (debt)
```

Debt is not an error, because a rule that forbids honest debt does not produce
locked decisions — it produces locks pointed at tests that do not really cover
anything, which is worse than no lock and much harder to detect. What the rule
does forbid is debt that is *invisible*. A count you see on every run gets paid
down.

**The index is generated, not written.** `./scripts/adr-check.sh --index` reads
the titles and statuses out of the files. A hand-maintained index is wrong the
first time a file is renamed, and by ADR-0018 an index that lies is worse than
none.

**This ADR is locked by the checker itself.** Not a trick: if someone guts the
lock resolution — the one part that makes this more than a linter — `resolve_lock`
and `check_lock` stop existing, and this ADR fails its own check. The mechanism
is the first thing it defends.

## Consequences

**What it costs:**

- **Writing an ADR got harder, on purpose.** You can no longer write down a
  decision without answering "what breaks if this is undone?" Some decisions
  cannot answer, and now you have to say so in the file, in as many words.
- **The gate fails for reasons that are not the code.** Renaming a test can turn
  a green build red because of a markdown file. This is the intended trade — it
  is the moment the record would otherwise have started lying — and it will be
  annoying on a day when someone is trying to ship something unrelated.
- **The display-name lock shape is fragile by construction.** A lock naming the
  phrase inside `@Test("...")` breaks when someone rewords the phrase, which is
  a change with no behavioural meaning at all. `Suite/methodName` is the more
  stable shape and the README says so, but the fragile shape is accepted because
  it is already in use.
- **It validates form, never substance.** The checker confirms a test named
  `x` exists in file `y`. It has no idea whether that test has anything to do
  with the decision, and it never will. A lock pointed at an unrelated passing
  test satisfies every rule here. Review is the only defence, and this ADR does
  not change that.
- **A debt count that only goes up teaches nothing.** The number is printed to
  create pressure. If it never falls, it becomes scenery, and the mechanism has
  the appearance of working while doing nothing.

**What it buys:**

- A stale ADR has a failing state. That is the whole thesis.
- The link between a decision and its test is bidirectional and checked: you can
  no longer delete the test without hearing about the decision.
- New decisions are written knowing they must be defensible, which is a
  different and better kind of thinking than writing them knowing they must be
  persuasive.

## How this regresses

- **The gate call is removed from `check.sh` during a merge conflict.** One line
  disappears. Nothing fails, ever again, and the directory silently reverts to a
  museum. This is the most likely regression by a wide margin, and nothing in
  this repo detects it.
- **`none — debt` becomes the default.** It is always available and always
  passes. Nobody decides to stop locking decisions; it just becomes what one
  types when in a hurry, and the debt count climbs past the point where anyone
  reads it.
- **Locks get pointed at whatever test is nearby.** The checker is satisfied,
  the ADR looks defended, and the decision is not. Form validation invites this,
  and only a reviewer catches it.
- **The rule against editing accepted ADRs erodes first.** It is the one rule
  here that nothing enforces — no check can tell a typo fix from a rewritten
  decision. Once ADRs are edited in place, the record shows only the present,
  and the disagreement between what we thought then and what we know now — the
  entire reason to keep it — is gone.
- **What a person would notice:** they read an ADR, follow its reasoning,
  build on it, and discover the code has done the opposite for months. Then they
  stop reading ADRs. That is terminal, and it is quiet.

## When to revisit

- If the debt count stops falling for a long stretch. That means the field is
  being used as an escape hatch, and the answer is to look at what kinds of
  decisions cannot be locked — not to forbid the marker.
- If the display-name lock shape breaks the build more than once for a pure
  rewording. At that point the fragile shape should be dropped and the existing
  ADRs migrated to `Suite/methodName`.
- When the record grows past roughly fifty ADRs. Sequential numbering with fixed
  ranges is fine at twenty and will feel arbitrary at eighty; that is the moment
  to reconsider ranges, not to renumber.
- If a way appears to check that `check.sh` still calls this script. That is
  currently the single point of failure for the whole mechanism, and it is
  undefended.
