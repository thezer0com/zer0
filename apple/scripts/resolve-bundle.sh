#!/usr/bin/env bash
# The one door for "which bundle id, app name and .app path does a channel get?"
# — and, since ADR-0111, for "what CFBundleVersion does a release carry?".
#
# Two channels ship side by side (ADR-0109): stable (`com.thezer0.browser`) and
# canary (`com.thezer0.canary`). Every script that wraps, signs or embeds into
# the `.app` reads the mapping from here, so the rule lives at one call site
# instead of N. A test in apple/Tests/Zer0ShellTests/BundleIdTests.swift runs
# this script end to end and asserts the ids; that lock is what keeps a typo in
# this file from producing a `.app` that runs as the wrong channel.
#
# Two ways in:
#
#   source apple/scripts/resolve-bundle.sh
#   build_bundle_id_parametrized stable        # sets globals, returns 0/1
#   build_bundle_id_parametrized canary
#
#   apple/scripts/resolve-bundle.sh stable     # prints KEY=VALUE lines, exits
#   apple/scripts/resolve-bundle.sh canary     #   (eval-friendly; Swift uses
#                                             #   this path in the test)
#
# Globals set by the function, and the same names printed when run directly:
#   RB_CHANNEL        stable | canary
#   RB_BUNDLE_ID      com.thezer0.browser | com.thezer0.canary
#   RB_APP_NAME       zer0 | zer0 Canary        (CFBundleName)
#   RB_EXEC_NAME      Zer0 | Zer0 Canary        (CFBundleExecutable)
#   RB_DISPLAY_NAME   zer0 | zer0 Canary        (CFBundleDisplayName)
#   RB_APP_REL        Zer0.app | Zer0 Canary.app (under apple/.build/)
#
# The `.app` directory name on disk follows CFBundleName on purpose. macOS does
# not require it, but Finder shows it, the menu bar reads CFBundleDisplayName,
# and keeping the two in sync is one less thing to misread when both bundles
# sit next to each other in /Applications.

# A function rather than top-level code: the lock in ADR-0109 names a function
# (`build_bundle_id_parametrized`), and a function is the only shape the gate's
# shell-lock resolver accepts. It also lets callers source this file once and
# resolve several channels without forking.
build_bundle_id_parametrized() {
	local channel="${1:-}"
	case "$channel" in
	stable)
		RB_CHANNEL="stable"
		RB_BUNDLE_ID="com.thezer0.browser"
		RB_APP_NAME="zer0"
		RB_EXEC_NAME="Zer0"
		RB_DISPLAY_NAME="zer0"
		RB_APP_REL="Zer0.app"
		;;
	canary)
		RB_CHANNEL="canary"
		RB_BUNDLE_ID="com.thezer0.canary"
		RB_APP_NAME="zer0 Canary"
		RB_EXEC_NAME="Zer0 Canary"
		RB_DISPLAY_NAME="zer0 Canary"
		RB_APP_REL="Zer0 Canary.app"
		;;
	*)
		echo "error: ZER0_CHANNEL must be 'stable' or 'canary', got '${channel:-<empty>}'" >&2
		return 1
		;;
	esac
	return 0
}

# The one door for "what CFBundleVersion does a release carry?" (ADR-0111).
#
# Sparkle ranks updates by sparkle:version, which is the bundle's
# CFBundleVersion — so that number has to be monotonic across releases, and
# the number the bundle carries has to be the number the appcast publishes.
# Both sides derive it from here, so they cannot disagree:
#
#   - the workflow's `compute version` step calls this function and passes the
#     result to the build as ZER0_BUNDLE_VERSION, which bundle.sh stamps into
#     CFBundleVersion;
#   - scripts/publish-appcast.sh calls this function on --version and refuses
#     an --bundle-version that disagrees, so the appcast's sparkle:version is
#     the same number by construction.
#
# Stable packs X.Y.Z into M*10000 + m*100 + p, so 0.2.10 (210) ranks above
# 0.2.9 (209) and 1.0.0 (10000) above both — the same packing every stable
# tag has used since the formula lived inline in the workflow. Minor and
# patch are assumed below 100; a project that ships 0.2.100 has outgrown this
# scheme and must reopen ADR-0111, not silently break ranking.
#
# Canary's human version already carries a UTC build timestamp
# (0.0.0-canary.YYYYMMDDHHMM-<sha>); the timestamp *is* the build number —
# 12 digits, monotonic by construction, and always far above any stable code,
# which keeps a hypothetical cross-channel comparison from going wrong too.
#
# Anything else is refused rather than repaired: a wrong build number is not
# a visible defect (the build works, the feed validates) — it silently breaks
# update ranking, which is the one thing this number exists to hold.
bundle_version_for_channel() {
	local channel="$1" version="$2"
	case "$channel" in
	stable)
		if [[ "$version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
			echo $((\
			10#${BASH_REMATCH[1]} * 10000 + \
			10#${BASH_REMATCH[2]} * 100 + \
			10#${BASH_REMATCH[3]}))
		else
			echo "error: stable version '${version}' is not X.Y.Z;" >&2
			echo "       refusing to derive a build number (ADR-0111)." >&2
			return 1
		fi
		;;
	canary)
		if [[ "$version" =~ ^0\.0\.0-canary\.([0-9]{12})-[0-9a-f]+$ ]]; then
			echo "${BASH_REMATCH[1]}"
		else
			echo "error: canary version '${version}' is not 0.0.0-canary.<12-digit-ts>-<sha>;" >&2
			echo "       refusing to derive a build number (ADR-0111)." >&2
			return 1
		fi
		;;
	*)
		echo "error: channel must be 'stable' or 'canary', got '${channel:-<empty>}'" >&2
		return 1
		;;
	esac
	return 0
}

# Run directly: print the same globals the function sets, in eval-friendly
# form. The Swift test reads this output; keeping it identical to the in-process
# shape means a caller can swap `source` for `eval "$(...)"` with no surprises.
if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
	set -euo pipefail
	channel="${1:-${ZER0_CHANNEL:-stable}}"
	build_bundle_id_parametrized "$channel" || exit 1
	cat <<VARS
CHANNEL=$RB_CHANNEL
BUNDLE_ID=$RB_BUNDLE_ID
APP_NAME=$RB_APP_NAME
EXEC_NAME=$RB_EXEC_NAME
DISPLAY_NAME=$RB_DISPLAY_NAME
APP_REL=$RB_APP_REL
VARS
fi
