# ADR-0003: uniffi bridges Rust↔Swift

- **Status:** Accepted
- **Date:** 2026-01-09
- **Lock:** `apple/Tests/Zer0ShellTests/ShortcutTests.swift::ShortcutTests/everyBoundCommandIsHandled`

## Context

ADR-0002 puts all behavior in Rust and all rendering in Swift. That is only
sustainable if crossing the boundary is cheap to write and expensive to get
wrong. The alternatives were hand-writing `extern "C"` with a header maintained
in parallel, generating the header with `cbindgen` (which solves the header and
does not solve the Swift side), or `swift-bridge`.

What settled it was the maintenance cost on the Swift side: enums with payloads,
`Option`, `Vec`, and an error type crossing the ABI. Writing that by hand is
where projects like this die.

## Decision

`uniffi` 0.32, with proc-macro scaffolding (`uniffi::setup_scaffolding!()` in
`lib.rs`), not a UDL file. Types are annotated where they already live:
`#[derive(uniffi::Record)]` on `Tab`, `Space`, `SpaceProfile`,
`NavigationError`; `#[derive(uniffi::Enum)]` on `Action` and `EngineCommand`;
`#[derive(uniffi::Object)]` on the `Zer0` handle.

Three deliberate details:

- **The generator is a binary of the crate itself**
  (`src/bin/uniffi-bindgen.rs`, `required-features = ["ffi"]`), so the generator
  version cannot drift from the lib version.
- **The FFI sits behind a feature.** `ffi = ["dep:uniffi", "store", "ext"]`, off
  by default, with the comment spelled out in `Cargo.toml`: "a Linux engine host
  has no reason to pull in uniffi". The bridge is the Apple host's decision, not
  the core's.
- **The generated Swift is not committed.**
  `apple/Sources/Zer0Core/zer0_core.swift` and `apple/Sources/Zer0CoreFFI/` are
  written by `apple/scripts/build-core.sh` and excluded by `.gitignore`, so a
  fresh checkout does not build until that script has run once. `swift build`
  never sees a stale copy, because there is no copy to go stale.

  **Factual correction.** This bullet used to read "The generated Swift is
  checked into the repo (`apple/Sources/Zer0Core/zer0_core.swift`), because
  `swift build` needs it before any generation step can run." That was never
  true, and it was contradicted by two files in this repository: `.gitignore`
  excludes exactly that path, and `build-core.sh` says "the generated sources
  are not committed" in its own header. The decision it sits under did not move
  — uniffi still generates the bridge and the generator is still a binary of
  the crate — so this is corrected here rather than superseded. What the wrong
  sentence would have cost someone: looking for a file that is not in the
  history, or committing one and giving every later diff a 15,000-line
  passenger.

### The friction that actually showed up: name collisions with SwiftUI

`uniffi` publishes everything into a flat namespace in the Swift module, and
SwiftUI already owns the obvious names. Two collided, and both were renamed in
the annotation, not in the Rust code:

```rust
// crates/zer0-core/src/model.rs
#[cfg_attr(feature = "ffi", derive(uniffi::Record), uniffi(name = "BrowserTab"))]
pub struct Tab { … }

// crates/zer0-core/src/shortcuts.rs
#[cfg_attr(feature = "ffi", derive(uniffi::Record), uniffi(name = "ShortcutBinding"))]
pub struct Binding { … }
```

`Tab` collides with the `Tab` SwiftUI started exposing on macOS 15+. `Binding`
collides with SwiftUI's `Binding`, which is everywhere. Both comments in the
code say the same thing, and it is honest: "an ambiguous type lookup is a
miserable thing to debug". Rust still reads `Tab` and `Binding`; only Swift sees
`BrowserTab` and `ShortcutBinding` (`BrowserModel.swift`, `Sidebar.swift`,
`ExtensionHost.swift`).

## Consequences

- **Contract checking happens at runtime, not at compile time.** The generated
  Swift carries per-method checksums and validates them on first use; a mismatch
  gives `fatalError("UniFFI API checksum mismatch: try cleaning and rebuilding
  your project")`. Which means: forgetting to run `apple/scripts/build-core.sh`
  before `swift build` compiles fine and blows up at runtime. It is the worst
  class of failure we accept here, and we accept it because the alternative was
  no checking at all.
- **A huge generated file, and a build step nobody can skip.**
  `zer0_core.swift` is over 15,000 lines today. Because it is generated rather
  than committed, that costs build time instead of review time — and it costs
  the rule that `apple/scripts/build-core.sh` runs before `swift build`, every
  time, on every machine.

  **Factual correction.** This read "A huge generated file in the repo …
  shows up in every diff that touches the boundary, hiding the real change
  inside the noise". It shows up in no diff: the file is not tracked. Same
  wrong premise as the Decision bullet above, and the line count was stale by a
  factor of three besides.
- **The model gets pushed toward plain data.** Everything that crosses becomes a
  `Record`/`Enum` — no lifetimes, no `&str`, no type whose invariant is held by
  a private method. That already shaped `model.rs`: the fields are public
  because they have to be.
- **Every future collision costs a rename.** The namespace is flat and SwiftUI
  grows with every release. `Space`, `Route`, `Preferences` and `Key` are the
  obvious candidates for the next clash, and the cost of finding out is always
  the same unreadable ambiguous type lookup error.
- **Ties us to a pre-1.0 third-party crate.** `uniffi` 0.32 can break
  compatibility on any minor, and the generator lives inside our crate precisely
  because that drift is the expected failure mode.

## How this regresses

Two distinct symptoms:

1. Someone drops `uniffi(name = "BrowserTab")` or
   `uniffi(name = "ShortcutBinding")`. The happy case is the Swift build failing
   with an ambiguous type lookup. The bad case is it **compiling**, resolving to
   the SwiftUI type in a context where both fit, and the error surfacing as
   wrong behavior on screen.
2. Someone changes a signature under `#[uniffi::export]` without regenerating.
   The app compiles and dies at the checksum `fatalError` on the first call.

`everyBoundCommandIsHandled` covers both cheaply: it reads `m.keymap`, which is
`[ShortcutBinding]` coming over FFI, and iterates running each command. If the
rename disappears, the file does not compile; if the bindings are stale, the
test blows up on the checksum before the first `#expect`. It was not written for
this, but it is what holds.

**What is missing:** nothing tests that `BrowserTab` and `ShortcutBinding` are
exactly those names. A test declaring `let _: BrowserTab.Type = BrowserTab.self`
would make the intent explicit instead of relying on incidental use.

## When to revisit

When the Linux host exists: there the core is linked directly by another Rust
crate and `uniffi` never enters the picture (that is why `ffi` is opt-in). If at
that point the `Action`/`EngineCommand` boundary needs a different shape to
serve both, this decision comes back to the table.

And when `uniffi` breaks compatibility in an upgrade the repo has to take — at
that point the question is migrate or leave, not migrate by reflex.
