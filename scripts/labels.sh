#!/usr/bin/env bash
# Applies the curated issue-label taxonomy (FR-001) and the repository topic
# set (FR-002) to the repository this checkout points at (gh resolves the
# target from the git remotes, so a fork labels itself, never upstream).
#
# Both are repo-owned, not remote-only state. They live in the tables below so
# that changing either is a reviewable diff, and running this script is what
# makes the remote converge to the tables. Labels converge row by row: each
# row is create-or-edit, a label that exists with the wrong colour or
# description is corrected rather than reported, re-running is always safe,
# and nothing is ever deleted — the nine GitHub default labels are untouched
# for a structural reason, not a careful one: the script cannot touch a name
# the table does not carry. Topics converge as one set: a topic the table does
# not carry is removed, because a topic is a claim about what this project is
# and only the table's claims were reviewed. That is what retires the four
# broken topics (FR-002) — 'androi' and 'webki' name nothing, 'android' and
# 'windows' name hosts the repo does not have.
#
# Both sets are closed (FR-001, FR-002): adding a label or a topic is a human
# decision, and the row in a table is that decision written down where it can
# be reviewed.
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

# One topic per line — a topic is a single word, so there is no field
# separator to abuse. The order is the spec's (FR-002); 'apple' is listed
# last because it is the one pre-existing topic the table keeps rather than
# curates.
TOPIC_TABLE="$(
	cat <<'EOF'
browser
webkit
rust
swift
macos
linux
ios
zer0-browser
open-source
web-browser
apple
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

bad_topics="$(printf '%s\n' "$TOPIC_TABLE" | grep -Ev "^[a-z0-9]+(-[a-z0-9]+)*$" || true)"
if [[ -n "$bad_topics" ]]; then
	printf 'error: malformed topic(s); GitHub takes lowercase letters and digits in hyphen-separated words:\n%s\n' "$bad_topics" >&2
	exit 1
fi

dup_topics="$(printf '%s\n' "$TOPIC_TABLE" | sort | uniq -d)"
if [[ -n "$dup_topics" ]]; then
	printf 'error: the same topic appears twice in the table:\n%s\n' "$dup_topics" >&2
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

# --- topics ------------------------------------------------------------------
#
# The label half converges row by row because gh offers one call per label;
# the topic half converges as one set because gh rewrites the whole list in a
# single call — there is no window where the repository carries half a set.
# Idempotence is cheaper than that: the edit is not issued at all when the
# remote already matches the table, so re-running is a read, not a write.

echo "==> topics"
current_topics="$(gh repo view --json repositoryTopics --jq '.repositoryTopics[].name' | sort)"
table_topics="$(printf '%s\n' "$TOPIC_TABLE" | sort)"

if [[ "$current_topics" == "$table_topics" ]]; then
	echo "    already converged; no edit issued"
else
	# comm wants sorted input: -13 keeps table-only lines (to add), -23 keeps
	# remote-only lines (to remove).
	to_add="$(comm -13 <(printf '%s\n' "$current_topics") <(printf '%s\n' "$table_topics"))"
	to_remove="$(comm -23 <(printf '%s\n' "$current_topics") <(printf '%s\n' "$table_topics"))"

	topics_args=()
	while IFS= read -r topic; do
		[[ -n "$topic" ]] || continue
		topics_args+=(--add-topic "$topic")
		printf '  + %s\n' "$topic"
	done <<<"$to_add"
	while IFS= read -r topic; do
		[[ -n "$topic" ]] || continue
		topics_args+=(--remove-topic "$topic")
		printf '  - %s\n' "$topic"
	done <<<"$to_remove"

	gh repo edit "${topics_args[@]}" >/dev/null
fi
