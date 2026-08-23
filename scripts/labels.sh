#!/usr/bin/env bash
# Applies the curated issue-label taxonomy to the repository this checkout
# points at (gh resolves the target from the git remotes, so a fork labels
# itself, never upstream).
#
# The taxonomy is repo-owned, not remote-only state. It lives in the table
# below so that changing it is a reviewable diff, and running this script is
# what makes the remote converge to the table: each row is create-or-edit, a
# label that exists with the wrong colour or description is corrected rather
# than reported, and re-running is always safe. Nothing is ever deleted. The
# nine GitHub default labels are untouched for a structural reason, not a
# careful one: the script cannot touch a name the table does not carry.
#
# The set is closed (FR-001): adding a label is a human decision, and the row
# in this table is that decision written down where it can be reviewed.
set -euo pipefail

# name|colour|description — the pipe is the field separator, so no field may
# contain one. Palette: areas sit at the cool end of the spectrum, kinds at
# the warm end, priorities on the traffic light. Two curated labels sharing a
# colour would read as one bucket in the issue list, so a collision fails the
# script before a single gh call runs.
LABEL_TABLE="$(
	cat <<'EOF'
area:core|0550AE|The Rust core (crates/zer0-core): state, commands, every decision. The shells only render.
area:macos|0969DA|The macOS shell (apple/, Swift): windows, panels, WebKit hosting, keymap delivery.
area:linux|006B75|The Linux host (linux/): GTK shell consuming the core as a crate — no Apple types.
area:ios|5319E7|The iOS host (apple/ios): skeleton today; the roadmap epic turns it into a real browser.
area:extensions|1BC9C0|The WebExtension runtime: install path, permissions, store compat, native messaging.
area:assistant|8250DF|The assistant and its MCP integration (ADR-0050): servers, gates, persistence.
area:design|D946EF|The visual system: DESIGN.md, design/tokens.toml, and the harnesses that inspect pixels.
area:docs|C5DEF5|The repo explaining itself: README, ADRs, CONTRIBUTING, community files.
area:ci-release|6699CC|Canary and stable channels, the WebKit rebuild pipelines, notarization, appcast.
area:security|111111|Threat surface: the sandbox, permissions, the update chain, hostile input at every boundary.
kind:adr-needed|D93F0B|No code before the decision: an ADR must exist and be accepted before this merges.
kind:debt-lock|F9D0C4|Pays down a 'Lock: none — debt' line in an ADR into a real lock.
kind:measurement|E99695|Decide by measuring: needs a number or a harness before the decision can be made.
priority:high|B60205|Blocks the v0.1.0 release or fixes a defect a person feels; everything else waits.
priority:medium|FBCA04|Real work with no deadline pressure; scheduled behind the high column.
priority:low|0E8A16|Genuinely deferrable; sitting here should cost nobody any guilt.
status:blocked|454B54|Cannot move until a named thing changes; the issue body must say what unblocks it.
epic|A87900|Roadmap tracking issue: a checklist body citing the governing ADRs. Never a task itself.
EOF
)"

# --- the table is checked before the repository is touched ------------------
#
# A malformed row or a colour used twice is a mistake in the decision, not in
# the application of it, and both are cheaper to see here than in the issue
# list. Interval quantifiers ({6}) are unreliable in the pattern matching this
# script can run under — macOS still ships bash 3.2 — so the six hex digits
# are spelled out.
HEX='[0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F]'

bad_rows="$(printf '%s\n' "$LABEL_TABLE" | grep -Ev "^[^|]+\|${HEX}\|[^|]+$" || true)"
if [[ -n "$bad_rows" ]]; then
	printf 'error: malformed row(s), expected name|RRGGBB|description:\n%s\n' "$bad_rows" >&2
	exit 1
fi

dup_names="$(printf '%s\n' "$LABEL_TABLE" | awk -F'|' 'NF { print $1 }' | sort | uniq -d)"
if [[ -n "$dup_names" ]]; then
	printf 'error: the same name appears twice in the table:\n%s\n' "$dup_names" >&2
	exit 1
fi

dup_colours="$(printf '%s\n' "$LABEL_TABLE" | awk -F'|' 'NF { print $2 }' | sort | uniq -d)"
if [[ -n "$dup_colours" ]]; then
	printf 'error: two labels share a colour (%s); in the issue list they would read as one bucket.\n' \
		"$dup_colours" >&2
	exit 1
fi

# --- apply ------------------------------------------------------------------

apply_label() {
	local name="$1" colour="$2" description="$3"

	# gh label create fails on an existing name; that failure is the signal to
	# converge, not an error. Any real failure (auth, network, a rejected
	# colour) fails the edit the same way and visibly — only stdout is quiet,
	# stderr still reaches the terminal — so nothing is swallowed.
	if gh label create "$name" --color "$colour" --description "$description" >/dev/null 2>&1; then
		printf '  + %s\n' "$name"
	else
		gh label edit "$name" --color "$colour" --description "$description" >/dev/null
		printf '  = %s\n' "$name"
	fi
}

count=0
echo "==> labels"
while IFS='|' read -r name colour description; do
	[[ -n "$name" ]] || continue
	apply_label "$name" "$colour" "$description"
	count=$((count + 1))
done <<<"$LABEL_TABLE"

echo "==> labels: ${count} applied; nothing deleted; the GitHub defaults are not in the table and were not touched"
