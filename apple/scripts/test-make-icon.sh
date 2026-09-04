#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/project/apple/scripts" "$WORK/project/design/logo" "$WORK/bin" "$WORK/captured"
cp "$ROOT/apple/scripts/make-icon.sh" "$WORK/project/apple/scripts/make-icon.sh"

cat >"$WORK/project/design/logo/zer0.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1 1">
<!--
<path d="M99 99Z" fill="#FF0000"/>
-->
<path d="M0 0Z" fill="#635BC9"/>
</svg>
SVG
cp "$WORK/project/design/logo/zer0.svg" "$WORK/project/design/logo/zer0-small.svg"

cat >"$WORK/bin/magick" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
for argument in "$@"; do
	case "$argument" in
	msvg:*)
		cp "${argument#msvg:}" "$ZER0_CAPTURE_DIR/$(basename "${argument#msvg:}")"
		;;
	esac
done

last="${!#}"
case "$last" in
info:) printf '1x1+0+0 1' ;;
PNG32:*) : >"${last#PNG32:}" ;;
esac
STUB

cat >"$WORK/bin/iconutil" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
while (($#)); do
	if [[ "$1" == "--output" ]]; then
		: >"$2"
		exit 0
	fi
	shift
done
exit 1
STUB

chmod +x "$WORK/bin/magick" "$WORK/bin/iconutil"
PATH="$WORK/bin:$PATH" ZER0_CAPTURE_DIR="$WORK/captured" \
	bash "$WORK/project/apple/scripts/make-icon.sh" -o "$WORK/AppIcon.icns" >/dev/null

generated="$WORK/captured/canonical-mark.svg"
[[ -f "$generated" ]] || {
	echo "FAIL: make-icon.sh did not render the canonical mark" >&2
	exit 1
}
if grep -q 'M99 99Z' "$generated"; then
	echo "FAIL: make-icon.sh treated a path inside an XML comment as artwork" >&2
	exit 1
fi
grep -q 'M0 0Z' "$generated" || {
	echo "FAIL: make-icon.sh dropped the live artwork path" >&2
	exit 1
}

echo "PASS: make-icon.sh ignores paths inside multiline XML comments"
