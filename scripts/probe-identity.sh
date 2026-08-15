#!/usr/bin/env bash
# Measures whether extension storage.local survives identity changes across
# process restarts. Answers ADR-0104 §"When to revisit" P1 + P2.
#
# 8 subprocesses: 4 cases × (write + read). Each subprocess is a full
# `swift test` run with ZER0_SHOT=1 and the case-specific env vars that the
# #if DEBUG shim in ExtensionHost.load reads.
#
# Usage: scripts/probe-identity.sh
# Prereq: the apple package must build (swift build in apple/).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPLE="$ROOT/apple"

STABLE_ID="aeblfdkhhhdcdjpifhhbdiojplfjncoa"
UUID_A="11111111-1111-1111-1111-111111111111"
UUID_B="22222222-2222-2222-2222-222222222222"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

say() { echo "[orchestrator] $*" >&2; }

# run_case <case_name> <step> <extra-env...>
run_case() {
	local case_name="$1"
	shift
	local step="$1"
	shift
	local case_dir="$WORK_DIR/$case_name"
	mkdir -p "$case_dir"

	say "--- $case_name / $step ---"
	(
		cd "$APPLE"
		env ZER0_SHOT=1 \
			CASE="$case_name" \
			STEP="$step" \
			ZER0_PROBE_DB="$case_dir" \
			"$@" \
			swift test --filter ZZExtensionIdentityProbe 2>&1
	) | grep '^\[probe\]' || true
}

say "building (once)..."
(cd "$APPLE" && swift build --build-tests) >/dev/null 2>&1 || {
	say "build failed"
	exit 1
}

say "running 8 cases..."

# Case 1: baseline-same-scheme
# WebKit default scheme, DIFFERENT uuid per step (simulates today's per-launch mint).
# Expected: storage orphaned (different origin).
run_case baseline-same-scheme write \
	ZER0_PROBE_BASE_URL="webkit-extension://$UUID_A/" \
	ZER0_PROBE_UNIQUE_ID="$UUID_A"
run_case baseline-same-scheme read \
	ZER0_PROBE_BASE_URL="webkit-extension://$UUID_B/" \
	ZER0_PROBE_UNIQUE_ID="$UUID_B"

# Case 2: new-scheme-same-id
# Proposed fix: zer0-extension scheme, STABLE id across both steps.
# Expected: storage persists (same origin).
run_case new-scheme-same-id write \
	ZER0_PROBE_BASE_URL="zer0-extension://$STABLE_ID/" \
	ZER0_PROBE_UNIQUE_ID="$STABLE_ID"
run_case new-scheme-same-id read \
	ZER0_PROBE_BASE_URL="zer0-extension://$STABLE_ID/" \
	ZER0_PROBE_UNIQUE_ID="$STABLE_ID"

# Case 3: migration
# Write under old scheme (uuid), read under new scheme (stable id).
# Expected: storage orphaned (different origin — migration loses data).
run_case migration write \
	ZER0_PROBE_BASE_URL="webkit-extension://$UUID_A/" \
	ZER0_PROBE_UNIQUE_ID="$UUID_A"
run_case migration read \
	ZER0_PROBE_BASE_URL="zer0-extension://$STABLE_ID/" \
	ZER0_PROBE_UNIQUE_ID="$STABLE_ID"

# Case 4: control-default-store
# Filesystem only — validates the harness plumbing, not WebKit semantics.
run_case control-default-store write
run_case control-default-store read

say "done. results:"
echo
echo "## Probe results"
echo
echo "| Case | Write origin | Read origin | Read value | Persisted? |"
echo "|---|---|---|---|---|"
echo "| baseline-same-scheme | webkit-extension://$UUID_A | webkit-extension://$UUID_B | (see above) | |"
echo "| new-scheme-same-id | zer0-extension://$STABLE_ID | zer0-extension://$STABLE_ID | (see above) | |"
echo "| migration | webkit-extension://$UUID_A | zer0-extension://$STABLE_ID | (see above) | |"
echo "| control-default-store | (filesystem) | (filesystem) | (see above) | |"
