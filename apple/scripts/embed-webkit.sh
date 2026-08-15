#!/usr/bin/env bash
# Embeds a WebKit into Zer0.app so the browser carries its own engine instead of
# borrowing whichever one the machine happens to have.
#
#   ./apple/scripts/embed-webkit.sh ~/.cache/zer0/webkit/src/WebKitBuild/Release
#   ./apple/scripts/embed-webkit.sh --orion       # stand-in, for testing only
#   ./apple/scripts/embed-webkit.sh --check       # report what the app carries now
#
# The argument is the directory that CONTAINS WebKit.framework, not the
# framework itself. Its sibling frameworks (WebCore, JavaScriptCore, ...) are
# picked up from the same directory.
#
# --- How an embedded WebKit is found ---------------------------------------
#
# Apple's WebKit is built with its install name hard-wired to
# /System/Library/Frameworks/WebKit.framework/Versions/A/WebKit, and on macOS 26
# that path holds no Mach-O at all: dyld resolves it out of the shared cache.
# Neither install_name_tool nor an @rpath on the app can undo that on its own,
# because the same absolute path is baked into every WebKit-family binary and
# into the XPC services.
#
# What redirects it is DYLD_FRAMEWORK_PATH, which rewrites the leading
# directories of a framework load path. Setting it in the environment is a
# development trick (see run-with-webkit.sh) and does not survive `open`, the
# Dock, or launchd. Setting it as a Mach-O load command does: LC_DYLD_ENVIRONMENT
# travels inside the executable, so every process that starts from that binary
# gets it, no matter who started it.
#
#   Zer0                     DYLD_FRAMEWORK_PATH=@executable_path/../Frameworks
#   com.apple.WebKit.*.xpc   DYLD_FRAMEWORK_PATH=@executable_path/../../../../../../..
#                       or   DYLD_FRAMEWORK_PATH=@executable_path/../../..
#
# The app's copy is added at link time by scripts/build.sh. The XPC services'
# copies are put there by WebKit's own build system, and how many `../` it bakes
# in depends on where that build meant the service to end up:
#
#   installed inside the framework   seven, reaching Contents/Frameworks from
#                                    .../XPCServices/X.xpc/Contents/MacOS
#   left beside the framework        three, reaching whatever directory holds
#                                    the framework -- also Contents/Frameworks,
#                                    because a source build's WebKitBuild/Release
#                                    maps onto Contents/Frameworks one for one
#
# Both arrive in the same place, so this script resolves where each service
# really lives and checks the destination, rather than counting levels.
#
# That is what makes this structural rather than a wrapper script. The web
# content process is spawned by launchd and inherits nothing from the app, which
# is why an exported DYLD_FRAMEWORK_PATH reaches the UI process only and WebKit
# then aborts with "WebKit framework version mismatch". A load command has no
# such hole: the XPC binary carries its own.
#
# --- What this does not do -------------------------------------------------
#
# The bundle stays ad-hoc signed, without the hardened runtime. Under the
# hardened runtime dyld ignores LC_DYLD_ENVIRONMENT unless the binary also
# carries com.apple.security.cs.allow-dyld-environment-variables, so a notarised
# build needs that entitlement.
#
# There is no @rpath way out of this, and it is worth writing down why, because
# the setting is named as if there were. WK_RELOCATABLE_FRAMEWORKS is already
# YES in a source build -- Source/WebKit/Configurations/DebugRelease.xcconfig
# sets it -- and what it turns on is the -Wl,-dyld_env above, not @rpath install
# names. The install names in the build tree are still absolute:
#
#   $ otool -D WebKitBuild/Release/WebKit.framework/Versions/A/WebKit
#   /System/Library/Frameworks/WebKit.framework/Versions/A/WebKit
#
# because DYLIB_INSTALL_NAME_BASE stays $(NORMAL_WEBKIT_FRAMEWORKS_DIR) whatever
# WK_RELOCATABLE_FRAMEWORKS says. Getting @rpath would mean patching WebKit's
# own build configuration, not passing it a flag.
set -euo pipefail

APPLE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Two channels ship side by side (ADR-0109). ZER0_APP still wins outright so a
# caller can point at any `.app` for ad-hoc diagnosis; when it is unset the
# channel resolves the path through the same door every other script uses, so
# `ZER0_CHANNEL=canary ./apple/scripts/embed-webkit.sh --orion` finds the
# canary bundle without an extra flag.
if [[ -z "${ZER0_APP:-}" ]]; then
	# shellcheck source=resolve-bundle.sh
	. "$APPLE/scripts/resolve-bundle.sh"
	build_bundle_id_parametrized "${ZER0_CHANNEL:-stable}"
	APP="$APPLE/.build/${RB_APP_REL}"
else
	APP="$ZER0_APP"
fi

# The WebKit-family frameworks a browser needs at runtime. WebKit is the only
# one that must be there; the rest are copied when the source directory has
# them, because which of them exist depends on how WebKit was built.
REQUIRED_FRAMEWORKS=(WebKit)
OPTIONAL_FRAMEWORKS=(WebCore JavaScriptCore WebKitLegacy WebGPU WebInspectorUI)
OPTIONAL_DYLIBS=(libANGLE-shared.dylib libwebrtc.dylib)

# The three processes WebKit splits itself into. Without these inside the
# embedded framework, launchd falls back to the system services and the two
# halves of WebKit disagree about their version.
EXPECTED_XPC=(com.apple.WebKit.WebContent.xpc com.apple.WebKit.Networking.xpc com.apple.WebKit.GPU.xpc)

ORION="/Applications/Orion.app/Contents/Frameworks"

die() {
	echo "error: $*" >&2
	exit 1
}
note() { echo "==> $*"; }

# Absolute, symlink-free path. Comparing dyld search paths by string only works
# if both sides went through this.
canon() { (cd "$1" >/dev/null 2>&1 && pwd -P) || return 1; }

# Every DYLD_FRAMEWORK_PATH written into a binary's load commands. A universal
# binary repeats them once per architecture, hence the sort -u.
dyld_framework_path() {
	otool -l "$1" 2>/dev/null |
		awk '/LC_DYLD_ENVIRONMENT/ { want = 1; next } want && /name DYLD_FRAMEWORK_PATH=/ { print $2; want = 0 }' |
		sed 's/^DYLD_FRAMEWORK_PATH=//' | sort -u
}

# Collapses `..` segments textually. Safe here only because the caller feeds it
# a `pwd -P` prefix: with no symlinks left in the path, `a/b/..` really is `a`.
# It has to work on a directory that does not exist yet, which is why this is not
# just another canon call -- the check has to run before the copy, not after.
normalise() {
	local part out=()
	IFS=/ read -r -a parts <<<"$1"
	for part in "${parts[@]}"; do
		case "$part" in
		"" | .) ;;
		..) [[ ${#out[@]} -gt 0 ]] && unset 'out[${#out[@]}-1]' ;;
		*) out+=("$part") ;;
		esac
	done
	printf '/%s\n' "$(
		IFS=/
		echo "${out[*]}"
	)"
}

# Resolves an @executable_path-relative dyld path against a binary, so it can be
# compared with where the frameworks are meant to land.
resolve_executable_path() {
	local value="$1" bin_dir="$2"
	[[ "$value" == @executable_path/* ]] || {
		printf '%s\n' "$value"
		return
	}
	bin_dir="$(canon "$bin_dir")" || {
		printf '%s\n' "(unresolvable) $value"
		return
	}
	normalise "$bin_dir/${value#@executable_path/}"
}

# Fails unless the binary will look for frameworks in $2. Silence here is the
# expensive failure: without the load command the app runs the system WebKit and
# nothing says so.
require_dyld_path() {
	local bin="$1" want="$2" label="$3" found=0 value resolved
	while read -r value; do
		[[ -n "$value" ]] || continue
		resolved="$(resolve_executable_path "$value" "$(dirname "$bin")")"
		[[ "$resolved" == "$want" ]] && found=1
	done < <(dyld_framework_path "$bin")

	((found)) || die "$label does not carry a DYLD_FRAMEWORK_PATH pointing at
  $want

  binary: $bin
  found:  $(dyld_framework_path "$bin" | tr '\n' ' ')${_hint:-}"
}

mach_o() { /usr/bin/file -bL "$1" 2>/dev/null | grep -q "Mach-O"; }

# Signs one bundle ad-hoc, carrying over the entitlements it already had.
#
# Two things are deliberate. The hardened runtime is NOT carried over: it is what
# makes dyld ignore LC_DYLD_ENVIRONMENT, so preserving it would quietly undo the
# embedding. And entitlements are re-applied rather than dropped, because the web
# content process asks for JIT and loses it otherwise.
sign_bundle() {
	local target="$1" ents
	ents="$(mktemp -t zer0-ents)"
	if codesign -d --entitlements :- --xml "$target" 2>/dev/null | grep -q "<plist"; then
		codesign -d --entitlements :- --xml "$target" 2>/dev/null >"$ents"
		codesign --force --sign - --identifier "$(bundle_identifier "$target")" \
			--entitlements "$ents" "$target" 2>&1 | grep -v "replacing existing signature" || true
	else
		codesign --force --sign - "$target" 2>&1 | grep -v "replacing existing signature" || true
	fi
	rm -f "$ents"

	local out
	if ! out="$(codesign --verify --strict "$target" 2>&1)"; then
		# One failure is expected and is not a defect in the signature. A
		# framework from a source build keeps its XPC services beside itself
		# and links out to them, and codesign will not accept a link leaving
		# the bundle it is being asked to judge on its own -- even though the
		# destination is inside the app. The copy step above has already
		# refused any link that lands outside Contents/Frameworks, and the
		# app's own --deep --strict verification at the end is what settles it.
		grep -q "invalid destination for symbolic link in bundle" <<<"$out" ||
			die "signing $target produced a signature that does not verify

$out"
	fi
}

# codesign derives the signing identifier from CFBundleIdentifier, but only when
# it can read one. Keeping com.apple.WebKit.WebContent as the identifier is what
# lets launchd match the XPC service the UI process asks for.
bundle_identifier() {
	local plist="$1/Contents/Info.plist"
	[[ -f "$plist" ]] || plist="$1/Resources/Info.plist"
	/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$plist" 2>/dev/null ||
		basename "$1" | sed 's/\.[^.]*$//'
}

size_of() { du -sh "$1" | cut -f1; }

# --- report mode -----------------------------------------------------------

report() {
	local fw="$APP/Contents/Frameworks/WebKit.framework"
	echo "app:  $APP ($(size_of "$APP"))"
	if [[ ! -d "$fw" ]]; then
		echo "webkit: system (nothing embedded)"
		return 0
	fi
	local plist="$fw/Versions/A/Resources/Info.plist"
	echo "webkit: embedded, version $(/usr/bin/defaults read "$plist" CFBundleVersion 2>/dev/null || echo unknown)"
	echo "        $(du -sh "$APP/Contents/Frameworks" | cut -f1) in Contents/Frameworks"
	ls "$fw/Versions/A/XPCServices" 2>/dev/null | sed 's/^/        xpc: /'
	[[ -f "$APP/Contents/Resources/webkit-stand-in.txt" ]] &&
		echo "        STAND-IN: $(cat "$APP/Contents/Resources/webkit-stand-in.txt")"
	return 0
}

# --- arguments -------------------------------------------------------------

STAND_IN=""
SOURCE=""

case "${1-}" in
-h | --help)
	sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
	exit 0
	;;
--check)
	[[ -d "$APP" ]] || die "no app at $APP; run ./scripts/build.sh first"
	report
	exit 0
	;;
--orion)
	[[ -d "$ORION" ]] || die "Orion is not installed; its frameworks would be at $ORION"
	SOURCE="$ORION"
	STAND_IN="Orion.app ($(defaults read /Applications/Orion.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null || echo '?')) - third-party build, not redistributable"
	;;
"") die "usage: $0 <dir-containing-WebKit.framework> | --orion | --check" ;;
-*) die "unknown option: $1 (try --help)" ;;
*) SOURCE="${1%/}" ;;
esac

# --- preflight -------------------------------------------------------------
# Everything below is a failure that is cheap to hit now and expensive to
# diagnose later, when the symptom is "the new WebKit changed nothing".

[[ -d "$SOURCE" ]] || die "no such directory: $SOURCE"
SOURCE="$(canon "$SOURCE")"

[[ -d "$APP" ]] || die "no app at $APP; run ./scripts/build.sh first"
# CFBundleExecutable is what bundle.sh wrote into the plist; reading it back
# rather than hardcoding "Zer0" is what lets a canary build (whose executable
# is "Zer0 Canary") pass the same preflight as a stable one.
BIN="$APP/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist" 2>/dev/null || echo Zer0)"
[[ -x "$BIN" ]] || die "no executable at $BIN"

for name in "${REQUIRED_FRAMEWORKS[@]}"; do
	[[ -d "$SOURCE/$name.framework" ]] || die "no $name.framework in $SOURCE
Point this at the directory that CONTAINS the frameworks, not at one of them."
	fwbin="$SOURCE/$name.framework/Versions/A/$name"
	[[ -f "$fwbin" ]] || fwbin="$SOURCE/$name.framework/$name"
	mach_o "$fwbin" || die "$fwbin is not a loadable Mach-O binary.
The system WebKit is not embeddable: since macOS moved it into a cryptex,
/System/Library/Frameworks/WebKit.framework holds only resources and dyld
resolves the code from the shared cache. There is no file to copy."
done

# A WebKit without its XPC services is half an engine: launchd would spawn the
# system web content process against our framework and WebKit aborts on the
# version mismatch.
XPC_DIR="$SOURCE/WebKit.framework/Versions/A/XPCServices"
[[ -d "$XPC_DIR" ]] || die "$SOURCE/WebKit.framework has no XPCServices directory.
WebKit renders in com.apple.WebKit.WebContent, which launchd spawns from inside
the framework. A framework without them cannot be embedded."
for svc in "${EXPECTED_XPC[@]}"; do
	[[ -d "$XPC_DIR/$svc" ]] || die "$XPC_DIR is missing $svc"
done

# The app has to be looking for frameworks next to itself before there is any
# point in putting them there. scripts/build.sh links this in.
_hint="

scripts/build.sh adds it with -Wl,-dyld_env. Rebuild with:
  ./scripts/build.sh"
require_dyld_path "$BIN" "$(canon "$APP/Contents")/Frameworks" "the app executable"
unset _hint

# The hardened runtime makes dyld drop LC_DYLD_ENVIRONMENT unless the binary is
# entitled for it, which would leave the app silently on the system WebKit.
if codesign -d --verbose=2 "$APP" 2>&1 | grep -q "flags=.*runtime"; then
	codesign -d --entitlements :- "$APP" 2>/dev/null |
		grep -q "allow-dyld-environment-variables" || die \
		"$APP is signed with the hardened runtime but not entitled for
com.apple.security.cs.allow-dyld-environment-variables, so dyld would ignore the
embedded framework. Re-run apple/scripts/bundle.sh, which signs ad-hoc."
fi

BEFORE="$(size_of "$APP")"

# --- copy ------------------------------------------------------------------

FRAMEWORKS="$APP/Contents/Frameworks"
rm -rf "$FRAMEWORKS"
mkdir -p "$FRAMEWORKS"

copied=()
for name in "${REQUIRED_FRAMEWORKS[@]}" "${OPTIONAL_FRAMEWORKS[@]}"; do
	[[ -d "$SOURCE/$name.framework" ]] || continue
	ditto "$SOURCE/$name.framework" "$FRAMEWORKS/$name.framework"
	copied+=("$name.framework")
done
for name in "${OPTIONAL_DYLIBS[@]}"; do
	[[ -f "$SOURCE/$name" ]] || continue
	ditto "$SOURCE/$name" "$FRAMEWORKS/$name"
	copied+=("$name")
done

note "copied ${#copied[@]} items from $SOURCE"
printf '    %s\n' "${copied[@]}"

# A source build leaves a .tbd next to each framework binary: a text stub the
# linker reads instead of the real thing. Nothing loads one at runtime, and
# codesign treats it as a piece of unsigned code sitting inside the framework,
# so `codesign --verify --strict` on the framework fails with
#
#   code object is not signed at all
#   In subcomponent: .../JavaScriptCore.framework/Versions/A/JavaScriptCore.tbd
#
# Apple's shipped frameworks carry no .tbd, so this is a no-op against those.
stubs=$(/usr/bin/find "$FRAMEWORKS" -name '*.tbd' | wc -l | tr -d ' ')
if ((stubs)); then
	/usr/bin/find "$FRAMEWORKS" -name '*.tbd' -delete
	note "dropped $stubs .tbd link stubs (build-time only, and codesign rejects them)"
fi

# --- follow the symlinks that leave the framework ---------------------------
# A WebKit built from source does not keep its XPC services inside
# WebKit.framework. It leaves them in the build directory beside it and links
# out to them, and does the same for libWebKitSwift.dylib:
#
#   WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc
#     -> ../../../../com.apple.WebKit.WebContent.xpc
#   WebKit.framework/Versions/A/Frameworks/libWebKitSwift.dylib
#     -> ../../../../libWebKitSwift.dylib
#
# Copying the framework on its own therefore produces a framework whose every
# service is a broken link, and a browser that cannot start a web process.
# Apple's shipped framework has real directories in both places, so against
# that input this loop finds nothing and does nothing.
#
# The links do not have to be rewritten, only satisfied. Four levels up from
# XPCServices is whatever directory holds WebKit.framework, which here is
# Contents/Frameworks -- the same place the services' own
# DYLD_FRAMEWORK_PATH=@executable_path/../../.. lands. A source build's layout
# maps onto the bundle exactly, with Contents/Frameworks standing in for
# WebKitBuild/Release.

# Not every broken link is ours to fix. A framework can ship one that was
# already broken where it was built -- WebCore.framework/Frameworks is one --
# and copying that faithfully is correct. What must not survive is a link that
# worked in the source directory and stopped working in the bundle.
dangling() { /usr/bin/find "$1" -type l ! -exec test -e {} \; -print | sort; }

FRAMEWORKS_REAL="$(canon "$FRAMEWORKS")"
adopted=()
while IFS= read -r link; do
	rel="${link#"$FRAMEWORKS/"}"
	target="$(readlink "$link")"
	[[ "$target" == /* ]] && die "$link points at the absolute path
  $target
A framework that reaches outside itself by absolute path cannot be embedded."

	# The same relative walk on both sides. Both bases come from `pwd -P`, so
	# collapsing `..` textually is exact.
	dest="$(normalise "$(canon "$(dirname "$link")")/$target")"
	src="$(normalise "$(canon "$(dirname "$SOURCE/$rel")")/$target")"

	# Broken in the source too: not caused by the copy, so leave it alone.
	[[ -e "$src" ]] || continue

	[[ "$dest" == "$FRAMEWORKS_REAL"/* ]] || die "$link would reach outside the
bundle, at $dest. Refusing to copy anything there."

	ditto "$src" "$dest"
	adopted+=("${dest#"$FRAMEWORKS_REAL"/}")
done < <(dangling "$FRAMEWORKS")

if ((${#adopted[@]})); then
	note "brought ${#adopted[@]} link targets in from beside the framework"
	printf '    %s\n' "${adopted[@]}"
fi

# One link that the copy broke is one runtime failure with no message attached
# to it, so this compares against the source rather than demanding perfection.
while IFS= read -r link; do
	[[ -n "$link" ]] || continue
	[[ -e "$SOURCE/${link#"$FRAMEWORKS/"}" ]] && die "$link resolves in $SOURCE
but not in the bundle. The copy broke it."
done < <(dangling "$FRAMEWORKS")

# Quarantine travels with a copy and makes launchd refuse the XPC services.
xattr -rc "$FRAMEWORKS" 2>/dev/null || true

# --- verify the layout the XPC services assume ------------------------------
# WebKit's build bakes a fixed number of ../ into each service: seven for a
# service installed inside the framework, three for one left beside it. Either
# is fine as long as it arrives at Contents/Frameworks, so this resolves the
# service's real location rather than counting levels. If it does not match,
# the service starts and cannot find the framework.

EMBEDDED_XPC="$FRAMEWORKS/WebKit.framework/Versions/A/XPCServices"
for svc in "${EXPECTED_XPC[@]}"; do
	exe_name="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" \
		"$EMBEDDED_XPC/$svc/Contents/Info.plist" 2>/dev/null)" ||
		die "$svc has no CFBundleExecutable"
	exe="$EMBEDDED_XPC/$svc/Contents/MacOS/$exe_name"
	[[ -f "$exe" ]] || die "$svc declares $exe_name, which is not there"
	_hint="

WebKit's own build adds this with -Wl,-dyld_env. A WebKit built for a different
bundle layout cannot be embedded here without rebuilding it."
	require_dyld_path "$exe" "$(canon "$FRAMEWORKS")" "$svc"
	unset _hint
done
note "all ${#EXPECTED_XPC[@]} XPC services resolve to $FRAMEWORKS"

# --- sign, innermost first --------------------------------------------------
# Nested code must be signed before whatever contains it: signing a bundle seals
# the hashes of everything inside, so re-signing an inner bundle afterwards
# invalidates the outer seal.

# Both places a service can live: inside the framework, or beside it with the
# framework linking out to it. `! -L` keeps a service that is reachable through
# both from being signed twice.
for svc in "$FRAMEWORKS"/*.xpc "$EMBEDDED_XPC"/*.xpc; do
	[[ -d "$svc" && ! -L "$svc" ]] || continue
	sign_bundle "$svc"
done

for fw in "$FRAMEWORKS"/*.framework; do
	[[ -d "$fw" ]] || continue
	for nested in "$fw"/Versions/A/Frameworks/*.framework; do
		[[ -d "$nested" ]] && sign_bundle "$nested"
	done
	if [[ -d "$fw/Versions/A" ]]; then
		sign_bundle "$fw/Versions/A"
	else
		sign_bundle "$fw"
	fi
done

for lib in "$FRAMEWORKS"/*.dylib; do
	[[ -f "$lib" ]] || continue
	codesign --force --sign - "$lib" 2>&1 | grep -v "replacing existing signature" || true
done

# Contents/Resources, not Contents/Frameworks: codesign treats everything under
# Frameworks as nested code and refuses to seal a plain file there.
if [[ -n "$STAND_IN" ]]; then
	mkdir -p "$APP/Contents/Resources"
	printf '%s\n' "$STAND_IN" >"$APP/Contents/Resources/webkit-stand-in.txt"
else
	rm -f "$APP/Contents/Resources/webkit-stand-in.txt"
fi

# The app last, so its seal covers the frameworks as they now are.
codesign --force --sign - "$APP" 2>&1 | grep -v "replacing existing signature" || true
codesign --verify --deep --strict "$APP" ||
	die "the embedded bundle does not verify; refusing to call this done"

note "$APP: $BEFORE -> $(size_of "$APP")"
report

if [[ -n "$STAND_IN" ]]; then
	cat >&2 <<WARN

!! STAND-IN BUILD. The WebKit inside this app came from $ORION.
!! It is Kagi's build of WebKit, embedded here only to develop and test this
!! packaging while zer0's own WebKit build does not exist yet. Do not ship it,
!! do not publish it, do not hand this .app to anyone. Replace it with
!! scripts/webkit/build.sh output before any of that.
WARN
fi
