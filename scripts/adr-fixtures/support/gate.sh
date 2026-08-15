#!/usr/bin/env bash
# A lock target for the adr-check fixtures: the shell-function shape, which is
# how a decision enforced by a gate script rather than by a test names its cover.
#
# Nothing sources or runs this file. It exists to be pointed at, which is exactly
# what `adr-check.sh` resolves a `.sh` lock against.

# Named by scripts/adr-fixtures/cases/valid/0003-*.md.
a_check_that_resolves() {
    return 0
}
