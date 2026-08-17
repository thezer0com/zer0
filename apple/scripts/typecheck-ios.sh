#!/usr/bin/env bash
# Typechecks the shared shell set against the iOS SDK, without a simulator and
# without Xcode: emit the Zer0Core module for the iOS target once, then run
# swiftc -typecheck over the files both hosts compile.
#
# The list below is the anti-drift. A file that joins the shared set joins this
# list in the same commit or this gate goes red the moment it compiles iOS
# wrong — and a file added to Zer0Shell but absent here is the quieter failure
# this script exists to catch: it typechecks nowhere on iOS while reading as
# shared. The xcodebuild in CI and check.sh both run after this, so the set and
# the app are each held by the check that can see them.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SHELL_DIR="$ROOT/apple/Sources/Zer0Shell"
FFI_DIR="$ROOT/apple/Sources/Zer0CoreFFI"
BINDINGS="$ROOT/apple/Sources/Zer0Core/zer0_core.swift"
FLOOR=18.4

# The set both hosts compile, one basename per line. Alphabetical, because a
# list a reviewer scans for a name is a list that has to be scannable.
SHARED=(
	AuthChallengeHost
	BrowserModel
	BrowserTabFields
	ChatConfiguration
	ChatHost
	ChatProse
	ChatProviderHost
	ConfigHost
	ConfiguredChatHost
	ConfigVocabulary
	ContentBlocking
	DesignSystem
	DownloadHost
	EngineHost
	EnginePolicy
	ExtensionApiHost
	ExtensionHost
	ExtensionPopupDialogs
	ExternalScheme
	LucideIcon
	McpHost
	McpHttpLink
	NativeMessagingHost
	PageActions
	PageDialogHost
	PageMenu
	PageProcessHost
	Palette
	PaletteProposals
	PasswordHost
	PasswordStore
	PendingPrompts
	PopupHost
	SecretStore
	SessionLifecycle
	SettingsSection
	Shortcuts
	SiteBadge
	SiteIcons
	SitePermissionHost
	SplitFields
	StoreInstall
	WebInspector
	WindowRole
	Zer0Mark
)

typecheck_shared_shell() {
	local missing=()
	local name
	for name in "${SHARED[@]}"; do
		[[ -f "$SHELL_DIR/$name.swift" ]] || missing+=("$name")
	done
	if ((${#missing[@]})); then
		echo "error: the shared set names files Zer0Shell does not have:" >&2
		printf '       %s\n' "${missing[@]}" >&2
		echo "       A file was renamed or removed and this list stayed behind." >&2
		return 1
	fi

	local sdk target
	sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
	target="arm64-apple-ios${FLOOR}-simulator"

	local staging
	staging="$(mktemp -d)"
	trap 'rm -rf "$staging"' RETURN

	# Phase one: the Zer0Core module, emitted for the iOS target. Without it,
	# `import Zer0Core` inside the shell files would typecheck against nothing.
	# Not regenerated here — this script consumes the bindings build-core.sh
	# writes, for the dlopen reason ADR-0121 records.
	xcrun swiftc -emit-module -module-name Zer0Core \
		-swift-version 6 -target "$target" -sdk "$sdk" \
		-I "$FFI_DIR" \
		-emit-module-path "$staging/Zer0Core.swiftmodule" \
		"$BINDINGS" >/dev/null

	# Phase two: the set itself. Swift 6 and warnings-as-errors, matching what
	# the macOS package demands of Zer0Shell — a file that is shared but only
	# clean under looser flags on one platform is not shared, it is drifting.
	local files=()
	for name in "${SHARED[@]}"; do
		files+=("$SHELL_DIR/$name.swift")
	done
	xcrun swiftc -typecheck \
		-swift-version 6 -warnings-as-errors \
		-target "$target" -sdk "$sdk" \
		-I "$FFI_DIR" -I "$staging" \
		"${files[@]}"
}

# The bindings are an input, not a product: refuse before compiling rather
# than fail inside swiftc with an error about a file that names the real fix.
[[ -f "$BINDINGS" ]] || {
	echo "error: $BINDINGS is missing." >&2
	echo "       Run ./apple/scripts/build-core.sh first: it writes the Swift" >&2
	echo "       bindings both hosts typecheck against (ADR-0121)." >&2
	exit 1
}

echo "==> typecheck shared shell (iOS $FLOOR, ${#SHARED[@]} files)"
typecheck_shared_shell
echo "==> shared shell typechecks against the iOS SDK"
