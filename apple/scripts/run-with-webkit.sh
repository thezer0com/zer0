#!/usr/bin/env bash
# Runs the built app against a WebKit other than the one in /System.
#
#   ./apple/scripts/run-with-webkit.sh                 # Safari Technology Preview
#   ./apple/scripts/run-with-webkit.sh --system        # system WebKit, for comparison
#   ./apple/scripts/run-with-webkit.sh /path/to/dir    # any directory holding WebKit.framework
#   ./apple/scripts/run-with-webkit.sh ~/WebKit/WebKitBuild/Release
#
# Anything after the path is passed to the app. ZER0_OPEN_URL still works.
#
# How it works: dyld rewrites the leading directory of a framework's install
# name when DYLD_FRAMEWORK_PATH is set, so a binary linked against
# /System/Library/Frameworks/WebKit.framework/Versions/A/WebKit loads
# $DYLD_FRAMEWORK_PATH/WebKit.framework/Versions/A/WebKit instead. If that file
# is missing or not a valid Mach-O, dyld silently falls back to the system
# copy, which is why this script verifies the framework before launching.
#
# The __XPC_ prefixed copies matter more than they look. WKWebView does its
# rendering in com.apple.WebKit.WebContent, which launchd spawns rather than
# the app forking it, so it inherits nothing from this environment. libxpc
# forwards variables named __XPC_FOO to the child as FOO. Without them the UI
# process runs the new WebKit while the web process runs the system one, and
# WebKit deliberately crashes on that mismatch with "WebKit framework version
# mismatch: X != Y".
#
# This needs no entitlement and no SIP change. What strips DYLD_* is the
# hardened runtime, and bundle.sh signs ad-hoc without it.
set -euo pipefail

APPLE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Same channel door the rest of the scripts use (ADR-0109). ZER0_APP wins
# outright so an ad-hoc path still works; otherwise `ZER0_CHANNEL=canary` here
# launches the canary bundle.
if [[ -z "${ZER0_APP:-}" ]]; then
	# shellcheck source=resolve-bundle.sh
	. "$APPLE/scripts/resolve-bundle.sh"
	build_bundle_id_parametrized "${ZER0_CHANNEL:-stable}"
	APP="$APPLE/.build/${RB_APP_REL}"
else
	APP="$ZER0_APP"
fi
# Read CFBundleExecutable back rather than hardcoding "Zer0"; canary's
# executable is "Zer0 Canary".
BIN="$APP/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist" 2>/dev/null || echo Zer0)"

STP="/Applications/Safari Technology Preview.app/Contents/Frameworks"
SYSTEM="/System/Library/Frameworks"

# Reads CFBundleShortVersionString out of a WebKit.framework, so the launch
# banner shows what you actually got rather than what you asked for.
webkit_version() {
	local plist="$1/WebKit.framework/Versions/A/Resources/Info.plist"
	[[ -f "$plist" ]] || plist="$1/WebKit.framework/Resources/Info.plist"
	[[ -f "$plist" ]] || {
		echo "unknown"
		return
	}
	/usr/bin/defaults read "$plist" CFBundleVersion 2>/dev/null || echo "unknown"
}

die() {
	echo "error: $*" >&2
	exit 1
}

[[ -x "$BIN" ]] || die "no app at $APP; run ./scripts/build.sh first"

OVERRIDE=1

case "${1-}" in
-h | --help)
	sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
	exit 0
	;;
--system)
	FRAMEWORKS="$SYSTEM"
	LABEL="system"
	OVERRIDE=0
	shift
	;;
"")
	[[ -d "$STP" ]] || die "Safari Technology Preview is not installed.
Its WebKit would be at:
  $STP
Install it from https://developer.apple.com/safari/technology-preview/
or point this script at another build:
  $0 ~/WebKit/WebKitBuild/Release"
	FRAMEWORKS="$STP"
	LABEL="Safari Technology Preview"
	;;
*)
	FRAMEWORKS="${1%/}"
	LABEL="$FRAMEWORKS"
	shift
	[[ -d "$FRAMEWORKS" ]] || die "no such directory: $FRAMEWORKS"
	;;
esac

[[ -d "$FRAMEWORKS/WebKit.framework" ]] || die \
	"no WebKit.framework in $FRAMEWORKS
Point this at the directory that CONTAINS WebKit.framework, not at the
framework itself."

# Only an override needs an on-disk binary. The system WebKit has none: since
# macOS moved it into a cryptex, /System/Library/Frameworks/WebKit.framework
# holds only Resources and XPCServices, and dyld resolves the code out of the
# shared cache. Checking for a Mach-O there would reject the one path that
# always works.
if ((OVERRIDE)); then
	# A framework that exists but is not loadable is worse than one that is
	# missing: dyld falls back to /System without a word and you spend an hour
	# wondering why the new feature is absent.
	WEBKIT_BIN="$FRAMEWORKS/WebKit.framework/Versions/A/WebKit"
	[[ -f "$WEBKIT_BIN" ]] || WEBKIT_BIN="$FRAMEWORKS/WebKit.framework/WebKit"
	/usr/bin/file -bL "$WEBKIT_BIN" 2>/dev/null | grep -q "Mach-O" || die \
		"$WEBKIT_BIN is not a loadable Mach-O binary; dyld would ignore it and
silently use the system WebKit instead."
fi

# The hardened runtime makes dyld drop every DYLD_* variable, so the override
# would be a no-op. Ad-hoc signing alone does not do this.
if codesign -d --verbose=2 "$APP" 2>&1 | grep -q "flags=.*runtime"; then
	die "$APP is signed with the hardened runtime, which strips DYLD_*.
Re-run apple/scripts/bundle.sh, which signs ad-hoc without it."
fi

echo "==> WebKit: $LABEL"
echo "    path:    $FRAMEWORKS"
echo "    version: $(webkit_version "$FRAMEWORKS") (system is $(webkit_version "$SYSTEM"))"

if ((OVERRIDE)); then
	export DYLD_FRAMEWORK_PATH="$FRAMEWORKS${DYLD_FRAMEWORK_PATH:+:$DYLD_FRAMEWORK_PATH}"
	export DYLD_LIBRARY_PATH="$FRAMEWORKS${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
	export __XPC_DYLD_FRAMEWORK_PATH="$FRAMEWORKS"
	export __XPC_DYLD_LIBRARY_PATH="$FRAMEWORKS"
else
	echo "    note:    no override; this is what ./scripts/build.sh already gives you"
fi

# Executing the binary rather than `open` keeps the environment intact:
# LaunchServices starts the app from launchd and drops the caller's variables.
exec "$BIN" "$@"
