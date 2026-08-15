# ADR-0001: A lock naming a Swift test that never runs

- **Status:** Accepted
- **Date:** 2026-08-09
- **Lock:** `scripts/adr-fixtures/support/Locked.swift::FixtureSuite/aTestThatNeverRuns`

## Context

The method is there and carries `.disabled(if: ZER0_SHOT == nil)`. Every
screenshot harness in `apple/Tests` has that trait by design, so this is not a
hypothetical shape — it is most of the Swift test files in the repo.

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
