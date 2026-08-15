# ADR-0003: A decision locked by a shell function

- **Status:** In progress — the gate enforces it, no test observes it
- **Date:** 2026-08-09
- **Lock:** `scripts/adr-fixtures/support/gate.sh::a_check_that_resolves`

## Context

Not every decision the gate enforces is enforced by a test. A decision held
by a shell check names that check rather than claiming a test it does not have.
This also pins that `Status:` is a prefix and not an enum: everything after
`In progress` is free text.

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
