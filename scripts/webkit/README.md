# Building WebKit for zer0

zer0 must not depend on whichever WebKit happens to be installed on the
machine that runs it. These scripts fetch a pinned WebKit revision and build
it, so the engine the browser ships is the engine we chose. Embedding the
result into `Zer0.app` is a separate step and lives elsewhere.

Verified end to end on 2026-08-09: `WebKit-7624.4.5.14.1` fetched, built
release, and `Zer0.app` loaded a page with its web content, networking and GPU
processes all running out of the build tree rather than out of `/System`.

Nothing here writes inside the repo. Source and build products go to
`~/.cache/zer0/webkit` by default, overridable with `ZER0_WEBKIT_DIR`.

## Flow

```sh
./scripts/webkit/fetch.sh              # shallow checkout of the pinned tag
./scripts/webkit/build.sh --release    # build it; prints where it landed
```

The build takes a long time. Run it detached and read the log:

```sh
nohup ./scripts/webkit/build.sh --release >/dev/null 2>&1 &
tail -f ~/.cache/zer0/webkit/build-release.log
```

Then run the app against what you built:

```sh
./apple/scripts/run-with-webkit.sh ~/.cache/zer0/webkit/src/WebKitBuild/Release
```

To prove it took, check that the web process came from the build tree rather
than from `/System` — the launch banner only tells you what the *app* process
resolved:

```sh
pgrep -fl "WebKitBuild/Release/com.apple.WebKit"
```

Three lines (`Networking`, `GPU`, `WebContent`) means the whole engine is
yours. Note the binaries inside are the `.Development` variants; that is what a
source build produces and is expected.

## Files

| File | What it is |
| --- | --- |
| `version.txt` | The pinned tag, and how to pick a new one. The only place a version is written down. |
| `fetch.sh` | Clones or updates the checkout at that tag. Idempotent. |
| `build.sh` | Preflights the toolchain, then runs `Tools/Scripts/build-webkit`. Resumable. |
| `common.sh` | Shared path and version resolution. Not run directly. |

## Which revision, and why not `main`

`version.txt` pins a `WebKit-*` tag. Those tags are the source drops Apple
shipped a Safari from, so each one built and survived a release cycle. `main`
is whatever landed in the last hour and regularly does not build at all.

Tags carry no `v` and no semver; they look like `WebKit-7624.4.5.14.1`. List
them newest-last:

```sh
git ls-remote --tags --refs https://github.com/WebKit/WebKit.git \
  'refs/tags/WebKit-*' | sed 's|.*refs/tags/||' | sort -V | tail -20
```

To see how a tag relates to the WebKit already on the machine, read the system
framework's version:

```sh
defaults read /System/Library/Frameworks/WebKit.framework/Versions/A/Resources/Info.plist CFBundleVersion
```

On macOS 26.6 that is `21624.4.5.11.5`, whose trailing components line up with
the `WebKit-7624.4.5.11.*` tags — a few stabilisation revisions behind the tag
pinned here.

## Requirements

- **Full Xcode**, not the standalone command line tools. `build.sh` refuses if
  `xcode-select -p` points at `CommandLineTools`.
- **The Metal toolchain**, on Xcode 26 and newer. It is a separate download and
  is *not* installed by default:

  ```sh
  xcodebuild -downloadComponent MetalToolchain
  ```

  Without it the build dies partway through on a `.metal` shader with an error
  that never mentions a missing component. `build.sh` checks for it up front.
- **No dependency installer.** `Tools/gtk/install-dependencies` and friends are
  for the Linux ports. On macOS the SDK is the dependency set.
- **Disk.** `build.sh` refuses to start with less than 100 GB free; a release
  build measured 34 GB, so that floor has room for a debug build on top.

## Cost, honestly

Measured on this machine (M4 Max, 14 cores, 36 GB RAM, macOS 26.6, Xcode 26.6):

- Shallow checkout of `WebKit-7624.4.5.14.1`: **7.4 GB and 455,214 files**,
  about 20 minutes. Almost all of it is the working tree, not history — the
  clone is one commit deep. `LayoutTests/` is the bulk of the file count.
- The Metal toolchain download is a few minutes on top, once per machine.
- Clean release build: **35m34s**, 110 targets in one `xcodebuild` invocation.
- `WebKitBuild/` afterwards: **34 GB**, of which `Release/` (the products you
  care about) is **5.2 GB**. Source plus build is **41 GB** total.

So the top-level `README.md`'s "on the order of 100 GB" is roughly 2.5x the
measured figure, and "tens of minutes" is right. The 100 GB floor `build.sh`
enforces is deliberately conservative: a debug build and a `dwarf-with-dsym`
release are both much larger than the numbers above.

## Resuming and re-running

Both scripts are safe to run again.

`fetch.sh` fetches into an existing checkout instead of re-cloning, and does
nothing at all if the checkout is already at the pinned tag. It refuses to move
a checkout that has uncommitted changes: carrying a local patch is a reason
someone builds WebKit from source, and the script will not discard work it did
not create.

`build.sh` drives `xcodebuild`, which is incremental, so a build killed at 80%
resumes near 80%. Measured: re-running it against a finished build takes **31
seconds** against the 35m34s the clean build took. There is no `--clean` flag
on purpose — `rm -rf ~/.cache/zer0/webkit/src/WebKitBuild` says what it does.

## What this does not solve

Building the framework is the easy half. Two open questions belong to whoever
embeds it:

1. **`DYLD_FRAMEWORK_PATH` is a development tool, not a shipping mechanism.**
   `run-with-webkit.sh` works only because `bundle.sh` signs ad-hoc without the
   hardened runtime. Anything notarised has the hardened runtime, which strips
   `DYLD_*`. A shipped bundle has to resolve an embedded WebKit through install
   names and `@rpath`, not through the environment.
2. **The XPC services are half the engine, and they are not inside the
   framework.** `launchd` spawns the web content, networking and GPU processes,
   not the app, so they have to be embedded, signed and entitled alongside the
   framework — and the UI process and the web process must agree on the WebKit
   version or WebKit deliberately crashes.

   The trap: in a source build, `WebKit.framework/Versions/A/XPCServices/*.xpc`
   are **symlinks pointing outside the framework**, at
   `../../../../com.apple.WebKit.*.xpc` — that is, into `WebKitBuild/Release`
   itself. Apple's shipped framework has real directories there. So

   ```sh
   cp -R WebKitBuild/Release/WebKit.framework /somewhere/   # verified: DANGLING
   ```

   produces a framework whose every XPC service is a broken link. Copy the
   seven `com.apple.WebKit.*.xpc` bundles from `Release/` alongside it, or
   dereference the links on copy. `build.sh` at least fails the build if
   `XPCServices` is missing entirely.

On the other hand, building from source removes the licensing question the
top-level README raises about redistributing Apple's binary frameworks: this is
the open-source WebKit, built from a public tag.
