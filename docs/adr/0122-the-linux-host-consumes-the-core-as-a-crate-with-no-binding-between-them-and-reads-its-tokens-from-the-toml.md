# ADR-0122: The Linux host consumes the core as a crate, with no binding between them, and reads its tokens from the TOML

- **Status:** Accepted
- **Date:** 2026-08-16
- **Lock:** none — debt

## Context

The core's own crate documentation has said since the beginning that the same
core drives "a `WKWebView` on macOS and a `webkit2gtk` view on Linux without
changing", and ADR-0121 closed with the promise that "Linux will be a new
host, not a rewrite." This record is that sentence with a working example —
and with the three traps the example surfaced.

**The workspace gates have no GTK.** `scripts/check.sh` and the `linux-core`
CI job run `cargo clippy`/`cargo test` with no `-p`, and in a virtual
workspace that means every member. A GTK shell in `members` would turn every
existing gate red on machines that lack GTK and WebKitGTK headers — which is
all of them. The shell must be a member (fmt, one workspace, one lockfile)
without being in the default build.

**The capabilities door lived behind the FFI.** ADR-0118 put
`HostCapabilities` at the constructors of the `Zer0` object and the keymap
retirement in a private `ffi.rs` function. A host that links the core as a
crate never sees either: the type was not even re-exported at the crate root.
A second declaration of the same rule in the Linux shell would be the rule at
two doors, which is one bug away from being two rules.

**A third shell reads the tokens.** ADR-0117's file header already names
"Linux/Windows to come" as consumers of `design/tokens.toml`. The macOS copy
is hand-written and held by `scripts/token-check.sh`; a Linux shell that
hand-copied the hexes would be a third transcription of the same data, which
is the exact drift the ADR exists to prevent.

## Decision

**The Linux host is `linux/shell`, a workspace member that consumes
`zer0-core` as a path dependency — no FFI, no generated binding — and it is
kept out of the default build so the existing gates keep meaning what they
meant.** Five parts:

**1. A crate, not a binding.** `zer0-core`'s public surface is the protocol:
`zer0_core::{Action, EngineCommand, dispatch, Session, HostCapabilities}`.
The shell sends actions in, carries commands out on WebKitGTK, and reports
engine facts (`NavigationStarted`, `TitleChanged`,
`NavigationStackChanged`, …) back as actions. The `ffi` feature stays
Apple-only, exactly as its Cargo.toml comment always said ("a Linux engine
host has no reason to pull in uniffi"). The one core change this needed was
exporting `HostCapabilities` from the crate root — the wire a host declares
on was already defined unconditionally, just unreachable.

**2. `default-members = ["crates/zer0-core"]`.** Bare `cargo` commands —
`check.sh`, the `linux-core` job — keep meaning "the core". The shell is
still a member: `cargo fmt --all` formats it, one workspace lints it
(including ADR-0031's no-wildcard rule, which the shell inherits and
exercises over both `UiCommand` and `EngineCommand`), and the `linux-shell`
CI job builds it explicitly with `-p`.

**3. The retirement moved to the one door.** `retire_what_the_host_cannot_run`
is now a method on `Session`, called by the FFI constructors (behaviour
unchanged, all four ADR-0118 locks still green) and by the Linux host at its
own door. The host declares `extension_runtime: false` (WebKitGTK has no
public extension runtime) and `page_printing: false` (WebKitPrintOperation
exists; the wiring is a named follow-up, and the declaration flips the day it
lands) — the honest answers, in the one place each host states what it is.

**4. Tokens are read at runtime, never copied.** The shell parses
`design/tokens.toml` with `toml_edit` (the same parser the core's config
reads) at startup, applies the light or dark palette as GNOME's
`color-scheme` answers, and paints header bar, tab strip, address field and
window from it — chrome is painted, not blurred (ADR-0043), so solid colours
from the file are the whole job. A missing or malformed file refuses to
start: a fallback palette would be the second truth ADR-0117 forbids. v1
first consumed only the palette and two spacing families; the amendment
below records the pass that made the loader read every section and the
chrome wear the system.

**5. What v1 does, it does through the core.** One window, one space, a tab
strip with one WebKitGTK view per tab (as `CreateWebView` commands), the core
keymap answering chords (Ctrl is primary on Linux — the keymap is minted
knowing that), and the command bar submitting raw text to
`Action::NavigateTo`, because URL-versus-search is the core's decision, not
the shell's. Nothing is persisted: no session store, no history on disk. The
`EngineCommand` and `UiCommand` variants this host has no surface for are
each named, routed through an explicitly named `not_carried_out_yet` that
says why — a wildcard would be the silence ADR-0031's lint exists to prevent,
and a new variant breaking this build until it earns an arm is the point.

## Consequences

**The protocol is proven portable, not promised.** 32 `EngineCommand` arms
and 46 `UiCommand` arms compiled against a second engine and a second
toolkit with one re-export added to the core. That is the evidence for
ADR-0002's split being real: everything the arms disagreed about was
rendering, everything they agreed about was behaviour.

**`cargo` on a laptop without GTK still works, and says less.** A developer
running bare `cargo test` after editing the shell must know to add `-p
zer0-linux`; the runner that knows is CI. The cost of the workspace not
breaking is one flag, paid by one job.

**The third token consumer has no checker.** macOS is compared value by
value by `token-check.sh`; this shell has no gate-side comparison because it
has no copy — it reads the file, so the numbers cannot drift, but a rename
or a shape change in the TOML becomes a startup refusal on Linux rather than
a red build on every machine. That asymmetry is the named debt of this
record's lock.

**The User-Agent is not this host's to fake.** The core composes a
Safari-shaped UA (ADR-0008, ADR-0119) from host-supplied facts; WebKitGTK
would be supplying facts about a Safari it is not. v1 leaves WebKitGTK's own
honest default in place; what a WebKitGTK host should truthfully supply is
an open question the revisit below owns.

**What hurts:** two `load` boundaries. WebKitGTK's default session backs
every space's view, so per-space cookie jars — the core's isolation unit —
do not exist on this host yet, and `DeleteDataStore` rightly says there is
nothing to delete. Per-space `NetworkSession`s are the follow-up that make
the core's `data_store_id` mean on Linux what it means on macOS.

## How this regresses

**"The shell is quiet; give the wildcard back."** Someone tired of writing
arms for commands this host ignores replaces the tail with `_ =>`. The
workspace lint denies it, and the next `EngineCommand` variant compiles
nowhere until someone decides, out loud, which side of the door it is on —
which is ADR-0031 doing precisely what it was built for.

**"The Linux job is red on a machine without GTK; put the shell in
`default-members` so it is built everywhere."** That turns every existing
gate red on every machine that lacks the headers — the exact failure this
record's second decision exists to prevent. The fix direction is the
opposite: the job installs the headers, and everyone else keeps `-p`.

**"A missing tokens file should fall back to sensible defaults."** The
refusal path is the fence. A fallback palette is a second copy of the
design system wearing a try/catch, and the day someone ships it, Linux and
macOS can disagree with nothing red anywhere.

**"`retire_what_the_host_cannot_run` is fine as an FFI free function
again."** The move is what keeps one rule at one door; the four ADR-0118
locks hold the FFI half, and the Linux host holding the method in its
constructor is the visible other half. A revert needs this record's
argument, not a merge conflict.

**"The lock points at the `linux-shell` CI job."** It cannot: `adr-check`
resolves Rust tests, Swift tests and shell functions, and a workflow job is
none of those. Naming a core test that does not exercise the shell would buy
confidence with nothing behind it — worse than the declared debt, which is
counted on every run.

## When to revisit

- **When a gate-side check for the shell exists** — a script that runs the
  shell's clippy or its own tests wherever the gate runs. That script's
  function becomes this record's lock, and the debt line goes away.
- **When the Linux User-Agent is decided.** What a WebKitGTK host supplies
  to `user_agent()` (ADR-0119) — and whether the composed shape admits a
  non-Safari engine suffix — is a decision about honesty to sites, not a
  config value, and it needs its own measured argument.
- **When per-space isolation arrives.** `NetworkSession` per `data_store_id`,
  `DeleteDataStore` growing a real deletion, and the session store feature
  (`Store`, ADR-0017's refusal shape) turning this from a browser that writes
  nothing into one that remembers. Each arrives with its own decision.
- **When the command bar grows its dropdown.** `command_bar::suggest` is
  public and untouched; wiring it is UI work, not protocol work, and the
  ranking arrives from the core rather than being reinvented per shell.
- **When `page_printing` can honestly flip.** `WebKitPrintOperation` wiring,
  then the one-line declaration change — and the keymap grows the chord back
  with nothing else to do, which is ADR-0118's whole ceremony in reverse.

## Amendment — dressing the shell in the whole file (2026-08-16)

Decision 4 above first read "v1 consumes the palette plus the spacing and
radius rungs its surfaces actually draw; the rest of the file is untouched
debt." This pass retired that debt, and the record of how is kept here
because three of its choices are approximations someone will be tempted to
"fix" into regressions.

**The loader reads every section.** Palette (thirteen tokens per
appearance), all seven spacing rungs, three radii, both strokes, three glyph
sizes, both durations, the spring, three elevation steps, every type token
plus the two field sizes, and the pane floor. Unknown values refuse at
startup — a weight the CSS layer cannot spell, a `design` this consumer does
not know — so a change to the TOML is either worn or loud, never silently
rounded. What is loaded but unworn carries an `#[allow(dead_code)]` whose
comment names the surface that will wear it; the debt is visible instead of
absent.

**What the chrome wears, all generated from the file.** Tab titles are
`type.row` (11pt), the address field is `rowTitle` (13pt/500), the empty
screen is `emptyTitle` (17pt/600) over `detail` with its chord in `mono`;
hover is ink at 6% and press at 12% (DESIGN.md §4 states the hover depth as
behaviour, not data — until the TOML carries interaction alphas, those two
numbers are this shell's named debt); the active tab sits on `selectedRow`
with ink on it, a pair the palette guarantees 4.5:1 by construction; the
hairline rule under the strip and the separators between tabs are `rule` at
`stroke.hairline`; the entry's focus ring is `accent` at `stroke.insertion`,
drawn transparent at rest so focus does not shift the field by its own
width; the empty screen's action is `accent`/`onAccent` with the hover and
pressed variants from the file.

**Motion is an approximation and is named as one.** DESIGN.md has two
curves; GTK has CSS `transition`. `subtle` — easeOut over `durations.quick`
— is worn honestly as `transition: background-color 180ms ease-out` on the
hover and press states. `entrance`, the spring, has no GTK equivalent
without physics this shell does not carry: nothing fakes it, the spring's
numbers are loaded so the approximation sits beside the data it
approximates, and the first arriving panel re-decides against libadwaita or
manual frames rather than inheriting a guess.

**Elevation is emitted and unworn, on purpose.** The three steps exist as
`.elevation-resting/.floating/.overlay` box-shadows generated from the TOML,
and no v1 surface takes one: "a shadow is earned by distance", and nothing
in this window has left a surface. The classes are generated rather than
hand-written so the first popover arrives at the right depth with no number
to forget.

**The mark is read, not ported.** macOS ports `zer0.svg`'s geometry into a
SwiftUI `Shape`; GSK speaks SVG path syntax, so this shell extracts the `d`
attribute from the same file the tokens walk finds and hands it to
`gsk::Path::parse` — one less transcription than the reference shell, which
is the whole argument of ADR-0117 taken further. Colour is the palette's
tertiary ink ("large, quiet and low-contrast on purpose", DESIGN.md §5),
size is `glyph.mark` at 72, and the empty browser screen is a product
screen: "Nothing open", a line saying what the button does, one prominent
New Tab whose chord is re-read from the live keymap on every sync and which
answers Return as the window's default widget.

**The loading bar says only what the engine says.** 2pt (`spacing.line`) of
accent laid over the page's top edge through an Overlay, filled by
WebKitGTK's `estimated-load-progress` and never animated — a smoothed bar
would claim progress the engine did not report, which is ADR-0018's rule
one layer up. The estimate notification is deferred to an idle, because it
can change while a dispatch still holds the host borrow — the same
reentrancy shape the module header describes.

**Two defects the file was carrying, found and fixed.** `tab.id == active`
compared a `TabId` to an `Option<TabId>`, and `views.get(&active)` passed
the Option where the id was expected — compile errors in a file no gate had
ever built, because it had never been committed. Proof, again, that "it was
written" and "it compiles" are different claims, and that a shell no
machine in the room can build is a shell nobody has built.

**What this machine could prove, and what it could not.** A laptop without
the GTK headers proved: `cargo fmt --all --check`, `cargo tree -p
zer0-linux` resolving, and the tokens module compiled standalone (std +
`toml_edit`) with its five unit tests green — the loader, the CSS it emits
for both appearances, the refusal paths and the mark extraction all ran.
What only the `linux-shell` job and a first Linux run can prove: that
`host.rs` and `main.rs` type-check against gtk4-rs 0.11 and webkit6 0.6,
that GSK accepts the SVG's elliptical-arc commands, that GTK renders the
transitions and box-shadows as specified, and that Return activates the
empty screen's default button. Those are this amendment's named debts; the
CI job already holds the compile half, and an Xvfb or Broadway screenshot
job closes the visual half the day a screen worth screenshotting exists —
the empty screen is now one. The unit tests ride along wherever the crate
compiles; they run under `cargo test -p zer0-linux`, which the job does not
run yet.
