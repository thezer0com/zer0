# ADR-0121: iOS arrives as a second host beside the macOS package, linking the same core through a script-built xcframework

- **Status:** Accepted
- **Date:** 2026-08-16
- **Lock:** `apple/scripts/build-core-ios.sh::check_bundled_sqlite_ios`, `crates/zer0-core/src/ffi_tests.rs::core_version_is_the_version_cargo_built`

## Context

zer0 is going multi-platform — ADR-0118 wrote the host boundary for exactly
this, ADR-0116 budgets icons against it, and iOS is the first host that is not
the macOS package. The decision here is not "iOS support" but the shape of its
first footprint: what a second host is allowed to touch, what it must never
touch, and what it is honest to say it proves.

Three traps shaped the shape:

**The bindings cannot be generated from an iOS build.** `uniffi-bindgen
generate --library` dlopens the library it reads on the *host*, and a macOS
process cannot load an iOS archive. Any plan where the iOS host "generates its
own bindings" is a plan that fails at its first command — measured, not
inferred: it is the reason `build-core.sh` runs on the host library at all.

**The workspace floor says nothing about iOS.** `.cargo/config.toml` sets
`MACOSX_DEPLOYMENT_TARGET=15.4` for ADR-0114's reasons, and `cc` consults that
variable only for Apple-macOS targets. A cross-compile to
`aarch64-apple-ios` reads no floor from it, so the bundled SQLite records
whatever the SDK of the day claims — ADR-0114's own revisit clause: "when a
build targets something that is not this host… an iOS host or a cross-compile
needs that check re-read, not just the env re-set."

**The macOS flow works and is defended.** `Package.swift`, `bundle.sh`,
`sign.sh`, `notarize.sh`, `resolve-bundle.sh` and `check.sh` are held by
eleven ADRs between them. A second host that edits its way through them to
"share" code is the dangerous regression that reads as an improvement: every
macOS lock stays green while the thing it locked is quietly reshaped around.

## Decision

**iOS is a sibling that consumes, never a tenant that remodels.** Four parts:

**1. The build is a brother script, not a fork of the flow.**
`apple/scripts/build-core-ios.sh` cross-compiles the core
(`aarch64-apple-ios`, both simulator architectures — measured: the simulator
target for x86_64 is spelled `x86_64-apple-ios`, there is no
`x86_64-apple-ios-sim` in `rustc --print=target-list`), lipo-fuses the two
simulator slices into one universal library, and wraps device + simulator in
`apple/ios/Zer0Core.xcframework` (gitignored, like every generated binding).
`build-core.sh` is untouched; `build-core-ios.sh` *refuses to run* until it
has produced the bindings, because that is the dependency the dlopen fact
forces, named at the one door rather than discovered in a linker error.

**2. ADR-0114 is honoured in its own currency on the new platform.** The
script exports `IPHONEOS_DEPLOYMENT_TARGET=18.4` for the `cc` crate, and
`check_bundled_sqlite_ios` inspects every archive it links: the SQLite object
must claim platform `IOS`/`IOSSIMULATOR` — the identity check re-read for a
cross-compile, where the host-architecture check the macOS guard uses would
pass a wrong-platform object — and a minimum no higher than the floor. Watched
failing on a poisoned floor (RED) and passing clean (GREEN) before trusting
it, per the lock rule.

**3. The host is a hand-written `xcodeproj`, not a package, not a generator.**
`apple/ios/Zer0IOS.xcodeproj` (Xcode 16 object format,
`FileSystemSynchronizedRootGroup`: the whole app source is one synchronized
folder) compiles three things: the app's two files, the *shared* generated
binding `apple/Sources/Zer0Core/zer0_core.swift` referenced by relative path,
and the modulemap via `SWIFT_INCLUDE_PATHS` — the same
`apple/Sources/Zer0CoreFFI` the macOS package compiles, because shipping a
second copy of the header inside the framework would be a copy nothing reads.
No SwiftPM: `unsafeFlags` cannot ride into an iOS package anyway, and no
xcodegen/Tuist dependency for a target whose file list is one directory. The
xcframework is referenced normally — staticlib via xcframework, Xcode links
it without linker flags; measured, `OTHER_LDFLAGS` is not needed and is not
set. Deployment target 18.4 everywhere, `CODE_SIGNING_ALLOWED=NO` (this
skeleton is a simulator citizen; signing is a canal decision, below).

**4. The skeleton proves what it claims and nothing more.** The app opens the
core in memory with `HostCapabilities(extension_runtime: false,
page_printing: false)` — the honest answers for a host with no extension
runtime and no print API (`WKWebView.printOperation` is `macos(11.0)`-only in
the iPhoneOS 26.5 SDK, measured), which ADR-0118's gates turn into
refusals-with-a-reason the moment something asks and a keymap with no print
chord to wear. The screen shows the core's
own version — through a new `core_version()` FFI function, because a host that
hand-copied "0.1.0" into a label would be reporting the core it shipped last
month — and a tab counter that moves when `NewTab` is dispatched, proving the
reducer answered across the boundary. The bundle id `com.thezer0.browser.ios`
is a placeholder spelling of the macOS pattern; whether iOS ships at all, in
which canal, under which id, is a future ADR's question, and
`resolve-bundle.sh` was not extended to answer it now.

CI grows an `ios` job per ADR-0102's rule — it says what a laptop without a
simulator cannot: that the cross-compile and the Xcode build happen from a
clean checkout on the pinned toolchain, no secrets. It runs `build-core.sh`
first, then `build-core-ios.sh`, because the binding order is the dependency,
not a preference. The proof the app *runs* is not CI's to give: a simulator
booted on the author's machine, the process stayed up, and
`simctl io screenshot` recorded the screen for a person to look at — the
interface is verified by looking, and no assertion in a runner replaces eyes.

## Consequences

**The macOS flow is untouched and provably so** — `git status` after the iOS
work names not one file the eleven macOS ADRs hold.

**The bindings stay single-sourced.** One generation per build, from the host
library, consumed by two platforms. The cost is the ordering constraint: an
iOS build always pays a macOS `build-core.sh` first (~8s incremental,
measured) even where it wants no macOS artifact beyond the bindings.

**The iOS floor is now spelled in three new places** — the script's
`IPHONEOS_DEPLOYMENT_TARGET`, the guard's `FLOOR`, and the project's
`IPHONEOS_DEPLOYMENT_TARGET` — joining ADR-0114's five macOS spellings. Same
cost, same reasoning: each tool reads its own spelling, none derives another,
and the revisit clause is the same one.

**What hurts:** a second build system. The macOS half is SwiftPM, the iOS half
is a hand-maintained pbxproj, and the app's *four* committed source lines
ride in a project file an order of magnitude larger. The alternative —
SwiftPM with a plugin, or a generator dependency for one target — moves the
same mass somewhere harder to read. The pbxproj is expected to grow; when its
hand-maintenance has been paid three times, that is the moment a generator
earns its dependency.

**What it buys:** the next host question is answerable in one file.
`HostCapabilities` at the door, a brother script beside the macOS one, and a
project that cannot reach back into what it consumes — Linux will be a new
host, not a rewrite, and this is that sentence with a working example.

## How this regresses

**"The iOS script regenerates bindings itself, for self-containedness."**
Someone unused to the dlopen fact adds a `uniffi-bindgen` call pointed at an
iOS archive. It fails at once — a macOS process cannot load the library — and
the failure teaches the constraint. The quieter variant, copying the bindings
into `apple/ios/` "for cleanliness", breaks nothing today and starts two files
that can differ; the fence is that the project's file reference points at
`../Sources/Zer0Core/zer0_core.swift`, one path, and a reviewer who sees a
second copy is looking at this ADR's reasoning.

**"The guard is relaxed to unversioned-accepts."** An object with no
`LC_BUILD_VERSION` would pass a numeric comparison by having nothing to
compare. `check_bundled_sqlite_ios` refuses it, same as the macOS guard —
watched RED on a poisoned floor before it was trusted, and the lock names the
function so its removal fails `adr-check.sh`, not someone's memory.

**"The skeleton declares `extension_runtime: true` so Settings rows appear."**
Nothing iOS-side installs anything today, so the flip buys exactly the
success-shaped silence ADR-0118 exists to prevent. The regression is a lie
told in this host's source at its own door; `a_host_that_declared_no_
extension_runtime_is_refused_installation` holds the core's half, and the
host's half is one line anyone can read.

**"The bundle id placeholder hardens into a decision."** Someone ships
TestFlight under `com.thezer0.browser.ios` and the canal question is answered
by accident. Nothing goes red — that is the honest gap. The ADR says the id is
a placeholder; the moment iOS distribution is real, a new ADR owns it, and
this paragraph is the argument for writing that one before shipping.

## When to revisit

- **When the iOS host grows real behaviour** — an engine (WKWebView), a store,
  a place for its data to live. Each arrives with its own decision; this
  skeleton's `scenePhase` stub and in-memory core are the empty hooks, and
  the first engine question (does iOS get extension support at all?) is
  ADR-0118's revisit, not this one's.
- **`extension_runtime` stays `false` until `WKWebExtension` is verified on a
  device.** The named risk is service-worker suspension: iOS reclaims
  background execution aggressively, and whether an extension's service
  worker — the thing a browser extension *is* — survives that has not been
  measured on hardware. Flipping the declaration before that measurement buys
  exactly the success-shaped silence ADR-0118 exists to prevent. The
  revisit condition is concrete: an extension with a background service
  worker, installed on a physical device, still working after the system has
  had its way with it.
- **When iOS distribution becomes real** — bundle id, canal, signing. A new
  ADR supersedes the placeholder here; `resolve-bundle.sh` grows an iOS half
  only then.
- **When the pbxproj has been hand-edited three times.** That is the paid
  evidence a generator (xcodegen/Tuist) earns its dependency with; before
  that it is a dependency for tidiness.
- **When the iOS floor moves.** Three new spellings of 18.4 move together,
  joining ADR-0114's revisit clause — and by then the derivation question it
  defers may have two platforms' worth of answer.
