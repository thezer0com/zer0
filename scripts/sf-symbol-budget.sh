#!/usr/bin/env bash
# SF Symbols do not grow: the shell's use of them has a budget, and this is it.
#
#   ./scripts/sf-symbol-budget.sh
#
# zer0 is going multi-platform and SF Symbols render on Apple platforms only
# (ADR-0116). The licensed replacement is Lucide; the sites already in the
# shell migrate to it component by component, and each migration PR lowers the
# budget with them. What this refuses is growth: a new
# `Image(systemName:)` is one keystroke away in any SwiftUI file, reads as the
# obvious choice on macOS, and quietly re-locks a surface that was about to
# become cross-platform.
#
# The count is occurrences, not files — a line can carry two:
#
#   grep -roE 'systemName:|systemImage:' --include='*.swift' \
#       apple/Sources/Zer0Shell | wc -l
#
# A count below the budget is green but says so loudly: slack in a ratchet is
# slack the next addition spends for free.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SHELL_DIR="apple/Sources/Zer0Shell"

# 112 on 2026-08-15: 66 `systemName:` + 46 `systemImage:` (ADR-0116). Only
# ever moves down, in the PR that migrated the sites away.
BUDGET=112

count_sites() {
	# grep exits 1 on zero matches, which under `pipefail` would turn "fully
	# migrated" into a cryptic crash — the day this reaches zero is the day
	# the budget is deleted, not a broken gate.
	(grep -roE 'systemName:|systemImage:' --include='*.swift' "$SHELL_DIR" || true) |
		wc -l | tr -d '[:space:]'
}

check_sf_symbol_budget() {
	local count
	count="$(count_sites)"

	if ((count > BUDGET)); then
		printf 'error: %d SF Symbol sites under %s, budget is %d.\n' \
			"$count" "$SHELL_DIR" "$BUDGET" >&2
		echo "  SF Symbols render on Apple platforms only and the shell is going" >&2
		echo "  multi-platform (ADR-0116). Take the icon from the licensed set" >&2
		echo "  (Lucide), or migrate an existing site and lower the budget with it." >&2
		exit 1
	fi

	if ((count < BUDGET)); then
		echo "==> sf symbols: $count sites, below budget $BUDGET — lower BUDGET to $count in this PR"
		return
	fi

	echo "==> sf symbols: $count sites, at budget ($BUDGET)"
}

check_sf_symbol_budget
