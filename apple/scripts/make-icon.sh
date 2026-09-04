#!/usr/bin/env bash
# Draws Zer0.app's icon from the marks in design/logo/.
#
#   ./apple/scripts/make-icon.sh                    free-standing (default)
#   ./apple/scripts/make-icon.sh --body             mark knocked out of a body
#   ./apple/scripts/make-icon.sh --color '#RRGGBB'  the --body squircle's fill
#   ./apple/scripts/make-icon.sh -o path/to.icns    default: apple/Resources/AppIcon.icns
#   ./apple/scripts/make-icon.sh --png-dir DIR      also leave the flat PNGs there
#   ./apple/scripts/make-icon.sh --help
#
# This is a design-time tool, not a build step. The .icns it writes is checked
# in and apple/scripts/bundle.sh only copies it, so building zer0 needs no
# ImageMagick. Run this when a mark changes, then commit the result.
#
# --- The two treatments ----------------------------------------------------
#
# --free-standing  the mark alone on transparent, no body. Every pixel of the
#                  grid's content box goes to the mark, in the artwork's own
#                  colours -- the canonical master is two paths, purple ring
#                  and white inlay, and both go through together.
# --body           the mark punched out of a solid squircle, the way most macOS
#                  apps do it. The body eats about a third of the linear size,
#                  which the mark pays for at 16px. The knockout is by alpha,
#                  so it is the silhouette that shows.
#
# Both are here because it is a real fork, and the only way to judge it is to
# render both and look. Run with --png-dir and open the result.
#
# --- Colour ----------------------------------------------------------------
#
# The mark has chosen its colour: #635BC9 with a white inlay, adopted with the
# 2026-09 logo and carried by the masters themselves. --color no longer reinks
# the free-standing mark (it would be repainting artwork); it colours the
# --body treatment's squircle, which is ours rather than the artwork's.
#
# --- The macOS icon grid ---------------------------------------------------
#
# Since Big Sur a Mac app icon is not a full-bleed square. It is a rounded
# square inset from the canvas, and an icon that ignores the inset sits visibly
# larger than its neighbours in the Dock. On a 1024 canvas:
#
#   body            824 x 824      (0.8046875 of the canvas)
#   margin          100 per side   ((1024 - 824) / 2)
#   corner radius   185.4          (45% of the half-width, i.e. 0.225 * 824)
#
# Apple publishes the 1024 canvas in the HIG but has never published the 824 in
# pixels; 824/185.4 is the number measured off Apple's own template and used by
# every icon tool since. See:
#   https://developer.apple.com/design/human-interface-guidelines/app-icons
#   https://developer.apple.com/forums/thread/670578
#
# The corner is a continuous corner, not a circular arc, so it cannot be drawn
# with a plain rounded rect. SQUIRCLE below is Liam Rosenfeld's reconstruction
# of Apple's own UIBezierPath -- three cubics per corner, measured at zero
# deviation from Apple's template -- expanded here for side 824:
#   https://liamrosenfeld.com/posts/apple_icon_quest/
#
# On macOS 26 the system masks every icon into its own squircle regardless.
# Drawing the body ourselves is what the app's LSMinimumSystemVersion (15.4)
# requires; on 26 it is redundant but harmless, since our squircle is the shape
# the mask expects.
#
# --- Which master gets drawn at which size ---------------------------------
#
# See HINT_MAX_PX. This routing is the whole reason .icns carries a separate
# image per size rather than one image scaled.
set -euo pipefail

die() {
	echo "error: $*" >&2
	exit 1
}
note() { echo "==> $*"; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# --- the grid --------------------------------------------------------------
CANVAS=1024
BODY=824
MARGIN=100 # (CANVAS - BODY) / 2

# Apple's continuous-corner squircle, side 824, origin at 0,0. Translated into
# place by MARGIN when it is drawn.
SQUIRCLE="M283.4145 0L540.5855 0\
C622.1934 0 662.9974 0 706.9211 13.8886\
C754.8785 31.3436 792.6564 69.1215 810.1114 117.0789\
C824 161.0026 824 201.8066 824 283.4145L824 540.5855\
C824 622.1934 824 662.9974 810.1114 706.9211\
C792.6564 754.8785 754.8785 792.6564 706.9211 810.1114\
C662.9974 824 622.1934 824 540.5855 824L283.4145 824\
C201.8066 824 161.0026 824 117.0789 810.1114\
C69.1215 792.6564 31.3436 754.8785 13.8886 706.9211\
C0 662.9974 0 622.1934 0 540.5855L0 283.4145\
C0 201.8066 0 161.0026 13.8886 117.0789\
C31.3436 69.1215 69.1215 31.3436 117.0789 13.8886\
C161.0026 0 201.8066 0 283.4145 0Z"

# How much of the body the knocked-out mark spans, in --body. Not a published
# number: Apple's guidance is "leave breathing room" and nothing more. 0.68
# is what looked right against the Dock's neighbours -- large enough that the
# mark is the icon, small enough that the body still reads as a body.
GLYPH_FRACTION=0.68

# --- the masters -----------------------------------------------------------
CANONICAL="$ROOT/design/logo/zer0.svg"
SMALL="$ROOT/design/logo/zer0-small.svg"

# The pixel size at and below which the hinted master is drawn instead of the
# canonical one. 32 and not 24: at 32px the canonical mark's cut survives only
# as a smudge in the antialiasing -- technically present, not legible -- while
# the hinted one is unambiguous. 64px is where the canonical mark starts
# winning, because there the extra weight of the hinted drawing begins to look
# like weight rather than like clarity.
#
# The threshold is in *pixels*, not points, because the question is how many
# pixels the cut has to live in. 16pt@2x and 32pt@1x are both 32px and both get
# the hinted mark; 32pt@2x is 64px and gets the canonical one.
HINT_MAX_PX=32

# Every size macOS asks for, as "<iconset basename> <pixels>". The names are
# fixed by iconutil:
#   https://developer.apple.com/library/archive/documentation/GraphicsAnimation/Conceptual/HighResolutionOSX/Optimizing/Optimizing.html
ICONSET_ENTRIES="
icon_16x16 16
icon_16x16@2x 32
icon_32x32 32
icon_32x32@2x 64
icon_128x128 128
icon_128x128@2x 256
icon_256x256 256
icon_256x256@2x 512
icon_512x512 512
icon_512x512@2x 1024
"

# --- arguments -------------------------------------------------------------
TREATMENT=free
COLOR='#16181D'
OUT="$ROOT/apple/Resources/AppIcon.icns"
PNG_DIR=""

while (($#)); do
	case "$1" in
	--free-standing | --free)
		TREATMENT=free
		shift
		;;
	--body)
		TREATMENT=body
		shift
		;;
	--color)
		[[ $# -ge 2 ]] || die "--color needs a value"
		COLOR="$2"
		shift 2
		;;
	-o | --out)
		[[ $# -ge 2 ]] || die "$1 needs a path"
		OUT="$2"
		shift 2
		;;
	--png-dir)
		[[ $# -ge 2 ]] || die "--png-dir needs a path"
		PNG_DIR="$2"
		shift 2
		;;
	# Prints the header comment: every line after the shebang up to the
	# first line that is not a comment. A line count would drift.
	-h | --help)
		awk 'NR>1 && !/^#/{exit} NR>1{sub(/^# ?/,""); print}' "${BASH_SOURCE[0]}"
		exit 0
		;;
	*) die "unknown argument: $1 (try --help)" ;;
	esac
done

[[ "$COLOR" == '#'?????? ]] || die "--color wants #RRGGBB, got: $COLOR"

# --- preflight -------------------------------------------------------------
command -v magick >/dev/null || die "ImageMagick is not installed, and this script rasterises SVG.
Run: brew install imagemagick"

command -v iconutil >/dev/null || die "iconutil not found; it ships with the Xcode command line tools.
Run: xcode-select --install"

for svg in "$CANONICAL" "$SMALL"; do
	[[ -f "$svg" ]] || die "missing master: $svg"
done

# ImageMagick reaches for librsvg when it is installed and falls back to its own
# renderer when it is not, which would make the output depend on what happens to
# be on the machine. msvg: pins the internal renderer either way. It is enough
# because the masters are deliberately plain filled paths -- one for the hinted
# master, two for the canonical lockup -- and that is what the "no stroke,
# transform, mask or clipPath" rule in design/logo/zer0.svg buys, and this is
# one of the places it gets spent.
render() { # <svg file> <pixels> <output png>
	magick -background none "msvg:$1" -depth 8 -strip \
		-define png:exclude-chunk=date,time,tIME,tEXt,bKGD,cHRM,gAMA \
		-resize "${2}x${2}" "PNG32:$3"
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- fitting the mark into a box -------------------------------------------
#
# The masters do not promise where the mark sits inside their viewBox, and they
# should not have to: that is layout, and layout belongs to whoever draws them.
# So measure the inked area and fit that, rather than trusting the viewBox.
#
# Prints "<scale> <translate-x> <translate-y>" for placing <svg file>'s mark,
# centred on the canvas, spanning <box> on its longer side.
fit() { # <svg file> <box>
	local svg="$1" box="$2" flat="$WORK/flat.svg" view geom trim px

	# currentColor has no meaning outside a document that sets a colour, and
	# ImageMagick renders it as nothing. Any opaque colour will do for measuring.
	sed 's/currentColor/#000000/' "$svg" >"$flat"

	view="$(tr '\n' ' ' <"$svg" | sed -n 's/.*viewBox="\([^"]*\)".*/\1/p')"
	[[ -n "$view" ]] || die "$svg has no viewBox"

	geom="$(magick -background none -density 1024 "msvg:$flat" -format '%@ %w' info:)" ||
		die "could not rasterise $svg"
	trim="${geom% *}"
	px="${geom##* }"

	# A master that renders to nothing measures as nothing, and a nothing that
	# reaches awk comes back as a divide-by-zero and a blank icon. Refuse here.
	[[ "$trim" == *x*+*+* && "$px" -gt 0 ]] ||
		die "$svg rendered to nothing (measured '$geom'); is the path empty?"

	awk -v trim="$trim" -v view="$view" -v px="$px" -v box="$box" -v canvas="$CANVAS" '
        BEGIN {
            split(view, v, /[ ,]+/)          # min-x min-y width height
            split(trim, t, /[x+]/)           # width height x y, in pixels
            u = px / v[3]                    # rendered pixels per user unit
            w = t[1] / u; h = t[2] / u
            x = v[1] + t[3] / u; y = v[2] + t[4] / u
            s = (w > h ? box / w : box / h)
            printf "%.6f %.4f %.4f\n", s, canvas/2 - (x + w/2) * s, canvas/2 - (y + h/2) * s
        }'
}

# The master's <path/> elements, verbatim and with the header comment stripped
# first so a "d=" or "fill=" in prose cannot be mistaken for artwork. All of
# them, in file order: the canonical lockup is a purple ring and a white inlay,
# and splitting or recolouring them here would be redrawing the logo.
strip_xml_comments() {
	awk '
		{
			line = $0 "\n"
			while (length(line) > 0) {
				if (in_comment) {
					end = index(line, "-->")
					if (end == 0) next
					line = substr(line, end + 3)
					in_comment = 0
				}
				start = index(line, "<!--")
				if (start == 0) {
					printf "%s", line
					line = ""
				} else {
					printf "%s", substr(line, 1, start - 1)
					line = substr(line, start + 4)
					in_comment = 1
				}
			}
		}
		END { if (in_comment) exit 1 }
	' "$1"
}

mark_elements() { # <svg file>
	local markup els
	markup="$(strip_xml_comments "$1")" || die "$1 has an unterminated XML comment"
	els="$(printf '%s' "$markup" | tr '\n' ' ' | grep -o '<path[[:space:]][^>]*/>')"
	[[ -n "$els" ]] || die "$1 has no <path/> elements"
	printf '%s' "$els"
}

# Writes the 1024px artwork for one master into $WORK/<tag>.png.
compose() { # <svg file> <tag>
	local svg="$1" tag="$2" box placement els scale tx ty

	case "$TREATMENT" in
	free) box="$BODY" ;;
	# In --body the mark lives inside the body, not inside the canvas.
	body) box="$(awk -v b="$BODY" -v f="$GLYPH_FRACTION" 'BEGIN{printf "%.4f", b*f}')" ;;
	esac

	# Assigned, not piped into read: a die() inside a command substitution only
	# kills the subshell, and an assignment is the one place set -e still sees
	# the non-zero status.
	placement="$(fit "$svg" "$box")"
	els="$(mark_elements "$svg")"
	read -r scale tx ty <<<"$placement"

	{
		printf '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %s %s">' "$CANVAS" "$CANVAS"
		printf '<g transform="translate(%s,%s) scale(%s)">' "$tx" "$ty" "$scale"
		printf '%s' "$els"
		printf '</g></svg>'
	} >"$WORK/$tag-mark.svg"

	if [[ "$TREATMENT" == free ]]; then
		render "$WORK/$tag-mark.svg" "$CANVAS" "$WORK/$tag.png"
		return
	fi

	{
		printf '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %s %s">' "$CANVAS" "$CANVAS"
		printf '<g transform="translate(%s,%s)">' "$MARGIN" "$MARGIN"
		printf '<path fill="%s" d="%s"/>' "$COLOR" "$SQUIRCLE"
		printf '</g></svg>'
	} >"$WORK/$tag-body.svg"

	render "$WORK/$tag-body.svg" "$CANVAS" "$WORK/$tag-body.png"
	render "$WORK/$tag-mark.svg" "$CANVAS" "$WORK/$tag-mark.png"

	# DstOut subtracts the mark's alpha from the body's: a real hole, so the
	# desktop shows through it, rather than the mark painted in a second colour.
	magick "$WORK/$tag-body.png" "$WORK/$tag-mark.png" -compose DstOut -composite \
		-depth 8 -strip -define png:exclude-chunk=date,time,tIME,tEXt,bKGD,cHRM,gAMA \
		"PNG32:$WORK/$tag.png"
}

note "composing ($TREATMENT, $COLOR)"
compose "$CANONICAL" canonical
compose "$SMALL" small

# --- the iconset -----------------------------------------------------------
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"

while read -r name px; do
	[[ -n "$name" ]] || continue

	# The routing this whole script exists for: below the threshold the mark is
	# redrawn, above it, it is the canonical drawing.
	if ((px <= HINT_MAX_PX)); then
		src="$WORK/small.png"
	else
		src="$WORK/canonical.png"
	fi

	# Downsampling a 1024px render rather than rasterising at the target size:
	# supersampling gives cleaner edges at 16px than any rasteriser's own
	# antialiasing, and the master is already the right *drawing* for the size.
	magick "$src" -filter Lanczos -resize "${px}x${px}" \
		-depth 8 -strip -define png:exclude-chunk=date,time,tIME,tEXt,bKGD,cHRM,gAMA \
		"PNG32:$ICONSET/$name.png"
done <<<"$ICONSET_ENTRIES"

mkdir -p "$(dirname "$OUT")"
iconutil --convert icns --output "$OUT" "$ICONSET" ||
	die "iconutil failed on $ICONSET"

note "$OUT ($(du -h "$OUT" | cut -f1))"

if [[ -n "$PNG_DIR" ]]; then
	mkdir -p "$PNG_DIR"
	for px in 16 32 128 512; do
		cp "$ICONSET/$(echo "$ICONSET_ENTRIES" | awk -v p="$px" '$2 == p { print $1; exit }').png" \
			"$PNG_DIR/zer0-$TREATMENT-${px}.png"
	done
	note "$PNG_DIR"
fi
