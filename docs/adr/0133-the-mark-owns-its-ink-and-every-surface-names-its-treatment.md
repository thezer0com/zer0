# ADR-0133: The mark owns its ink and every surface names its treatment

- **Status:** Accepted; supersedes ADR-0040 where it made the mark one ink
- **Date:** 2026-09-02
- **Lock:** `apple/Tests/Zer0ShellTests/Zer0MarkTests.swift::Zer0MarkTests/theApplePortMatchesBothSvgMasters`, `apple/Tests/Zer0ShellTests/Zer0MarkTests.swift::Zer0MarkTests/theInlayDropsWhereTheHintTakesOver`, `apple/Tests/Zer0ShellTests/Zer0MarkTests.swift::Zer0MarkTests/theArtworkInkIsTheSvgPurple`, `linux/shell/src/tokens.rs::the_supplied_mark_keeps_declared_fills`, `linux/shell/src/tokens.rs::the_quiet_mark_draws_only_the_zero`, `linux/shell/src/tokens.rs::the_brand_mark_keeps_the_complete_lockup`

## Context

ADR-0040 adopted a cut zero as one-ink geometry. That decision made colour a
caller's concern: the SVG used `currentColor`, SwiftUI exposed a `Shape`, and
the two places then using the mark chose `.tertiary` or `.tint`. It also left a
small-size redraw as debt in the Apple shell.

The adopted artwork is now the complete name: a purple cut zero with a white
`zer` inlaid on its upper-right band. Treating the white path as another tintable
shape makes it disappear into the ring; dropping it everywhere discards the
supplied lockup; painting it everywhere turns a quiet empty state into branding.
The mark therefore needs intent at the one rendering door, not colour choices
distributed among its consumers.

## Decision

`design/logo/zer0.svg` owns the canonical geometry and its literal purple and
white fills. `design/logo/zer0-small.svg` owns the hinted one-path redraw used at
and below 32 rendered pixels. Both native shells consume those masters:

- **Brand** draws every layer the selected master can carry. The canonical
  master is the purple ring plus white inlay; the hinted master is the purple
  ring alone because three letters cannot survive in five pixels.
- **Quiet** draws only the ring in the semantic foreground supplied by its
  surface. It never draws the inlay and never imports brand purple into an
  empty state.

Apple names that intent through `Zer0MarkGlyph.Ink`; Linux names it through
`MarkTreatment`. Quiet is the default because omission must produce the less
assertive result. Brand is explicit at About and at badges for the browser's own
pages. The Linux empty state is explicitly quiet.

The 32-pixel switch remains the decision ADR-0040 measured. This record
supersedes its one-ink and `currentColor` claims, not its geometry, hinting, or
free-standing app-icon decisions.

## Consequences

**What hurts:**

- The Apple shell carries a coordinate-for-coordinate port of two masters and
  the canonical inlay. The SVG remains authoritative, but changing it requires
  changing the port and watching both masters' tests fail first.
- Linux parses a small, deliberately narrow SVG subset at startup. A malformed
  view box, path, fill or fill rule refuses launch rather than guessing at a
  logo.
- Brand and quiet are two real treatments of one asset. Every new mark surface
  has to say which claim it is making instead of inheriting an ambient tint.

**What we get:**

- The complete supplied lockup is recognisable wherever the browser identifies
  itself, with the same artwork-owned colours on light and dark grounds.
- Empty states keep the hierarchy they had: the mark is present, quiet and
  subordinate to the action.
- Small marks use geometry made for their pixel budget instead of scaling a
  detail until it becomes antialiasing noise.

## How this regresses

- **The empty screen grows a white scar or a purple logo above its action.** A
  quiet surface starts drawing all layers or reaches for the artwork's colour.
  `the_quiet_mark_draws_only_the_zero` goes red on Linux; Apple pixel boards make
  the hierarchy visible.
- **About says `zer0` with a plain O.** A brand surface drops the inlay or lets
  ambient foreground replace the artwork's fills.
  `the_supplied_mark_keeps_declared_fills`,
  `the_brand_mark_keeps_the_complete_lockup` and
  `theArtworkInkIsTheSvgPurple` go red.
- **A 16-point badge becomes three blurred flecks on a purple band.** The detail
  and hint thresholds diverge. `theInlayDropsWhereTheHintTakesOver` goes red.
- **One native mark drifts from the masters while still looking plausible.** A
  point, layer, fill or view box changes in only the Apple port.
  `theApplePortMatchesBothSvgMasters` goes red.

All six named locks have been watched red: the Linux treatment tests before
`layers_for` existed, the Apple treatment locks against the previous one-ink
port, the Apple parity lock against a moved canonical point, and the Linux fill
lock against a changed channel in the white layer.

## When to revisit

- If the supplied artwork changes its number of layers or needs fills other
  than literal white and `#635BC9`, revisit the parser and treatment vocabulary
  together rather than teaching one host a private exception.
- If a third treatment gains a concrete surface on both native shells, name it
  here before adding another branch to either renderer.
- If the mark is no longer used below 33 rendered pixels, remove the hinted
  master and its routing as one change.
