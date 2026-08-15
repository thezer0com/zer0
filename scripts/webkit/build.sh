#!/usr/bin/env bash
# Builds the pinned WebKit and says where it landed.
#
#   ./scripts/webkit/build.sh              # release (default)
#   ./scripts/webkit/build.sh --release
#   ./scripts/webkit/build.sh --debug
#   ZER0_WEBKIT_DIR=/Volumes/big/webkit ./scripts/webkit/build.sh --release
#
# Run fetch.sh first. Everything after `--` is handed to build-webkit, so
# `build.sh --release -- DEBUG_INFORMATION_FORMAT=dwarf-with-dsym` works.
#
# Resuming: just run it again. build-webkit drives xcodebuild, which is
# incremental, so a build interrupted at 80% picks up near 80% rather than at
# zero. Nothing is deleted between runs. That is also why there is no --clean
# here: `rm -rf $WEBKIT_SRC/WebKitBuild` is clearer than a flag that hides it.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

CONFIG=release
EXTRA=()

while (( $# )); do
    case "$1" in
        --release) CONFIG=release; shift ;;
        --debug)   CONFIG=debug;   shift ;;
        # Prints the header comment: every line after the shebang up to the
        # first line that is not a comment. A line count would drift.
        -h|--help) awk 'NR>1 && !/^#/{exit} NR>1{sub(/^# ?/,""); print}' "${BASH_SOURCE[0]}"; exit 0 ;;
        --)        shift; EXTRA=("$@"); break ;;
        *)         die "unknown argument: $1 (try --help)" ;;
    esac
done

# build-webkit names its output directory with a capital, WebKitBuild/Release.
CONFIG_DIR="$(tr '[:lower:]' '[:upper:]' <<< "${CONFIG:0:1}")${CONFIG:1}"

# --- preflight -------------------------------------------------------------
# Every check below is a failure someone would otherwise hit deep into a long
# build, when the error is buried under thousands of lines of compiler output.

[[ -x "$WEBKIT_SRC/Tools/Scripts/build-webkit" ]] || die \
    "no WebKit source at $WEBKIT_SRC
Run $WEBKIT_SCRIPT_DIR/fetch.sh first."

command -v xcode-select >/dev/null || die "the Xcode command line tools are not installed.
Run: xcode-select --install"

DEVELOPER_DIR_ACTIVE="$(xcode-select -p 2>/dev/null || true)"
[[ -n "$DEVELOPER_DIR_ACTIVE" ]] || die "xcode-select has no active developer directory.
Run: sudo xcode-select --switch /Applications/Xcode.app"

# WebKit needs the full Xcode, not the standalone command line tools: the build
# uses xcodebuild, .xcconfig files and SDKs that CommandLineTools does not ship.
[[ "$DEVELOPER_DIR_ACTIVE" == *".app/Contents/Developer" ]] || die \
    "xcode-select points at $DEVELOPER_DIR_ACTIVE, which is the standalone
command line tools. WebKit needs the full Xcode.
Install Xcode, then run: sudo xcode-select --switch /Applications/Xcode.app"

command -v xcodebuild >/dev/null || die "xcodebuild not found under $DEVELOPER_DIR_ACTIVE"

XCODE_VERSION="$(xcodebuild -version 2>/dev/null | head -1 | awk '{print $2}')" || true
[[ -n "$XCODE_VERSION" ]] || die "xcodebuild -version failed.
Usually this means the licence has not been accepted. Run: sudo xcodebuild -license"

# Xcode 26 moved the Metal compiler out of the default install into a
# separately downloaded component. WebKit compiles .metal shaders, so without
# it the build dies partway through with a metal driver error that says nothing
# about a missing download.
if (( ${XCODE_VERSION%%.*} >= 26 )); then
    if ! xcodebuild -showComponent MetalToolchain 2>/dev/null | grep -qi 'Status: *installed'; then
        die "the Metal toolchain is not installed, and Xcode $XCODE_VERSION needs it
to compile WebKit's shaders.
Run: xcodebuild -downloadComponent MetalToolchain"
    fi
fi

command -v perl >/dev/null || die "perl not found; build-webkit is a perl script"

# A release build's object files, static archives and dSYMs run to tens of GB.
# 391 GB free was the measured headroom when this was written; the floor below
# is a guess with margin rather than a measured minimum, and it is cheap to
# fail here instead of at 90% with a full disk.
require_free_gb "$WEBKIT_DIR" 100 "a WebKit $CONFIG build"

# --- build -----------------------------------------------------------------

# build-webkit honours WEBKIT_OUTPUTDIR; when unset it writes to WebKitBuild
# inside the source tree. Resolving it here means the path printed at the end
# is the path that was actually used.
OUTPUT_DIR="${WEBKIT_OUTPUTDIR:-$WEBKIT_SRC/WebKitBuild}"
export WEBKIT_OUTPUTDIR="$OUTPUT_DIR"
PRODUCTS="$OUTPUT_DIR/$CONFIG_DIR"
FRAMEWORK="$PRODUCTS/WebKit.framework"
LOG="$WEBKIT_DIR/build-$CONFIG.log"

note "tag:     $WEBKIT_TAG"
note "source:  $WEBKIT_SRC"
note "config:  $CONFIG"
note "output:  $PRODUCTS"
note "log:     $LOG"
# Not `[[ ... ]] && note ...`: under `set -e` a false test would end the script.
if [[ -d "$FRAMEWORK" ]]; then
    note "a previous build is present; this run is incremental"
fi

mkdir -p "$OUTPUT_DIR"
START=$SECONDS

# Full output to the log, a live tail to the terminal. PIPESTATUS keeps the
# exit status of build-webkit rather than of tee.
set +e
# The ${EXTRA[@]+...} guard keeps an empty array from tripping `set -u` on the
# bash 3.2 that ships with macOS.
( cd "$WEBKIT_SRC" && ./Tools/Scripts/build-webkit "--$CONFIG" ${EXTRA[@]+"${EXTRA[@]}"} ) 2>&1 | tee "$LOG"
STATUS=${PIPESTATUS[0]}
set -e

ELAPSED=$(( SECONDS - START ))

if (( STATUS != 0 )); then
    die "build-webkit failed after $(( ELAPSED / 60 ))m (exit $STATUS).
Full output: $LOG
Last lines:
$(tail -20 "$LOG" | sed 's/^/  /')
Re-running this script resumes; it does not start over."
fi

[[ -d "$FRAMEWORK" ]] || die "build-webkit reported success but there is no
WebKit.framework at $FRAMEWORK. Check $LOG."

# The XPC services are the half of WebKit that launchd spawns: the web content,
# networking and GPU processes. A framework without them loads and then fails
# to render anything, which is a miserable thing to debug later.
XPC="$FRAMEWORK/Versions/A/XPCServices"
[[ -d "$XPC" ]] || XPC="$FRAMEWORK/XPCServices"
[[ -d "$XPC" ]] || die "$FRAMEWORK has no XPCServices directory.
Without com.apple.WebKit.WebContent.xpc the framework cannot render a page."

note "built in $(( ELAPSED / 60 ))m$(( ELAPSED % 60 ))s"
echo "    framework:   $FRAMEWORK"
echo "    version:     $(/usr/bin/defaults read "$FRAMEWORK/Versions/A/Resources/Info.plist" CFBundleVersion 2>/dev/null || echo unknown)"
echo "    XPCServices: $(ls "$XPC" | tr '\n' ' ')"
echo "    size:        $(du -sh "$PRODUCTS" | cut -f1)"
echo
echo "    Run the app against it:"
echo "      ./apple/scripts/run-with-webkit.sh $PRODUCTS"
