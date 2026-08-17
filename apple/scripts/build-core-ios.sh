#!/usr/bin/env bash
# Builds the Rust core for iOS (device + simulator) and wraps the two static
# archives in the xcframework the iOS app links. Run build-core.sh first: it
# emits the Swift bindings and the C header both hosts share.
set -euo pipefail

# The floor the iOS app promises. IPHONEOS_DEPLOYMENT_TARGET rather than the
# workspace-wide MACOSX_DEPLOYMENT_TARGET in .cargo/config.toml, which says
# nothing about an iOS SDK build: the `cc` crate compiles bundled sqlite3.c
# for whichever deployment target the environment names, and with this unset
# it would record the installed SDK's own version instead (ADR-0114, the same
# bug one SDK over).
export IPHONEOS_DEPLOYMENT_TARGET=18.4

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IOS="$ROOT/apple/ios"
FLOOR=18.4

TARGETS=(aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios)

# Missing targets are added rather than refused: `rustup target add` is
# idempotent, and the alternative — a refusal telling the reader to run the
# same command by hand — is a slower copy of the same outcome.
missing=()
for target in "${TARGETS[@]}"; do
	rustup target list --installed | grep -qx "$target" || missing+=("$target")
done
if ((${#missing[@]})); then
	echo "==> rustup target add ${missing[*]}"
	rustup target add "${missing[@]}"
fi

# The xcframework carries only objects. The C module the Swift side imports is
# apple/Sources/Zer0CoreFFI (modulemap + header), the same files the macOS
# package compiles — shipping a second copy of the header inside the framework
# would be a copy nothing reads.
#
# The bindings are NOT regenerated here on purpose. `uniffi-bindgen generate
# --library` dlopens the library it reads on the *host*, and an iOS archive
# cannot be loaded by a macOS process. The Swift bindings are
# platform-agnostic, so the ones every build-core.sh run writes are the ones
# this host uses too — which is why this script refuses to run before it.
HEADER="$ROOT/apple/Sources/Zer0CoreFFI/include/zer0_coreFFI.h"
BINDINGS="$ROOT/apple/Sources/Zer0Core/zer0_core.swift"
for required in "$HEADER" "$BINDINGS"; do
	[[ -f "$required" ]] || {
		echo "error: $required is missing." >&2
		echo "       Run ./apple/scripts/build-core.sh first: it writes the bindings" >&2
		echo "       both hosts share, and this script only builds the archives." >&2
		exit 1
	}
done

# Cargo reads .cargo/config.toml from the working directory upwards, not from
# --manifest-path (same reason as build-core.sh).
cd "$ROOT"

echo "==> cargo build (release, ios + ios-sim)"
# -p zer0-core --lib: the workspace also carries the uniffi-bindgen *binary*,
# and building it for an iOS target links an iOS executable nothing ever runs.
# Two simulator targets because Xcode links a generic simulator build for both
# architectures, and an arm64-only slice is a thousand linker warnings deep.
cargo build --manifest-path "$ROOT/Cargo.toml" -p zer0-core --lib \
	--release --features ffi \
	--target aarch64-apple-ios --target aarch64-apple-ios-sim \
	--target x86_64-apple-ios

check_bundled_sqlite_ios() {
	local lib="$1" want_platform="$2" member tmp minos platform
	# The C object compiled by the `cc` crate; Rust codegen units end in
	# `.rcgu.o` and never match.
	member="$(ar t "$lib" | grep -E 'sqlite3\.o$' | head -1 || true)"
	if [[ -z "$member" ]]; then
		echo "error: no bundled SQLite object in $lib" >&2
		return 1
	fi
	tmp="$(mktemp -d)"
	ar p "$lib" "$member" >"$tmp/sqlite3.o"
	minos="$(vtool -show-build "$tmp/sqlite3.o" | awk '/minos/{print $2}')"
	platform="$(vtool -show-build "$tmp/sqlite3.o" | awk '/platform/{print $2}')"
	rm -rf "$tmp"
	# ADR-0114, re-read for the cross-compile its revisit clause named: the
	# identity check is the *platform* the object claims, not the build host's
	# architecture — a host check would pass a macOS object off as an iOS one.
	if [[ "$platform" != "$want_platform" ]]; then
		echo "error: bundled SQLite in $(basename "$(dirname "$lib")") claims platform" >&2
		echo "       '${platform:-none}', expected $want_platform." >&2
		return 1
	fi
	# Empty means no LC_BUILD_VERSION at all — refused rather than let an
	# unversioned object stand in for a versioned promise.
	if [[ ! "$minos" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
		echo "error: bundled SQLite in $(basename "$(dirname "$lib")") reports no" >&2
		echo "       build version (got '${minos:-none}')." >&2
		return 1
	fi
	if [[ "$(printf '%s\n%s\n' "$minos" "$FLOOR" | sort -V | tail -1)" != "$FLOOR" ]]; then
		echo "error: bundled SQLite claims minimum iOS $minos, above the $FLOOR floor." >&2
		echo "       IPHONEOS_DEPLOYMENT_TARGET decides it, and the stale object" >&2
		echo "       outlives a plain rebuild — cargo's fingerprints do not track the" >&2
		echo "       variable, and a cached rustc compilation replays the old bytes." >&2
		echo "       Run: cargo clean --release -p libsqlite3-sys -p rusqlite -p zer0-core" >&2
		return 1
	fi
}

check_bundled_sqlite_ios \
	"$ROOT/target/aarch64-apple-ios/release/libzer0_core.a" IOS
check_bundled_sqlite_ios \
	"$ROOT/target/aarch64-apple-ios-sim/release/libzer0_core.a" IOSSIMULATOR
check_bundled_sqlite_ios \
	"$ROOT/target/x86_64-apple-ios/release/libzer0_core.a" IOSSIMULATOR

# One universal simulator library out of the two simulator slices, so the
# xcframework matches what Apple ships and Xcode never has to warn its way
# past a missing architecture.
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
lipo -create \
	"$ROOT/target/aarch64-apple-ios-sim/release/libzer0_core.a" \
	"$ROOT/target/x86_64-apple-ios/release/libzer0_core.a" \
	-output "$staging/libzer0_core.a"

echo "==> xcframework"
rm -rf "$IOS/Zer0Core.xcframework"
xcodebuild -create-xcframework \
	-library "$ROOT/target/aarch64-apple-ios/release/libzer0_core.a" \
	-library "$staging/libzer0_core.a" \
	-output "$IOS/Zer0Core.xcframework" >/dev/null

[[ -d "$IOS/Zer0Core.xcframework" ]] || {
	echo "error: $IOS/Zer0Core.xcframework was not created" >&2
	exit 1
}

echo "==> $IOS/Zer0Core.xcframework"
