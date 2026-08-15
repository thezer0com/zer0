#!/usr/bin/env bash
# Shared by fetch.sh and build.sh. Not executable on its own.
#
# Everything here exists so the two scripts cannot disagree about where the
# source tree is or which tag is pinned: a fetch that writes one directory and
# a build that reads another fails in a way that looks like a WebKit bug.

set -euo pipefail

WEBKIT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "error: $*" >&2; exit 1; }
note() { echo "==> $*"; }

# Reads one KEY from version.txt. Deliberately not `source`: version.txt is
# data, and sourcing it would let a stray backtick in a comment run.
version_get() {
    local key="$1" value
    value="$(sed -n "s/^${key}=//p" "$WEBKIT_SCRIPT_DIR/version.txt" | tail -1)"
    [[ -n "$value" ]] || die "version.txt has no $key"
    printf '%s\n' "$value"
}

WEBKIT_TAG="$(version_get WEBKIT_TAG)"

# ZER0_WEBKIT_DIR wins; version.txt only supplies the default. The `~` in
# version.txt is expanded here rather than by the shell, since the file is read
# as data.
if [[ -n "${ZER0_WEBKIT_DIR-}" ]]; then
    WEBKIT_DIR="$ZER0_WEBKIT_DIR"
else
    WEBKIT_DIR="$(version_get WEBKIT_DIR_DEFAULT)"
    WEBKIT_DIR="${WEBKIT_DIR/#\~/$HOME}"
fi

WEBKIT_SRC="$WEBKIT_DIR/src"
WEBKIT_UPSTREAM="https://github.com/WebKit/WebKit.git"

# Free space on the volume that would hold $1, in GB. Uses the first existing
# ancestor, because the target directory usually does not exist yet.
free_gb() {
    local path="$1"
    while [[ ! -d "$path" && "$path" != "/" ]]; do path="$(dirname "$path")"; done
    df -g "$path" | awk 'NR==2 {print $4}'
}

require_free_gb() {
    local path="$1" want="$2" what="$3" have
    have="$(free_gb "$path")"
    (( have >= want )) || die "not enough free disk for $what.
  volume holding $path has ${have} GB free, ${want} GB is the floor
Free space or point ZER0_WEBKIT_DIR at a bigger volume."
}
