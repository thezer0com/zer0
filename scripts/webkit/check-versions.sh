#!/usr/bin/env bash
# Holds scripts/webkit/version.txt to the two-channel contract (ADR-0124).
#
#   ./scripts/webkit/check-versions.sh
#
# version.txt is the only place a WebKit revision is written down, and every
# reader -- common.sh, three workflows, the bump bot -- parses it as data. A
# key renamed on one side of that contract is a canary channel silently
# building stable's engine (the cache keys still resolve), so the shape of the
# file is checked, not just the presence of values: the stable pin must be a
# `WebKit-*` source-drop tag, the canary pin a 40-hex sha of its ref.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERSION_FILE="$ROOT/scripts/webkit/version.txt"

failures=0
fail() {
	printf 'error: %s\n' "$1" >&2
	failures=$((failures + 1))
}

version_get() {
	sed -n "s/^$1=//p" "$VERSION_FILE" | tail -1
}

require_channel_keys() {
	local key
	while IFS= read -r key; do
		if [[ -z "$(version_get "$key")" ]]; then
			fail "version.txt has no $key= with a value.
  A reader that names a missing key dies at fetch time with a worse message;
  the contract is checked here first (ADR-0124)."
		fi
	done <<'EOF'
WEBKIT_TAG_STABLE
WEBKIT_CANARY_REF
WEBKIT_CANARY_SHA
WEBKIT_DIR_DEFAULT
EOF
}

refuse_legacy_single_channel_key() {
	# The pre-0124 spelling. Left in the file it is inert data today and a
	# trap tomorrow: the first reader to prefer it back builds one engine
	# under two channel names.
	if grep -q '^WEBKIT_TAG=' "$VERSION_FILE"; then
		fail "version.txt still writes WEBKIT_TAG, the single-channel spelling.
  Two channels are two keys (ADR-0124); the old key is how a channel silently
  builds the other's engine."
	fi
}

require_stable_is_tag() {
	local tag
	tag="$(version_get WEBKIT_TAG_STABLE)"
	if [[ -n "$tag" && ! "$tag" =~ ^WebKit-[0-9] ]]; then
		fail "WEBKIT_TAG_STABLE is '$tag', not a WebKit-* source-drop tag.
  Stable embeds a revision a Safari shipped from; a branch or a bare sha here
  is a stable channel that never asked to be one."
	fi
}

require_canary_is_sha() {
	local sha
	sha="$(version_get WEBKIT_CANARY_SHA)"
	if [[ -n "$sha" && ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
		fail "WEBKIT_CANARY_SHA is '$sha', not a 40-hex commit id.
  A branch name here is a moving target: two checkouts an hour apart build
  different engines under the same pin, and the cache key stops meaning
  anything."
	fi
}

require_channel_keys
refuse_legacy_single_channel_key
require_stable_is_tag
require_canary_is_sha

if ((failures > 0)); then
	printf 'error: %d problem(s) in scripts/webkit/version.txt.\n' "$failures" >&2
	exit 1
fi
echo "==> version.txt: stable tag and canary sha both well-formed"
