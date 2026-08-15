#!/usr/bin/env bash
# Builds the Rust core and regenerates the Swift bindings it exposes.
# Run this before `swift build`; the generated sources are not committed.
set -euo pipefail

PROFILE="${1:-debug}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APPLE="$ROOT/apple"

# Must match Package.swift's platform floor, or the linker warns that the Rust
# objects were built for a newer macOS than the Swift side targets.
export MACOSX_DEPLOYMENT_TARGET=15.4

# Cargo reads .cargo/config.toml from the working directory upwards, not from
# --manifest-path, so the workspace [env] in .cargo/config.toml has to be
# picked up from the repo root no matter where this script is invoked from.
cd "$ROOT"

cargo_flags=(--manifest-path "$ROOT/Cargo.toml" --features ffi)
[[ "$PROFILE" == "release" ]] && cargo_flags+=(--release)

echo "==> cargo build ($PROFILE)"
cargo build "${cargo_flags[@]}"

lib="$ROOT/target/$PROFILE/libzer0_core.a"
[[ -f "$lib" ]] || {
	echo "missing $lib" >&2
	exit 1
}

check_bundled_sqlite() {
	local lib="$1" member tmp minos arch
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
	arch="$(lipo -info "$tmp/sqlite3.o" | awk -F': ' '{print $NF}')"
	rm -rf "$tmp"
	# Empty means no LC_BUILD_VERSION at all — refuse that too rather than
	# let an unversioned object pass for a versioned promise.
	if [[ ! "$minos" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
		echo "error: bundled SQLite reports no macOS build version (got '${minos:-none}')" >&2
		return 1
	fi
	if [[ "$(printf '%s\n15.4\n' "$minos" | sort -V | tail -1)" != "15.4" ]]; then
		echo "error: bundled SQLite claims minimum macOS $minos, above the 15.4 floor" >&2
		echo "       MACOSX_DEPLOYMENT_TARGET decides it, and the stale object" >&2
		echo "       outlives a plain rebuild — cargo's fingerprints do not track the" >&2
		echo "       variable, and a cached rustc compilation replays the old bytes." >&2
		echo "       Run: cargo clean --release -p libsqlite3-sys -p rusqlite -p zer0-core" >&2
		echo "       and, if RUSTC_WRAPPER caches compilations, zero that cache too." >&2
		return 1
	fi
	if [[ "$arch" != "$(uname -m)" ]]; then
		echo "error: bundled SQLite is $arch, expected $(uname -m)" >&2
		return 1
	fi
}
check_bundled_sqlite "$lib"

staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT

echo "==> uniffi-bindgen"
cargo run -q --manifest-path "$ROOT/Cargo.toml" --features ffi --bin uniffi-bindgen -- \
	generate --library "$lib" --language swift --out-dir "$staging"

mkdir -p "$APPLE/Sources/Zer0CoreFFI/include" "$APPLE/Sources/Zer0Core"
mv "$staging/zer0_coreFFI.h" "$APPLE/Sources/Zer0CoreFFI/include/"
mv "$staging/zer0_core.swift" "$APPLE/Sources/Zer0Core/"

# SwiftPM requires the file to be named module.modulemap, and the header path
# is relative to the modulemap's own directory.
sed 's|header "zer0_coreFFI.h"|header "include/zer0_coreFFI.h"|' \
	"$staging/zer0_coreFFI.modulemap" >"$APPLE/Sources/Zer0CoreFFI/module.modulemap"

echo "==> bindings written to apple/Sources/"
