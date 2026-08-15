# A decision whose heading is not a title

- **Status:** Accepted
- **Date:** 2026-08-09
- **Lock:** `scripts/adr-fixtures/support/locked.rs::a_lock_that_resolves`

## Context

The first heading does not carry `ADR-0001`. The number lives in two places on
purpose, and a heading that drops it is a file whose identity depends entirely
on never being renamed.

## Decision

The fixture stands still so the checker can be measured against it.

## Consequences

A change to `adr-check.sh` that stops handling this case turns
`scripts/adr-fixtures.sh` red, and names this directory when it does.

## How this regresses

Someone puts the number back to make a run green, and the case is gone.

## When to revisit

When the number stops being part of the title.
