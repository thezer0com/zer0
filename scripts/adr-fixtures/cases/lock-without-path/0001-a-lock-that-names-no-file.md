# ADR-0001: A lock that names no file

- **Status:** Accepted
- **Date:** 2026-08-09
- **Lock:** `a_lock_that_resolves`

## Context

A bare test name, no `path::`. Nobody can resolve it, and a lock nobody
can resolve is the same as no lock, minus the honesty of saying so.

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
