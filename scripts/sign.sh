#!/usr/bin/env bash
#
# Sign the built app with a Developer ID.
#
# Not part of `build.sh` and not run by `check.sh`. Signing needs a certificate
# in somebody's keychain, so a build that required one would be a build nobody
# else could run — and this project's definition of done has to stay something
# a stranger can reach.
#
#     ZER0_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/sign.sh
#     ZER0_SIGN_IDENTITY=... ZER0_CHANNEL=canary ./scripts/sign.sh
#
# Without ZER0_CHANNEL it signs every app under apple/.build/ — typically just
# the stable one, both when a canary was built on the same machine. An explicit
# channel narrows to that one; CI names one on every job.
#
# `security find-identity -v -p codesigning` lists what this Mac holds.
#
# Why this exists at all, in the order the reasons arrived:
#
#   - An ad-hoc signature has no Team Identifier and no authority, so nothing
#     can verify it. 1Password's browser enrolment refuses exactly that, in
#     those words: "signed in an unsupported way or may be missing a required
#     identifier". Measured on this bundle: `Signature=adhoc`,
#     `TeamIdentifier=not set`.
#   - Gatekeeper refuses an ad-hoc bundle on any Mac but the one that built it,
#     so this is what any release needs regardless of any extension.
#
# **Hardened runtime and an embedded WebKit fight each other, and the
# entitlement is the bridge.** `--options runtime` makes dyld drop every
# `DYLD_*` load command unless the binary carries
# `com.apple.security.cs.allow-dyld-environment-variables`, and that load
# command is what `apple/scripts/embed-webkit.sh` relies on to redirect
# WebKit loading at `Contents/Frameworks` (ADR-0005). The entitlement reopens
# the door; ADR-0109 records it as a real widening -- every `DYLD_*` variable
# for this process, not only ours, scoped to the process and not the kernel.
# The entitlements file is `apple/Resources/Zer0.entitlements`, applied here
# to the app and to every helper that does not already carry its own.
#
# (Earlier text here claimed the `-dyld_env` load command "survives hardening
# where the environment variable does not". It does not. `embed-webkit.sh`'s
# own preflight refuses a hardened-runtime bundle without the entitlement,
# because dyld ignores `LC_DYLD_ENVIRONMENT` under hardening without it. The
# entitlement is what makes the load command survive.)
#
# Two things still bite silently, and both are worth a check after signing:
#   - Replacing the load command with an exported variable defeats the
#     entitlement. The entitlement preserves `LC_DYLD_ENVIRONMENT`, not the
#     environment, so an `export DYLD_FRAMEWORK_PATH=...` goes back to being
#     dropped and the app runs the system WebKit while looking fine.
#   - The `WebKit.framework` XPC services come with their own entitlements
#     from the WebKit build (allow-jit, allow-unsigned-executable-memory,
#     network.client). Overwriting those with the app's file would drop one
#     WebKit needs or grant one it does not, so they are signed with
#     `--preserve-metadata=entitlements` below. Check which WebKit is loaded
#     after signing, do not assume.

set -euo pipefail

cd "$(dirname "$0")/.."

# Which apps get signed. An explicit ZER0_CHANNEL signs exactly that channel.
# Unset, it signs every app the build produced — usually just the stable one,
# both when a canary was built here too (ADR-0109). An empty build directory
# is an error, not a no-op: signing air is how a release ships unsigned.
# shellcheck source=../apple/scripts/resolve-bundle.sh
. "apple/scripts/resolve-bundle.sh"

APPS=()
if [ -n "${ZER0_CHANNEL:-}" ]; then
	build_bundle_id_parametrized "$ZER0_CHANNEL" ||
		{
			echo "error: ZER0_CHANNEL must be 'stable' or 'canary'" >&2
			exit 1
		}
	APPS+=("apple/.build/${RB_APP_REL}")
else
	for candidate in apple/.build/*.app; do
		[ -d "$candidate" ] || continue
		APPS+=("$candidate")
	done
fi

if [ "${#APPS[@]}" -eq 0 ]; then
	echo "error: no app to sign under apple/.build/. Run ./scripts/build.sh release" >&2
	echo "       first, or set ZER0_CHANNEL to name one." >&2
	exit 1
fi

if [ -z "${ZER0_SIGN_IDENTITY:-}" ]; then
	echo "error: set ZER0_SIGN_IDENTITY to a signing identity." >&2
	echo >&2
	echo "What this Mac holds:" >&2
	security find-identity -v -p codesigning 2>/dev/null | sed 's/^/    /' >&2
	echo >&2
	# The three kinds are easy to confuse and only one of them ships a browser.
	echo "Which is which:" >&2
	echo "    Developer ID Application  — the one to distribute with. Gatekeeper" >&2
	echo "                                accepts it on a stranger's Mac." >&2
	echo "    Apple Distribution        — App Store submission only." >&2
	echo "    Apple Development         — runs on registered devices. Carries a" >&2
	echo "                                real Team Identifier, so it is enough to" >&2
	echo "                                find out whether something that inspects" >&2
	echo "                                a signature will accept us at all." >&2
	exit 1
fi

# The entitlements the embedded WebKit needs (ADR-0005 + ADR-0109). Hardened
# runtime without this file silently unhooks the embedded framework -- dyld
# drops LC_DYLD_ENVIRONMENT and the app loads the system WebKit.
ENTITLEMENTS="apple/Resources/Zer0.entitlements"
if [ ! -f "$ENTITLEMENTS" ]; then
	echo "error: $ENTITLEMENTS missing. Without it the embedded WebKit goes silent." >&2
	exit 1
fi

for APP in "${APPS[@]}"; do
	if [ ! -d "$APP" ]; then
		echo "error: $APP is not there. Run ./scripts/build.sh release first." >&2
		exit 1
	fi

	# Inside out: a bundle is only as signed as the things inside it, and codesign
	# refuses a bundle whose nested code was signed after its container.
	find "$APP/Contents" -type f \( -name '*.dylib' -o -name '*.so' \) -print0 2>/dev/null |
		while IFS= read -r -d '' nested; do
			codesign --force --timestamp --options runtime \
				--entitlements "$ENTITLEMENTS" \
				--sign "$ZER0_SIGN_IDENTITY" "$nested"
		done

	# WebKit.framework's own XPC services come with their own entitlements from the
	# WebKit build (WebContent: allow-jit + allow-unsigned-executable-memory;
	# Network: network.client). `--preserve-metadata=entitlements` keeps those
	# rather than overwriting them with Zer0.entitlements, which would either drop
	# one WebKit needs or grant one it does not. These are inside the framework, so
	# they must be signed before the framework wrapper -- signing a bundle seals
	# the hashes of everything inside it.
	WEBKIT_XPC="$APP/Contents/Frameworks/WebKit.framework/Versions/A/XPCServices"
	if [ -d "$WEBKIT_XPC" ]; then
		for svc in "$WEBKIT_XPC"/*.xpc; do
			[ -e "$svc" ] || continue
			codesign --force --timestamp --options runtime \
				--preserve-metadata=entitlements \
				--sign "$ZER0_SIGN_IDENTITY" "$svc"
		done
	fi

	# Sparkle carries whole processes inside its framework (Updater.app, the
	# Installer/Downloader XPC services, the bare Autoupdate binary). They arrive
	# with entitlements Sparkle chose and they run as their own processes, so they
	# get the same treatment as the WebKit XPC services above: theirs preserved,
	# none of ours granted. They sit inside the framework, so they are signed
	# before its wrapper. Left ad-hoc inside a Developer-ID app, notarisation
	# fails on exactly these.
	SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
	if [ -d "$SPARKLE" ]; then
		find "$SPARKLE" -type d \( -name '*.xpc' -o -name '*.app' \) -print0 2>/dev/null |
			while IFS= read -r -d '' nested; do
				codesign --force --timestamp --options runtime \
					--preserve-metadata=entitlements \
					--sign "$ZER0_SIGN_IDENTITY" "$nested"
			done
		# Autoupdate is a bare executable at Versions/B (symlinked from Current and
		# the framework root) — not in Resources, and extensionless, so neither the
		# dylib find above nor any bundle glob reaches it.
		AUTOUPDATE="$SPARKLE/Versions/Current/Autoupdate"
		if [ -f "$AUTOUPDATE" ]; then
			codesign --force --timestamp --options runtime \
				--preserve-metadata=entitlements \
				--sign "$ZER0_SIGN_IDENTITY" "$AUTOUPDATE"
		fi
	fi

	for framework in "$APP/Contents/Frameworks/"*.framework; do
		[ -e "$framework" ] || continue
		codesign --force --timestamp --options runtime \
			--entitlements "$ENTITLEMENTS" \
			--sign "$ZER0_SIGN_IDENTITY" "$framework"
	done

	for helper in "$APP/Contents/XPCServices/"*.xpc "$APP/Contents/Helpers/"*; do
		[ -e "$helper" ] || continue
		codesign --force --timestamp --options runtime \
			--entitlements "$ENTITLEMENTS" \
			--sign "$ZER0_SIGN_IDENTITY" "$helper"
	done

	codesign --force --timestamp --options runtime \
		--entitlements "$ENTITLEMENTS" \
		--sign "$ZER0_SIGN_IDENTITY" "$APP"

	echo "==> signed"
	codesign -dv --verbose=4 "$APP" 2>&1 |
		grep -E "^(Identifier|TeamIdentifier|Authority|Signature|CodeDirectory)" |
		sed 's/^/    /'

	echo
	echo "==> gatekeeper"
	# `spctl` is the check a stranger's Mac actually performs. It refuses an
	# unnotarised build even when the signature is good, which is expected here and
	# is the difference between "signed" and "distributable". scripts/notarize.sh
	# is the door from this state to a distributable one.
	if spctl --assess --type execute --verbose "$APP" 2>&1 | sed 's/^/    /'; then
		echo "    accepted"
	else
		echo "    rejected — signed but not notarised. Run ./scripts/notarize.sh"
		echo "    to cross that door. This does not stop this Mac running it, and"
		echo "    it does not stop 1Password's enrolment reading the signature."
	fi

done
