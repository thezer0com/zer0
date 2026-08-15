# ADR-0102: CI runs the one gate on the oldest macOS zer0 claims, and adds only what a laptop cannot say

- **Status:** Accepted
- **Date:** 2026-08-10
- **Lock:** none — debt

## Context

ADR-0030 says a change is done when `./scripts/check.sh` exits zero. That leaves
CI with an awkward job, because the obvious thing for CI to do — run the checks —
has already happened on the machine that pushed. If CI runs the same command in
the same conditions, it proves one thing only: that nothing needed an uncommitted
file. Real, and thin.

So the question this file answers is not "what should CI check". It is: **what
can CI say that the author's laptop cannot, and what must it never say that the
laptop would not?**

The second half matters more than it sounds. Every knob CI has — a different
runner, a serialised test flag, a rerun, an extra step — buys a fact at the price
of moving CI away from the thing the author actually ran. ADR-0030 already names
where that ends: *"a check is added to CI instead of here… it catches them twenty
minutes after the author moved on. The script stops being the definition and
becomes a subset of it."*

Three things forced a decision rather than a default.

**The author's toolchain is already the newest one.** Local is Xcode 26.6, build
17F113, Swift 6.3.3, compiling against the macOS 26 SDK. The GitHub `macos-26`
image ships Xcode 26.6 build 17F113 — the same build, to the digit. A CI job
there is the laptop with a different hostname.

**Nothing has ever run zer0 on the macOS it claims to support.** `Package.swift`
declares `platforms: [.macOS("15.4")]` and `build-core.sh` exports
`MACOSX_DEPLOYMENT_TARGET=15.4`, both because `WKWebExtension` is 15.4+
(ADR-0001). The floor is asserted in two files and observed in none.

**The Swift build looked like the expensive half, and is not.** Measured on the
author's 14-core machine, into an empty scratch path so nothing was warm:

| | wall | cpu |
| --- | --- | --- |
| `swift build --build-tests`, cold | 27.6 s | 94.8 s |
| the same, after `touch`ing every source | 18.6 s | 68.7 s |

The second row is what a restored cache actually gets you, because SwiftPM's
llbuild decides staleness on mtime: touching a file whose bytes did not change
recompiles it, and `actions/checkout` stamps every source with the time it
checked out. So a perfectly restored `.build` still recompiles all 146 units. The
saving is the 9 s that is linking and module cache. The directory that has to
move to buy it is 536 MB, 137 MB compressed.

## Decision

**Three jobs, and each one has to answer a question the laptop cannot.**

1. **`record`** — `adr-fixtures.sh`, `adr-check.sh`, `scratch-check.sh` on
   `ubuntu-latest`. ~26 s measured. `check.sh` still runs all three and must keep
   doing so; this is the cheap end of the same gate brought forward, so a `Lock:`
   pointing at a renamed test is heard in a minute rather than after a macOS
   build.
2. **`macos`** — `./scripts/check.sh`, whole, on **`macos-15`** with
   **`DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer`**.
3. **`linux-core`** — `fmt`, `clippy`, `test` on the **default** feature set,
   where `store`, `ext`, `config`, `prose` and `ffi` are all off. Not `check.sh`,
   which uses `--all-features` and would hide exactly this.

**The macOS job runs on the floor, not on the author's OS.** `macos-15` is macOS
15.7.7. It is the only place anything ever proves that a binary deployed at 15.4
starts, draws and passes its tests on a macOS 15. `macos-26` would compile with a
byte-identical Xcode to the author's — which is precisely why it proves less.

**Xcode is pinned to 26.3, the newest that image carries.** New enough to be one
minor from the author's, so the compiler is not a source of surprise; the SDK is
macOS 26.2, which is fine because the deployment target is the thing that gates
availability and it is 15.4. And the job prints `sw_vers`, `xcodebuild -version`,
`swift --version`, `rustc --version` and the SDK version and path before it does
anything, because a year from now the first question about a failure is which
compiler, and that answer cannot be recovered after the image moves on.

**Nothing caches the Swift build.** The numbers above are the whole argument:
moving 137 MB compressed and unpacking 536 MB, twice, to save at most 9 s of a
27.6 s build, and only the part that was never going to recompile anyway. The
Rust half is cached and worth caching — `target/` is 2.3 GB and 163 crates deep,
with a bundled SQLite in it — with `cache-on-failure: true`, so a flaky Swift
test does not throw away a Rust cache that was fine, and `save-if` limited to
`main`, so branches do not evict each other out of a 10 GB ceiling.

**CI adds no flag `check.sh` does not have.** No `--no-parallel`, no rerun. The
Swift suite is timing-fragile today — ~571 mostly-`@MainActor` tests through one
lane, and a test measured at 0.6 s alone has been seen taking 116.9 s under
full-suite load. The answer to that is not a flag that makes CI green under
conditions the author never runs under. It is `timeout-minutes: 60`, so the real
failure mode — a run that never ends — fails inside the hour instead of hanging
for the default six.

**A security advisory blocks.** `cargo audit`, in its own workflow so a weekly
schedule does not drag the macOS job along, on every push to `main` and every
pull request, plus Mondays. Plain, so it fails on vulnerabilities and only warns
on unmaintained, unsound and yanked. This is a browser: it is the process on the
machine that eats the most hostile input, and behind it are a bundled SQLite, a
zip reader and a Markdown parser.

## Consequences

**What it costs:**

- **An advisory published on a Tuesday turns an unrelated pull request red on
  Wednesday**, and the author cannot fix it by fixing his change. That is
  intended: what is true on Wednesday is that this repository ships a
  known-vulnerable dependency, and that is true of the pull request too. The
  escape hatches — `cargo update`, or `[advisories] ignore` in
  `.cargo/audit.toml` with a sentence saying why — both leave a record. A
  non-blocking version leaves none, because nobody reads a green run.
- **The macOS job compiles with a compiler the author does not have.** Xcode 26.3
  against his 26.6. A language feature that lands in 26.4 is a red build he
  cannot reproduce, and the fix is to notice that rather than to shrug.
- **The macOS build is a minute or so slower than it would be with a warm
  `.build`.** That is bought deliberately and the receipt is in the table above.
- **`dtolnay/rust-toolchain@stable` floats.** A new stable Rust can land a clippy
  lint that reddens an unrelated change. It floats on the laptop too, so this is
  matched rather than divergent — but it is unpinned, and a `rust-toolchain.toml`
  would make the Rust half as pinned as the Xcode half.
- **The `record` job runs three scripts that `check.sh` runs again.** Deliberate
  duplication. It is only defensible while it stays seconds.

**What it buys:**

- The 15.4 floor stops being an assertion in two files and becomes something
  observed on every push.
- CI cannot drift stricter or laxer than the machine the author verified on,
  because on macOS it runs the same command with no arguments.
- A broken decision record is heard in a minute.
- A hung runner fails loudly in an hour instead of silently in six.
- A pull request from a fork runs exactly what a branch runs: no job reads a
  secret, no job needs write, so there is no second, weaker CI for outsiders.

## How this regresses

Not by argument. Every one of these looks like an improvement from a distance.

- **Someone moves the macOS job to `macos-26`,** because the image is newer and
  the Xcode matches the author's exactly. Both true. The floor check disappears
  in the same commit and nothing goes red, because nothing was testing the floor
  except the runner itself. The symptom arrives months later as a user on macOS
  15 reporting that the app does not launch.
- **Someone unpins the Xcode,** because `DEVELOPER_DIR` looks like clutter and the
  default works. It works until an image update, and then an ADR that cites
  measured SDK behaviour is being defended by a different SDK.
- **Someone adds a Swift build cache,** because every other repository has one and
  the Rust half already does. It will appear to work — caches always do — and it
  will move 536 MB per run to save nine seconds. If you are about to do this,
  measure the two rows above again first; if they have changed, this ADR is what
  should change.
- **Someone adds `--no-parallel` or a rerun to CI** on the first flaky day. Green
  stops meaning what `check.sh` means, and ADR-0030 dies of it.
- **Someone makes `cargo audit` non-blocking** on the first Wednesday it is
  inconvenient. It never blocks again, and the advisory it would have caught is
  in a log nobody opens.

**No lock.** A test could grep `.github/workflows/ci.yml` for `macos-15` and for
the Xcode path, and it would be a spelling lock of exactly the kind ADR-0030
refuses: red on a harmless rewrite, green on a job someone quietly deleted. The
honest cover is that the runner OS is load-bearing at runtime — if `macos-15`
becomes `macos-26`, no test fails, and that is the debt, stated.

## When to revisit

- **When GitHub deprecates `macos-15`.** It is announced in
  `actions/runner-images` well ahead. The replacement is the oldest still-offered
  image at or above the deployment floor, not the newest one — and if no image
  is left below macOS 26, then the floor in `Package.swift` is the thing that
  should move, consciously, in a new ADR.
- **When the floor in `Package.swift` changes.** The runner follows it. They are
  one decision written in two files.
- **When the Swift build stops being 27 s cold.** Dependencies, a WebKit built
  from source (ADR-0004, ADR-0005), or a second target would all change the
  table, and the cache refusal is arithmetic, not principle.
- **When the timing-fragile tests are fixed.** `timeout-minutes: 60` is sized for
  a suite that can stall. A fixed suite deserves a tighter number, because a
  timeout that never fires teaches nothing.
- **If a release or notarisation workflow is ever added.** It needs a Developer
  ID certificate and secrets, which breaks the "no job reads a secret" property
  this file leans on for fork pull requests, and actions pinned by tag stop being
  good enough — pin by SHA at that point.
