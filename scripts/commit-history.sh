#!/usr/bin/env bash
# Checks the local history before it is pushed as the release's base.
#
#   ./scripts/commit-history.sh
#
# This is deliberately a preflight, not a history rewrite. It catches the
# commits that are plainly unfinished while leaving the repository's existing
# plain-English and merge subjects alone. Remote state is outside this check.
set -euo pipefail

ROOT="${ZER0_COMMIT_HISTORY_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT"

failures=0
fail() {
	printf 'error: %s\n' "$1" >&2
	failures=$((failures + 1))
}

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	fail "${ROOT} is not a Git worktree. Run this from the repository that will be pushed."
else
	if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
		fail "the repository has no HEAD commit. A release base must have history."
	fi

	shallow="$(git rev-parse --is-shallow-repository 2>/dev/null || true)"
	if [[ "$shallow" == true ]]; then
		fail "the checkout is shallow. Fetch the complete HEAD history before validating release commits."
	fi

	if history="$(git log --format='%H%x09%s' HEAD 2>/dev/null)"; then
		count=0
		while IFS=$'\t' read -r hash subject; do
			[[ -n "$hash" ]] || continue
			count=$((count + 1))

			if [[ ! "$subject" =~ [^[:space:]] ]]; then
				fail "$hash has an empty commit subject."
				continue
			fi

			if [[ "$subject" =~ ^[Ww][Ii][Pp]([[:space:]]|:|$) ||
				"$subject" =~ ^[Tt][Mm][Pp]([[:space:]]|:|$) ||
				"$subject" =~ ^[Tt][Ee][Mm][Pp]([[:space:]]|:|$) ||
				"$subject" =~ ^[Ff][Ii][Xx][Uu][Pp]!([[:space:]]|$) ||
				"$subject" =~ ^[Ss][Qq][Uu][Aa][Ss][Hh]!([[:space:]]|$) ]]; then
				fail "$hash has an unfinished subject: $subject"
			fi
		done <<<"$history"

		if ((count == 0)); then
			fail "HEAD has no reachable commits."
		fi
	else
		fail "git log could not read the history reachable from HEAD."
	fi
fi

if ((failures > 0)); then
	printf 'error: %d problem(s) in the local commit history.\n' "$failures" >&2
	exit 1
fi

echo "==> commit history: ${count} reachable commit(s), no unfinished subjects"
