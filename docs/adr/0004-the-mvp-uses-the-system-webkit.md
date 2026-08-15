# ADR-0004: The MVP uses the system WebKit, with named triggers for leaving it

> **Partly superseded by ADR-0109 (stable and canary both ship an embedded
> WebKit) and ADR-0005 (the embedded WebKit is built from source and
> validated).** The system WebKit stays as the development fallback
> `run-with-webkit.sh` points at when no local build exists; it no longer
> describes what the browser ships. The decision below was right at the
> time it was taken, the triggers it named are the triggers that fired,
> and the file is preserved unchanged because the reasoning is what later
> ADRs cite. This note is the only edit; §Decision and §Consequences keep
> the history.

- **Status:** Accepted, and already partly superseded by ADR-0005
- **Date:** 2026-01-12
- **Lock:** none — debt

## Context

With WebKit chosen (ADR-0001), the question left is which WebKit. On macOS the
engine is already installed: `/System/Library/Frameworks/WebKit.framework`.
Using it means the whole `Zer0.app` bundle comes out at **7.4 MB** in release
(59 MB in debug, measured), and that a WebKit CVE reaches the user through the
macOS update, with no release from us.

The price is the flip side of the same coin: whatever the WebKit team landed
last week is months away from running here.

## Decision

The MVP renders with the system WebKit. Nothing in the bundle carries an engine.

For development, `apple/scripts/run-with-webkit.sh` points the app at another
`WebKit.framework` — Safari Technology Preview by default, or any directory
holding a build — using `DYLD_FRAMEWORK_PATH` and `__XPC_DYLD_FRAMEWORK_PATH`
(both, because the web content process is spawned by `launchd` and inherits
nothing from the app; setting only the first makes the two halves of WebKit
disagree on version and WebKit aborts on purpose).

And there are **three named triggers** for abandoning the system WebKit:

1. **Needing behavior the public API does not expose.**
2. **Going to Linux or Windows**, where there is no system WebKit to borrow.
3. **Needing to run ahead of Apple's release cycle.**

## Consequences

- **The engine changes underneath the app.** A macOS point update swaps the
  browser's renderer without a line of ours changing. A rendering or layout
  regression arrives as a user-reported bug, in a binary we did not touch, and
  there is no bisect: there are not two engine versions to compare on the same
  machine.
- **A feature behind a flag is unreachable.** Running a newer WebKit gives you
  whatever shipped enabled; it does not give you anything depending on
  `_WKFeature` / `WKPreferences._features`, which is SPI and we do not use it
  (ADR-0001).
- **The development tool depends on us not being ready to distribute.**
  `run-with-webkit.sh` only works because `bundle.sh` signs ad-hoc **without**
  hardened runtime — hardened runtime is exactly what makes dyld drop `DYLD_*`.
  The day notarization exists, that tool stops working. The script refuses to
  run if it finds the app signed with hardened runtime, rather than silently
  doing nothing, which is the right behavior and does not change the fact.
- **The license is comfortable and the autonomy is not.** We do not redistribute
  an Apple binary, but we also do not choose anything about the engine that
  runs.

## How this regresses

A regression here is not breaking the decision — it is **finding out it no
longer holds and not noticing**. The concrete symptom is one of the three
triggers firing with nobody writing it down.

Trigger 1 has already fired at least once and it is visible in the code:
`EngineHost.setMuted` injects JavaScript into every `video,audio` on the page
and reapplies it after each navigation, because WebKit exposes no public API for
muting audio (only camera and microphone capture). That is exactly "behavior the
public API does not expose", and the answer was a workaround, not a review of
this decision.

Trigger 3 fired later, and that one did turn into ADR-0005.

No test screams. There is no possible test for "which WebKit is loaded" inside
`swift test`, because the test runs in the same process with the engine dyld
already resolved. What exists is a manual check, outside `check.sh`:

```sh
vmmap $(pgrep -x Zer0) | grep __TEXT | grep WebKit.framework
```

That is declared debt: until this check lives in `scripts/check.sh` (or in a
bundle smoke test), the only way to know which engine runs is for someone to go
look.

## When to revisit

Already happened. Trigger 3 fired and produced ADR-0005 (build from source and
embed). This decision holds only while no build of ours exists; the day
ADR-0005 leaves "in progress", this one becomes **Superseded**.

Before that, the other trigger to watch is 2: the first line of code of a Linux
host makes "the system WebKit" a phrase without meaning.
