# ADR-0040: The mark is a cut zero, drawn as geometry

- **Status:** Accepted
- **Date:** 2026-04-20
- **Lock:** none — debt

## Context

The product is called `zer0`. The obvious mark is the digit, and the obvious
treatment is the slashed zero of monospaced fonts — a shape programmers already
read as "this is a zero, not a letter O".

Obvious is not the same as solved. Four directions were drawn and compared:

- the **classic slash**, a diagonal crossing the ring and overshooting it, as in
  JetBrains Mono or IBM Plex Mono;
- the **gap**, where a band is removed from the ring rather than a stroke added,
  so the cut is read as absence;
- the **rigid grid**, where every radius and weight is a clean fraction of the
  canvas;
- the **displacement**, where the zero is sliced and the halves slip.

Two findings came out of drawing them rather than reasoning about them, and both
changed the answer.

**A solid diagonal at 45° reads as the "no entry" pictogram.** Not arguably —
rasterised at 32 and 64px it is simply that sign. The planned defence, that our
bar rises left-to-right like the solidus while the prohibition sign descends,
does not survive contact: the pictogram is drawn both ways in the wild. A 3:4
variant escaped the prohibition reading and landed on the Danish Ø instead: a
letter, not a digit.

**The small sizes are where this family dies.** A zero's cut is a thin feature
inside a thin ring. At 16px the ring is about three pixels and the cut closes
under antialiasing, leaving a plain O.

## Decision

The mark is a **zero cut on the diagonal with its two halves slipped along the
cut**, like a geological fault. `design/logo/zer0.svg` is canonical.

The cut is **subtractive and displaced**, not an added stroke. That is what
takes it out of both traps: there is no bar crossing the ring, so it is not the
prohibition sign, and the halves are offset, so the outer silhouette carries a
step that no Ø has. The recognition survives before the inner gap is even
visible, because the step shows up in the outline first.

It is **drawn as path geometry, never as text in a font**:

- No `<text>`. A logo that depends on an installed font is not a logo, it is a
  suggestion.
- No `stroke`, `transform`, `mask` or `clipPath`. Anything not in the path
  geometry disappears in conversion to `.icns`, a favicon, or a font.
- No `width`/`height` on the root, and `fill="currentColor"`. Size and colour
  belong to whoever draws it.

Being free of an existing typeface is also why the proportions are ours: the
slashed zero of a monospaced font was drawn to live at a fixed width beside two
hundred other glyphs. Those constraints are not ours.

**Small sizes get their own drawing.** `.icns` carries a separate image per
size precisely so a mark can be redrawn rather than scaled down. **At 32
rendered pixels and below** the canonical file is not used; `zer0-small.svg`
takes over — a redraw, not a scale: the ring goes 32u→44u, the gap 16u→22u and
the slip 14u→20u — *this said "gap and slip roughly double"; measured against
the file, all three grow by the same ~1.375, which is the more interesting
fact and the one the prose was hiding* — and
the mark is *shortened* 80×104→72×94, because the grid scales by
the tallest dimension and height given up buys thickness everywhere else. This
is what type designers call hinting, and refusing to do it is how a mark ends up
as a smudge in the Dock.

The threshold is measured in **pixels, not points**, so 16pt@2x and 32pt@1x both
get the hinted drawing while 32pt@2x gets the canonical one. 32 rather than the
24 first assumed: at 32 the canonical cut survives only as a disturbance in the
antialiasing — present, but not legible, which is the worse failure because it
looks intentional.

**The body of the icon is the system's, not ours.** On macOS 26 the platform
already draws the rounded-square body and insets the artwork into it, so the
mark ships free-standing on transparency. Drawing our own body puts a second
squircle inside the system's — a dark tile floating in a light one — and at 16px
that degrades into a checkerboard smudge. Verified through `NSWorkspace.icon(forFile:)`,
the same path Finder and the Dock draw with, not inferred from the guidelines.

## Consequences

**The canonical file is not usable at every size, and that is a trap for the
next person.** Anyone who reaches for `zer0.svg` for a 16px favicon gets a plain
O and will not necessarily notice. The limit is written in the file's own header
comment, which is the only place someone will actually read it.

**Two files now have to stay in agreement.** The hinted master is a second
drawing of the same idea. A change to the mark that is not carried across leaves
the small sizes drifting from the large ones — the classic way icon sets rot.

**There is no wordmark and no colour.** The project has no palette at all: the
interface runs on system semantics. That was right while the mark did not exist,
and it stops being right now. This ADR does not settle it.

**The mark carries no meaning beyond the name.** It says "zero" and nothing
about browsing, speed or privacy. That is deliberate — a browser icon competing
with a globe, a compass and a fox does better as an unexplained shape than as a
worse metaphor — but it does mean the mark earns recognition only through use,
and has none on day one.

## How this regresses

Three ways, in descending order of likelihood:

1. Someone needs the mark somewhere new, reaches for the canonical SVG, scales
   it to 16px, and ships an O. Nothing errors. It just quietly stops being our
   logo in the one place people see it most.
2. Someone "simplifies" the SVG by setting it in a monospaced font with a
   slashed zero. It looks identical on their machine and renders as a fallback
   glyph, or nothing, on someone else's.
3. A conversion tool flattens the geometry — a `transform` or a `mask` creeping
   in during an export round-trip — and the cut disappears from the icon while
   the source file still looks right.

No test guards any of this today. The honest cheap fence is a check that the SVG
files contain none of the forbidden constructs and declare no `width`/`height`,
which would catch (2) and (3) but not (1). Catching (1) needs the icon pipeline
to assert which master it used per size.

*Corrected 2026-08-10: the paragraph above was written when the mark was only
ever drawn large, and it is now half false. (1) reached the shell — the sidebar
badge is 16pt — and ADR-0083 ports `zer0-small.svg` into `Zer0Mark`, routes every
drawing of the mark through one view at the same 32-pixel threshold, and locks
that routing with*
`apple/Tests/Zer0ShellTests/Zer0MarkTests.swift::Zer0MarkTests/theSmallSizesGetTheirOwnDrawing`.
*The `.icns` pipeline is still unguarded, and so are (2) and (3), so this ADR's
`Lock:` stays `none — debt`: what is now fenced is the shell's copy of the
problem, not this decision.*

## When to revisit

When the palette is decided. A mark that only exists in `currentColor` has never
been tested against a background it must live on, and colour can break a shape
that works in black — a thin cut between two mid-tone fills has far less contrast
than the same cut in black on white.

Also if the step in the silhouette turns out not to survive the platforms we do
not control: a Dock badge, a monochrome menu-bar rendering, a favicon in a tab
strip. Each of those is a size and a treatment we have not yet seen it in.
