# ADR-0001: A decision with no status field

- **Date:** 2026-08-09
- **Lock:** `scripts/adr-fixtures/support/locked.rs::a_lock_that_resolves`

## Context

There is no `- **Status:**` line. Without a status there is no way to tell
whether the decision still holds, and a superseded ADR reads exactly like a
live one.

## Decision

The fixture stands still so the checker can be measured against it.

## Consequences

A change to `adr-check.sh` that stops handling this case turns
`scripts/adr-fixtures.sh` red, and names this directory when it does.

## How this regresses

Someone adds a status here to make a run green, and the case is gone.

## When to revisit

Never; a record of decisions with no state is a pile of essays.
