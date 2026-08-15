# ADR-0001: A lock naming a shell function that is gone

- **Status:** Accepted
- **Date:** 2026-08-09
- **Lock:** `scripts/adr-fixtures/support/gate.sh::a_check_that_was_removed`

## Context

The shell shape has to rot as loudly as the others. This is the shape
ADR-0032 uses for itself, so a checker that resolved `.sh` locks loosely would
be loosest exactly where the mechanism defends itself.

## Decision

The fixture stands still so the checker can be measured against it.

## Consequences

A change to `adr-check.sh` that stops handling this case turns
`scripts/adr-fixtures.sh` red, and names this directory when it does.

## How this regresses

Someone edits this file to make a run green. Then the fixture stops describing
the case it was written for, and the checker loses its only witness.

## When to revisit

When the rule this fixture pins is deliberately dropped from the checker.
