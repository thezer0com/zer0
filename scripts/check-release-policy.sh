#!/usr/bin/env bash
# Holds the two release workflows to the release policy (ADR-0125).
#
#   ./scripts/check-release-policy.sh
#
# The policy is two halves that only mean something together: main ships a
# rolling `latest` prerelease that yields the Latest badge, and the official
# release is the `v*` tag, which takes the badge. Each half lives in a
# different workflow file that a later edit can quietly reshape -- a branch
# trigger added to stable, `--latest=false` dropped from the rolling release
# because "a prerelease isn't latest anyway", `make_latest` removed because
# "the default is true". The moment any of those lands, an unvetted build
# owns the recommendation or a tagged one loses it, and nothing red happens
# anywhere. The greps below are deliberately dumb: they ask whether the
# sentence is still written down, not whether the YAML around it is clever,
# because the failure they exist to catch is a sentence being quietly
# unwritten.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STABLE="$ROOT/.github/workflows/stable.yml"
CANARY="$ROOT/.github/workflows/canary.yml"

failures=0
fail() {
	printf 'error: %s\n' "$1" >&2
	failures=$((failures + 1))
}

require() {
	# require <file> <fixed-string> <what the policy loses without it>
	local file="$1" needle="$2" why="$3"
	if ! grep -qF -- "$needle" "$file"; then
		fail "$file no longer contains \"$needle\".
  $why"
	fi
}

refuse() {
	# refuse <file> <fixed-string> <what the policy loses by keeping it>
	local file="$1" needle="$2" why="$3"
	if grep -qF -- "$needle" "$file"; then
		fail "$file now contains \"$needle\".
  $why"
	fi
}

check_release_policy() {
	# (a) The official release is a tag, never a branch push: stable fires
	# on `v*` only. A stable that also fires on a branch is a second
	# rolling channel with signing powers.
	require "$STABLE" "tags: ['v*']" \
		"Stable lost its v* tag trigger (ADR-0125): without it there is no official release at all."
	refuse "$STABLE" "branches:" \
		"A branch trigger on stable makes an untagged build an official release (ADR-0125). Rolling belongs to canary."

	# (b) The rolling release yields the badge. Both flags matter and both
	# look droppable: --prerelease marks the unvetted population, and
	# --latest=false is the half of the policy that keeps the badge on the
	# tag when the rolling release is newer.
	require "$CANARY" "rolling-latest:" \
		"Canary has no rolling-latest job (ADR-0125): main has nothing rolling to ship."
	require "$CANARY" "--latest=false" \
		"The rolling release must publish with --latest=false (ADR-0125), or every push to main quietly takes the Latest badge off the tagged release."
	require "$CANARY" "--prerelease" \
		"The rolling release must be a prerelease (ADR-0125): it is unvetted by definition."

	# (c) The rolling population rides main: a rolling release on anything
	# else is a third channel nobody decided on.
	require "$CANARY" "branches: [main]" \
		"Canary must fire on pushes to main (ADR-0125): that push is the rolling release's whole cadence."

	# (d) The official release takes the badge explicitly. The action's
	# default today is true; the policy must not rest on a default that a
	# copied step or an upstream change can flip silently.
	require "$STABLE" "make_latest: true" \
		"The v* release must carry make_latest: true in writing (ADR-0125): the badge moves only with a tag."
}

check_release_policy

if ((failures > 0)); then
	printf 'error: %d problem(s) against the release policy in the workflows (ADR-0125).\n' "$failures" >&2
	exit 1
fi
echo "==> release policy: official on v* (badge on the tag), rolling latest on main"
