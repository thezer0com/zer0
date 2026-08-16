# Lucide — the licensed icon set

This directory is the vendoring home of the icon set ADR-0116 licenses:
[Lucide](https://lucide.dev), ISC, stroke-drawn on a 24pt grid with a default
stroke of 2. The set's license is [`LICENSE`](LICENSE) beside this file.

**It is the home of assets, not of boards.** Screenshot harnesses write their
output elsewhere; what lands here is source: the upstream SVGs, the license,
and this record of how both are kept honest.

## Current state — read this before trusting the paths

This directory was created **offline**. No upstream SVG has been fetched yet,
and no release is pinned. The first five icons (the ones the find bar's
migration needed) were ported by hand into
`apple/Sources/Zer0Shell/LucideIcon.swift` from the set's published geometry —
shapes the set inherited from Feather and has carried unchanged — and each
port quotes the SVG `d` attribute it came from in a comment beside it. They
are verified two ways that do not need the network: `LucideIconTests` checks
the geometry (subpaths, ink bounds, the direction a chevron points), and
`ZER0_SHOT=1 swift test --filter ZZLucideShots` renders the set to boards a
person can open.

What that verification cannot prove is **byte-for-byte agreement with a
pinned upstream release** — a coordinate that drifted upstream between
releases would still pass, because the geometry reads correctly on its own.
That is the debt below.

## Vendoring, once there is a network

Pin one release and vendor only the icons a consumer needs — an icon with no
call site is stockpile, and stockpile rots:

```sh
git clone --depth 1 --branch <tag> https://github.com/lucide-icons/lucide.git /tmp/lucide
# For each icon a migrating component needs, e.g. `search`:
cp /tmp/lucide/icons/search.svg design/lucide/
```

Then, in the same PR:

1. **Verify the license.** `diff /tmp/lucide/LICENSE design/lucide/LICENSE`.
   The file here was written offline from the standard ISC template; the
   pinned tag's file is the authority. Record the tag in this README.
2. **Port the drawing.** Add the case in `LucideIcon.swift` with the SVG's
   `d` quoted beside it, exactly as the existing five do.
3. **Earn a row in `LucideIconTests`** — the suite holds the expected ink
   bounds and subpath count per case and fails until the new one has vouched
   geometry.
4. **Look at it.** `ZER0_SHOT=1 swift test --filter ZZLucideShots` and open
   the boards; then lower `scripts/sf-symbol-budget.sh` by the sites the
   migration removed.

## Icons vendored

| Icon | Lucide file | First consumer |
|---|---|---|
| `search` | `icons/search.svg` | `FindBar` (leading glyph) |
| `chevron-up` | `icons/chevron-up.svg` | `FindBar` (previous match) |
| `chevron-down` | `icons/chevron-down.svg` | `FindBar` (next match) |
| `check` | `icons/check.svg` | `FindBar` (found status) |
| `x` | `icons/x.svg` | `FindBar` (close) |

## Debt

- **Fetch the pinned release and reconcile.** Vendor the five SVGs, diff the
  `d` attributes against the Swift ports, verify `LICENSE` byte-for-byte, and
  pin the tag in the table above. Until then the paths here are honest
  geometry, not a verbatim vendor.
