# Contributing to zer0

The conventions this project works by — what goes where, what has to be true
before a change is done, how a decision gets recorded — live in
[`CLAUDE.md`](CLAUDE.md) and [`DESIGN.md`](DESIGN.md). Read `CLAUDE.md` first;
it is short and it is the part that settles arguments. This file is the
mechanical half: how to build, how to verify, and where things are.

## What you need

- macOS 15.4 or newer. The floor is `WKWebExtension`, which is public API from
  15.4 and not before.
- Xcode, for the Swift toolchain and the SDK.
- A stable Rust toolchain, with `clippy` and `rustfmt`.

There is no Linux shell yet. The core builds and its tests run on Linux, and CI
keeps it that way on purpose — see [CI](#ci).

## Build

```sh
./scripts/build.sh            # debug   → apple/.build/Zer0.app
./scripts/build.sh release    # optimised
open apple/.build/Zer0.app
```

`build.sh` runs three steps. Run them separately while developing if you prefer:

```sh
./apple/scripts/build-core.sh [debug|release]        # cargo build + regenerate bindings
cd apple && ZER0_RUST_PROFILE=debug swift build
./apple/scripts/bundle.sh [debug|release]            # wrap in Zer0.app, ad-hoc sign
```

Two things to know about that middle step:

- **The Swift bindings are generated, not committed.** `build-core.sh` runs
  `uniffi-bindgen` and writes `apple/Sources/Zer0Core/zer0_core.swift` and
  `apple/Sources/Zer0CoreFFI/`. A `swift build` without it fails, or worse,
  builds against a stale bridge.
- **`ZER0_RUST_PROFILE` tells `Package.swift` which `target/` directory to link
  against.** Without it `swift build` links the debug core, which is right while
  developing and wrong in a release.

`ZER0_OPEN_URL=https://example.com apple/.build/Zer0.app/Contents/MacOS/Zer0`
launches straight into a page.

The bundle is **ad-hoc signed**, deliberately without the hardened runtime.
That is enough to run on the machine that built it and it is not enough for
anyone else's machine. `docs/webkit.md` explains why the hardened runtime is
left off and what would have to change to ship.

## Verify

```sh
./scripts/check.sh
```

Green is the definition of done ([ADR-0030](docs/adr/0030-check-sh-green-is-the-definition-of-done.md)),
and there is no shortcut around it. In order, it runs:

1. `./scripts/adr-check.sh` — every ADR's `Lock:` is resolved against the file
   it names, sections are present and non-empty, numbers are unique.
2. A guard that every `@Test` in `apple/Tests/**/ZZ*.swift` is gated on
   `ZER0_SHOT`.
3. `cargo fmt --check`, `cargo clippy -- -D warnings`, `cargo test --all-features`.
4. On macOS only: `build-core.sh`, `swift build`, `swift test`.

The `ZZ*` files are offscreen render and motion harnesses rather than
assertions — they pump the run loop for tens of seconds and would starve the
timing tests. Run them on purpose:

```sh
ZER0_SHOT=1 swift test --filter ZZ
```

They exist because a claim about motion is worth what the frames are worth.
They read geometry across layout passes rather than pixels, for a reason
documented in `DESIGN.md` §3: `cacheDisplay` on an `NSHostingView` draws the
*model* layer, so a view part way through a transform-based transition
photographs as "never moved".

### Probes that touch `native_host`

A `ZZ*` probe that drives `chrome.runtime.connectNative` (or anything else that
routes through `core.native_host`) needs a non-nil `storagePath`, or the core
has no `application_support` root and `native_messaging::outcome` refuses in
its fallback path — the sheet never rises, the helper never spawns, and the
probe reports "nothing happened" for a reason that is the harness's, not the
browser's. The pattern is in
`apple/Tests/Zer0ShellTests/ZZNativeMessagingProbe.swift`: build a throwaway
root under `/tmp`, point `BrowserModel(storagePath:)` at `<root>/zer0/profile.sqlite`,
and the core reads NMH registrations from `<root>/zer0/NativeMessagingHosts/`
beside it. `ZER0_PROBE_APPROVE=1` makes the probe answer "allow" on the sheet
automatically, so a run that is watching the gate does not also have to click
it. `ZER0_PROBE_DIR=<dir>` redirects the probe's log file somewhere other than
`$TMPDIR`.

## Where things are

```
crates/zer0-core/        the whole core: state, reducer, and every decision
apple/Sources/Zer0Shell/ the macOS shell — views, WKWebView hosting, hosts
apple/Sources/Zer0Core/  generated uniffi bindings (not committed)
apple/Tests/             Swift tests, including the ZZ* render harnesses
docs/adr/                one file per decision, numbered, never renumbered
design/                  the mark, the palette boards, rendered proposals
scripts/                 build, check, adr-check
scripts/webkit/          fetch and build a pinned WebKit from source
apple/scripts/           build-core, bundle, embed-webkit, run-with-webkit
```

`crates/` holds exactly one crate. Everything except MCP sits behind a Cargo
feature — `store` (SQLite), `ext` (CRX), `config` (TOML), `provider` (LLM wire
formats) — and `ffi` turns on all of them. The Apple build always takes `ffi`.
The features exist so a host that does not want persistence or extensions is a
smaller build rather than a fork.

## The two rules that decide where code goes

Both are from `CLAUDE.md` and both are worth repeating here because they are the
ones a first patch gets wrong:

**Behaviour goes to the core; appearance stays in the shell.** If two platforms
could reasonably disagree about something, that something is in the wrong place.
Ranking, the keymap, tab lifecycle, routing, what a downloaded file is named,
whether a progress bar can fill at all — core. Colour, spacing, animation curve,
label copy — shell. `DESIGN.md` §1 has the ambiguous cases already resolved, and
each one was decided against the obvious reading; read it before arguing a new
one.

**No `default:` in a switch over a command or an action.** A new command has to
break the build until it earns behaviour ([ADR-0031](docs/adr/0031-no-default-in-a-switch-over-a-command-or-an-action.md)).

## Decisions get recorded

Every decision worth arguing about gets an ADR in `docs/adr/`. The format and
the two rules that hold it up are in
[`docs/adr/README.md`](docs/adr/README.md); the short version:

- The title states what was decided, affirmatively. "WebKit is the engine, not
  Chromium", not "Engine choice".
- Five sections, none empty: Context, Decision, Consequences, How this
  regresses, When to revisit.
- A `Lock:` field naming the test that goes red if the decision is undone.
  `adr-check.sh` resolves it — the file must exist and the name must really be
  in it. A lock pointing at a renamed test fails the gate.
- `none — debt` is a legal lock and prints as a count on every run, because a
  number you see every day gets paid down and a number behind a flag does not.
- An accepted ADR is not edited; it is superseded by a new one. A *factual*
  error is corrected in place and the correction is left visible.
- The index is generated: `./scripts/adr-check.sh --index`. Never hand-written.

Take the next free number. Never reuse one, never renumber.

## Tests

Tests cover behaviour, not pixels — but UX behaviour is behaviour. Focus, order,
selection, what Enter does, where the cursor lands: those get a test. Where a
claim needs eyes to make, it is either a `ZZ*` harness that reads geometry or it
is written down as unverified. Both are better than an assertion nobody checked.

## CI

`.github/workflows/ci.yml` runs two jobs on every push and pull request:

- **macOS** — `./scripts/check.sh`, the whole gate.
- **Linux** — `cargo fmt --check`, `cargo clippy -D warnings`, `cargo test` on
  the core alone. This one exists to prove the core stays free of Apple
  assumptions well before a Linux engine host exists.

## Licence

Contributions are under the MIT licence in `LICENSE`. If a change touches what
ships in a bundle — a new dependency, anything to do with embedding WebKit —
read [`docs/licensing.md`](docs/licensing.md) first.
