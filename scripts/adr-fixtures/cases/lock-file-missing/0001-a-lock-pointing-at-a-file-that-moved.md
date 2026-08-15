# ADR-0001: A lock pointing at a file that moved

- **Status:** Accepted
- **Date:** 2026-08-09
- **Lock:** `scripts/adr-fixtures/support/moved-away.rs::a_lock_that_resolves`

## Context

The file is gone. Either the test moved and the lock stayed behind, or the
decision lost its cover; both are worth hearing about at the moment they become
true rather than six months later.

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
