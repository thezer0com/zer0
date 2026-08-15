#!/usr/bin/env bash
# A test never names a path two tests could both mean.
#
#   ./scripts/scratch-check.sh
#
# Two tests that write to the same place do not fail where the mistake is. They
# fail on whichever one lost the race, on whichever machine happened to
# interleave them, and it reads as flakiness in code that is correct — so it
# gets rerun, goes green, and nobody learns anything. Two agents have already
# spent a session each chasing a phantom failure that was this and nothing
# else, and a fixed `/tmp` target that nothing cleans up is worse still: one
# genuine failure leaves the file behind, and every later run on that machine
# reports an escape it did not make.
#
# Three rules, all mechanical:
#
#   1. `std::env::temp_dir()` is spelled in exactly two files. Everywhere else
#      under test, ask `crate::test_support::scratch_path`, which puts the
#      process, the thread and a counter in the name.
#   2. No hard-coded path under /tmp that anything opens, creates, removes or
#      asks about — unless the name carries a uniquifier on the same line. A
#      `/tmp` string that is only ever compared is fine; it is not a place.
#   3. A Swift test folder built on `temporaryDirectory` carries a UUID. The
#      test's own label is not a uniquifier: swift-testing runs in parallel.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

failures=0

fail() {
    printf 'error: %s\n' "$1" >&2
    failures=$(( failures + 1 ))
}

# --- 1. temp_dir() lives in one place per side ------------------------------

# The two files allowed to say it, and why each is allowed:
#
#   test_support.rs — the shared helper every test goes through.
#   ffi.rs          — production. An in-memory session has no profile
#                     directory, so its extensions land in scratch; the path is
#                     unique per instance, which is the property that matters.
TEMP_DIR_ALLOWED="crates/zer0-core/src/test_support.rs
crates/zer0-core/src/ffi.rs"

while IFS= read -r hit; do
    [[ -n "$hit" ]] || continue
    file="${hit%%:*}"
    if printf '%s\n' "$TEMP_DIR_ALLOWED" | grep -qxF "$file"; then
        continue
    fi
    fail "$hit
  A raw std::env::temp_dir() names a directory every other test also means.
  Use crate::test_support::scratch_path(\"label\") instead: it puts the
  process id, the thread id and a counter in the name, so two tests, two
  threads and two runs cannot collide."
done < <(grep -rn 'env::temp_dir()' --include='*.rs' crates/ || true)

# --- 2. no hard-coded /tmp that anything touches ----------------------------

# Only lines that actually reach the filesystem. A `/tmp/...` string compared
# against a return value is a value, not a place, and flagging it would teach
# people to route around this check rather than to read it.
TOUCHES='fs::|File::open|File::create|fileURLWithPath|FileManager|create_dir|remove_dir|remove_file|\.exists\(\)|\.metadata\(\)'
# What makes a name this run's own. Present on the same line, the path is not
# shared and the rule has nothing to say about it.
UNIQUE='UUID\(|uuid|scratch_path|process::id'

while IFS= read -r hit; do
    [[ -n "$hit" ]] || continue
    line="${hit#*:*:}"
    printf '%s' "$line" | grep -qE "$TOUCHES" || continue
    printf '%s' "$line" | grep -qE "$UNIQUE" && continue
    fail "$hit
  A fixed path under /tmp is shared with every other run on this machine, and
  nothing removes it. One genuine failure leaves the file there and every run
  afterwards reads it as a failure of its own. Build the name from
  crate::test_support::scratch_path (Rust) or a UUID (Swift), and remove it."
done < <(grep -rn '/tmp' --include='*.rs' crates/ 2>/dev/null; grep -rn '/tmp' --include='*.swift' apple/Tests/ 2>/dev/null || true)

# --- 3. a Swift scratch folder carries a UUID -------------------------------

# `ZZ*` is skipped, and that is not an oversight. Those are the screenshot
# harnesses: `check.sh` already proves every case in them is gated behind
# ZER0_SHOT=1, so none of them runs beside another test, and what they write is
# meant to be *found* afterwards — a PNG at a path with a UUID in it is a PNG
# nobody opens.
#
# The path is built over two or three lines, so the uniquifier is looked for in
# the window rather than on the one line.
while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    while IFS= read -r number; do
        [[ -n "$number" ]] || continue
        window="$(sed -n "${number},$(( number + 3 ))p" "$file")"
        if ! printf '%s' "$window" | grep -q 'UUID('; then
            fail "$file:$number: a folder under temporaryDirectory with no UUID in it.
  swift-testing runs these in parallel and two runs can overlap, so a label is
  not a name of your own. Append \\(UUID().uuidString)."
        fi
    done < <(grep -n 'FileManager\.default\.temporaryDirectory\|NSTemporaryDirectory' "$file" | cut -d: -f1)
done < <(find apple/Tests -name '*.swift' ! -name 'ZZ*.swift' 2>/dev/null)

if (( failures > 0 )); then
    printf 'error: %d shared path(s) in tests.\n' "$failures" >&2
    exit 1
fi

echo "==> scratch: no test names a shared path"
