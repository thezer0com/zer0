# ADR-0125: A push to main ships a rolling `latest` prerelease, and an official release exists only on a `v*` tag

- **Status:** Accepted, and it extends the channel model of ADR-0109 rather than changing it
- **Date:** 2026-08-17
- **Lock:** `scripts/check-release-policy.sh::check_release_policy`

## Context

GitHub puts a "Latest" badge on one release, and every surface that says
"download this project" — the repository landing page, `gh release view`,
`gh repo clone` helpers — follows that badge. Until now nothing owned the
badge on purpose. Stable fires on `v*` tags (ADR-0109), so the badge lands
on whatever tag was cut most recently: honest, but it means the newest
build a person can install is always one tag behind, and "try the current
trunk without building anything" has no answer that does not spend a tag.

At the same time the host map grew. A Linux host exists (ADR-0122) and can
produce a tar.gz a Linux user can run, but the `v*` release carried only
the macOS zip. iOS exists as a host (ADR-0121) with no artefact story at
all, and Windows has no host. "What is in a release" had never been
decided as a policy — it had only ever been "what stable.yml happens to
attach".

The decision, made by the author in one sentence and recorded here: every
push to `main` is shippable as far as the rolling population is concerned,
and *official* is a word reserved for the tag.

## Decision

**Main ships a rolling GitHub Release named `latest`.** Every push to
`main` publishes to the one release called `latest`, owned by canary.yml's
`rolling-latest` job. It is created `--prerelease` and `--latest=false`:
prerelease because it is unvetted by definition, badge-less because the
badge is a recommendation and no commit that nobody tagged should ever be
the recommendation. "Rolling" is the whole point — the same release is
overwritten as main moves, so there is exactly one place to point someone
who wants the current trunk.

**The official release is the `v*` tag, and it takes the badge on
purpose.** stable.yml fires only on tags matching `v*`, and keeps
signing+notarisation fail-closed exactly as before — an official release
that ships ad-hoc is not a release (ADR-0109's rule, unchanged). The tag's
release is created with `make_latest: true` written out. The action's
default today is true; the policy does not rest on a default, because a
default change — or a step copied from somewhere that overrides it — must
not be able to move the recommendation onto an untagged build silently.

**Artefacts are per OS, and the list is closed.**

- **macOS: the signed, notarised zip, always.** This is the population the
  appcast serves and the only artefact Sparkle ever points at.
- **Linux: a tar.gz with its dependencies declared.** The binary, plus
  `design/tokens.toml` and the mark SVG beside it (the shell reads them at
  runtime from the working directory, ADR-0122), plus a README naming the
  runtime dependencies — GTK 4.12+ and WebKitGTK's 6.0 (GTK4) API —
  because Linux v1 consumes the distro's WebKitGTK rather than embedding
  one (the divergence ADR-0124 declared). The job attaches to the tag's
  release *after* the macOS release exists (`needs: build`) and does not
  gate it: a broken GTK header on ubuntu must not hold a signed macOS
  release hostage. The failure is a red job on the tag's run, and a re-run
  re-attaches with `--clobber` once fixed.
- **iOS: no release artefact.** The App Store is its own channel with its
  own gates; a sideload artefact would be a second, worse store competing
  with the real one.
- **Windows: no host, no artefact.** The core stays CI-only there, and the
  release claims nothing it cannot run.

## Consequences

**The Latest badge can only move with a tag.** An unvetted build can never
be the recommendation, structurally: the rolling release is published with
the badge switched off and the official one switches it on. The two flags
are written on purpose in opposite files, which is exactly why they need a
lock — neither file can see the other.

**`latest` is a promise about freshness, not about retention.** The
rolling release is overwritten as main moves; yesterday's rolling build is
not kept anywhere but the workflow artefacts, and nobody should pin an
asset URL of `latest` expecting the same bytes tomorrow. The version a
person is running is the version in the artefact name, same discipline as
canary's.

**Linux users get a runnable artefact on every official release**, and the
release notes' asset list now says what each platform's users should
fetch. The macOS population notices nothing: sign, notarise, release,
appcast — the order and the fail-closed rules are untouched, and the Linux
job runs after, not beside, the publication path.

**`check.sh` grows a cheap gate.** `scripts/check-release-policy.sh` holds
the two workflows to the sentences above — tag trigger and no branch
trigger on stable, rolling-latest with `--latest=false`/`--prerelease` on
main, `make_latest: true` on the tag — before any compiler runs, because a
workflow edit is not a change anyone's laptop tests.

## How this regresses

**"Someone adds a branch trigger to stable."** A stable that also fires on
a branch is a second rolling channel with signing powers, and the branch
that trips it becomes an official release nobody tagged. The gate refuses
`branches:` in stable.yml on sight.

**"Someone drops `--latest=false` from the rolling release."** This is the
regression that reads as an improvement: the flag looks redundant ("of
course a prerelease isn't latest"), and removing it is tidy — after which
every push to main quietly takes the badge away from the tagged release.
The gate greps the flag's presence, not its effect.

**"Someone removes `make_latest: true` because the default is true
anyway."** Same shape, other file: the day after, an action default change
or a copied step moves the recommendation with nothing red anywhere. The
gate greps the flag in stable.yml.

All three were watched failing (each grep inverted in turn, the gate red
naming the file) before being trusted. The greps are deliberately dumb —
they ask whether the sentence is still written down, not whether the YAML
around it is clever — because the failure they exist to catch is a
sentence being quietly unwritten.

## When to revisit

- **When the Linux host grows an installer or package-repository story.**
  A tar.gz with a README is v1's shape; a distro package (or a repo of
  them) would supersede both the artefact and the "dependencies declared
  beside the binary" half of this decision.
- **When a Windows host exists.** The closed artefact list reopens: the
  same per-OS question gets asked for a fourth platform, and this record
  is the wrong answer the day it ships.
- **If the rolling release's churn proves noisier than useful** — watcher
  notifications on every push making `latest` a nuisance rather than a
  promise. Then the rolling cadence (not the badge policy) is what
  revisits: publish on schedule instead of per push, keeping the same
  name and the same badge-less rule.
- **When iOS ships via the App Store.** The "no artefact" clause should
  then name the store link in the release notes, so the official release
  answers iOS users with a pointer instead of silence.
