#!/usr/bin/env bash
# Checks that scripts/adr-check.sh still catches things.
#
#   ./scripts/adr-fixtures.sh
#
# The decision record is held up by one script. If that script stops resolving
# locks — a bad edit, a merge, or somebody in a hurry writing
# `resolve_lock() { return 0; }` — then every lock in the project resolves,
# `check.sh` prints "all green", and the entire mechanism is gone without a
# single red line anywhere. A checker that has been hollowed out and a checker
# that works are indistinguishable from their exit status, which is the only
# thing anyone ever looks at.
#
# So the checker gets fixtures: under scripts/adr-fixtures/cases/ there is one
# directory per rejection adr-check.sh can make, each holding an ADR that is
# valid in every respect but one. The suite runs the checker against each of
# them with ZER0_ADR_DIR and requires two things — that it fails, and that it
# fails *for the stated reason*. Weaken the checker and the fixtures it stopped
# catching go red by name.
#
# `cases/valid` is the other half, and it is not decoration: without it a
# checker that rejected everything would pass every case above and be just as
# broken in the opposite direction.
#
# The fixtures live outside docs/adr/ on purpose. A broken ADR is exactly what
# the real record must never contain, and adr-check.sh run normally never sees
# these files.
#
# What this suite does not prove: that a lock covers the decision it is written
# under. Nothing can. See scripts/adr-check.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CHECKER="./scripts/adr-check.sh"
CASES="scripts/adr-fixtures/cases"

# Every place adr-check.sh refuses something. Twenty-three of them; this suite
# has a fixture for twenty-two. The twenty-third is the "filename does not start
# with a four-digit number" branch, which the NNNN-*.md glob makes unreachable —
# it cannot be provoked from a directory, only from a call.
#
# The number is here so that adding a rejection without adding a fixture is
# noisy rather than silent. That is the failure this whole file exists to
# prevent, applied to itself.
EXPECTED_REJECTIONS=23

failures=0
checked=0
covered=""

# Set by run_checker.
checker_output=""
checker_status=0

fail() {
    printf 'error: %s\n' "$1" >&2
    failures=$(( failures + 1 ))
}

run_checker() {
    # Both streams together: some findings go to stderr and the run summary goes
    # to stdout, and a fixture may want to assert on either.
    local dir="$1"
    shift
    if checker_output="$(ZER0_ADR_DIR="$dir" "$CHECKER" "$@" 2>&1)"; then
        checker_status=0
    else
        checker_status=$?
    fi
}

# The checker must reject $1 and say $2 while doing it.
expect_rejected() {
    local name="$1" want="$2" dir="$CASES/$1"

    checked=$(( checked + 1 ))
    covered="$covered
$name"

    if [[ ! -d "$dir" ]]; then
        fail "$name: no fixture at $dir.
  This suite names a case that is not on disk. Either the fixture was deleted,
  or the name in the table is a typo."
        return
    fi

    run_checker "$dir"

    if (( checker_status == 0 )); then
        fail "$name: adr-check.sh accepted $dir.
  That directory holds a deliberately broken ADR and the checker passed it.
  Whatever just changed in scripts/adr-check.sh stopped catching:
      $want
  This is what a hollowed-out check looks like from the outside: the record is
  no longer defended and nothing else says so."
        return
    fi

    if ! printf '%s\n' "$checker_output" | grep -qF -- "$want"; then
        fail "$name: adr-check.sh rejected $dir, but not for the reason the
  fixture exists. The output had to contain:
      $want
  What it said was:
$checker_output"
    fi
}

# The checker must accept $1 and say $2 while doing it.
expect_accepted() {
    local name="$1" want="$2" dir="$CASES/$1"

    checked=$(( checked + 1 ))
    covered="$covered
$name"

    if [[ ! -d "$dir" ]]; then
        fail "$name: no fixture at $dir."
        return
    fi

    run_checker "$dir"

    if (( checker_status != 0 )); then
        fail "$name: adr-check.sh rejected $dir, which is a valid record.
  A checker that refuses good ADRs is as broken as one that accepts bad ones,
  and it fails closed, so nobody notices until they are the one blocked. It
  said:
$checker_output"
        return
    fi

    if ! printf '%s\n' "$checker_output" | grep -qF -- "$want"; then
        fail "$name: adr-check.sh accepted $dir but did not report
      $want
  What it said was:
$checker_output"
    fi
}

# --- the rejections --------------------------------------------------------

# One line per fixture: directory | the phrase the refusal has to contain,
# matched literally. The phrase is not decoration — it is what distinguishes
# "the checker caught this" from "the checker fell over for some other reason
# and the exit status happened to be right".
while IFS='|' read -r name want; do
    [[ -n "$name" ]] || continue
    expect_rejected "$name" "$want"
done <<'EOF'
missing-section|missing section "## Consequences"
empty-section|section "## When to revisit" is empty
no-lock-field|missing the `- **Lock:**` field
no-status-field|missing the `- **Status:**` field
unknown-status|status "Probably still fine" does not start with a known value
superseded-by-missing-adr|the status points at ADR-0099
title-missing|the first heading is not `# ADR-0001: ...`
number-disagrees-with-title|the file is 0001 but its title says ADR-0002
duplicate-number|number 0001 is already taken by
lock-not-backticked|is neither backticked nor the debt marker
lock-without-path|is not of the form `path::test_name`
lock-file-missing|which does not exist
lock-wrong-file-kind|which is not `.rs`, `.swift` or `.sh`
lock-test-not-in-file|has no `fn a_test_that_was_renamed_away`
lock-suite-missing|does not declare suite "SuiteThatMovedAway"
lock-method-missing|but no `func aMethodThatWasRenamedAway`
lock-shell-function-missing|has no shell function `a_check_that_was_removed`
lock-ignored-rust-test|but it is `#[ignore]`d
lock-disabled-swift-test|but the test is disabled
lock-disabled-swift-suite|but the suite is disabled
lock-display-name|`scripts/adr-fixtures/support/Locked.swift::FixtureSuite/aLockThatResolves`
lock-display-name-unknown|does not contain that phrase either
one-of-several-locks-bad|has no `fn a_test_that_was_renamed_away`
no-adrs|holds no ADRs
EOF

# --- what must still pass --------------------------------------------------

# Five ADRs covering all three lock shapes, a multi-lock line, a status that is
# a prefix and not an enum, a pointer to an ADR that exists, and one honest
# debt. The debt count is asserted because it is the number the record is
# supposed to feel pressure from: a checker that stopped counting would still
# exit zero.
expect_accepted valid "==> adr: 5 ADRs, 1 without a lock (debt)"

# --- assertions the table cannot make --------------------------------------

# A list of locks is a fence, and one plank missing has to be reported as one
# plank missing. A checker that stopped at the first lock, or that read a list
# as pass-if-any, would still fail this fixture — for the wrong reason and with
# the wrong count.
run_checker "$CASES/one-of-several-locks-bad"
if ! printf '%s\n' "$checker_output" | grep -qF -- '1 problem(s)'; then
    fail "one-of-several-locks-bad: three locks, one of them rotten, and the
  checker did not report exactly one problem. Every item on a Lock: line is
  resolved on its own. It said:
$checker_output"
fi

# A directory that is not there is not an empty record. Failing loudly here is
# what keeps a moved or renamed docs/adr from reading as a clean run.
run_checker "$CASES/there-is-no-such-directory"
if (( checker_status == 0 )); then
    fail "a missing ADR directory was accepted.
  A checker that passes when it cannot find the record passes forever the day
  someone moves it."
elif ! printf '%s\n' "$checker_output" | grep -qF -- 'there is no'; then
    fail "a missing ADR directory failed for the wrong reason:
$checker_output"
fi

# The index is generated from the files, and it is the only view of the record
# most people read. A row is asserted whole: number, title and status together,
# because an index that drops the status still looks like an index.
run_checker "$CASES/valid" --index
if (( checker_status != 0 )); then
    fail "--index failed on the valid fixtures:
$checker_output"
elif ! printf '%s\n' "$checker_output" | grep -qF -- \
    '| [0003](0003-a-decision-locked-by-a-shell-function.md) | A decision locked by a shell function | In progress — the gate enforces it, no test observes it |'; then
    fail "--index did not print the row it reads out of the fixture file.
  The index is generated, so a wrong index means the generator drifted from the
  files. It printed:
$checker_output"
fi

# --- the suite checking itself ---------------------------------------------

# A fixture on disk that nothing runs is worse than no fixture: it reads as
# coverage. This is the same failure the fixtures exist to catch, one level up.
while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    name="$(basename "$dir")"
    if ! printf '%s\n' "$covered" | grep -qxF -- "$name"; then
        fail "$name: there is a fixture at $dir that this suite never runs.
  Add it to the table in scripts/adr-fixtures.sh, or delete it."
    fi
done < <(find "$CASES" -mindepth 1 -maxdepth 1 -type d | sort)

# A fixture can only catch a rejection somebody thought to write one for. This
# counts the rejections adr-check.sh can make, so that adding one without a
# fixture is a conversation rather than a silent gap.
rejections="$(grep -c '^ *fail "' "$CHECKER")"
if (( rejections != EXPECTED_REJECTIONS )); then
    fail "scripts/adr-check.sh now refuses things in $rejections places, not $EXPECTED_REJECTIONS.
  If you added a rejection, add the fixture that proves it fires and raise
  EXPECTED_REJECTIONS in this file. If you removed one, make sure it was not
  the only thing holding a rule up, then lower the number."
fi

echo "==> adr fixtures: $checked cases"

if (( failures > 0 )); then
    printf 'error: %d fixture(s) the checker no longer handles.\n' "$failures" >&2
    exit 1
fi
