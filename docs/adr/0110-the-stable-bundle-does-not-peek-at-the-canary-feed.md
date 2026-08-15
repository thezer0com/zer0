# ADR-0110: The stable bundle does not peek at the canary feed

- **Status:** Accepted
- **Date:** 2026-08-13
- **Lock:** `apple/Tests/Zer0ShellTests/UpdateChannelTests.swift::UpdateChannelTests/theStableChannelReadsOnlyTheStableFeedAndHasNoPeek`

## Context

ADR-0109 shipped two `.app` bundles — stable and canary — differing in bundle
id, profile directory, and Sparkle appcast, and made the isolation structural:
"Profiles are isolated by bundle id, not by flag. ... we do not add a
`--profile-dir` override to make canary and stable share state. ... The
isolation is structural, not a preference." The lock on that isolation is
`defaultStoragePathFollowsTheBundleIdRule`, which holds the profile path to the
bundle id.

When Sparkle was wired in (`UpdateHost.swift`), a toggle slipped in that
ADR-0109 never named: **"Receive canary updates"**, a stable-only switch in
Settings › Updates that re-points Sparkle's `feedURLString(for:)` at
`appcast-canary.xml` at runtime. The file header argued the peek was harmless
— "a stable user who peeks canary is *not* running the canary binary, is *not*
touching the canary profile, and is only asking Sparkle to read a different
appcast." The settings footnote repeated the claim: the peek "does not install
Zer0 Canary, does not share its profile."

That claim is true up to the moment Sparkle applies an update, and false
after. The canary appcast's enclosure is a full `.app` built with
`CFBundleIdentifier=com.thezer0.canary` (the same `resolve-bundle.sh` door
ADR-0109 names). Sparkle replaces the on-disk app at the install path with
whatever the enclosure carries, and an enclosure is the whole bundle,
`Info.plist` included. So the first canary item whose `sparkle:version`
exceeds the stable binary's turns the peek into a silent bundle-id mutation:

- `Bundle.main.bundleIdentifier` reads `com.thezer0.canary` on next launch
- the profile path derives from the bundle id →
  `~/Library/Application Support/com.thezer0.canary/`
- the stable profile at `com.thezer0.browser/` is orphaned in place
- the 1Password enrolment (ADR-0108, ADR-0109) was for `com.thezer0.browser`
  and now points at nothing

The toggle is reversible — flipping it off re-points the feed — but it does
not revert the *installed binary*. The one-way door is disguised as a two-way
switch. `sparkle-setup.md` even waved this off as "the peek only widens the
feed, it does not downgrade," which held only because the two channels
happened to ship the same `CFBundleVersion=1`; the moment canary's build
number pulls ahead (which is canary's entire purpose), Sparkle offers the
canary build and installs it into the stable path.

This is three AGENTS.md rules failing at once: **say only what you can prove**
(the footnote claimed no profile touch it could not guarantee), **the dangerous
regression is the one that reads as an improvement** (a tidy "let stable
preview canary" affordance), and **a guarantee is structural or it is not a
guarantee** (the isolation ADR-0109 made structural, the peek poked a flag
through).

## Decision

**Remove the peek. The stable bundle reads the stable feed; the canary bundle
reads the canary feed; nothing in the shell offers a stable binary a path to
the canary appcast.**

A person who wants canary installs `Zer0 Canary.app` — the second `.app`, side
by side, that ADR-0109 already committed to and that the release pipeline
already produces. That path is honest about what it is: a different bundle id,
a different profile, a different 1Password enrolment, named in the app name,
the icon and the dock. The peek was a third path that collapsed all four into
a toggle whose label promised none of them.

Concretely: `UpdateHost` loses `canaryPeekEnabled`, `setCanaryPeek(_:)`,
`currentFeedURL()`, and `activeFeedURL`. The feed a channel reads becomes
`Channel.appcastURL` and nothing else — the delegate's `feedURLProvider`
returns `self?.channel.appcastURL` with no branch. Settings › Updates loses
the "Receive canary updates" row on stable and keeps the canary channel
readout on canary. `@AppStorage("updateCanaryPeek")` is gone; the choice it
held was not a preference the shell should have been offering.

This does not supersede ADR-0109; it narrows it. ADR-0109 said the two
channels are isolated by bundle id and named the doors that keep them so. This
ADR removes the one shell affordance that let a flag reach across, and is
recorded because the implementation had drifted past the decision it claimed
to implement.

## Consequences

**The shell has one feed-resolution surface: `Channel.appcastURL`.** No
toggle, no UserDefaults key, no runtime override. A future feature that wants
a stable user to see something from canary has to come back through this ADR,
because the cheap path — a `@AppStorage` bool consulted by the feed delegate —
is exactly the shape that broke.

**The Sparkle `SUFeedURL` written into `Info.plist` by `bundle.sh` is now the
whole story at launch.** It was always the default; `UpdateHost` overrode it
at runtime when the peek was on. With the peek gone, the delegate and the
plist agree for every launch, and the "two readers of the channel" the file
header warned about are the plist and the Swift suffix check — both already
locked by ADR-0109.

**A stable user cannot preview canary from inside the app.** That is the cost,
and it is the right cost: the honest preview is a second `.app`, and "I want
to see trunk without reinstalling" is a wish the toggle satisfied by lying
about what reinstalling means here. The release pipeline already publishes
both bundles; `docs/stable-canary.md` points at the second install.

**No migration.** `updateCanaryPeek` was a local UserDefaults bool that
defaulted to `false`; deleting the reader leaves any stored `true` as an
orphan key macOS ignores. There is no profile move, no data to carry, nothing
to prompt over.

## How this regresses

**"Someone re-adds a feed-override toggle, and the isolation ADR-0109
promised develops a flag-shaped hole again."** The cheap shape is a
`@AppStorage` bool and a branch in the feed delegate — exactly what was just
removed. The lock `theStableChannelReadsOnlyTheStableFeedAndHasNoPeek` holds
the `Channel.appcastURL` values and their distinctness, so a change that
repoints stable at canary fails the build. What the test does *not* catch is
a peek reintroduced as a second resolution surface the host consults *instead
of* `Channel.appcastURL`; that is a code-review concern, and this ADR is the
argument against it. This is the same shape as ADR-0109's own un-testable
regressions (the workflow misroute, the signing-key drift): the structural
part is locked, the operational part is named.

**"A stable user who had the peek on updates to a build that removed it, and
Sparkle still holds a stale feedURL from the old toggle."** It does not: the
feed URL was always delivered through the delegate on every check
(`feedURLString(for:)` is called per check), never persisted via `setFeedURL:`
(the deprecated setter that fights back). Removing the toggle removes the
branch the delegate read; the next check consults the delegate and gets
`channel.appcastURL`. There is no persisted override to clean up, and this is
precisely the reason the implementation routed through the delegate rather
than `setFeedURL:` — the decision to remove the peek later was kept cheap by
that earlier choice.

**"The two appcasts ship the same `sparkle:version`, and someone reads the
absence of a canary update as proof the peek would have been safe."** The
versions matching is an accident of both channels sitting at `0.1.0`/build 1
today; the moment canary's build number advances (its reason for existing),
the canary appcast carries a newer item than the stable binary. A removed peek
is safe regardless; the trap is reasoning "the peek never installed anything"
from a window where it structurally could not have. `sparkle-setup.md`'s old
line asserting the peek "does not downgrade" was exactly that reasoning, and
is gone with it.

## When to revisit

- **When Sparkle (or a successor) can install a channel's payload without
  replacing the host's `Info.plist`.** The peek was unsafe because an appcast
  enclosure is a full `.app` and Sparkle swaps it whole. If a future
  distribution substrate can deliver "the canary binary, keep my stable
  identity," the peek becomes a real preview rather than a silent migration,
  and this decision reopens. That substrate does not exist in Sparkle 2 today.
- **When a third channel (e.g. `main`-tracking, per ADR-0109 §"When to
  revisit") makes "what channel is this binary on" a question worth a UI
  answer.** A read-only channel indicator is not a peek; a switch still
  belongs in a new ADR.
- **When the Linux port lands and the channel mechanism is no longer
  bundle-id-derived.** ADR-0109 already names this as its own ADR; the "no
  peek" stance carries, but the lock shape (a Swift test on `Channel`) does
  not, and a host-specific lock takes over.
