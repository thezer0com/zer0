#!/usr/bin/env bash
# Builds zer0 end to end: Rust core, Swift bindings, app, .app bundle.
#
#   ./scripts/build.sh            debug, for developing
#   ./scripts/build.sh release    optimised, for actually using
#
#   ZER0_EMBED_WEBKIT=<dir> ./scripts/build.sh release
#                                 self-contained: also copy that WebKit into the
#                                 bundle, so the app carries its own engine
#   ZER0_EMBED_WEBKIT=orion ./scripts/build.sh
#                                 same, using Orion's WebKit as a stand-in while
#                                 zer0 has no WebKit build of its own
#
#   ZER0_CHANNEL=canary ./scripts/build.sh release
#                                 build the canary bundle (com.thezer0.canary)
#                                 instead of stable (com.thezer0.browser). The
#                                 channel is read by apple/scripts/bundle.sh
#                                 and apple/scripts/embed-webkit.sh through the
#                                 one door at apple/scripts/resolve-bundle.sh,
#                                 and the two `.app`s co-exist in apple/.build/
#                                 so neither clobbers the other (ADR-0109).
#
# Without ZER0_EMBED_WEBKIT the app runs the system WebKit, which is the fast
# default and the one to develop against.
set -euo pipefail

PROFILE="${1:-debug}"
if [[ "$PROFILE" != "debug" && "$PROFILE" != "release" ]]; then
	echo "usage: $0 [debug|release]" >&2
	exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Validate the channel once at the top, so a typo fails in a second rather
# than after the Rust and Swift builds. The source of truth is resolve-bundle.sh
# (ADR-0109); sourcing it here keeps build.sh from duplicating the channel
# list and drifting from it.
# shellcheck source=../apple/scripts/resolve-bundle.sh
. "$ROOT/apple/scripts/resolve-bundle.sh"
build_bundle_id_parametrized "${ZER0_CHANNEL:-stable}" ||
	{
		echo "error: ZER0_CHANNEL must be 'stable' or 'canary'" >&2
		exit 1
	}
echo "==> channel: $RB_CHANNEL ($RB_BUNDLE_ID)"

"$ROOT/apple/scripts/build-core.sh" "$PROFILE"

echo "==> swift build ($PROFILE)"
# Tells Package.swift which target/ directory to link against.
export ZER0_RUST_PROFILE="$PROFILE"
swift_flags=(--package-path "$ROOT/apple")
[[ "$PROFILE" == "release" ]] && swift_flags+=(-c release)

# Teaches the executable to look for frameworks beside itself before falling
# back to the system ones. LC_DYLD_ENVIRONMENT is a load command, not an
# environment variable, so it survives `open`, the Dock and launchd, which is
# what an embedded WebKit needs and what an exported DYLD_FRAMEWORK_PATH cannot
# give (see apple/scripts/embed-webkit.sh for the whole story).
#
# This is unconditional on purpose. With nothing in Contents/Frameworks it is
# inert -- dyld looks, finds nothing, uses the install name -- so the default
# build still runs the system WebKit, and embedding stays a matter of what is in
# the bundle rather than of how the binary was linked.
swift_flags+=(-Xlinker -dyld_env -Xlinker "DYLD_FRAMEWORK_PATH=@executable_path/../Frameworks")

swift build "${swift_flags[@]}"

"$ROOT/apple/scripts/bundle.sh" "$PROFILE"

if [[ -n "${ZER0_EMBED_WEBKIT-}" ]]; then
	if [[ "$ZER0_EMBED_WEBKIT" == "orion" ]]; then
		"$ROOT/apple/scripts/embed-webkit.sh" --orion
	else
		"$ROOT/apple/scripts/embed-webkit.sh" "$ZER0_EMBED_WEBKIT"
	fi
fi
