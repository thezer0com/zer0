#!/usr/bin/env bash
# Design tokens are data: this proves the Swift shell still agrees with them.
#
#   ./scripts/token-check.sh
#
# The tokens are stated once, machine-readable, in design/tokens.toml, so
# every shell (macOS today; iOS/Android/Linux/Windows to come) consumes one
# artifact instead of re-transcribing DESIGN.md's tables (ADR-0117). What this
# refuses is drift: the macOS shell still spells its tokens by hand in
# DesignSystem.swift, Palette.swift and PaletteProposals.swift, and a hand
# copy of data drifts — one side gets edited, the other quietly doesn't, and
# two platforms ship two spacings under one name.
#
# Compared value by value, in both directions (a token present on one side
# only is the same drift as a value changed on one side only): spacing,
# stroke, radius, glyph, durations, pane, motion.spring, elevation, the type
# tokens' style/weight/tracking, the fixed type sizes (greetingSize,
# FieldSize), and every palette hex.
#
# Deliberately NOT compared: [type].pt, the point size macOS resolves for
# each semantic text style. The Swift side names a style and the platform
# supplies the number, so there is nothing to compare against — those values
# are platform-resolved data for the other shells, documented in the TOML
# header with the OS they were measured on. Not debt: by design, until a
# second shell exists to check against.
#
# Debt, honestly: nothing numeric. `subtle` is easeOut(quick) — derived, not
# a second number — and Reduce Motion resolution lives in Design.Motion,
# which is behaviour spelled in code, not a token. If a future token shape
# defeats the parsers below, the checker says its anchor rotted rather than
# passing silently.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TOKENS="design/tokens.toml"
SWIFT_DESIGN="apple/Sources/Zer0Shell/DesignSystem.swift"
SWIFT_PALETTE="apple/Sources/Zer0Shell/Palette.swift"
SWIFT_PROPOSALS="apple/Sources/Zer0Shell/PaletteProposals.swift"

check_tokens() {
	python3 - "$TOKENS" "$SWIFT_DESIGN" "$SWIFT_PALETTE" "$SWIFT_PROPOSALS" <<'PY'
import re
import sys
import tomllib

tokens_path, design_path, palette_path, proposals_path = sys.argv[1:5]

failures = []
compared = 0
documented_pt = 0


def fail(msg):
    failures.append(msg)


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def uncomment(text):
    # Braces inside `//` comments would defeat the brace-scoped block
    # extraction below; no code line in these files contains `//`.
    return "\n".join(line.split("//", 1)[0] for line in text.splitlines())


def brace_block(text, anchor):
    """The `{...}` block that follows the first match of `anchor` regex."""
    m = re.search(anchor, text)
    if m is None:
        return None
    start = text.index("{", m.end())
    depth = 0
    for i in range(start, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[start:i]
    return None


def numeric_constants(block):
    """`static let <name>: CGFloat|Double = <value>` pairs."""
    return {
        m.group(1): float(m.group(2))
        for m in re.finditer(
            r"static let (\w+): (?:CGFloat|Double) = ([0-9]+(?:\.[0-9]+)?)", block
        )
    }


def fmt(v):
    return "%g" % v


def compare(table, toml_side, swift_side, where):
    """Compare scalar-or-table values both ways, naming every disagreement."""
    global compared
    for key in sorted(set(toml_side) | set(swift_side), key=str):
        label = f"{table}.{key}"
        if key not in toml_side:
            fail(f"{label}: in {where} but not in {tokens_path}")
            continue
        if key not in swift_side:
            fail(f"{label}: in {tokens_path} but not in {where}")
            continue
        t, s = toml_side[key], swift_side[key]
        if isinstance(t, dict) and isinstance(s, dict):
            compare(label, t, s, where)
        elif isinstance(t, (int, float)) and isinstance(s, (int, float)):
            if float(t) != float(s):
                fail(f"{label}: {tokens_path} says {fmt(t)}, {where} says {fmt(s)}")
            else:
                compared += 1
        elif isinstance(t, str) and isinstance(s, str):
            if t != s:
                fail(f"{label}: {tokens_path} says \"{t}\", {where} says \"{s}\"")
            else:
                compared += 1
        else:
            fail(f"{label}: cannot compare {type(t).__name__} against {type(s).__name__}")


with open(tokens_path, "rb") as f:
    tokens = tomllib.load(f)
design = uncomment(read(design_path))

# --- the plain numeric enums ---------------------------------------------

for table, enum in [
    ("spacing", "Space"),
    ("stroke", "Stroke"),
    ("radius", "Radius"),
    ("glyph", "Glyph"),
    ("durations", "Duration"),
    ("pane", "Pane"),
]:
    block = brace_block(design, rf"\benum {enum}\b")
    if block is None:
        fail(f"{design_path}: no `enum {enum}` to read {table} from")
        continue
    compare(
        table,
        tokens.get(table, {}),
        numeric_constants(block),
        f"`enum {enum}` in {design_path}",
    )

# --- motion.spring --------------------------------------------------------

m = re.search(
    r"Animation\.spring\(response: ([0-9.]+), dampingFraction: ([0-9.]+)\)", design
)
spring = tokens.get("motion", {}).get("spring", {})
if m is None:
    fail(f"motion.spring: no `Animation.spring(response:dampingFraction:)` in {design_path}")
    for key in spring:
        fail(f"motion.spring.{key}: in {tokens_path} but the spring is gone from {design_path}")
else:
    compare(
        "motion.spring",
        spring,
        {"response": float(m.group(1)), "damping": float(m.group(2))},
        f"the `entrance` curve in {design_path}",
    )

# --- elevation ------------------------------------------------------------

elev_block = brace_block(design, r"\benum Elevation\b")
swift_elev = {}
if elev_block is not None:
    for em in re.finditer(
        r"static let (\w+) = Level\(opacity: ([0-9.]+), radius: ([0-9.]+), y: ([0-9.]+)\)",
        elev_block,
    ):
        swift_elev[em.group(1)] = {
            "opacity": float(em.group(2)),
            "radius": float(em.group(3)),
            "y": float(em.group(4)),
        }
compare("elevation", tokens.get("elevation", {}), swift_elev, f"`enum Elevation` in {design_path}")

# --- type: styles, weights, and the fixed sizes ---------------------------

text_block = brace_block(design, r"\benum Text\b")
swift_type = {}
if text_block is None:
    fail(f"{design_path}: no `enum Text` to read the type tokens from")
else:
    for tm in re.finditer(
        r"static let (\w+) = Font\.system\((\.\w+)(?:, design: \.(\w+))?\)(?:\.weight\(\.(\w+)\))?",
        text_block,
    ):
        name, style, design_mod, weight = tm.groups()
        entry = {"style": style[1:], "weight": weight or "regular"}
        if design_mod:
            entry["design"] = design_mod
        swift_type[name] = entry

type_tables = {
    k: v
    for k, v in tokens.get("type", {}).items()
    if isinstance(v, dict) and k not in ("field", "greetingSize")
}
# `pt` is platform-resolved data (see the TOML header) and `tracking` has its
# own anchor below; neither is compared against `enum Text`.
type_clean = {}
for name, tbl in type_tables.items():
    if "pt" in tbl:
        documented_pt += 1
    type_clean[name] = {k: v for k, v in tbl.items() if k not in ("pt", "tracking")}
compare("type", type_clean, swift_type, f"`enum Text` in {design_path}")

# Tracking: exactly one letter-spaced spelling exists, .sectionHeading().
# More than one on either side means this anchor rotted, not that they match.
toml_tracking = {n: t["tracking"] for n, t in type_tables.items() if "tracking" in t}
swift_tracking_m = re.search(r"\.tracking\(([0-9.]+)\)", design)
if len(toml_tracking) == 1 and swift_tracking_m is not None:
    name, value = next(iter(toml_tracking.items()))
    if float(value) != float(swift_tracking_m.group(1)):
        fail(
            f"type.{name}.tracking: {tokens_path} says {fmt(value)}, "
            f"`.sectionHeading()` in {design_path} says {swift_tracking_m.group(1)}"
        )
    else:
        compared += 1
else:
    fail(
        "type.*.tracking: expected exactly one tracking token and exactly one "
        f"`.tracking(...)` in {design_path} — the checker's anchor rotted, "
        "extend it rather than trusting this green"
    )

# The fixed sizes: greetingSize lives in `enum Text`, FieldSize in its own.
if text_block is not None:
    greeting = tokens.get("type", {}).get("greetingSize", {})
    gs = numeric_constants(text_block).get("greetingSize")
    if isinstance(greeting, dict) and "pt" in greeting:
        if gs is None:
            fail(f"type.greetingSize.pt: in {tokens_path} but `greetingSize` is gone from `enum Text`")
        elif float(greeting["pt"]) != gs:
            fail(
                f"type.greetingSize.pt: {tokens_path} says {fmt(greeting['pt'])}, "
                f"`enum Text` in {design_path} says {fmt(gs)}"
            )
        else:
            compared += 1

field_block = brace_block(design, r"\benum FieldSize\b")
compare(
    "type.field",
    tokens.get("type", {}).get("field", {}),
    numeric_constants(field_block) if field_block is not None else {},
    f"`enum FieldSize` in {design_path}",
)

# --- palette --------------------------------------------------------------

# The 13 paired hexes live in fault(dark:)'s two Zer0Palette constructors —
# the dark branch returns first. The 4 adoption additions (chrome, rule,
# selectedRow, companionRow) are single-line swatch functions in Palette.swift.
swift_palette = {"light": {}, "dark": {}}
proposals = uncomment(read(proposals_path))
fault = brace_block(proposals, r"static func fault\(")
if fault is None:
    fail(f"{proposals_path}: no `static func fault(dark:)` to read the palette from")
else:
    ctors = re.findall(r"Zer0Palette\(([^)]*)\)", fault)
    if len(ctors) != 2:
        fail(
            f"{proposals_path}: expected the dark and light `Zer0Palette(...)` "
            f"constructors in fault(), found {len(ctors)} — the checker's anchor rotted"
        )
    else:
        for appearance, ctor in zip(("dark", "light"), ctors):
            for pm in re.finditer(r"(\w+): 0x([0-9A-Fa-f]+)", ctor):
                swift_palette[appearance][pm.group(1)] = "#%06X" % int(pm.group(2), 16)

for sm in re.finditer(
    r"static func (\w+)Swatch\(dark: Bool\) -> Swatch \{ dark \? 0x([0-9A-Fa-f]+) : 0x([0-9A-Fa-f]+) \}",
    read(palette_path),
):
    swift_palette["dark"][sm.group(1)] = "#%06X" % int(sm.group(2), 16)
    swift_palette["light"][sm.group(1)] = "#%06X" % int(sm.group(3), 16)

palette_where = "the Swift palette (PaletteProposals.swift fault(), Palette.swift)"
compare("palette.light", tokens.get("palette", {}).get("light", {}), swift_palette["light"], palette_where)
compare("palette.dark", tokens.get("palette", {}).get("dark", {}), swift_palette["dark"], palette_where)

# --- verdict ---------------------------------------------------------------

if failures:
    for message in failures:
        print(f"error: {message}", file=sys.stderr)
    print(
        f"error: {len(failures)} token disagreement(s) between {tokens_path} and the Swift shell.",
        file=sys.stderr,
    )
    print(
        "  Tokens are data (ADR-0117): change the value in design/tokens.toml and in",
        file=sys.stderr,
    )
    print(
        "  the Swift consumer in the same PR, or add/remove the token on both sides.",
        file=sys.stderr,
    )
    sys.exit(1)

suffix = ""
if documented_pt:
    suffix = f", {documented_pt} type sizes documented as platform-resolved (unchecked by design)"
print(f"==> tokens: {compared} values agree between design/tokens.toml and the Swift shell{suffix}")
PY
}

check_tokens
