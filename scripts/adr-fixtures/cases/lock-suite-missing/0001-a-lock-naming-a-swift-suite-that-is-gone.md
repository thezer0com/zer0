# ADR-0001: A lock naming a Swift suite that is gone

- **Status:** Accepted
- **Date:** 2026-08-09
- **Lock:** `scripts/adr-fixtures/support/Locked.swift::SuiteThatMovedAway/aLockThatResolves`

## Context

The method name exists in that file; the suite does not. Checking only the
method would pass this, and the lock would be pointing at a test in a suite
somebody split out months ago.

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
