# ADR-0001: A lock naming a Rust test that never runs

- **Status:** Accepted
- **Date:** 2026-08-09
- **Lock:** `scripts/adr-fixtures/support/locked.rs::a_test_that_never_runs`

## Context

The function is there and it is `#[ignore]`d. It satisfies "the name is
really in it" and can never go red, so the ADR reads as defended and is not.

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
