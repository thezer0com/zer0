# ADR-0124: Each channel pins its own WebKit, and the About window names the engine that runs

- **Status:** Accepted, and it partly supersedes the same-pin clause of ADR-0109
- **Date:** 2026-08-16
- **Lock:** `scripts/webkit/check-versions.sh::require_channel_keys`, `apple/Tests/Zer0ShellTests/Zer0MarkTests.swift::AboutVersionTests/embeddedEngineIsNamedAsTheBundlesOwn`, `apple/Tests/Zer0ShellTests/Zer0MarkTests.swift::AboutVersionTests/systemEngineIsNamedAsTheSystems`, `apple/Tests/Zer0ShellTests/Zer0MarkTests.swift::AboutVersionTests/unreadableEngineVersionIsOmittedNotInvented`

## Context

ADR-0109 put both channels on one WebKit pin and named the moment that
would change: "when the WebKit `main` branch carries a feature this browser
needs, and no `WebKit-*` tag has shipped it yet." What actually fired is
not a feature. It is two obligations ADR-0109 wrote down itself and left to
a person.

**The stale pin.** ADR-0109's own regression section: "an advisory dropped,
the pin didn't move, and both channels shipped a vulnerable engine for a
week… The mitigation is operational: a recurring check of the WebKit
advisory feed against the pin, owned by a person, until that check is
automated." Nobody automated it. The pin has not moved since 2026-08-08.

**The canary that meets engine change last.** ADR-0109's rationale for a
canary channel was a risk population absorbing breakage early. It does that
for the shell — every push to `main` — but not for the engine: both
channels embed the same source-drop tag, so an engine regression introduced
upstream reaches canary exactly when it reaches stable, one Safari release
cycle late. The population that volunteered to find engine regressions
early is the last population to see them.

And a third, smaller thing: the About window names the app's version and
says nothing about the engine. `run-with-webkit.sh` documents that dyld
silently falls back to `/System` when an override is not loadable — a
browser that renders with a different WebKit than it thinks it has is a bug
report that cannot be reproduced. The About window is where that fact
belongs, because it is the thing a person pastes into the report.

## Decision

**`version.txt` carries one truth per channel, and stays the only place a
revision is written down.** `WEBKIT_TAG_STABLE` is the `WebKit-*`
source-drop tag stable embeds (unchanged: `WebKit-7624.4.5.14.1`).
`WEBKIT_CANARY_REF=main` plus `WEBKIT_CANARY_SHA` is canary's pin. The ref
alone is a moving target — two checkouts an hour apart would build different
engines under the same name — so the sha is the pin and the ref documents
how the next sha is resolved.

**Every reader goes through one door, and the channels cannot drift
silently.** `webkit_pin_for_channel` in `scripts/webkit/common.sh` is the
only thing that maps a channel to a revision; `fetch.sh` accepts a tag or a
raw sha (GitHub serves unadvertised shas to `git fetch --depth 1`); each
workflow reads its own key, and the engine caches are keyed
`webkit-stable-<tag>` and `webkit-canary-<sha>`. `fail-on-cache-miss`
survives untouched: a canary release without *its* engine is no release at
all, and a job that somehow reached for the other channel's cache would
miss, not hit.

**The bump is automated, dependabot-style.** `.github/workflows/webkit-bump.yml`
runs weekly, resolves the newest `WebKit-*` tag and `main`'s sha with the
same `ls-remote` recipe `version.txt` always documented, and opens a PR.
Merging it is the loud part: the push to `version.txt` makes
`build-webkit.yml` build both caches. A canary sha that does not build goes
red there — `fail-fast: false`, so stable's leg is not cancelled with it —
and the canary channel fails closed until the next bump or a revert. The
bump bot uses only `GITHUB_TOKEN`, and events made with it trigger no
workflows, so the bot's PR carries no CI of its own; a hand-edited pin gets
a PR-time build instead, because a human's push does trigger them.

**The About window declares the engine that runs.** One line under the
version: "Engine: embedded WebKit 7624.4.5.14.1" or "Engine: system WebKit
21624.4.5.11.5". Provenance is decided by where the loaded WebKit bundle
lives — `Bundle(for: WKWebView.self)` inside `Bundle.main` — never by what
the app ships, so an embed dyld silently dropped shows "system", which is
the truth. The number is the framework's own `CFBundleVersion`, the same
one `run-with-webkit.sh` prints; a version nobody can read is omitted, not
invented.

**iOS follows the OS and will say so; Linux v1 is a declared divergence.**
iOS cannot swap its engine: the WebKit an iPhone runs is the OS's, floor
18.4 (ADR-0121, ADR-0123), and the iOS About screen declaring that is a
named follow-up in the iOS host — the wording is decided here so both hosts
agree. Linux v1 consumes the distro's WebKitGTK (ADR-0122); that is a
divergence stated in this record, not a third pin in `version.txt`.

## Consequences

**Stable rebuilds once on the key change.** The cache key grows the channel
name (`webkit-<tag>` → `webkit-stable-<tag>`), so the first run after this
lands misses and pays ~35 min; the old entry is orphaned. One-time, and
cheaper than two channels sharing a key they can silently collide in.

**Canary pays a build per bump.** ~35 min of CI weekly, the price of
tracking `main`, paid by runners rather than users. The source offer
follows the pin: canary's LGPL 6(a) offer becomes the sha's source, cached
`webkit-source-<sha>` — the tarball stays deterministic per pin.

**A week without canary is now a possible week.** When `main` does not
build at the pinned sha, canary ships nothing until the next bump. That is
the honest failure: loud (a red workflow), bounded (one week), and absorbed
by the population that opted in.

**`check.sh` grows a cheap gate.** `scripts/webkit/check-versions.sh` holds
the file to its contract — keys present, stable a `WebKit-*` tag, canary a
40-hex sha, the legacy single-channel key refused — before any compiler
runs.

## How this regresses

**"Someone renames a key, or writes `WEBKIT_TAG` back."** The pre-0124
spelling left in the file is inert data today and the first reader to
prefer it back is a channel building the other's engine under its own
cache keys. `check-versions.sh` goes red at the gate naming the key — this
was watched failing (renaming `WEBKIT_TAG_STABLE` → `WEBKIT_TAG`: two
errors there, and `common.sh` refuses besides) before being trusted.

**"The bump merges a sha that does not build."** The PR is green (the bot's
token runs no CI); the failure lands at merge, in `build-webkit`'s canary
leg, and in every canary push afterwards as a cache miss. Recovery is a
revert or a re-run of `webkit-bump` — newer sha, same week. The risk is
bounded by cadence, not by review.

**"The About line says embedded while the system WebKit runs."** The lock
covers the wording; the lookup decides provenance from the loaded bundle,
so the failure mode this cannot have is the one that matters — a broken
embed presenting as embedded. It presents as system, because it is.

**"The channels drift silently."** They cannot, structurally: distinct
keys, distinct caches, `fail-on-cache-miss`. The quiet version of this bug
— canary restoring stable's cache because both keyed on the same tag — is
what the channel-namespaced keys exist to make impossible.

## When to revisit

- **When someone measures whether the source drop builds under the Gtk
  port** (`Tools/gtk/jhbuild`). Nobody has; until then Linux stays
  declared-divergent and this record promises nothing. If it builds, Linux
  joins the same truth with a channel key of its own, and the divergence
  paragraph above becomes wrong the honest way.
- **On the first WebKit CVE after the split.** ADR-0109's question
  survives intact: can stable ship the fix inside a week now that the bump
  is automated? If not, the cadence — not the split — is what revisits.
- **When the iOS About ships.** It should reuse the wording decided here
  ("system WebKit", provenance from the loaded bundle) so a bug report
  from either host reads the same.
- **When a canary sha failing to build becomes routine** (say, more than
  one bump in four). Then the bump should resolve the last known-green
  commit of `main` — WebKit's rollout branches exist for exactly this —
  rather than HEAD. Not promised now; the current failure is loud and
  weekly, which is inside what canary signed up for.
