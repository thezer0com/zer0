#!/usr/bin/env bash
# Wraps the SwiftPM executable in a .app bundle. AppKit needs a real bundle for
# menus, activation and window restoration to behave.
#
# Two channels ship side by side (ADR-0109): stable and canary. Which one this
# build becomes is decided by `ZER0_CHANNEL` (default `stable`), and the bundle
# id, app name and `.app` path all come from `apple/scripts/resolve-bundle.sh`.
# That file is the one door for the mapping; this script is the one door for
# turning a built binary into a `.app` that carries it.
set -euo pipefail

PROFILE="${1:-debug}"
APPLE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$APPLE/.build/$PROFILE"

# shellcheck source=resolve-bundle.sh
. "$APPLE/scripts/resolve-bundle.sh"

# `build_bundle_id_parametrized` is the lock ADR-0109 names. Calling it here is
# what makes that lock honest: every bundle this script produces has been
# resolved through one function, and the Swift test that runs the same function
# via resolve-bundle.sh defends the id end to end.
build_bundle_id_parametrized "${ZER0_CHANNEL:-stable}"
APP="$APPLE/.build/${RB_APP_REL}"

# Sparkle feed per channel. ADR-0109: "stable users read appcast-stable.xml;
# canary users read appcast-canary.xml." The URL is derived from the same
# channel decision that produced the bundle id above, so a stable build cannot
# accidentally ship pointed at the canary feed. UpdateHost reads this same
# channel and answers Sparkle's delegate with the matching appcast; the value
# here is the default a build opens with, and the only feed it ever reads
# (ADR-0110 closed the peek that used to override it).
SU_FEED_URL="https://download.thezer0.app/appcast-${RB_CHANNEL}.xml"
# EdDSA public key Sparkle verifies the appcast against. Empty until a real key
# exists; the workflow that signs releases (see docs/sparkle-setup.md) is what
# writes the real value into a built bundle. Shipped empty, Sparkle refuses to
# install anything — which is the correct posture for a build with no signing
# story yet, and a better one than a placeholder a stranger could impersonate.
SUPUBLIC_ED_KEY="${ZER0_SPARKLE_PUBLIC_KEY:-}"

# Versioning (ADR-0111). CFBundleVersion is the number Sparkle ranks updates
# by, so CI passes it as ZER0_BUNDLE_VERSION — derived through the same door
# publish-appcast.sh verifies against (`bundle_version_for_channel` in
# resolve-bundle.sh), which makes the plist's number and the appcast's
# sparkle:version the same number by construction. ZER0_SHORT_VERSION is the
# human string the same CI step computed (the tag for stable,
# 0.0.0-canary.<ts>-<sha> for canary).
#
# Without the env, the defaults are the honest local-build ones: 0.1.0 / 1.
# Build 1 is deliberately frozen — a local build is not a release, and a dev
# machine's Sparkle should keep offering the real canary/stable updates over
# it rather than be silenced by a number that only looks newer.
if [[ -n "${ZER0_BUNDLE_VERSION:-}" ]]; then
	if [[ ! "$ZER0_BUNDLE_VERSION" =~ ^[0-9]+$ ]]; then
		echo "error: ZER0_BUNDLE_VERSION must be an integer (got '${ZER0_BUNDLE_VERSION}');" >&2
		echo "       it is the number Sparkle ranks by — see ADR-0111." >&2
		exit 1
	fi
	BUNDLE_VERSION="$ZER0_BUNDLE_VERSION"
else
	BUNDLE_VERSION="1"
	echo "warning: ZER0_BUNDLE_VERSION not set; CFBundleVersion defaults to 1." >&2
	echo "         that is the local-build default: not distributable, and Sparkle" >&2
	echo "         will keep ranking published updates above it (ADR-0111)." >&2
fi
SHORT_VERSION="${ZER0_SHORT_VERSION:-0.1.0}"

[[ "$PROFILE" == "debug" || "$PROFILE" == "release" ]] || {
	echo "usage: $0 [debug|release]" >&2
	exit 1
}

[[ -x "$BUILD/Zer0" ]] || {
	echo "no $PROFILE binary; run scripts/build.sh $PROFILE" >&2
	exit 1
}

# SwiftPM emits one executable target named `Zer0` regardless of channel; the
# channel's own executable name (`Zer0` vs `Zer0 Canary`) is applied here, at
# the copy into the bundle. CFBundleExecutable below matches RB_EXEC_NAME so
# macOS finds what the plist points at.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/Zer0" "$APP/Contents/MacOS/$RB_EXEC_NAME"

# Sparkle ships as a SwiftPM binary target, and SwiftPM — unlike Xcode — does
# not copy binary-target frameworks into a produced .app. `swift test` does not
# catch the omission because it runs against the build tree, where the
# executable and Sparkle.framework sit next to each other and @loader_path
# resolves. The bundle moves the executable into Contents/MacOS/ and leaves
# the framework behind, so dyld aborts at launch with
# "Library missing: @rpath/Sparkle.framework/Versions/B/Sparkle". Refuse rather
# than ship a bundle that crashes (the project rule): if the framework is not
# in the build tree the build was incomplete and this script should not paper
# over it.
SPARKLE_SRC="$BUILD/Sparkle.framework"
if [[ ! -d "$SPARKLE_SRC" ]]; then
	echo "error: Sparkle.framework missing at $SPARKLE_SRC." >&2
	echo "       the app would crash at launch (Library missing); run swift build first." >&2
	exit 1
fi
mkdir -p "$APP/Contents/Frameworks"
cp -R "$SPARKLE_SRC" "$APP/Contents/Frameworks/Sparkle.framework"

# SwiftPM emits @loader_path and nothing else (see `otool -l` on the binary).
# In the bundle @loader_path resolves to Contents/MacOS/, but the framework
# lives in Contents/Frameworks/, so without this second rpath dyld cannot
# find it. Added before re-signing so the signature covers the modified
# load commands; guarded because install_name_tool errors if the rpath
# already exists, and a future SwiftPM that emits it should not break us.
if ! otool -l "$APP/Contents/MacOS/$RB_EXEC_NAME" | grep -A2 LC_RPATH |
	grep -q '^ *path @executable_path/../Frameworks'; then
	install_name_tool -add_rpath '@executable_path/../Frameworks' \
		"$APP/Contents/MacOS/$RB_EXEC_NAME"
fi

# Sign inside-out: the framework before the outer app below. Sparkle.framework
# carries nested bundles (Updater.app, Downloader.xpc, Installer.xpc, the
# Autoupdate binary) behind Versions/Current/ symlinks, so --deep is needed
# to re-sign every leaf. Without it the outer codesign below only re-seals
# the top, and a future Sparkle build that ships unsigned leaves would fail
# at launch inside the XPC service rather than at the app's main dyld load.
codesign --force --deep --sign - "$APP/Contents/Frameworks/Sparkle.framework" >/dev/null 2>&1

# The plist is written with the channel's vars rather than from a template, so
# the bundle id and the names cannot drift apart: they all come from the same
# `build_bundle_id_parametrized` call above. The usage descriptions name "zer0"
# verbatim because that is the product, not the channel — a canary user is
# still using zer0, and the consent sentence should not pretend otherwise.
cat >"$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${RB_APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${RB_DISPLAY_NAME}</string>
    <key>CFBundleExecutable</key><string>${RB_EXEC_NAME}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>${RB_BUNDLE_ID}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${SHORT_VERSION}</string>
    <key>CFBundleVersion</key><string>${BUNDLE_VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>15.4</string>
    <!-- Without these two keys, macOS terminates the process the instant a page
         starts capturing. Not a refusal, not an error the page can catch: the
         app disappears. So granting a camera before ADR-0056 added them would
         have crashed the browser rather than turned one on.

         The sentence is what TCC puts in its own dialog, which is a second
         dialog after ours and outside our control. It is written the same way
         the consent sheet is — the consequence, in the second person — so the
         two do not read as two different products asking the same question
         twice. -->
    <key>NSCameraUsageDescription</key>
    <string>A site you are on asked to see through your camera. zer0 asks you before any site is allowed to, and you can take it back in Settings › Privacy.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>A site you are on asked to hear through your microphone. zer0 asks you before any site is allowed to, and you can take it back in Settings › Privacy.</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <!-- Sparkle (ADR-0109). SUFeedURL names the appcast this build checks;
         UpdateHost's delegate returns the same channel's URL on every check,
         so the plist default and the runtime answer agree (ADR-0110 closed
         the peek that used to override this at runtime).
         SUPublicEDKey verifies the appcast signature; empty
         means Sparkle will refuse every update, which is the correct posture
         for a build with no signing story yet. The workflow that signs
         releases substitutes a real key here. -->
    <key>SUFeedURL</key><string>${SU_FEED_URL}</string>
    <key>SUPublicEDKey</key><string>${SUPUBLIC_ED_KEY}</string>
</dict>
</plist>
PLIST

# The icon is drawn ahead of time by apple/scripts/make-icon.sh and committed,
# so a build needs no SVG rasteriser. Missing is a warning and not a failure:
# without it the app runs, wearing the generic icon.
ICON="$APPLE/Resources/AppIcon.icns"
if [[ -f "$ICON" ]]; then
	cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
else
	echo "warning: no $ICON; the app will use the generic icon." >&2
	echo "         run apple/scripts/make-icon.sh to draw it." >&2
fi

# Ad-hoc signature runs on this machine only. Shipping to anyone else needs a
# Developer ID certificate and notarisation.
codesign --force --sign - "$APP" >/dev/null 2>&1

echo "==> $APP ($PROFILE, $RB_CHANNEL, $(du -sh "$APP" | cut -f1))"
