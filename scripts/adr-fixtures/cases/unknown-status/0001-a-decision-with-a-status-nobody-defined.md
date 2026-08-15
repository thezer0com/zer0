# ADR-0001: A decision with a status nobody defined

- **Status:** Probably still fine
- **Date:** 2026-08-09
- **Lock:** `scripts/adr-fixtures/support/locked.rs::a_lock_that_resolves`

## Context

The status has to *start* with a known value. Free text after it is
welcome and carries facts no enum can, but the first word is a contract.

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
