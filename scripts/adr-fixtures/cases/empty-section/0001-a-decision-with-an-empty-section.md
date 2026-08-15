# ADR-0001: A decision with an empty section

- **Status:** Accepted
- **Date:** 2026-08-09
- **Lock:** `scripts/adr-fixtures/support/locked.rs::a_lock_that_resolves`

## Context

Valid but for `## When to revisit`, which is present and holds nothing but a
line of spaces. An empty section is worse than a missing one: it looks decided
and is not, and a body test written as `grep -q .` would pass this.

## Decision

The fixture stands still so the checker can be measured against it.

## Consequences

A change to `adr-check.sh` that stops handling this case turns
`scripts/adr-fixtures.sh` red, and names this directory when it does.

## How this regresses

The whitespace below is deliberate. Do not tidy it.

## When to revisit

   
