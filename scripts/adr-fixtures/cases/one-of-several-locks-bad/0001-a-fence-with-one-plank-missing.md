# ADR-0001: A fence with one plank missing

- **Status:** Accepted
- **Date:** 2026-08-09
- **Lock:** `scripts/adr-fixtures/support/locked.rs::a_lock_that_resolves`, `scripts/adr-fixtures/support/locked.rs::a_test_that_was_renamed_away`, `scripts/adr-fixtures/support/Locked.swift::FixtureSuite/aLockThatResolves`

## Context

Three locks, the middle one rotten. Every item is resolved individually, so
this must fail exactly once and name the broken one. A checker that stopped at
the first lock, or that took a list as pass-if-any, would pass this.

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
