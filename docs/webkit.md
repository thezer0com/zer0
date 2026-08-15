# WebKit: running it, embedding it, signing it

`zer0` renders with WebKit. By default that is the WebKit that ships with
macOS, which is the point — a security fix arrives with an OS update instead of
with a release from us. This file is everything below that sentence: how to run
against a newer engine while developing, how to put an engine inside the bundle,
what that costs, and exactly which of it is proved and which is not.

Nothing here is needed to build or use the browser. `README.md` and
`CONTRIBUTING.md` cover that.

- [Running against a newer WebKit](#running-against-a-newer-webkit)
- [Embedding WebKit](#embedding-webkit)
- [What it costs](#what-it-costs)
- [How the app finds it](#how-the-app-finds-it)
- [What changes in code signing](#what-changes-in-code-signing)
- [What is still missing to hand this to anyone else](#what-is-still-missing-to-hand-this-to-anyone-else)

Background: [ADR-0001](adr/0001-webkit-as-the-engine-not-chromium.md) (WebKit
rather than Chromium), [ADR-0004](adr/0004-the-mvp-uses-the-system-webkit.md)
(the system engine), [ADR-0005](adr/0005-we-build-webkit-from-source-and-embed-it.md)
(building and embedding our own).

---

## Running against a newer WebKit

The cost of using the system engine is that anything the WebKit team landed last
week is months away from being runnable here. `apple/scripts/run-with-webkit.sh`
buys that back at development time.

```sh
./apple/scripts/run-with-webkit.sh                       # Safari Technology Preview
./apple/scripts/run-with-webkit.sh --system              # system WebKit, for comparison
./apple/scripts/run-with-webkit.sh ~/WebKit/WebKitBuild/Release
```

It prints which WebKit it resolved and that version next to the system's, then
launches `apple/.build/Zer0.app`. Point it at any directory that contains a
`WebKit.framework`.

**Safari Technology Preview** is the cheap option and the one to reach for
first. It carries its own `WebKit.framework` in
`/Applications/Safari Technology Preview.app/Contents/Frameworks`, ships roughly
every two weeks, and is signed by Apple. Nothing to build. The limits are that
you take whatever WebKit that release happens to contain, you cannot patch it,
and you are testing against a build Apple assembled rather than one matching a
specific upstream commit.

**Building WebKit from source** is the only way to run a specific commit or your
own patch. `scripts/webkit/` does it against a pinned tag; its README carries
the full flow. Measured on an M4 Max, not estimated: the shallow clone is
**7.4 GB** and about 20 minutes, a clean release build is **35 minutes** and
leaves **34 GB** in `WebKitBuild/`, and an incremental no-op rebuild is 31
seconds. On Xcode 26 and newer the build also needs a component that is not
installed by default — `xcodebuild -downloadComponent MetalToolchain` — without
which it dies partway through on a shader, with an error that never mentions a
missing download.

**Turning on experimental feature flags is not available to us.** WebKit does
expose per-feature toggles, but only through SPI: `_WKFeature`,
`WKPreferences._features` and `_setEnabled:forFeature:`, all underscore-prefixed
private API. There is no public equivalent on `WKPreferences` or
`WKWebViewConfiguration`. Using it would tie the app to an interface Apple can
change or remove in any point release, with no deprecation and no compile-time
warning, so we do not. Running a newer WebKit gets us features that shipped
enabled; it does not get us features still behind a flag.

### Why this works without weakening the app

Two pairs of environment variables do the work. `DYLD_FRAMEWORK_PATH` redirects
the app process, and `__XPC_DYLD_FRAMEWORK_PATH` redirects the web content
process, which `launchd` spawns rather than the app forking, so it inherits
nothing otherwise. Set only the first and the two halves of WebKit disagree
about their version and WebKit deliberately crashes.

No entitlement is added and SIP stays on. What strips `DYLD_*` is the hardened
runtime, and `bundle.sh` signs ad-hoc without it, so
`com.apple.security.cs.disable-library-validation` is not needed and is not
present: it would be a permanent weakening of the shipped bundle to buy a
development convenience. The script refuses to run if it ever finds the app
signed with the hardened runtime, rather than silently doing nothing.

`run-with-webkit.sh` is a development tool, not a distribution strategy: the
variables it exports die at the first `open`. Carrying an engine in the bundle
is the next section.

---

## Embedding WebKit

A browser that renders with whatever WebKit the machine has is a browser whose
engine changes under it. `embed-webkit.sh` puts a WebKit inside `Zer0.app`, so
the app carries the engine we chose and nothing outside the bundle decides which
one runs.

```sh
ZER0_EMBED_WEBKIT=~/.cache/zer0/webkit/src/WebKitBuild/Release ./scripts/build.sh release
ZER0_EMBED_WEBKIT=orion ./scripts/build.sh          # stand-in, see below
./apple/scripts/embed-webkit.sh --check             # what does this bundle carry?
```

Without `ZER0_EMBED_WEBKIT` the build is exactly what it was: the system WebKit,
`59M` debug and `7.4M` release, in eleven seconds. Embedding is a copy and a
re-sign on top of a finished bundle, not a different build.

**A WebKit build of ours exists, and it runs.** `scripts/webkit/` builds the
pinned tag; embedding it and launching produces a browser whose Networking, GPU
and WebContent processes all come out of the bundle, with no `__TEXT` mapped
from `/System/Library/Frameworks/WebKit` in any of the four processes, and a
page that lays out and rasterises. The versions differ from the system's, which
is the point.

One trap that cost a debugging session and is worth knowing before you copy a
framework by hand: in a source build the XPC services inside
`WebKit.framework/Versions/A/XPCServices` are **symlinks pointing out of the
bundle**, and so is `libWebKitSwift.dylib`. Apple's shipped framework has real
directories there. `cp -R` yields a framework whose seven services are all
broken. `embed-webkit.sh` materialises them; it also drops the ten `.tbd` link
stubs, which `codesign --verify --strict` refuses to accept inside a bundle.

`--orion` still exists, embedding the WebKit out of an installed
[Orion](https://kagi.com/orion) as a stand-in whose layout matches Apple's. It
is Kagi's build and it is not ours to redistribute: the script writes
`Contents/Resources/webkit-stand-in.txt` into any bundle built that way and
prints a warning that says so. Do not ship it.

---

## What it costs

Measured on macOS 26.6, arm64, with the Orion stand-in (WebKit 625.1.8):

| | release | debug |
| --- | --- | --- |
| system WebKit | 7.4 MB | 59 MB |
| embedded WebKit | 387 MB | 439 MB |

The 380 MB is `WebKit`, `WebCore`, `JavaScriptCore`, `WebKitLegacy`, `WebGPU`
and `WebInspectorUI`, plus `libANGLE-shared.dylib` and `libwebrtc.dylib`, all
universal x86_64 + arm64. Thinning to one architecture roughly halves it, and a
release build of our own can drop `WebInspectorUI` if we decide devtools are not
shipping. That is the honest floor: a self-contained browser is two orders of
magnitude larger than a shell that borrows one.

---

## How the app finds it

Apple's WebKit is built with its install name hard-wired to
`/System/Library/Frameworks/WebKit.framework/Versions/A/WebKit`, and on macOS 26
that path holds no Mach-O at all — dyld resolves the code out of the shared
cache. `install_name_tool` on our binary does not fix that, because the same
absolute path is baked into every WebKit-family framework and into the three XPC
services as well.

What redirects it is `DYLD_FRAMEWORK_PATH`, and the trick is where it is
written. As an environment variable it is a development crutch: `open`, the
Dock and `launchd` all drop it. As a Mach-O load command it travels inside the
executable, so every process that starts from that binary gets it regardless of
who started it.

```
Zer0                     DYLD_FRAMEWORK_PATH=@executable_path/../Frameworks
com.apple.WebKit.*.xpc   DYLD_FRAMEWORK_PATH=@executable_path/../../../../../../..
```

`scripts/build.sh` puts the first there with `-Wl,-dyld_env`. The second is
already in every XPC service WebKit builds — this is how WebKit expects to be
embedded — and both resolve to `Zer0.app/Contents/Frameworks`. `embed-webkit.sh`
computes both and refuses to continue if either misses, because the failure mode
otherwise is an app that quietly keeps using the system WebKit.

This is what closes the hole `run-with-webkit.sh` has to paper over with
`__XPC_DYLD_FRAMEWORK_PATH`. The web content process is spawned by `launchd` and
inherits nothing, so an exported variable reaches the UI process only and WebKit
aborts on the version mismatch. A load command has no such hole: the XPC binary
carries its own copy. `launchd` finds those services inside the bundle and
prefers them over the system ones, so the whole engine — UI process, web content,
networking, GPU — comes from `Contents/Frameworks`.

Verify it on a running app rather than believing this paragraph:

```sh
vmmap $(pgrep -x Zer0) | grep __TEXT | grep WebKit.framework
ps -axo pid,comm | grep 'Zer0.app.*WebKit'
```

Both should print paths inside `Zer0.app`. If they print `/System`, the embed
did not take.

---

## What changes in code signing

`install_name_tool` never runs, so nothing inside the frameworks is modified.
They are still re-signed, innermost first — XPC services, then each framework's
version directory, then the loose dylibs, then the app — because signing a
bundle seals the hashes of everything inside it, and an inner signature applied
afterwards invalidates the outer seal.

Two details are deliberate. Entitlements are carried across, since the web
content process asks for `com.apple.security.cs.allow-jit` and loses JIT without
it. The **hardened runtime is not** carried across: it is precisely what makes
dyld ignore `LC_DYLD_ENVIRONMENT`, so preserving it would silently undo the
embedding. Everything ends up ad-hoc, and `codesign --verify --deep --strict`
has to pass or the script fails.

`Contents/Frameworks` also has to hold code and nothing else — `codesign` treats
every file under it as nested code and refuses to seal a plain one, which is why
the stand-in marker lives in `Contents/Resources`.

---

## What is still missing to hand this to anyone else

**Developer ID and notarisation.** Ad-hoc runs on the machine that built it and
nowhere else. Notarisation requires the hardened runtime, and under the hardened
runtime dyld ignores `LC_DYLD_ENVIRONMENT` unless the binary carries
`com.apple.security.cs.allow-dyld-environment-variables`. That is the entitlement
Orion ships, and it is a real widening: it re-enables every `DYLD_*` variable for
the process, not just ours.

There is no `@rpath` escape from that, which was measured rather than assumed.
`WK_RELOCATABLE_FRAMEWORKS` is already `YES` in a source build
(`Source/WebKit/Configurations/DebugRelease.xcconfig`), and what it switches on
is `-Wl,-dyld_env`, **not** `@rpath` install names. The install name of a
source-built framework is still absolute:

```
$ otool -D WebKitBuild/Release/WebKit.framework/Versions/A/WebKit
/System/Library/Frameworks/WebKit.framework/Versions/A/WebKit
```

`DYLIB_INSTALL_NAME_BASE` stays at the system path regardless of that flag. So a
notarised bundle either carries the entitlement, or someone rewrites install
names across the framework set — which means `install_name_tool` on Apple-signed
binaries, with no guarantee of header padding. Neither is free, and the choice
is still open.

**Our own WebKit.** Everything above is proved against a third-party binary.
`scripts/webkit/build.sh` produces the thing that should actually go in, and
building from a public tag also answers the licensing question that
redistributing Apple's frameworks would raise.

**Architecture thinning and dSYMs.** 380 MB of universal binaries is not a
download. Nothing here strips or thins anything yet.

**The licence obligations that come with the engine.** WebKit is
LGPL-2.1-or-later; a bundle that embeds it owes the engine's source at the
pinned tag and a way for someone to replace the embedded frameworks with their
own build. [`licensing.md`](licensing.md) has the audit and the compliance
checklist. Read it before cutting a release, not after.
