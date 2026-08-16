# ADR-0117: Design tokens are data, and the shell must agree with them

- **Status:** Accepted
- **Date:** 2026-08-16
- **Lock:** `scripts/token-check.sh::check_tokens`

## Context

zer0 is going multi-platform — iOS, Android, Linux and Windows are the
direction, and the promise is one experience, not five approximations of one.
The design tokens that experience is made of — spacing, radius, stroke,
durations, the spring, elevation, the type scale, the whole B·Fault palette —
currently exist in two places: tables in DESIGN.md's prose, and hand-written
enums in `DesignSystem.swift` / `Palette.swift` / `PaletteProposals.swift`.
Two copies is one more than a project can hold honestly, and five shells
reading prose is five transcriptions to get wrong. The typography is worse
than duplicated: the point sizes the semantic text styles resolve to on macOS
existed only inside two sentences of DESIGN.md §2 prose, so no other platform
could consume them at all.

Nothing today can notice the two copies disagreeing. `PaletteContrastTests`
recomputes ratios from the `Swatch` bytes, which keeps the palette's
*relationships* honest but not the doc's account of the values; DESIGN.md's
tables are checked by nobody.

## Decision

**The tokens are stated once, as data, in `design/tokens.toml` — and
`scripts/token-check.sh`, run by `scripts/check.sh` at the gate, proves the
Swift shell agrees with that file value by value, in both directions.**

- **Keys are the Swift token names, spelled identically.** The checker maps by
  name, never by position: a renamed token fails loudly instead of silently
  pairing with its neighbour.
- **Both directions are compared.** A value changed on one side, or a token
  added or removed on one side only, is the same defect — drift — and gets the
  same red build naming the token.
- **The change rule is mechanical:** edit the TOML and the Swift consumer in
  the same PR and the gate stays green; edit either alone and it goes red.
  DESIGN.md keeps the *why* (criteria, arguments, what a token is for); the
  TOML is the *what*. A criterion change still edits DESIGN.md — and usually
  the ADR that owns the decision.
- **`[type].pt` is data, not a checked contract.** The point size macOS
  resolves for each semantic text style at the default text size is recorded
  measured (macOS 27.0, build 26A5406e), documented in the TOML header, and
  deliberately not compared: the Swift side names a style and the platform
  supplies the number, so there is nothing to compare against. Other shells
  resolve the same styles against their own scales.
- **The Swift enums stay hand-written for now.** Generating them from the TOML
  is a future PR, taken when a second consumer exists to pay for it; today the
  checker is what makes the hand copy safe.

## Consequences

**A second shell consumes one artifact, not a translation of prose.** The
Linux shell reads `design/tokens.toml`; the gate here already proves the
macOS numbers are those, so "identical experience" starts from checked data
instead of from two people reading the same table the same way.

**The typography has numbers other platforms can see.** The resolved macOS
pt/weight/tracking per token — previously two sentences of prose — is now in
the same file, stamped with the OS it was measured on.

**Adding a token is two edits by design.** A new spacing value that exists
only in Swift fails the gate until it is also stated as data; that refusal is
the point. The failure names the token and both files.

**DESIGN.md's tables become commentary, and can age.** The doc's token tables
are now the *criterion* columns reading matter; the numbers they quote are
checked copies of the TOML. Where the two ever disagree, the TOML wins and the
prose is stale — the checker says which, per token.

**Scope of the check is stated in the script, not implied.** Everything
numeric and every hex is compared: spacing, stroke, radius, glyph, durations,
`motion.spring`, elevation, pane, type styles/weights/tracking, the fixed
sizes (`greetingSize`, `FieldSize`), and all 17 palette tokens × 2
appearances. Nothing numeric is left out; `[type].pt` is excluded on purpose
and says so in both the script header and the green line's count.

## How this regresses

**"Someone edits `DesignSystem.swift` without the TOML."** The exact drift
this exists for — a value nudged in Swift reads as a one-line fix and ships
two spacings under one name. `check_tokens` goes red naming the token, both
values, and both files.

**"Someone 'fixes' the red by editing the TOML to match the Swift."** The
checker cannot tell an intentional change from a drift papered over; this
record is the argument that the red means *decide*, not *silence*. A value
change is a design change: it edits both sides together, with the criterion
that moved.

**"The call disappears from `check.sh`, and the lock keeps resolving."** The
lock proves the function exists, not that anything runs it — the same gap
ADR-0116 names for its own budget. Removing the invocation is a review concern
this record makes deliberate.

**"The parsers' anchors rot.** `DesignSystem.swift` gets restructured — the
`Level(...)` initialiser changes shape, `fault(dark:)` moves — and the
checker's regexes stop matching. It is built to say so (`no enum ... to read
from`, `the checker's anchor rotted`) rather than pass silently, but a
checker error message is not a checked token: fix the parser in the same PR
as the refactor.

**"The TOML grows a second truth.** Someone edits the TOML's *commentary*
(the per-token notes) into contradiction with DESIGN.md's criteria. Comments
are not checked and were never meant to be; the criterion lives in DESIGN.md
and the ADRs, and a comment that disagrees with them is a doc bug, not a gate
failure.

## When to revisit

- **When the second shell lands.** Generate the Swift (and the other shell's)
  token declarations from the TOML and delete the hand copy — the checker then
  becomes a test that generation ran, which is a smaller claim than the one it
  makes today.
- **When a platform needs a token macOS does not.** A third typography weight,
  an elevation step macOS's three don't cover: the TOML will need
  platform-scoped values rather than one column. Decide that shape when a real
  consumer asks, not before.
- **When the measured `[type].pt` drifts.** A macOS update that moves the
  resolved sizes makes the recorded numbers stale. They are stamped with the
  OS they were measured on; re-measure rather than trust, and treat a change
  as news about the platform, not about this file.
