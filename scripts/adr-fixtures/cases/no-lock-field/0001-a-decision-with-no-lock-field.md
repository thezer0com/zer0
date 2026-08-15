# ADR-0001: A decision with no lock field

- **Status:** Accepted
- **Date:** 2026-08-09

## Context

There is no `- **Lock:**` line at all. This is the state every ADR in the record
was in before the checker existed: well argued, and defending nothing.

## Decision

The fixture stands still so the checker can be measured against it.

## Consequences

A change to `adr-check.sh` that stops handling this case turns
`scripts/adr-fixtures.sh` red, and names this directory when it does.

## How this regresses

Someone adds a `Lock:` line here to make a run green, and the case is gone.

## When to revisit

When a `Lock:` field stops being mandatory, which would end the mechanism.
