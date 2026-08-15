#!/usr/bin/env bash
# Checks that every ADR in docs/adr is still a decision record and not prose.
#
#   ./scripts/adr-check.sh            # validate; non-zero if anything is wrong
#   ./scripts/adr-check.sh --index    # print the index, derived from the files
#
# An ADR is only worth writing if it stays true, and what keeps it true is the
# `Lock:` field: the test that goes red when someone undoes the decision. This
# script exists so a lock pointing at a test that no longer exists fails here,
# at the gate, instead of quietly becoming a lie in a file nobody opens.
#
# What is checked, per file:
#   - the five mandatory sections are present and none is empty;
#   - there is a `**Lock:**` field;
#   - every lock resolves: the file exists, the test name is really in it, and
#     that test actually runs — `#[ignore]` and `.disabled(…)` are refused;
#   - the ADR number is unique and matches the title;
#   - a `Superseded by ADR-XXXX` status points at an ADR that exists.
#
# The checker has its own fixtures, in scripts/adr-fixtures/: one broken ADR per
# rejection this script can make, plus a valid one. `scripts/adr-fixtures.sh`
# runs them and goes red when this script stops catching something — which is
# what a hollowed-out `resolve_lock` looks like from the outside.
#
# Debt is not an error. `none — debt` is the honest way to say "no test covers
# this yet"; the count is printed on every run so it stays in sight instead of
# hiding behind a flag.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Overridable so the checker itself can be run against a fixture directory.
# Lock paths are always resolved from the repo root, whatever this points at.
ADR_DIR="${ZER0_ADR_DIR:-docs/adr}"

# Written the same way in every ADR, em dash included. Compared literally, so a
# variant spelling fails instead of silently passing as debt.
DEBT_MARKER="none — debt"

MANDATORY_SECTIONS="Context
Decision
Consequences
How this regresses
When to revisit"

failures=0
total=0
debts=0

# Accumulated across files so a duplicate number is reported naming both files.
seen_numbers=""

fail() {
    printf 'error: %s\n' "$1" >&2
    failures=$(( failures + 1 ))
}

adr_files() {
    # nullglob so an empty directory yields nothing rather than the pattern.
    shopt -s nullglob
    local files=("$ADR_DIR"/[0-9][0-9][0-9][0-9]-*.md)
    shopt -u nullglob
    printf '%s\n' ${files[@]+"${files[@]}"}
}

adr_field() {
    # The value of `- **Name:** value`, first occurrence only.
    local file="$1" name="$2" line
    line="$(grep -m1 "^- \*\*$name:\*\*" "$file" || true)"
    [[ -n "$line" ]] || return 1
    printf '%s\n' "${line#- \*\*"$name":\*\* }"
}

# --- index -----------------------------------------------------------------

# Derived from the files, never maintained by hand: a hand-written index is
# wrong the moment a file is renamed, and an index that lies is worse than no
# index at all.
print_index() {
    local file number title status
    printf '| ADR | Title | Status |\n'
    printf '| --- | --- | --- |\n'
    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        number="$(basename "$file" | cut -c1-4)"
        title="$(sed -n 's/^# ADR-[0-9]\{4\}: *//p' "$file" | head -1)"
        status="$(adr_field "$file" Status || echo '(no status)')"
        printf '| [%s](%s) | %s | %s |\n' \
            "$number" "$(basename "$file")" "${title:-(no title)}" "$status"
    done < <(adr_files)
}

# --- section presence ------------------------------------------------------

# A section is present when its `## ` heading exists, and non-empty when there
# is at least one line with content before the next `## ` heading. A `### `
# subheading counts as content: several ADRs open a section with one.
section_body() {
    local file="$1" heading="$2"
    awk -v want="## $heading" '
        $0 == want { inside = 1; next }
        inside && /^## / { exit }
        inside { print }
    ' "$file"
}

check_sections() {
    local file="$1" heading body
    while IFS= read -r heading; do
        if ! grep -qxF "## $heading" "$file"; then
            fail "$file: missing section \"## $heading\".
  Every ADR carries all five: Context, Decision, Consequences, How this
  regresses, When to revisit. Add the missing one."
            continue
        fi
        body="$(section_body "$file" "$heading")"
        # `grep -q .` alone would match a line of spaces.
        if ! printf '%s\n' "$body" | grep -q '[^[:space:]]'; then
            fail "$file: section \"## $heading\" is empty.
  An empty section is worse than a missing one: it looks decided and is not.
  Write the content, or drop the decision from the record."
        fi
    done <<EOF
$MANDATORY_SECTIONS
EOF
}

# --- lock resolution -------------------------------------------------------

# The three shapes a lock may take, all of them after `path::`:
#
#   crates/zer0-core/src/shortcuts.rs::every_command_is_still_reachable...
#       a Rust `#[test] fn`, in a `_tests.rs` file or an inline `mod tests`.
#
#   apple/Tests/.../ShortcutTests.swift::ShortcutTests/everyBoundCommandIsHandled
#       swift-testing suite type + the func carrying the `@Test`.
#
#   scripts/adr-check.sh::resolve_lock
#       a shell function in a script the gate runs. Not every decision the gate
#       enforces is enforced by a test — some are enforced by a script, and
#       this one is enforced by this script. A decision held by a shell check
#       can name that check rather than claim a test it does not have.
#
# A fourth shape used to be accepted and no longer is: the display name inside
# `@Test("...")`. It breaks when someone rewords a sentence, which is a change
# with no behavioural meaning, and a lock that reddens for prose teaches people
# to edit the record to get the build green — the exact habit the record cannot
# survive. `Suite/methodName` says the same thing and outlives the wording, so
# the display-name form is refused and the replacement is printed with the
# refusal.
#
# A shape that is none of these is rejected rather than assumed good: a lock
# nobody can resolve is the same as no lock, minus the honesty of saying so.

# The line number of the first match, empty when there is none. `|| true`
# because a lock that does not resolve is a finding, not a crash.
line_matching() {
    grep -nE "$2" "$1" | head -1 | cut -d: -f1 || true
}

# Whether the declaration on line $2 carries `#[ignore]` (Rust) or a
# `.disabled(…)` trait (swift-testing).
#
# Both leave the name in the file — enough to satisfy "the test name is really
# in it" — while the test never executes, and a test that cannot go red defends
# nothing. This is not a corner case in this repo: every screenshot harness in
# apple/Tests is `.disabled(if: ZER0_SHOT == nil)` because check.sh insists on
# it, so without this an ADR could name one and read as locked forever.
#
# Both walk backwards from the declaration through the block of attributes above
# it, and stop at the first line that is neither an attribute nor a comment —
# `@Test(` and `@Suite(` are routinely spread over several lines with the trait
# on one of its own.
rust_declaration_is_ignored() {
    awk -v n="$2" '
        NR < n { line[NR] = $0 }
        END {
            for (i = n - 1; i >= 1; i--) {
                if (line[i] ~ /^[[:space:]]*#\[[[:space:]]*ignore/) exit 0
                if (line[i] ~ /^[[:space:]]*(#\[|\/\/)/) continue
                exit 1
            }
            exit 1
        }
    ' "$1"
}

swift_declaration_is_disabled() {
    awk -v n="$2" '
        NR < n { line[NR] = $0 }
        END {
            for (i = n - 1; i >= 1; i--) {
                # Checked before the stop conditions: the single-line form
                # `@Test("x", .disabled(…))` is both at once.
                if (index(line[i], ".disabled(") > 0) exit 0
                if (line[i] ~ /^[[:space:]]*$/) exit 1
                if (line[i] ~ /^[[:space:]]*@/) exit 1
                if (line[i] ~ /[{}][[:space:]]*$/) exit 1
            }
            exit 1
        }
    ' "$1"
}

# `Suite/methodName` for a test written as a display name, so refusing that
# shape can hand back the replacement instead of only saying no. Empty when the
# phrase is nowhere in the file, or is not followed by a func.
swift_stable_form_for() {
    awk -v want="$2" '
        match($0, /(struct|class|enum|actor)[[:space:]]+[A-Za-z0-9_]+/) {
            suite = substr($0, RSTART, RLENGTH)
            sub(/^[A-Za-z]+[[:space:]]+/, "", suite)
        }
        # Fixed-string, never a regex: these phrases carry ⌘, apostrophes and
        # commas, and one of them is a pattern by accident sooner or later.
        index($0, "\"" want "\"") > 0 { armed = 1 }
        armed && match($0, /func[[:space:]]+[A-Za-z0-9_]+/) {
            method = substr($0, RSTART, RLENGTH)
            sub(/^func[[:space:]]+/, "", method)
            if (suite != "") print suite "/" method
            exit
        }
    ' "$1"
}

resolve_lock() {
    local file="$1" spec="$2" path name suite method escaped
    local at suite_at method_at stable

    path="${spec%%::*}"
    name="${spec#*::}"

    if [[ "$path" == "$spec" || -z "$name" ]]; then
        fail "$file: lock \"$spec\" is not of the form \`path::test_name\`.
  Use \`crates/.../file.rs::fn_name\`, or
  \`apple/Tests/.../File.swift::Suite/methodName\`, or
  \`scripts/some-gate.sh::function_name\`."
        return
    fi

    if [[ ! -f "$path" ]]; then
        fail "$file: the lock points at \"$path\", which does not exist.
  Either the test file moved and the lock stayed behind, or the decision lost
  its cover. Point at the new path, or set the field to \"$DEBT_MARKER\" and
  own the debt."
        return
    fi

    case "$path" in
        *.rs)
            # The trailing `(` keeps `fn foo` from matching `fn foo_bar`.
            escaped="$(printf '%s' "$name" | sed 's/[][\.*^$\/]/\\&/g')"
            at="$(line_matching "$path" "fn[[:space:]]+${escaped}[[:space:]]*\(")"
            if [[ -z "$at" ]]; then
                fail "$file: \"$path\" has no \`fn $name\`.
  The test was renamed or deleted. Point the lock at the current name, or
  write the test back — until then the decision is uncovered."
                return
            fi
            if rust_declaration_is_ignored "$path" "$at"; then
                fail "$file: \"$path\" has \`fn $name\`, but it is \`#[ignore]\`d.
  An ignored test never runs, so it never goes red, so it defends nothing —
  the ADR reads as locked and is not. Point the lock at a test that runs, take
  the \`#[ignore]\` off, or set the field to \"$DEBT_MARKER\"."
                return
            fi
            ;;
        *.swift)
            if [[ "$name" == */* ]]; then
                suite="${name%%/*}"
                method="${name#*/}"
                # Suites here are `struct X {`; the other forms are accepted so
                # the check survives a rewrite of the test layer.
                suite_at="$(line_matching "$path" "(struct|final class|class|enum)[[:space:]]+$suite\b")"
                if [[ -z "$suite_at" ]]; then
                    fail "$file: \"$path\" does not declare suite \"$suite\".
  The lock \"$name\" names a suite that is not in that file. Check whether
  the suite was renamed or moved to another file."
                    return
                fi
                method_at="$(line_matching "$path" "func[[:space:]]+${method}[[:space:]]*\(")"
                if [[ -z "$method_at" ]]; then
                    fail "$file: \"$path\" has suite \"$suite\" but no \`func $method\`.
  Point the lock at the method's current name, or write the test back."
                    return
                fi
                if swift_declaration_is_disabled "$path" "$method_at"; then
                    fail "$file: \"$path\" has \`func $method\`, but the test is disabled.
  A \`.disabled(…)\` test runs only when someone opts in — every screenshot
  harness in this repo is disabled that way — so it never goes red and defends
  nothing. Point the lock at a test that runs by default, or set the field to
  \"$DEBT_MARKER\"."
                    return
                fi
                if swift_declaration_is_disabled "$path" "$suite_at"; then
                    fail "$file: \"$path\" has \`$suite/$method\`, but the suite is disabled.
  Disabling the suite disables every test in it, so this one never runs and
  never goes red. Point the lock at a suite that runs by default, or set the
  field to \"$DEBT_MARKER\"."
                    return
                fi
                return
            fi
            # The display-name shape, refused rather than resolved. Matched as a
            # fixed string — ⌘ and apostrophes included — only to find the
            # replacement worth printing.
            stable="$(swift_stable_form_for "$path" "$name")"
            if [[ -n "$stable" ]]; then
                fail "$file: lock \"$name\" names a test by the phrase inside \`@Test(\"...\")\`.
  That shape is no longer accepted: rewording the phrase breaks the lock for a
  change with no behavioural meaning, and a lock that reddens for prose gets
  fixed by editing the record. Write it as:
      \`$path::$stable\`"
            else
                fail "$file: lock \"$name\" names a test by the phrase inside \`@Test(\"...\")\`,
  and \"$path\" does not contain that phrase either. That shape is no longer
  accepted — a Swift lock names its suite and its method:
      \`$path::Suite/methodName\`"
            fi
            ;;
        *.sh)
            # `name()` — the shape bash uses for a function definition.
            if grep -qE "^[[:space:]]*${name}[[:space:]]*\(\)" "$path"; then
                return
            fi
            fail "$file: \"$path\" has no shell function \`$name\`.
  The check that held this decision was renamed or removed. Point at the
  current function, or declare \"$DEBT_MARKER\"."
            ;;
        *)
            fail "$file: the lock points at \"$path\", which is not \`.rs\`, \`.swift\` or \`.sh\`.
  A lock is something the gate runs: a Rust test, a Swift test, or a check
  in a shell script. Point at one of those, or declare \"$DEBT_MARKER\"."
            ;;
    esac
}

check_lock() {
    local file="$1" value spec

    if ! value="$(adr_field "$file" Lock)"; then
        fail "$file: missing the \`- **Lock:**\` field.
  Every ADR names the test that breaks if the decision is undone. When no
  test is possible yet, the field says so:
      - **Lock:** $DEBT_MARKER"
        return
    fi

    if [[ "$value" == "$DEBT_MARKER" ]]; then
        debts=$(( debts + 1 ))
        return
    fi

    if [[ "$value" != *'`'* ]]; then
        fail "$file: lock \"$value\" is neither backticked nor the debt marker.
  Write \`path/file.rs::test_name\` in backticks, or declare \"$DEBT_MARKER\"."
        return
    fi

    # One decision can be held by several tests, listed comma-separated. Only
    # what sits inside backticks is a lock; the commas are punctuation. tr puts
    # each backtick-delimited run on its own line so the bash 3.2 that ships
    # with macOS can loop over them without arrays of arrays.
    while IFS= read -r spec; do
        [[ -n "$spec" ]] || continue
        resolve_lock "$file" "$spec"
    done < <(printf '%s\n' "$value" | tr '`' '\n' | awk 'NR % 2 == 0')
}

# --- number and status -----------------------------------------------------

check_number() {
    local file="$1" number title_number previous

    number="$(basename "$file" | sed -n 's/^\([0-9][0-9][0-9][0-9]\)-.*\.md$/\1/p')"
    if [[ -z "$number" ]]; then
        fail "$file: the filename does not start with a four-digit number.
  Use \`NNNN-affirmative-title-in-kebab-case.md\`."
        return
    fi

    title_number="$(sed -n 's/^# ADR-\([0-9][0-9][0-9][0-9]\):.*/\1/p' "$file" | head -1)"
    if [[ -z "$title_number" ]]; then
        fail "$file: the first heading is not \`# ADR-$number: ...\`.
  The title carries the number and what was decided, stated affirmatively."
    elif [[ "$title_number" != "$number" ]]; then
        fail "$file: the file is $number but its title says ADR-$title_number.
  One of the two is wrong. Rename the file, or fix the title."
    fi

    previous="$(printf '%s\n' "$seen_numbers" | sed -n "s|^$number ||p")"
    if [[ -n "$previous" ]]; then
        fail "$file: number $number is already taken by \"$previous\".
  Two ADRs sharing a number break every cross-reference. Renumber the newer
  one to the next free slot in its range."
    else
        seen_numbers="$seen_numbers
$number $file"
    fi
}

check_status() {
    local file="$1" value target

    if ! value="$(adr_field "$file" Status)"; then
        fail "$file: missing the \`- **Status:**\` field.
  Without a status there is no way to tell whether the decision still holds."
        return
    fi

    # The line must *start* with a known value, and everything after it is free
    # text. That is not laxness: "Accepted, and already partly superseded by
    # ADR-0005" carries a fact that no enum value can, and flattening it to
    # "Accepted" would throw away the only part worth reading.
    case "$value" in
        Accepted*|"In progress"*|"Superseded by"*|Revoked*) ;;
        *)
            fail "$file: status \"$value\" does not start with a known value.
  Begin with Accepted, In progress, Superseded by, or Revoked. Anything after
  that is free text: \"Accepted, and already partly superseded by ADR-0005\"
  is a legitimate status."
            ;;
    esac

    # Any ADR named in the status must exist, wherever in the line it appears —
    # a superseding pointer is most of the time, but a dangling reference is how
    # a history stops being followable no matter which verb introduced it.
    while IFS= read -r target; do
        [[ -n "$target" ]] || continue
        if ! ls "$ADR_DIR/$target-"*.md >/dev/null 2>&1; then
            fail "$file: the status points at ADR-$target, which is not in $ADR_DIR.
  Write the ADR that supersedes this one, or fix the number."
        fi
    done < <(printf '%s\n' "$value" | grep -oE 'ADR-[0-9]{4}' | sed 's/^ADR-//')
}

# --- run -------------------------------------------------------------------

case "${1-}" in
    --index) ;;
    -h|--help)
        # Prints the header comment: every line after the shebang up to the
        # first line that is not a comment. A line count would drift.
        awk 'NR>1 && !/^#/{exit} NR>1{sub(/^# ?/,""); print}' "${BASH_SOURCE[0]}"
        exit 0
        ;;
    "") ;;
    *) printf 'error: unknown argument: %s (try --help)\n' "$1" >&2; exit 1 ;;
esac

[[ -d "$ADR_DIR" ]] || {
    printf 'error: there is no %s in this repo.\n' "$ADR_DIR" >&2
    exit 1
}

files_found="$(adr_files)"
if [[ -z "$files_found" ]]; then
    printf 'error: %s holds no ADRs (expected NNNN-title.md).\n' "$ADR_DIR" >&2
    exit 1
fi

if [[ "${1-}" == "--index" ]]; then
    print_index
    exit 0
fi

while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    total=$(( total + 1 ))
    check_number "$file"
    check_status "$file"
    check_sections "$file"
    check_lock "$file"
done <<EOF
$files_found
EOF

# Printed on every run, green or red. A debt count that is visible every day
# gets paid down; one you have to ask for does not.
echo "==> adr: $total ADRs, $debts without a lock (debt)"

if (( failures > 0 )); then
    printf 'error: %d problem(s) in the decision record.\n' "$failures" >&2
    exit 1
fi
