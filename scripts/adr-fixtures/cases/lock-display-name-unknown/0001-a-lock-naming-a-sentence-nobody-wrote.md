# ADR-0001: A lock naming a sentence nobody wrote

- **Status:** Accepted
- **Date:** 2026-08-09
- **Lock:** `scripts/adr-fixtures/support/Locked.swift::a sentence that was reworded away`

## Context

The display-name shape again, this time with a phrase that is not in the file —
which is what the shape looks like the morning after somebody improved the
wording. The refusal cannot suggest a replacement here, so it has to say the
shape is gone and what to write instead.

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
