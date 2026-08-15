# ADR-0114: Bundled SQLite builds for the floor the app ships with

- **Status:** Accepted
- **Date:** 2026-08-13
- **Lock:** `apple/scripts/build-core.sh::check_bundled_sqlite`

## Context

The session store is SQLite ([ADR-0006](0006-the-session-lives-in-sqlite-with-wal-and-the-store-detaches-on-load-failure.md)),
and `rusqlite` is built with the `bundled` feature: the C source is compiled
by the `cc` crate inside `libsqlite3-sys`'s build script, and the object
lands in `libzer0_core.a` beside the Rust codegen units. The app that links
that archive promises macOS 15.4 — `Package.swift`'s platform floor,
`bundle.sh`'s `LSMinimumSystemVersion` — and a linked object's
`LC_BUILD_VERSION` is part of that promise. An object claiming a higher
minimum raises the binary's claim: the browser that says "macOS 15.4 or
newer" would refuse every machine below whatever the SDK happened to be on
build day.

The bug was measured, not inferred. `vtool -show-build` on the `sqlite3.o`
inside a freshly linked archive reported `minos 26.5`. Three layers stacked
to produce it, and fixing any one alone would have left the other two
invisible.

**`cc` answers to the environment, and the environment was silent.**
`build-core.sh` exported `MACOSX_DEPLOYMENT_TARGET=15.4`, but a bare
`cargo build`, `cargo test` or `cargo clippy` sets nothing — including the
ones `scripts/check.sh` runs before it ever calls `build-core.sh`. With the
variable unset, `cc` takes its deployment target from the installed SDK's
own version: 26.5 on the machine that measured this, far above the floor.

**Cargo's fingerprint does not track that variable.** Setting the env and
rebuilding recompiles nothing: the cached `rustc` invocation replays the old
bytes, because nothing the fingerprint records has changed. A poisoned
object survived rebuilds this way — the fix could be in place and the
archive still wrong.

**Nothing looked at the artifact.** The wrong claim sat in a load command
nobody read, inside an archive nobody unpacked, until the linker mentioned
it in passing — and a linker warning is not a gate.

## Decision

**`MACOSX_DEPLOYMENT_TARGET = "15.4"` is set in `.cargo/config.toml`'s
`[env]` — the one door every cargo invocation under the workspace walks
through.** Bare, scripted, from `check.sh`, from an editor's rust-analyzer:
all of them now compile the C object for the floor. `[env]` does not force —
a value already present in the real environment still wins. That is the
right default (a pipeline asking for something else is asking on purpose)
and the residual hole named under regression.

**`check_bundled_sqlite` inspects the archive at the link, and fails
closed.** After `cargo build`, `build-core.sh` pulls the `sqlite3.o` member
out of the archive (`ar t` / `ar p`; the pattern `sqlite3\.o$` cannot match
a Rust codegen unit, which ends `.rcgu.o`) and refuses the build on any of:

- a minimum above 15.4, read with `vtool -show-build`;
- no `LC_BUILD_VERSION` at all — an unversioned object would pass a numeric
  comparison by having nothing to compare, so it is refused rather than
  allowed to stand in for a versioned promise;
- an architecture that is not the host's (`lipo -info`).

Refuse rather than repair: the refusal names the variable, the reason a
stale object outlives a plain rebuild, and the recovery —
`cargo clean -p libsqlite3-sys -p rusqlite -p zer0-core`, plus zeroing the
`RUSTC_WRAPPER` cache if one is in play.

Two halves, one decision. The env is *prevention* — it makes the common case
compile for the floor — and cannot prove a negative: some invocation,
somewhere, will forget. The guard is *detection*, at the moment the artifact
is about to be linked into everything else, and it checks the bytes rather
than the invocation, which is why it catches what the env cannot reach. The
guard was watched failing on a deliberately poisoned object (RED) and
passing on a clean build (GREEN) before it was trusted. `scripts/check.sh`
runs `build-core.sh` on every Darwin pass, so both halves run on every gate.

## Consequences

**A bare cargo invocation can no longer leave a poisoned object behind.**
The `clippy` and `test` runs inside `check.sh` compile with the floor set,
so the most likely producer of the bug is now itself covered.

**A poisoned archive fails the build instead of linking.** The gate goes red
at the exact step that would have shipped the claim, with the recovery in
the message rather than in someone's memory of a Slack thread.

**The floor is now spelled in five places that must agree.**
`Package.swift`, `bundle.sh`'s `LSMinimumSystemVersion`, `build-core.sh`'s
export, the guard's comparison constant, and `.cargo/config.toml`. That
duplication is the cost of this decision: each tool reads its own spelling
of the same number, and none of them derives it from another. Moving the
floor is five edits and a clean rebuild — and the revisit clause below.

**Linux builds carry the variable inertly.** `[env]` applies workspace-wide,
and `cc` only consults `MACOSX_DEPLOYMENT_TARGET` for Apple targets, so the
Linux CI leg sets a variable nothing reads. Harmless today; worth a re-read
when a Linux host exists.

## How this regresses

**"Someone deletes `.cargo/config.toml`."** It is an eleven-line file at the
workspace root that looks exactly like the kind of stray a cleanup removes.
Deleting it reopens the bare-cargo door silently — no error, no warning —
and the guard is the only thing watching: the next scripted build goes red
the moment a cache-refreshed object carries the wrong claim, instead of the
next machine refusing to open the app. The lock holds the guard in the gate
(`check.sh` runs `build-core.sh` on every Darwin pass); what no lock can see
is the comparison inside it being relaxed "temporarily" — this ADR is the
argument against that.

**"Someone exports `MACOSX_DEPLOYMENT_TARGET=26.x` globally."** A shell
profile or a CI image doing this wins over `[env]`, by design, and every
object compiles for 26.x. The guard refuses at the link with the variable
named in the message, which is the recovery path: the failure tells you
which door to look behind. A quieter failure — everything builds, nothing
runs on 15.x — is exactly what this shape prevents.

**"sccache replays the old bytes."** The fingerprint gap is still there:
with the env correct, a `RUSTC_WRAPPER` cache holding pre-fix compilations
will happily keep serving them, and `cargo clean` of the three crates does
not touch it. The guard catches this because it inspects the linked
artifact rather than any invocation's inputs — the same object, the same
`vtool` read, the same refusal. This is the regression the guard was watched
failing on.

## When to revisit

- **When the floor moves.** Five spellings of 15.4 must move together, and
  that is the moment to ask whether one of them should derive the others —
  a script reading `Package.swift`, say — rather than duplicating the
  number a sixth time. Until a floor actually moves, the duplication is
  cheaper than the derivation.
- **When cargo tracks this env var in fingerprints.** The staleness layer
  disappears; the env half of the decision becomes uncontroversial. The
  guard stays regardless — an artifact-level check is independent of how
  the artifact got wrong, and `vtool` does not care who compiled the object.
- **When a build targets something that is not this host.** The guard's
  architecture check assumes the build host is the target; an iOS host or a
  cross-compile needs that check re-read, not just the env re-set.
- **When `RUSTC_WRAPPER` becomes standard here.** If sccache arrives in the
  project's own tooling, the gate should zero it for the affected crates
  itself rather than tell a person to — the message already names it.
