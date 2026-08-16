# ADR-0116: Icons come from one licensed set, and SF Symbols do not grow

- **Status:** Accepted
- **Date:** 2026-08-15
- **Lock:** `scripts/sf-symbol-budget.sh::check_sf_symbol_budget`

## Context

zer0 is going multi-platform — iOS, Android, Linux and Windows are the
direction, and AGENTS.md already commits to a Linux host being "a new host
rather than a rewrite". The shell today draws its icons from SF Symbols —
**112 sites of them, measured 2026-08-15: 66 `systemName:` and 46
`systemImage:` under `apple/Sources/Zer0Shell`** — and SF Symbols render on
Apple platforms only. Every one of those sites is a place every other host
will have to invent an answer for.

The count is also free to grow. A new `Image(systemName:)` is the obvious
spelling in any SwiftUI file, autocomplete offers it, and it looks like no
decision at all — which is how a surface quietly re-locks itself to Apple one
keystroke at a time. Left alone, the port bill grows with every PR that adds
an icon.

Three ways out were weighed:

- **Draw our own set.** The author is a UI person, but a browser needs on the
  order of a hundred icons that read at 13pt, sit on a grid, and stay
  consistent as the set grows. That is months of work that produces nothing a
  person can browse with.
- **Keep SF Symbols on Apple, substitute per platform.** Every platform
  substitutes differently, so "identical experience" becomes N experiences to
  keep visually in step — the multi-platform problem again, one level down.
- **License one set for every platform.** One visual answer, vendored, that no
  platform vendor owns.

The set is **Lucide**: ISC license — permissive enough that vendoring the SVGs
into this repository is allowed, with no attribution clause and no copyleft —
and **stroke-based**, drawn on a 24pt grid with a default stroke of 2, which is
the same weight as the heaviest line the design system names
(`Design.Stroke.insertion`, 2 — DESIGN.md §Stroke). A filled glyph system
would sit next to hairline borders and stroke-drawn chrome; a stroke set sits
in them. SF Symbols matches Apple's materials best and is exactly the one that
cannot come with us.

## Decision

**Lucide is licensed (ISC) and vendored, and becomes the shell's one icon set.
The 112 SF Symbol sites do not grow: `scripts/sf-symbol-budget.sh` holds the
count at a budget — 112 today — and `scripts/check.sh` runs it on every
gate.**

- **Migration is incremental, per component, in the PRs that touch them.**
  Nothing migrates in this PR; the budget is what makes "later" a direction
  rather than a hope. Each migration PR lowers the budget in the same commit —
  a ratchet, not a ceiling. Where the vendored assets live and how the shell
  renders them arrive with the first migration PR, not before.
- **The mark does not change.** [ADR-0040](0040-the-mark-is-a-cut-zero-drawn-as-geometry.md)'s
  cut zero is drawn as geometry, not taken from any font; licensing an icon
  set has nothing to say about it.

## Consequences

**A new icon on any platform comes from Lucide.** The 112 existing sites keep
rendering as SF Symbols until their component migrates — the budget counts
sites, not what anything looks like, so nothing changes at runtime today.

**The budget fails closed and only moves down.** The script refuses a count
above it and names this ADR in the failure. Below it, the run is green but the
message says to lower the budget in the same PR — slack in a ratchet is slack
the next addition spends for free.

**SF Symbols stay reachable where the system itself asks for them.** The
budget counts zer0's own icon sites (`systemName:` / `systemImage:` in
`apple/Sources/Zer0Shell`), not what macOS renders internally. SwiftUI
controls that take an SF Symbol as part of their platform material are not
this decision's subject; zer0's own labels are.

## How this regresses

**"Someone adds one more `Image(systemName:`, because it is right there."**
This is the regression the whole shape is built around: the addition is one
keystroke, reads as the obvious choice on macOS, and each one widens the port
bill. `check_sf_symbol_budget` goes red at the gate the same day, with the
count, the budget and this ADR in the message.

**"Someone raises the budget 'temporarily'."** No lock can see a constant
being edited; this record is the argument against it. Raising the budget is
reopening this decision, and the honest way to do that is a superseding ADR,
not a number that quietly moves.

**"The call disappears from `check.sh`, and the lock keeps resolving."** The
lock proves the function exists, not that anything runs it — the same gap
ADR-0114 names for its own guard. Removing the `check.sh` invocation is a
review concern this record makes deliberate: the budget defends nothing the
day it stops running.

**"The migration stalls at some number above zero, and the budget becomes
furniture."** A ratchet nobody drives down is a ceiling with better manners.
The count is printed on every run, green or red, so the remainder stays in
sight instead of behind a flag.

## When to revisit

- **When Lucide reads badly at `control` size (13pt).** The smallest icon site
  in the design system is a whole-control label at 13pt (DESIGN.md §Icon
  scale). If 24pt-grid strokes close up or read fuzzy at that size on any
  platform, the set is wrong at a size this design actually uses — reopen
  before migrating the small sites, not after.
- **When coverage forces mixing sets.** If a surface needs an icon Lucide does
  not carry and the easy answer becomes "just this one SF Symbol", one set was
  the decision and mixing two is the N-platforms problem wearing a license.
  Reopen and decide the exception; do not mix quietly.
- **When the stroke weight diverges.** The match with the `Stroke` tokens is a
  measurement of the set's defaults. If a Lucide release or a platform's
  conventions move the weight, the reason it was chosen moved with it.
