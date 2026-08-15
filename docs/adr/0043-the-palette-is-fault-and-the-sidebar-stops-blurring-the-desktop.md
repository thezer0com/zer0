# ADR-0043: The palette is B · Fault, and the sidebar is painted rather than blurred

- **Status:** Accepted
- **Date:** 2026-04-30
- **Lock:** `apple/Tests/Zer0ShellTests/PaletteContrastTests.swift::AdoptedPaletteTests/theShellWearsFault`, `apple/Tests/Zer0ShellTests/PaletteContrastTests.swift::AdoptedPaletteTests/theSelectedRowIsSeenAndItsLabelIsRead`, `apple/Tests/Zer0ShellTests/PaletteContrastTests.swift::AdoptedPaletteTests/theSidebarDrawsThePalettesSurface`, `apple/Tests/Zer0ShellTests/PaletteContrastTests.swift::AdoptedPaletteTests/noViewSpellsAStatusColourForItself`

## Context

ADR-0040 drew the mark and then said, in as many words, that it could not
finish the job:

> *"There is no wordmark and no colour. The project has no palette at all: the
> interface runs on system semantics. That was right while the mark did not
> exist, and it stops being right now. **This ADR does not settle it.**"*

DESIGN.md §7 carried the same hole under the heading *"Colour, which mostly does
not exist yet"*, with an instruction attached: **do not add a colour constant
until it is decided.** That instruction was right and it has been honoured; this
ADR is what discharges it.

Three candidate palettes were built as inert token sets in
`PaletteProposals.swift` and rendered side by side to `design/palette/`, so the
choice could be made by looking rather than by reading adjectives:

- **A · Paper** — *"the browser has no colour so the page can."* Warm neutrals,
  one low-chroma ink-blue that appears only where something is selected.
- **B · Fault** — *"the mark is a cut zero: cold, geometric, and the colour
  commits to that."* One saturated ultramarine on neutrals tinted to the same
  temperature.
- **C · Spaces** — the accent belongs to the active Space rather than to the
  product, so which identity you are in is visible without reading a label.

Two things were true of the rendered boards and both matter here.

**The boards did not differ where it counts most.** On `04-sidebar-light.png`
all three palettes produced an identical selected row, because that row is
`.selection` and `.selection` resolves to the *system* accent — the colour macOS
is set to, not the colour the shell asks for. The single most-looked-at accent
surface in the product was outside every proposal.

**The sidebar was not the palette's to paint at all.** It is a material, and a
material at the window's edge with nothing opaque behind it samples the desktop.
Checked against the actual wallpaper file, the sidebar rendered the same dark
charcoal in the light board *and* the dark board, because the photograph behind
the window was dark. That is the status quo, and keeping it is a choice as much
as changing it is: it means the browser's appearance is a function of which
photo somebody picked.

Alongside both, `.orange`, `.red` and `.green` were written as concrete system
hues at about a dozen sites — the consent sheet's risk tiers among them, where
the three colours are a *rank* and a tier that moves on its own is a rank that
lies.

## Decision

**The palette is B · Fault.** It is the only one of the three that gives zer0 a
colour a person could describe over the phone, and the mark it has to sit beside
is a cut zero — cold and geometric. A palette that apologised for that would be
answering a different mark. The hue runs violet where Safari and Chrome run
cyan, which is deliberate: the shelf zer0 is on is already full of blue.

Adoption is `.zer0Palette()` at the root of all three windows, which re-points
`.tint`, the `.primary` → `.secondary` → `.tertiary` ladder and the window
background in one place. That was the payoff of spelling the accent `.tint` and
never `Color.accentColor` (DESIGN.md §7), and it holds.

Three things a root modifier cannot reach are decided here rather than left to
be discovered:

**1. The selected row gets a colour of its own, and its strength is derived.**
`Palette.selectedRow` is a wash of the accent, and the value is not taste — it
is the only band where two requirements both hold:

- the state must be **seen**: 3:1 against the sidebar's own surface, which is
  WCAG 1.4.11's floor for information carried by something other than text, and
  "this row is the one you are on" is exactly that;
- the label must still be **read**: 4.5:1 for primary ink laid on it, because
  the row keeps the same ink ladder every other row in the sidebar uses.

A solid accent fill with white text — the macOS default look — was the
alternative, and it was declined: it needs the row's own text to flip to
`onAccent`, which is a change to the row rather than to the palette, and it
would put the sidebar's selection on a different rule from everything else in
the shell. The companion row, the other half of a split, is defined as the
**luminance midpoint** between the sidebar and the selected row, which turns
*"the same colour and plainly less of it"* from an impression into a number.

**2. The sidebar is a painted surface, not a material.** It is
`Palette.chrome`, a colour the palette owns, and nothing outside the palette
gets a say in it.

The argument for keeping the behind-window blur is real and worth stating: it is
the macOS idiom for a sidebar. Finder, Mail and Notes all do it, and the desktop
showing faintly through is part of why a Mac window feels like it is sitting on
something rather than pasted over it. Against that:

- **the Theme setting does not currently hold.** Choose Light with a dark
  wallpaper and the sidebar is dark. Nothing on the Appearance pane explains
  that, and no reading of "Light" predicts it. That is not native integration,
  it is a setting that does not work.
- **a browser frames arbitrary content all day.** Chrome tinted by a photograph,
  an inch from a page whose colour we also do not choose, is two uncontrolled
  colours meeting at an edge.
- **the palette cannot reach the largest chrome surface in the product**, which
  makes *"neutrals tinted to the same temperature"* — the whole of Fault's
  thesis — untrue of the surface with the most pixels in it.

**The first attempt was to keep the material and change what it samples**: an
`NSVisualEffectView` with `.withinWindow` blending, drawn over a chrome fill.
That reads well in source and it does not work. Rendered offscreen and sampled,
the sidebar came out `#F3F3F3` in light and `#353535` in dark against a palette
asking for `#F0F0F6` and `#181925` — the effect view paints its own achromatic
backdrop over whatever is behind it. It is a system colour with extra steps, and
what it overwrites is precisely the surface this decision is about. Keeping it
would have been the same defect with a nicer name on it.

So the trade is stated plainly rather than dodged: **the sidebar loses its
translucency, and gets a colour.** What separates it from the page is colour and
an edge instead of depth. Materials keep every place they still earn — the
command bar, the download shelf, the find bar, the install banner and the
consent sheet all float over a live page, and blurring page content is what a
panel over a page is *for*. Only the surface at the window's edge, which had
nothing real to blur, gave one up.

That this was got wrong twice by reading APIs instead of pixels is why the lock
is a render and a sampled pixel rather than an assertion about a field.

**3. `warning`, `danger` and `success` come from the palette.** Every
`.orange` / `.red` / `.green` in the shell is now `Design.Palette.*`. `SiteBadge`
stays exempt and says why in its own header: it is a hash of a hostname, not a
palette.

## Consequences

- The shell has a colour. `Design.Palette` in `Palette.swift` is the one place
  it is stated; `PaletteProposals.swift` stays as the record of what was on the
  table, with its header corrected to say which one was taken.
- Every token is a `Swatch` — bytes — and reaches the screen as one dynamic
  `Color` per token, resolved against the drawing appearance. No view reads
  `colorScheme` to pick a hex, so no view can forget to.
- `DESIGN.md` §7's instruction *"until that is decided, do not add a colour
  constant"* is discharged. Colour constants now belong in `Design.Palette` and
  nowhere else, which is a stricter rule than the one it replaces.
- The sidebar is no longer translucent, and it no longer desaturates when the
  window loses key. Both are real losses and both are the price of the two
  defects above. Neither is expensive to reverse if the sidebar reads as flat in
  daily use rather than in a render.
- The panels that float over the *page* — the command bar, the download shelf,
  the find bar, the install banner, the consent sheet — keep `.regularMaterial`
  untouched. They blur page content, which is in-window and is exactly what a
  panel over a page should be doing. Only the surface at the window's edge had
  the problem, and only it changed.
- Contrast is checked, not asserted: `PaletteContrastTests` recomputes every
  ratio from the same bytes that are drawn, for the adopted tokens as well as
  the three candidates.

## How this regresses

- **Someone sets Theme to Light and gets a dark sidebar**, or two people running
  the same build screenshot the same window and get chrome of two different
  colours. That is the behind-window blur back.
- **The selected sidebar row changes colour when someone changes their macOS
  accent in System Settings.** That is `.selection` back, and it means the row
  a person looks at more than any other has left the palette.
- **The selected row's label goes hard to read**, or the row stops standing out
  from the sidebar around it — the two ends of the band the fill was derived
  from, which is what happens when a shade is nudged by eye.
- **The consent sheet's risk tiers drift apart from the rest of the product**:
  `critical` red and a destructive button's red stop being the same red, and the
  rank stops being a rank. That is a system hue creeping back into a view.
- **Text stops clearing AA on the sidebar's surface**, which is the failure mode
  a new surface introduces and the old one could not, because until now the
  sidebar had no surface anybody controlled.

## When to revisit

- **If the Spaces idea (proposal C) is revisited as a layer on top rather than
  instead of.** Fault and per-Space colour are not mutually exclusive: a Space
  hue could tint `chrome` a few percent while the accent stays Fault's. That is
  a different decision and it should be a different ADR, but this one does not
  block it.
- **If a favicon or page-derived colour lands in the sidebar.** Two colour
  sources on one surface need a rule about which wins, and there is none today.
- **If the sidebar's loss of translucency reads as flat in daily use**, rather
  than in a render. The honest way to reopen it is a build with behind-window
  blending restored *and* the Theme setting fixed some other way — because the
  Theme bug, not the aesthetics, is what settled this.
- **If AppKit's `NSVisualEffectView` gains a way to tint its backdrop.** That is
  the exact missing piece: today it paints an achromatic grey over whatever is
  behind it, and a tintable one would give the translucency back without giving
  up the surface. Reopen it by rendering and sampling, not by reading the
  header.
