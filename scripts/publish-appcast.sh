#!/usr/bin/env bash
#
# Publish a Sparkle appcast entry for the stable or canary channel.
#
# Reads the channel's appcast from the `gh-pages` branch, prepends a new
# `<item>` signed with EdDSA, commits and pushes. This is the one door for
# "an update is available" -- the workflow that built, signed and uploaded
# the bundle calls this, and nothing else writes to the appcast.
#
# ADR-0109: one appcast per channel. ADR-0110: the channel a bundle reads
# is the channel it was built for, and there is no peek across. This script
# takes the channel as an explicit argument rather than guessing it, because
# the same regression ADR-0109 warns about -- "the workflow pushed a canary
# build into the stable appcast" -- is a one-flag mistake this script refuses
# to make easy.
#
# Why the archive is signed, not the bundle:
#   Sparkle verifies both the EdDSA signature and the byte length against the
#   exact archive the user downloads. Re-zipping the `.app` here would sign a
#   different byte stream from the one the release uploaded, and the update
#   would be refused silently (docs/sparkle-setup.md names this failure). So
#   the script signs the `--archive` the workflow already produced and the
#   release already attached -- the same bytes, by construction.
#
# Why the bundle version is an argument checked against the door, not read
#   from the plist: the workflow that built the bundle passes the number it
#   stamped into CFBundleVersion (ADR-0111), and this script recomputes it
#   from --version through the same function the build derived it from
#   (`bundle_version_for_channel` in apple/scripts/resolve-bundle.sh) and
#   refuses a disagreement below. Reading the plist instead would quietly
#   publish whatever the build happened to carry -- a build that missed
#   ZER0_BUNDLE_VERSION would ship `1` into the feed and freeze update
#   ranking, which is the bug this door exists to make loud.
#
# Usage:
#   scripts/publish-appcast.sh \
#     --channel canary \
#     --version 0.0.0-canary.202608121500-abc1234 \
#     --bundle-version 202608121500 \
#     --archive zer0-canary-0.0.0-canary.202608121500-abc1234.zip \
#     --download-url https://github.com/OWNER/REPO/releases/download/canary-VERSION/zer0-canary-VERSION.zip \
#     --sparkle-private-key "$ZER0_SPARKLE_PRIVATE_KEY"
#
# Requires:
#   - Sparkle's `sign_update` in PATH, or network access to fetch the Sparkle
#     2.x tarball (the version pinned in apple/Package.swift). The script
#     downloads it on demand the way the workflow used to.
#   - Write access to the `gh-pages` branch. In Actions this is `secrets.GITHUB_TOKEN`
#     via `GH_TOKEN`; `gh auth setup-git` wires it into git if `gh` is present.
#   - The archive must already be uploaded to `--download-url` before this
#     runs, because the appcast entry is what tells Sparkle the update exists:
#     a reachable URL with no appcast entry is invisible to the updater, and
#     an appcast entry whose URL 404s is an update that fails mid-install.

set -euo pipefail

cd "$(dirname "$0")/.."

CHANNEL=""
VERSION=""
BUNDLE_VERSION=""
ARCHIVE=""
DOWNLOAD_URL=""
PRIVATE_KEY=""

while [[ $# -gt 0 ]]; do
	case "$1" in
	--channel)
		CHANNEL="$2"
		shift 2
		;;
	--version)
		VERSION="$2"
		shift 2
		;;
	--bundle-version)
		BUNDLE_VERSION="$2"
		shift 2
		;;
	--archive)
		ARCHIVE="$2"
		shift 2
		;;
	--download-url)
		DOWNLOAD_URL="$2"
		shift 2
		;;
	--sparkle-private-key)
		PRIVATE_KEY="$2"
		shift 2
		;;
	-h | --help)
		sed -n '2,/^set -euo pipefail$/p' "$0" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	*)
		echo "error: unknown argument: $1" >&2
		echo "see $0 --help" >&2
		exit 1
		;;
	esac
done

# Refuse rather than repair. A missing or half-populated argument set is a
# workflow bug, and guessing a channel or a version is exactly the kind of
# repair AGENTS.md calls "a bug with a delay on it".
if [[ "$CHANNEL" != "stable" && "$CHANNEL" != "canary" ]]; then
	echo "error: --channel must be 'stable' or 'canary' (got '${CHANNEL:-<empty>}')" >&2
	exit 1
fi
for pair in \
	"--version:$VERSION" \
	"--bundle-version:$BUNDLE_VERSION" \
	"--archive:$ARCHIVE" \
	"--download-url:$DOWNLOAD_URL" \
	"--sparkle-private-key:$PRIVATE_KEY"; do
	if [[ -z "${pair#*:}" ]]; then
		echo "error: ${pair%%:*} is required" >&2
		exit 1
	fi
done

if [[ ! -f "$ARCHIVE" ]]; then
	echo "error: archive not found at $ARCHIVE" >&2
	echo "       the workflow's archive step must run before publish-appcast," >&2
	echo "       and the path must be relative to the repo root." >&2
	exit 1
fi

# The agreement check (ADR-0111): --bundle-version must be exactly what the
# one door derives from --channel + --version. The build stamped CFBundleVersion
# from the same derivation (bundle.sh reads the ZER0_BUNDLE_VERSION the
# workflow computed through it), so a disagreement means one side of the
# pipeline drifted -- refuse rather than publish a number that silently breaks
# update ranking.
# shellcheck source=../apple/scripts/resolve-bundle.sh
. apple/scripts/resolve-bundle.sh
EXPECTED_BUNDLE_VERSION="$(bundle_version_for_channel "$CHANNEL" "$VERSION")" || exit 1
if [[ "$EXPECTED_BUNDLE_VERSION" != "$BUNDLE_VERSION" ]]; then
	echo "error: --bundle-version '${BUNDLE_VERSION}' disagrees with the formula for ${CHANNEL} ${VERSION}" >&2
	echo "       (expected '${EXPECTED_BUNDLE_VERSION}'); see bundle_version_for_channel in" >&2
	echo "       apple/scripts/resolve-bundle.sh (ADR-0111)." >&2
	exit 1
fi

# --------------------------------------------------------------------------- #
# sign_update: find it, or fetch the Sparkle tarball that ships it.
# --------------------------------------------------------------------------- #
# Sparkle's sign_update is the only thing that produces an EdDSA signature the
# appcast will verify against SUPublicEDKey. The version fetched here must
# match the one apple/Package.resolved links (EdDSA is interoperable across
# 2.x, but the declared lockstep rule is kept on purpose); keeping them in
# lockstep is what makes the signature and the verifier agree (ADR-0109
# signing-key rotation note).
SPARKLE_VERSION="2.9.5"
SPARKLE_TARBALL="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"

SIGN_UPDATE="$(command -v sign_update || true)"
SPARKLE_EXTRACT=""
if [[ -z "$SIGN_UPDATE" || ! -x "$SIGN_UPDATE" ]]; then
	echo "==> sign_update not on PATH; fetching Sparkle ${SPARKLE_VERSION}"
	# The tarball lays out `bin/sign_update` (and `generate_keys`) at its
	# ROOT, not under a Sparkle/ subdir -- extracting to a dedicated dir keeps
	# the path predictable and keeps /tmp clean.
	SPARKLE_EXTRACT="$(mktemp -d -t zer0-sparkle.XXXXXX)"
	curl -sSL "$SPARKLE_TARBALL" -o "$SPARKLE_EXTRACT/Sparkle.tar.xz"
	tar -xf "$SPARKLE_EXTRACT/Sparkle.tar.xz" -C "$SPARKLE_EXTRACT"
	SIGN_UPDATE="$SPARKLE_EXTRACT/bin/sign_update"
fi
if [[ ! -x "$SIGN_UPDATE" ]]; then
	echo "error: sign_update missing at $SIGN_UPDATE" >&2
	exit 1
fi

# The private key flows to sign_update through stdin. Per `sign_update --help`,
# `-f -` "can be used to echo the EdDSA key from a 'secret' environment variable
# to the standard input stream" -- which is exactly an argument holding a key.
# Reading from a pipe keeps the key off disk entirely; nothing is written, no
# temp file to trap and remove, and the key never lands on the runner's
# filesystem. (The earlier `export ZER0_SPARKLE_PRIVATE_KEY; sign_update ...`
# shape in the workflow never worked: sign_update reads the key from the
# Keychain when no -f is given, not from an env var, and the publish step was a
# stub that never exercised it.)
#
# sign_update prints one line: `sparkle:edSignature="..." length="..."`. That
# line is authoritative for BOTH attributes -- do not re-stat the archive for
# the length, the signature and the length it signs are a pair (AGENTS.md:
# say only what you can prove).
ENCLOSURE_LINE="$(printf '%s\n' "$PRIVATE_KEY" | "$SIGN_UPDATE" -f - "$ARCHIVE")"
SIGNATURE="$(printf '%s\n' "$ENCLOSURE_LINE" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
LENGTH="$(printf '%s\n' "$ENCLOSURE_LINE" | sed -n 's/.*length="\([0-9][0-9]*\)".*/\1/p')"
if [[ -z "$SIGNATURE" || -z "$LENGTH" ]]; then
	echo "error: could not parse sign_update output:" >&2
	printf '%s\n' "$ENCLOSURE_LINE" >&2
	echo "       expected a line like: sparkle:edSignature=\"...\" length=\"...\"" >&2
	exit 1
fi

# --------------------------------------------------------------------------- #
# Build the new <item> following the schema documented in docs/sparkle-setup.md
# (version strings and minimumSystemVersion as item children; url, edSignature,
# length and type on the enclosure). minimumSystemVersion is 15.4, the macOS
# floor ADR-0102 picks and LSMinimumSystemVersion in Info.plist already carries
# -- not 10.15.4, which the bundle cannot run on.
# --------------------------------------------------------------------------- #
PUB_DATE="$(date -R)"
case "$CHANNEL" in
canary) TITLE="zer0 Canary ${VERSION}" ;;
stable) TITLE="zer0 ${VERSION}" ;;
esac

# releaseNotesLink points at the release a human reads. Built from
# GITHUB_REPOSITORY when set (Actions always sets it); omitted otherwise, since
# an invented URL is worse than none (Sparkle simply shows no notes).
RELEASE_NOTES=""
if [[ -n "${GITHUB_REPOSITORY:-}" ]]; then
	case "$CHANNEL" in
	canary) RELEASE_NOTES="https://github.com/${GITHUB_REPOSITORY}/releases/tag/canary-${VERSION}" ;;
	stable) RELEASE_NOTES="https://github.com/${GITHUB_REPOSITORY}/releases/tag/v${VERSION}" ;;
	esac
fi

item_block() {
	cat <<ITEM
    <item>
        <title>${TITLE}</title>
        <pubDate>${PUB_DATE}</pubDate>
        <sparkle:version>${BUNDLE_VERSION}</sparkle:version>
        <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
        <sparkle:minimumSystemVersion>15.4</sparkle:minimumSystemVersion>
ITEM
	if [[ -n "$RELEASE_NOTES" ]]; then
		printf '        <sparkle:releaseNotesLink>%s</sparkle:releaseNotesLink>\n' "$RELEASE_NOTES"
	fi
	cat <<ITEM
        <enclosure
            url="${DOWNLOAD_URL}"
            sparkle:edSignature="${SIGNATURE}"
            length="${LENGTH}"
            type="application/octet-stream" />
    </item>
ITEM
}

NEW_ITEM="$(item_block)"

# --------------------------------------------------------------------------- #
# Read the existing appcast from gh-pages (or fall back to a fresh template).
# --------------------------------------------------------------------------- #
# actions/checkout clones only the branch that triggered the workflow, so the
# gh-pages ref is not present until fetched here. A missing branch is an
# operator step that has to happen once (docs/sparkle-setup.md); refusing
# beats silently creating a branch with no history, because two writers doing
# that race and one loses.
APPCAST_FILE="appcast-${CHANNEL}.xml"

if ! git fetch --depth=1 origin gh-pages 2>/dev/null; then
	cat >&2 <<EOF
error: the 'gh-pages' branch is not on origin.
       create it once, manually -- see docs/sparkle-setup.md "One-time gh-pages
       setup". This script publishes into an existing branch; it will not create
       one, because inventing the branch from two workflows at once is the race
       that loses appcast history.
EOF
	exit 1
fi

EXISTING="$(git show "origin/gh-pages:${APPCAST_FILE}" 2>/dev/null || true)"
if [[ -z "$EXISTING" ]]; then
	# No appcast for this channel yet: seed it with the documented template.
	# The host/title carry the channel so a reader of the raw feed knows which
	# population it serves (ADR-0109: two feeds, same schema, same key).
	case "$CHANNEL" in
	canary) FEED_TITLE="zer0 canary" ;;
	stable) FEED_TITLE="zer0 stable" ;;
	esac
	EXISTING="$(
		cat <<XML
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <title>${FEED_TITLE}</title>
  </channel>
</rss>
XML
	)"
fi

# Insert the new <item> right after the channel's own <title>, so the feed
# stays valid RSS (channel title/description precede items) and the newest
# entry stays first -- the order a person scanning the feed expects. Sparkle
# itself picks the highest sparkle:version regardless of order, so this is for
# the human reader, not the updater.
#
# The insert targets the first <title> after <channel>, which is always the
# channel title (item titles come after and are skipped by the `inserted`
# guard). ENVIRON carries the multi-line item because awk's -v mangles literal
# newlines on BSD awk (macOS). If the feed has no channel title -- a shape
# this script never produces -- the insert is refused rather than guessed.
if ! printf '%s\n' "$EXISTING" | grep -q '<channel>'; then
	echo "error: existing ${APPCAST_FILE} has no <channel> element; refusing to patch a feed whose shape is unknown." >&2
	echo "       inspect origin/gh-pages:${APPCAST_FILE} manually." >&2
	exit 1
fi
export ZER0_NEW_ITEM="$NEW_ITEM"
NEW_APPCAST="$(printf '%s\n' "$EXISTING" | awk '
	!done && seen_channel && /^[[:space:]]*<title>/ {
		print
		print ENVIRON["ZER0_NEW_ITEM"]
		done = 1
		next
	}
	/<channel>/ { seen_channel = 1 }
	{ print }
')"
# awk has no exit code for "did not insert"; detect by checking the new
# signature appears in the result (the EdDSA signature is unique per archive).
if ! printf '%s\n' "$NEW_APPCAST" | grep -Fq "$SIGNATURE"; then
	echo "error: failed to insert the new <item> (no channel <title> found to insert after)." >&2
	echo "       the feed shape is unexpected; inspect origin/gh-pages:${APPCAST_FILE}." >&2
	exit 1
fi
unset ZER0_NEW_ITEM

# --------------------------------------------------------------------------- #
# Commit to gh-pages via a throwaway worktree.
# --------------------------------------------------------------------------- #
# A worktree keeps the workflow's main checkout untouched (the job is still
# pointing at the branch that triggered it) and gives the publish an isolated
# tree to commit in. The push sends the worktree's HEAD to the remote gh-pages;
# a non-fast-forward fails loudly rather than rewriting history, which is the
# right posture when two channels could race for the same branch.
WORK="$(mktemp -d -t zer0-gh-pages.XXXXXX)"
trap '
	git worktree remove --force "$WORK" 2>/dev/null || true
	rm -rf "$WORK"
	[[ -n "${SPARKLE_EXTRACT:-}" ]] && rm -rf "$SPARKLE_EXTRACT"
' EXIT

git worktree add --quiet --detach "$WORK" origin/gh-pages
printf '%s\n' "$NEW_APPCAST" >"$WORK/${APPCAST_FILE}"

# Configure git user so the commit is attributable; the default ubuntu/runner
# identity is fine for an automated publish.
git -C "$WORK" config user.name "${GIT_AUTHOR_NAME:-zer0 release bot}"
git -C "$WORK" config user.email "${GIT_AUTHOR_EMAIL:-bot@users.noreply.github.com}"

git -C "$WORK" add "${APPCAST_FILE}"
git -C "$WORK" commit --quiet -m "publish ${CHANNEL} ${VERSION}

Prepend a new <item> to ${APPCAST_FILE}.
sparkle:version=${BUNDLE_VERSION}
length=${LENGTH}

Generated by scripts/publish-appcast.sh in CI."

# Auth: actions/checkout runs with persist-credentials: false, so the remote
# has no token. `gh auth setup-git` installs a credential helper that supplies
# GH_TOKEN; the workflow passes GH_TOKEN for this purpose. Outside Actions a
# configured credential helper or SSH remote just works.
if command -v gh >/dev/null 2>&1 && [[ -n "${GH_TOKEN:-}" ]]; then
	gh auth setup-git >/dev/null 2>&1 || true
fi

echo "==> pushing ${APPCAST_FILE} to gh-pages"
git -C "$WORK" push origin HEAD:gh-pages

echo "==> published ${CHANNEL} ${VERSION} (sparkle:version=${BUNDLE_VERSION}, length=${LENGTH})"
