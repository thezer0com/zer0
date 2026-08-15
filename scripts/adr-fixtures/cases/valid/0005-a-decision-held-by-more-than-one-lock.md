# ADR-0005: A decision held by more than one lock

- **Status:** Superseded by ADR-0001
- **Date:** 2026-08-09
- **Lock:** `scripts/adr-fixtures/support/locked.rs::a_lock_that_resolves`, `scripts/adr-fixtures/support/Locked.swift::FixtureSuite/aLockThatResolves`

## Context

Two locks on one line, comma separated, each in its own backticks. The
status also points at ADR-0001, which is in this directory, so the pointer
check has something valid to resolve rather than only something to reject.

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
