# apple/

The native shell: renders the core's state and carries out its commands. Decides nothing the core could decide.

- An `Action` goes to the core, `EngineCommand`s come back, the host reports facts. If two platforms could disagree about it, it belongs here; if they could not, it belongs in the core.
- Colour, spacing and scale come from `design/tokens.toml`. `scripts/token-check.sh` is the gate — a hardcoded value that disagrees with the TOML is a bug even when it looks right.
- Motion only through the `fileprivate` curves (`entrance`, `subtle`) reached via `Design.Curve` and `.motion(_:value:)`. They are `fileprivate` so only spellings that answer Reduce Motion compile; a curve written at a call site has not asked.
- There are exactly two curves, on purpose (ADR-0046). A third with no consumer is the first half of an inconsistency.
- The `ZZ*` harnesses in `Tests/` stay behind `ZER0_SHOT=1`. They are verification by looking, off the default path.
- Bindings under `Sources/Zer0Core*` are written by `apple/scripts/build-core.sh`. Never hand-edit them: change the Rust input and regenerate — an edit that cannot survive the next build is a lie with a timestamp.
- Panels put their witnesses on an `@objc` base class, dispatched by selector (ADR-0126, ADR-0127). The SDKs disagree per method, not per SDK.
