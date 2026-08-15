# ADR-0004: A decision that owns its debt

- **Status:** Accepted
- **Date:** 2026-08-09
- **Lock:** none — debt

## Context

`none — debt` is honest and is not an error. This fixture is why the suite
asserts the printed debt count and not only the exit status: a checker that
counted debt wrong, or stopped counting, would still exit zero.

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
