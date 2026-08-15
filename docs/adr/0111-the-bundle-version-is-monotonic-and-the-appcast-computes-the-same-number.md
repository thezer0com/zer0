# ADR-0111: The bundle version is monotonic and the appcast computes the same number

- **Status:** Accepted
- **Date:** 2026-08-13
- **Lock:** `apple/Tests/Zer0ShellTests/VersionTests.swift::VersionTests/stableVersionPacksXYZIntoAMonotonicInteger`, `apple/Tests/Zer0ShellTests/VersionTests.swift::VersionTests/canaryCarriesItsTimestampAsTheBundleVersion`

## Context

`apple/scripts/bundle.sh` wrote `CFBundleShortVersionString=0.1.0` and
`CFBundleVersion=1` as literals, for both channels, since the day it started
writing a plist at all. Meanwhile Sparkle ranks updates by `sparkle:version`,
and the version an installed app compares against is its own
`CFBundleVersion`. Frozen at 1, the installed build is "1", and the very first
appcast item — stable or canary, today or in a year — is at best equal, never
newer. A canary channel whose entire purpose is to be newer than the previous
canary cannot update anyone, forever, and the failure is invisible: the feed
validates, the app checks it, nothing is offered, no error is logged.

The right number already existed — twice. The workflows' `compute version`
steps derive it correctly (canary: a UTC build timestamp; stable: the tag
packed into `M*10000 + m*100 + p`, with a non-`X.Y.Z` tag refused), and
`scripts/publish-appcast.sh` publishes exactly that as `sparkle:version`. So
the feed said "202608121500" while the plist said "1": one build, two numbers,
and a Sparkle that would install the update and then immediately re-offer it,
because the freshly installed app still claims to be build 1. That is
ADR-0018's rule failing quietly — two claims about the same fact that do not
agree — plus AGENTS.md's "put the rule at the one door" failing structurally:
the formula lived in two workflow steps with nothing holding them together.

## Decision

**`CFBundleVersion` is a monotonic integer derived through one door, and the
appcast's `sparkle:version` is the same number by construction.**
`CFBundleShortVersionString` stays what a person reads: the tag for stable
(`0.1.0` today), `0.0.0-canary.<YYYYMMDDHHMM>-<sha>` for canary.

The door is `bundle_version_for_channel` in `apple/scripts/resolve-bundle.sh` —
the file that was already the one door for the channel's bundle identity
(ADR-0109), now also for its build number:

- **stable:** `vX.Y.Z` packs into `M*10000 + m*100 + p`. `0.2.10` (210) ranks
  above `0.2.9` (209), `1.0.0` (10000) above both — the same packing the
  stable workflow already used inline, so the published series continues; no
  renumbering. Minor and patch are assumed below 100.
- **canary:** the twelve-digit UTC timestamp the canary version already
  carries. Monotonic by construction, and far above every stable code, so
  even a hypothetical cross-channel comparison cannot rank a canary below a
  stable.
- **anything else is refused**, not repaired: a wrong build number is not a
  visible defect — the build works, the feed validates — it silently breaks
  ranking, which is the one thing this number exists to hold.

Both sides of the pipeline derive from that function. The canary workflow
computes the version *before* the build and passes the result to
`bundle.sh` as `ZER0_BUNDLE_VERSION` (and the human string as
`ZER0_SHORT_VERSION`), which stamps them into the plist.
`publish-appcast.sh` recomputes the number from `--channel`/`--version`
through the same function and refuses an `--bundle-version` that disagrees —
so a workflow bug on either side is a loud refusal, not a feed that lies
about what it ships.

A local build with no env keeps the honest defaults `0.1.0`/`1`, with a
warning. Build 1 is deliberately frozen: a local build is not a release, and
a dev machine's Sparkle should keep ranking every published canary above it —
which is exactly right, because they are all newer than it.

## Consequences

**The formula has one home and two callers that cannot drift.** The workflows
call it, the publish step verifies against it; a third implementation would
have to survive code review, not a test (see below). The stable workflow
still carries the inline derivation until it is moved onto the door and its
build step gains the two `ZER0_*` env lines the canary one now has; the
publish-side check already refuses a disagreement, so the invariant is
enforced from the publish end regardless.

**The stable tag series is arithmetic, not history.** `v0.1.0` → 100, today
and forever; the appcast items already published keep their meaning. A
project that ships a minor or patch ≥ 100 has outgrown the packing
(`0.0.100` == `0.1.0` == 100) and must reopen this ADR rather than let two
tags collide on one number.

**Local builds say what they are.** The warning names the default and what it
means: not distributable, never ranked above a release. A developer who ships
a `1` to a user did so past a printed warning, not past silence.

**`publish-appcast.sh` keeps `--bundle-version` as an argument rather than
reading the plist.** Reading the archive's plist would quietly publish
whatever the build happened to carry — a build that missed
`ZER0_BUNDLE_VERSION` would ship `1` into the feed and freeze ranking, which
is the bug this door exists to make loud. Recompute-and-refuse is the
stricter posture.

## How this regresses

**"Someone tidies `bundle.sh`'s env handling back into a literal plist."**
The lock holds the door's arithmetic, not `bundle.sh`'s reading of the
environment — a test cannot watch a shell script honor an env var without
running a full build. What catches the revert is the warning going silent in
the CI log, and the first user to be re-offered an update they already
installed. That residual is named here rather than papered over, the same way
ADR-0109 named its un-testable operational regressions.

**"A third copy of the formula springs up"** — a dev-build script, a future
channel, a release notes generator — **and drifts.** The lock defends the
door's values; it cannot see a duplicate elsewhere any more than ADR-0109's
lock could see a workflow misroute. The door's comment is the signpost; a
duplicate is a code-review refusal.

**"The formula is 'corrected' into something prettier."** Swapping the minor
and patch weights, or packing base-1000, compiles, runs, and publishes — and
every existing installation stops seeing updates once the new series drops
below the numbers they already hold. This is the regression that reads as an
improvement, and it is exactly what the two locks redden on: the named tests
pin the packed values (`0.1.0`→100, `0.2.10`→210, `1.2.3`→10203) and the
timestamp extraction, and were both watched to fail when the packing was
deliberately inverted.

## When to revisit

- **When a stable tag needs minor or patch ≥ 100.** The packing is bounded by
  design; outgrowing it is a new decision, not a bigger multiplier.
- **When a third channel appears** (ADR-0109 already leaves that door open):
  it brings its own version shape and its own case in the door, and its own
  lock.
- **When Sparkle (or a successor) ranks on something other than
  `sparkle:version`, or versions stop being integers.** The monotonic integer
  exists because of that ranking rule; if the rule changes, the number's job
  changes with it.
- **When the Linux port lands.** `CFBundleVersion` is a macOS bundle concept;
  the monotonic-build-number requirement survives, the plist wiring does not,
  and the lock moves to the host that owns it (as ADR-0109 anticipated for
  its own locks).
