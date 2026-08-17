# ADR-0109: Two bundles — stable and canary — each with its own bundle id, profile and update channel

- **Status:** Accepted, and the same-pin clause partly superseded by ADR-0124
- **Date:** 2026-08-12
- **Lock:** `apple/scripts/resolve-bundle.sh::build_bundle_id_parametrized`, `apple/Tests/Zer0ShellTests/BundleIdTests.swift::BundleIdTests/theStableBundleHasTheStableIdAndTheCanaryHasTheCanaryId`, `apple/Tests/Zer0ShellTests/BundleIdTests.swift::BundleIdTests/defaultStoragePathFollowsTheBundleIdRule`
- **Previous debt note:** this ADR landed as `none — debt` and named the two
  locks the first implementation had to produce. Both now exist: the channel
  mapping lives in `apple/scripts/resolve-bundle.sh` as
  `build_bundle_id_parametrized`, sourced by every script that wraps, signs
  or embeds into the `.app`; and the Swift test runs the same function
  end to end and asserts the id per channel. The lock above replaces the
  earlier note.

## Context

ADR-0004 chose the system WebKit for the MVP and named three triggers for
leaving it; the third — needing to run ahead of Apple's release cycle — fired
in ADR-0005, which decided to build WebKit from a pinned tag and embed it in
the bundle. ADR-0005 sat at `In progress — decided, partly implemented,
**not validated**` until 2026-08-09, when a build of `WebKit-7624.4.5.14.1`
was finished end to end and `Zer0.app` loaded a page with its networking,
web content and GPU processes all running out of the build tree rather than
out of `/System`. With that, ADR-0005 moves to `Accepted`, and ADR-0004 to
partial supersession.

What that still does not give us is a way to ship. ADR-0005 §"When to
revisit" #2 named the blocker plainly: **notarisation requires hardened
runtime, hardened runtime strips `DYLD_*`, and the embedding mechanism
relies on `LC_DYLD_ENVIRONMENT` carrying `DYLD_FRAMEWORK_PATH` into the
process.** The way through that door is the
`com.apple.security.cs.allow-dyld-environment-variables` entitlement — what
Orion carries, and a real widening — and it is taken here, not in ADR-0005,
because the choice belongs to a distribution strategy rather than to an
embedding one. ADR-0005 says *how the engine is embedded*; this ADR says
*what we ship, to whom, and how often*.

And there is a second pressure. From the day ADR-0005 lands in a real
release, **the engine becomes our responsibility**: a WebKit CVE reaches the
user only if we cut a release that carries the fix. That obligation is
incompatible with "every build goes to every user." The Chrome / Chrome
Canary split exists for exactly this reason, and so does Safari / Safari
Technology Preview: a canary channel absorbs breakage that would otherwise
reach people who picked the stable binary on purpose, and a stable channel
absorbs fixes at a cadence nobody has to babysit. We are taking the same
shape.

## Decision

**Two `.app` bundles live side by side. They share a codebase and a WebKit
pin, and they differ in bundle id, app name, profile directory, update
trigger, and Sparkle appcast.**

| | Stable | Canary |
| --- | --- | --- |
| Bundle id | `com.thezer0.browser` | `com.thezer0.canary` |
| App name | `zer0` | `zer0 Canary` |
| Profile dir | `~/Library/Application Support/com.thezer0.browser/` | `~/Library/Application Support/com.thezer0.canary/` |
| Update trigger | tag `v*` | push to `main` |
| Sparkle appcast | `appcast-stable.xml` | `appcast-canary.xml` |
| WebKit | embedded, pinned (ADR-0005) | embedded, pinned (ADR-0005) |

**Bundle id and app name are parametrised through one door.** Today
`apple/scripts/bundle.sh` hardcodes `CFBundleIdentifier=com.thezer0.zer0`
and `CFBundleName=zer0` inside a heredoc. The shape this ADR lands is a
`build_bundle_id_parametrized` in the same script — one function, one
parameter, one place the id is written — so a canary build and a stable
build are the same invocation with a different argument, and a test that
reads the plist back can prove it. The same door produces
`CFBundleDisplayName`, the profile path derivation, and the Sparkle channel
selection, because **a rule enforced at N call sites has N−1 bugs waiting**
(AGENTS.md).

**Profiles are isolated by bundle id, not by flag.** The shell appends
`Bundle.main.bundleIdentifier` to the `Application Support` directory macOS
provides, so each channel lands under its own subdirectory; we depend on
that, and we do not add a `--profile-dir` override to make canary and
stable share state. A person who installs both can be confident that a
canary crash does not eat their stable tabs, and a person who uninstalls
canary can `rm -rf` its directory without thinking. The isolation is
structural, not a preference.

**WebKit is embedded in both channels at the same pinned tag.** There is no
"canary on `main`, stable on the pin" split, and no Safari Technology
Preview–style third channel — yet. ADR-0005's argument that `WebKit-*` tags
are the only revisions that have been through a release cycle holds as
strongly for canary as it does for stable, and the cost of running a third
engine track is the cost of running a third browser. When `main` becomes
attractive enough to ship, that is its own ADR (see *When to revisit*).

> **The "same pinned tag" clause is superseded by ADR-0124**, and only that
> clause: stable keeps a `WebKit-*` source-drop tag, canary now pins an
> exact sha of `main`, both still embedded. Everything else this ADR
> decided — two bundles, two profiles, two appcasts — stands.

**Update triggers are GitHub Actions workflows on a macOS runner
(Blacksmith.sh).** Canary fires on every push to `main`; stable fires on
every tag matching `v*`. The WebKit build is the long pole — 35m34s clean,
31s incremental (measured in `scripts/webkit/README.md`) — so the workflow
caches it as an artefact keyed on `scripts/webkit/version.txt`, and the
`build-webkit` job runs only when that file changes. The downstream job
(assemble, embed, sign, package, publish to the appcast) is **~10 min**
against a cached engine.

**Hardened runtime is on, with one entitlement.**
`com.apple.security.cs.allow-dyld-environment-variables` is exactly what
ADR-0005 §"Consequences" warned it is: a widening that reopens *every*
`DYLD_*` variable for the process, not only ours. It is taken here because
the embedding mechanism does not work without it, because the alternative
is rewriting install names across Apple-signed binaries with no guarantee
of header padding, and because Orion — a WebKit browser with the same
problem — carries it too. The mitigation is that the widening is scoped to
the process, not to the kernel, and that no third-party code runs in the
UI process.

**Signing is ad-hoc today, Developer ID Application when we have one.**
Nothing in this ADR depends on the signature being real, and everything in
ADR-0108 does: 1Password's helper refuses ad-hoc parents by construction.
The split between "we have a signing identity" and "we do not" is
orthogonal to the split between stable and canary — both channels move
from ad-hoc to Developer ID on the same day, and both bundle ids need to
be enrolled in `browsers.other-trusted-apps` separately (see
*Consequences*).

**Auto-update is Sparkle 2, with one appcast per channel.** Stable users
read `appcast-stable.xml`; canary users read `appcast-canary.xml`. The two
files are signed with the same EdDSA key, published from the same workflow
job, and the only difference between them is which artifacts the enclosure
lists. Delta updates are deferred until a first failure forces the question
(see *When to revisit*).

## Consequences

**Size, measured against the Orion stand-in and the 2026-08-09 build.**
Each bundle carries the full WebKit family in `Contents/Frameworks/`, plus
the three XPC service bundles alongside it (ADR-0005). Numbers from
ADR-0005's table, with the thinning this ADR adds:

| | universal (x86_64 + arm64) | arm64 thinned |
| --- | --- | --- |
| stable `.app` | ~387 MB | ~190 MB |
| canary `.app` | ~387 MB | ~190 MB |

Two orders of magnitude heavier than the system-WebKit shell of ADR-0004,
unchanged from ADR-0005; the cost was paid when ADR-0005 was accepted.

**Build time.** The downstream job (downstream of a cached WebKit) is
**~10 min**: a release build of the Rust core, a SwiftPM build of the
shell, `embed-webkit.sh` against the cached engine, signing, packaging.
The upstream `build-webkit` job is **~45 min** on the same runner — the
35m34s measured clean build, plus the shallow checkout — and it runs only
when `scripts/webkit/version.txt` changes. In practice that is rare: the
tag has been pinned at `WebKit-7624.4.5.14.1` since 2026-08-08 and has not
moved.

**Security.** Both channels assume responsibility for WebKit CVEs in the
embedded engine. This was already true from the moment ADR-0005 moved to
`Accepted`; this ADR does not widen it. What it does add is a *cadence*
obligation — canary ships every push to `main`, so a CVE fix lands in
canary the day the pin bumps, and the question of how long stable users
wait becomes a real one. The answer named here is: stable follows the next
tag `v*`, on purpose, with no SLA yet. The first real CVE is the test of
whether that is acceptable (see *When to revisit*).

**1Password enrolment doubles, and neither id inherits.** ADR-0108 named
the `browsers.other-trusted-apps` entry as the commercial hinge for
1Password, and the entry it describes carries `com.thezer0.zer0`. This
ADR retires that id in favour of `com.thezer0.browser` and adds
`com.thezer0.canary` alongside it — and AgileBits has to enrol **both**,
separately, because `browsers.other-trusted-apps` is a list of exact
bundle ids, not a prefix match. The Team ID `24X5CQGA86` named in
ADR-0105 covers both once they are signed by it; the path the enrolment
names has to cover both as well. This is the part of the ADR most likely
to be the long pole in practice.

**Update fatigue, split by channel.** Canary users get an update every
push to `main` — every week, every day if the project is hot. Stable
users get one every tag, which is whenever someone decides the trunk is
shippable. The two populations are self-selecting, the way Chrome Canary
and Chrome are; the cost is that a canary user who wanted stable
behaviour installed the wrong binary, and the mitigation is that the app
name, the icon and the profile directory all name the channel
unambiguously.

**Sparkle 2 is a new dependency.** It is the de facto macOS auto-updater,
it is well-maintained, and it is one more thing to track. It is also the
one piece of the distribution story that touches the network on every
launch, and the appcast it reads is a signed XML file on a static host —
not a service. The signing key is a secret the project holds; the
verification key is embedded in the bundle.

## How this regresses

**"The bundle id was wrong in the build script, and nobody noticed until
enrolment broke."** A heredoc typo, a copy-paste of the wrong constant,
a `case` that falls through — any of these produces a `.app` that runs
fine and identifies itself as the wrong channel. The symptom arrives
weeks later, as "1Password stopped connecting", "I can't set zer0 as my
default browser", or "the URL scheme handler opened the other binary",
and none of it points back at `bundle.sh`. The lock that catches it is
`theStableBundleHasTheStableIdAndTheCanaryHasTheCanaryId`, named in the
debt note above; it reads the plist back after a parametrised build and
asserts the id matches the argument. Without it, the only signal is the
enrolment failure, which is exactly the delay AGENTS.md warns about.

**"The WebKit pin went stale, and a CVE sat unfixed because no one
bumped it."** This is the operational obligation ADR-0005 §"Consequences"
named, arriving. The pin in `scripts/webkit/version.txt` ages; WebKit
advisories publish against revisions; nothing in `check.sh` watches
either. The symptom is "an advisory dropped, the pin didn't move, and
both channels shipped a vulnerable engine for a week". No test in this
repo can catch this — the advisory is not in the tree. The mitigation is
operational: a recurring check of the WebKit advisory feed against the
pin, owned by a person, until that check is automated.

**"The Sparkle appcast was signed with the wrong key, and the update
silently refused."** Sparkle verifies the appcast signature against a
public key compiled into the bundle. If the workflow signs with a freshly
generated key and the bundle still carries the old one, the update is
refused, the user sees nothing — or sees a stale "up to date" — and the
next time someone reaches for "why aren't users on the latest build" the
answer is days away. The lock here is operational too: the signing key
rotation is a release step, and it touches both channels in lockstep.
When the keys drift, the channel that was not updated stops updating.

**"The workflow pushed a canary build into the stable appcast."** Two
workflows sharing YAML, a matrix dimension misconfigured, a reusable
workflow called with the wrong inputs — the failure produces a stable
binary that is actually trunk, distributed to people who picked stable
on purpose. No test in the bundle catches this; the gate is the workflow
name and the trigger condition, both of which are review concerns, not
assertions. The defence is that the two workflows are separate files
with separate names and that the channel is a required input, not a
default.

**"A canary user opened stable, and their profile was empty."** This is
the regression that *can* be caught by a test, and it is the second half
of `BundleIdTests`: a bundle built as canary must read its profile from
`com.thezer0.canary/`, not from `com.thezer0.browser/`, and a bundle
built as stable must read from `com.thezer0.browser/`. The lock the
implementation lands is `defaultStoragePathFollowsTheBundleIdRule`,
which asserts `defaultStoragePath()` builds on the bundle-id rule rather
than holding a literal of its own — the literal was the bug, and the test
goes red the moment it comes back. Without it, a refactor of the path
code silently collapses the two profiles, and a canary user's tabs show
up inside stable on next launch — or worse, stable writes into canary's
profile and the next canary update renders it unreadable.

## When to revisit

- **When the WebKit `main` branch carries a feature this browser needs,
  and no `WebKit-*` tag has shipped it yet.** That is the moment the
  STP-style third channel re-enters the conversation: a `main`-tracking
  build, behind a third bundle id, with no pretence of stability. It is
  not this ADR; it is the one this ADR points at when the cost of *not*
  shipping `main` becomes measurable. (ADR-0124 is that ADR, arrived at by
  the canary door rather than a third channel: canary tracks `main` on a
  sha, stable keeps the tag.)
- **On the first WebKit CVE published after the first embedded
  release.** ADR-0005 §"When to revisit" #3 names this moment as the
  test of whether the rebuild-and-ship path exists at all; this ADR
  narrows it to whether the stable channel can ship the fix inside a
  week. If it cannot, the cadence decision above is wrong and the
  channels have to share a faster trigger.
- **When Sparkle's delta update fails on a real release.** Delta
  updates are a size optimisation that trades reliability for bandwidth;
  if the binary diff is rejected on a real machine, the choice is to
  ship full archives forever (the current shape) or to revisit the
  distribution substrate. Either way, the channel split survives.
- **When the Linux port starts in earnest.** `webkit2gtk` has no
  `WKWebExtensionController` (ADR-0106), no Sparkle, and no bundle id.
  The channel *strategy* — separate risk populations, separate update
  cadences — crosses; the channel *mechanism* — bundle ids, appcasts,
  `.app` bundles — does not, and a third host rather than a rewrite is
  what AGENTS.md commits to. The Linux channel question is its own ADR.
- **When the bundle id has to change.** `com.thezer0.browser` is a
  decision, not a constant of nature; if it ever has to move (a rename,
  a domain change, an App Store guideline), the profiles break, the
  1Password enrolment breaks, and the Sparkle update chain breaks.
  Renaming the bundle id is a new ADR, not an edit to this one — the
  population that installed under the old id is a population this
  decision does not reach.
