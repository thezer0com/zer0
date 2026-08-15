# ADR-0005: We build WebKit from source and embed it in the bundle

- **Status:** Accepted — validated 2026-08-09
- **Date:** 2026-01-17
- **Lock:** none — debt

The build was validated end to end on 2026-08-09: `WebKit-7624.4.5.14.1`
fetched, built release, and `Zer0.app` loaded a page with its web content,
networking and GPU processes all running out of the build tree rather than
out of `/System`. See `scripts/webkit/README.md` for the measured wall time
and disk cost. The partial-supersession of ADR-0004 this ADR always implied
is now in force; the question of *what gets shipped, on which channel, and
how often* is taken by ADR-0109.

## Context

ADR-0004 named three triggers for leaving the system WebKit. The third —
needing to run ahead of Apple's release cycle — fired. And there is a problem
more basic than all three: **a browser that renders with whatever WebKit the
machine happens to have is a browser whose engine changes underneath it.** We
cannot depend on what is installed on the user's machine.

`run-with-webkit.sh` does not fix this: the variables it exports die at the
first `open`. It is a development tool, not a distribution strategy.

## Decision

Two halves, with separate scripts:

**Build.** `scripts/webkit/` pins a revision in `version.txt`
(`WEBKIT_TAG=WebKit-7624.4.5.14.1`, verified 2026-08-08), does a shallow
checkout and runs `Tools/Scripts/build-webkit`. None of it writes inside the
repo: it goes to `~/.cache/zer0/webkit`, overridable with `ZER0_WEBKIT_DIR`.

The tag is `WebKit-*` and not `main` on purpose: those tags are the source drops
Apple shipped a Safari from, so each one built and survived a release cycle.
`main` is whatever landed an hour ago and it regularly does not build.

**Embed.** `apple/scripts/embed-webkit.sh` copies WebKit into `Zer0.app` and
re-signs it. The mechanism that makes the app find the embedded engine is
neither `@rpath` nor `install_name_tool`: Apple's install name is hardcoded to
`/System/Library/Frameworks/...` across *the entire* WebKit family and the three
XPC services. What redirects it is `DYLD_FRAMEWORK_PATH` written as a **load
command** (`LC_DYLD_ENVIRONMENT`), which travels inside the executable and
therefore survives `open`, the Dock and `launchd`. The script computes both
paths (the app's and the XPC services') and **refuses to continue if either is
missing**, because the silent failure mode is an app that keeps using the system
WebKit.

## Consequences

This is the most expensive decision in the repository, and the cost has two
faces.

**Size.** Measured with the Orion stand-in:

| | release | debug |
| --- | --- | --- |
| system WebKit | 7.4 MB | 59 MB |
| embedded WebKit | 387 MB | 439 MB |

Two orders of magnitude. That is `WebKit`, `WebCore`, `JavaScriptCore`,
`WebKitLegacy`, `WebGPU`, `WebInspectorUI`, plus `libANGLE-shared.dylib` and
`libwebrtc.dylib`, all universal x86_64 + arm64. Thinning to one architecture
cuts it roughly in half, and a build of ours could drop `WebInspectorUI` if
devtools are not going to ship. Even so the honest floor is that: a
self-contained browser is ~50x bigger than a shell that borrows one.

**Security, which is the cost that hurts.** Today a WebKit CVE reaches the user
through the macOS update, with us out of the loop. With the engine embedded,
**it becomes our responsibility**: tracking WebKit advisories, deciding whether
the pinned revision is affected, rebuilding, re-signing and shipping. A user
with macOS fully up to date now runs a stale engine if we do not cut a release.
We trade "the engine changes underneath the app without warning" for "the engine
only changes when we touch it" — and the second half of that sentence is an
operational obligation the project does not have yet.

**The rest of the cost:**

- **A build machine becomes a requirement.** Full Xcode (not command line
  tools), the Metal toolchain downloaded separately (without it the build dies
  halfway through on a `.metal` shader, with an error that never mentions the
  missing component), and disk: `build.sh` refuses to start with less than
  100 GB free.
- **Peak time and disk are not measured.** The `README.md` under
  `scripts/webkit/` is explicit about it and the 100 GB number is a working
  estimate, not a measurement. The shallow checkout is already a fact: 7.4 GB
  and 455,214 files, ~20 min.
- **Notarization becomes an open problem.** It requires hardened runtime, and
  hardened runtime is exactly what makes dyld ignore `LC_DYLD_ENVIRONMENT`. Ways
  out: the `com.apple.security.cs.allow-dyld-environment-variables` entitlement,
  which reopens *every* `DYLD_*` variable for the process and not just ours —
  what Orion carries, and a real widening.

  This originally recorded a second way out: a WebKit built with
  `WK_RELOCATABLE_FRAMEWORKS=YES`, whose install names would be `@rpath`. **That
  escape does not exist**, and the correction is worth keeping rather than
  quietly deleting. The flag is already `YES` in a source build, and what it
  switches on is `-Wl,-dyld_env`, not `@rpath` install names; `otool -D` on the
  built framework still reports
  `/System/Library/Frameworks/WebKit.framework/Versions/A/WebKit`, because
  `DYLIB_INSTALL_NAME_BASE` is unaffected. Rewriting install names would mean
  running `install_name_tool` across Apple-signed binaries with no guarantee of
  header padding. Notarisation therefore costs the entitlement, or it costs that.
- **Signing stays ad-hoc.** The frameworks are re-signed inside out, entitlements
  are preserved (the web content process asks for
  `com.apple.security.cs.allow-jit` and loses JIT without it) but hardened
  runtime is **not** preserved, because preserving it would silently undo the
  embedding.
- **The good part, and it is worth recording:** building from a public tag
  settles the licensing question that redistributing Apple's binary frameworks
  would raise.

## How this regresses

The symptom is the app going back to the system engine with nobody noticing. It
is silent by construction: everything keeps working, just with a different
WebKit.

Check, on a running app:

```sh
vmmap $(pgrep -x Zer0) | grep __TEXT | grep WebKit.framework
ps -axo pid,comm | grep 'Zer0.app.*WebKit'
./apple/scripts/embed-webkit.sh --check
```

The first two should print paths inside `Zer0.app`. If they print `/System`, the
embedding did not take. Known triggers: someone signing with hardened runtime,
someone removing the `-Xlinker -dyld_env` from `scripts/build.sh`, or a WebKit
version changing the `XPCServices` layout so the seven-level `@executable_path`
count stops lining up.

**No test screams.** `scripts/check.sh` does not touch the bundle and does not
know what an embedded engine is. `embed-webkit.sh` checks both load commands and
fails if either is missing, but that is the *script* checking at the moment it
runs, not a test running in CI. A smoke test that builds, embeds, opens the app
and asserts that `vmmap` points inside the bundle is what is missing — and it is
expensive precisely because it depends on a WebKit build existing.

## When to revisit

Three named moments:

1. **When the current build finishes.** ✅ Done 2026-08-09. The real wall
   time and size are in `scripts/webkit/README.md` (35m34s clean release
   build, 34 GB on disk, 5.2 GB of products), the Orion stand-in has been
   swapped for a build of our own, and this ADR has moved to `Accepted`.
2. **Before handing the app to anyone outside the machine that built it.** That
   is when the choice between `allow-dyld-environment-variables` and
   `WK_RELOCATABLE_FRAMEWORKS=YES` has to be made and become its own ADR.
3. **On the first WebKit CVE published after the first embedded release.** If
   there is no rebuild-and-ship path that fits inside the week, this decision is
   wrong and the security cost beat the autonomy one.
