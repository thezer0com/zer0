# ADR-0001: A lock naming a Rust test that is gone

- **Status:** Accepted
- **Date:** 2026-08-09
- **Lock:** `scripts/adr-fixtures/support/locked.rs::a_test_that_was_renamed_away`

## Context

The file exists and the function does not. This is the single most likely
way a lock rots: a rename that looked local.

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
