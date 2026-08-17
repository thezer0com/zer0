#!/usr/bin/env bash
# Produces the LGPL 6(a) source offer for the channel's pinned WebKit
# revision (docs/licensing.md section 6): webkit-source-<pin>.tar.zst plus
# SHA256SUMS. The pin is the tag stable embeds or the sha canary embeds
# (ADR-0124), selected by ZER0_CHANNEL.
#
#   ./scripts/source-offer.sh
#   ./scripts/source-offer.sh --dry-run
#   ./scripts/source-offer.sh --out dist-source --release v0.2.0
#
# The tarball is `git archive` of the pinned revision, never a plain `tar` of
# the checkout directory: the developer checkout also holds WebKitBuild/ (tens
# of GB of build products) and .git, and neither of those is source. Archiving
# the pinned commit is also deterministic -- same pin, same bytes -- which is
# what lets the release workflows cache the tarball keyed on the pin.
#
# Prefers the fetch.sh checkout (~/.cache/zer0/webkit/src); falls back to a
# shallow clone when no checkout exists. A checkout at the wrong tag is
# refused rather than worked around: version.txt and the disk have to agree
# before anything is published under the tag's name.
#
# Never uploads. It prints the `gh release upload` command instead, so
# attaching the offer to a release is a deliberate, auditable act.
source "$(dirname "${BASH_SOURCE[0]}")/webkit/common.sh"

if [[ "${1-}" == "-h" || "${1-}" == "--help" ]]; then
	awk 'NR>1 && !/^#/{exit} NR>1{sub(/^# ?/,""); print}' "${BASH_SOURCE[0]}"
	exit 0
fi

DRY_RUN=0
OUT_DIR=""
RELEASE=""
while [[ $# -gt 0 ]]; do
	case "$1" in
	--dry-run) DRY_RUN=1 ;;
	--out)
		[[ $# -ge 2 ]] || die "--out needs a directory argument"
		OUT_DIR="$2"
		shift
		;;
	--release)
		[[ $# -ge 2 ]] || die "--release needs a tag argument"
		RELEASE="$2"
		shift
		;;
	*) die "unknown argument: $1 (try --help)" ;;
	esac
	shift
done
if [[ -z "$OUT_DIR" ]]; then
	OUT_DIR="$WEBKIT_DIR/source-offer"
fi

command -v git >/dev/null || die "git is not installed"
command -v zstd >/dev/null || die "zstd is not installed"

# CI runners are macOS; local machines may only carry shasum. Both write the
# same hex, and SHA256SUMS uses the sha256sum file format either way.
if command -v sha256sum >/dev/null; then
	sha256_of() { sha256sum "$1" | awk '{print $1}'; }
else
	sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }
fi

TARBALL="$OUT_DIR/webkit-source-$WEBKIT_PIN.tar.zst"
SUMS="$OUT_DIR/SHA256SUMS"

# Resolve the tree to archive. `git archive` packs the pinned commit, so
# untracked build products (WebKitBuild/) and working-tree dirt cannot leak
# into the tarball; what has to be proven is that HEAD *is* the pin.
SRC=""
SRC_DESC=""
if [[ -d "$WEBKIT_SRC/.git" ]]; then
	origin="$(git -C "$WEBKIT_SRC" remote get-url origin 2>/dev/null || true)"
	[[ "$origin" == "$WEBKIT_UPSTREAM" ]] || die \
		"$WEBKIT_SRC is a git checkout of something else:
  origin: ${origin:-<none>}
  wanted: $WEBKIT_UPSTREAM
Move it aside or set ZER0_WEBKIT_DIR to a different directory."
	if [[ "$WEBKIT_PIN" =~ ^[0-9a-f]{40}$ ]]; then
		at="$(git -C "$WEBKIT_SRC" rev-parse HEAD 2>/dev/null || true)"
	else
		at="$(git -C "$WEBKIT_SRC" describe --tags --exact-match 2>/dev/null || true)"
	fi
	if [[ "$at" == "$WEBKIT_PIN" ]]; then
		SRC="$WEBKIT_SRC"
		SRC_DESC="existing checkout at $WEBKIT_SRC"
	else
		die "$WEBKIT_SRC is at '${at:-nothing describable}', not the pinned $WEBKIT_PIN.
Re-run ./scripts/webkit/fetch.sh (idempotent) or point ZER0_WEBKIT_DIR elsewhere.
An offer published under a pin must come from that pin."
	fi
fi

CLONE_DIR=""
cleanup() { if [[ -n "$CLONE_DIR" ]]; then rm -rf "$CLONE_DIR"; fi; }
trap cleanup EXIT

upload_cmd() {
	echo "gh release upload ${RELEASE:-<zer0-release-tag>} \"$TARBALL\" \"$SUMS\" --clobber"
}

if ((DRY_RUN)); then
	note "dry-run: nothing is written"
	echo "    pin:     $WEBKIT_PIN ($ZER0_CHANNEL)"
	if [[ -n "$SRC" ]]; then
		echo "    source:  $SRC_DESC (verified at the pin)"
	else
		echo "    source:  shallow clone of $WEBKIT_UPSTREAM at $WEBKIT_PIN"
		echo "             (no checkout at $WEBKIT_SRC; several GB, minutes)"
	fi
	echo "    output:  $TARBALL"
	echo "             $SUMS"
	if [[ -f "$TARBALL" ]]; then
		echo "    reuse:   $TARBALL already exists and would be reused as-is"
	fi
	echo "    plan:    git archive --format=tar --prefix=WebKit/ $WEBKIT_PIN"
	echo "               | zstd -q -19 -T0 -o <tarball>.part && mv <tarball>.part <tarball>"
	echo "             sha256 <tarball> > SHA256SUMS"
	echo "    upload:  $(upload_cmd)"
	exit 0
fi

if [[ -z "$SRC" ]]; then
	# 7.4 GB checkout + ~2 GB tarball + headroom, on the volume that holds
	# both the clone and (by default) the output.
	require_free_gb "$WEBKIT_DIR" 12 "the WebKit clone for the source offer"
	CLONE_DIR="$WEBKIT_DIR/source-offer-clone.$$"
	if [[ "$WEBKIT_PIN" =~ ^[0-9a-f]{40}$ ]]; then
		# git clone cannot take a sha; init + shallow fetch lands on the
		# pinned commit at the same one-commit depth.
		note "no checkout at $WEBKIT_SRC, cloning $WEBKIT_PIN (shallow, by sha)"
		git init "$CLONE_DIR"
		git -C "$CLONE_DIR" remote add origin "$WEBKIT_UPSTREAM"
		git -C "$CLONE_DIR" fetch --depth 1 origin "$WEBKIT_PIN"
		git -C "$CLONE_DIR" checkout --detach "$WEBKIT_PIN"
	else
		note "no checkout at $WEBKIT_SRC, cloning $WEBKIT_PIN (shallow)"
		git clone --depth 1 --branch "$WEBKIT_PIN" "$WEBKIT_UPSTREAM" "$CLONE_DIR"
	fi
	SRC="$CLONE_DIR"
	SRC_DESC="shallow clone at $CLONE_DIR"
fi

mkdir -p "$OUT_DIR"
if [[ -f "$TARBALL" ]]; then
	note "$(basename "$TARBALL") already exists, reusing (git archive output is deterministic per pin)"
else
	note "archiving $WEBKIT_PIN -> $(basename "$TARBALL") (zstd -19; this is the slow part)"
	# Written as .part so a failed pipe cannot leave a corrupt tarball that a
	# later run would mistake for the finished offer.
	git -C "$SRC" archive --format=tar --prefix=WebKit/ "$WEBKIT_PIN" |
		zstd -q -19 -T0 -o "$TARBALL.part"
	mv "$TARBALL.part" "$TARBALL"
fi

note "writing $(basename "$SUMS")"
HASH="$(sha256_of "$TARBALL")"
printf '%s  %s\n' "$HASH" "$(basename "$TARBALL")" >"$SUMS"

note "ready"
echo "    pin:     $WEBKIT_PIN ($ZER0_CHANNEL)"
echo "    source:  $SRC_DESC"
echo "    tarball: $TARBALL ($(du -h "$TARBALL" | cut -f1))"
echo "    sha256:  $HASH"
echo "    upload:  $(upload_cmd)"
