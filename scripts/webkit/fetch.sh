#!/usr/bin/env bash
# Puts the pinned WebKit source tree on disk.
#
#   ./scripts/webkit/fetch.sh
#   ZER0_WEBKIT_DIR=/Volumes/big/webkit ./scripts/webkit/fetch.sh
#
# The tag comes from version.txt. The checkout is shallow (one commit, no
# history) because nothing here needs to bisect WebKit; it needs to compile one
# known revision. Re-running is safe: an existing checkout is fetched and moved
# to the pinned tag rather than re-cloned.
#
# Nothing is written inside the zer0 repo. The default location is
# ~/.cache/zer0/webkit, overridable with ZER0_WEBKIT_DIR.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Prints the header comment: every line after the shebang up to the first line
# that is not a comment. A line count would drift as the comment grows.
if [[ "${1-}" == "-h" || "${1-}" == "--help" ]]; then
    awk 'NR>1 && !/^#/{exit} NR>1{sub(/^# ?/,""); print}' "${BASH_SOURCE[0]}"
    exit 0
fi

# A shallow checkout of WebKit-7624.4.5.14.1 measured 7.4 GB across 455k files.
# The floor is set well above that so a fetch cannot be the thing that fills
# the volume the build is about to need.
require_free_gb "$WEBKIT_DIR" 25 "the WebKit checkout"

command -v git >/dev/null || die "git is not installed"

note "tag:    $WEBKIT_TAG"
note "source: $WEBKIT_SRC"

if [[ -d "$WEBKIT_SRC/.git" ]]; then
    origin="$(git -C "$WEBKIT_SRC" remote get-url origin 2>/dev/null || true)"
    [[ "$origin" == "$WEBKIT_UPSTREAM" ]] || die \
        "$WEBKIT_SRC is a git checkout of something else:
  origin: ${origin:-<none>}
  wanted: $WEBKIT_UPSTREAM
Move it aside or set ZER0_WEBKIT_DIR to a different directory."

    if [[ "$(git -C "$WEBKIT_SRC" describe --tags --exact-match 2>/dev/null || true)" == "$WEBKIT_TAG" ]]; then
        note "already at $WEBKIT_TAG, nothing to fetch"
    else
        # Local edits are the reason someone builds WebKit from source at all,
        # so refuse rather than reset. Reporting the tag we would have moved to
        # keeps the message actionable.
        if [[ -n "$(git -C "$WEBKIT_SRC" status --porcelain 2>/dev/null)" ]]; then
            die "$WEBKIT_SRC has uncommitted changes and is not at $WEBKIT_TAG.
Commit, stash or discard them, then re-run. This script will not throw away
work it did not create."
        fi
        note "fetching $WEBKIT_TAG into the existing checkout"
        git -C "$WEBKIT_SRC" fetch --depth 1 origin "refs/tags/$WEBKIT_TAG:refs/tags/$WEBKIT_TAG"
        git -C "$WEBKIT_SRC" checkout --detach "$WEBKIT_TAG"
    fi
else
    [[ ! -e "$WEBKIT_SRC" ]] || die "$WEBKIT_SRC exists but is not a git checkout"
    mkdir -p "$WEBKIT_DIR"
    note "cloning (shallow) — this moves a few GB and takes a while"
    git clone --depth 1 --branch "$WEBKIT_TAG" "$WEBKIT_UPSTREAM" "$WEBKIT_SRC"
fi

# The one file build.sh cannot work without. Checking it here turns a partial
# or wrong checkout into an error now rather than into a confusing failure
# twenty minutes into a build.
[[ -x "$WEBKIT_SRC/Tools/Scripts/build-webkit" ]] || die \
    "$WEBKIT_SRC/Tools/Scripts/build-webkit is missing.
The checkout is incomplete. Delete $WEBKIT_SRC and re-run."

note "ready"
echo "    revision: $(git -C "$WEBKIT_SRC" rev-parse --short HEAD) ($WEBKIT_TAG)"
echo "    size:     $(du -sh "$WEBKIT_SRC" | cut -f1)"
echo "    next:     $WEBKIT_SCRIPT_DIR/build.sh --release"
