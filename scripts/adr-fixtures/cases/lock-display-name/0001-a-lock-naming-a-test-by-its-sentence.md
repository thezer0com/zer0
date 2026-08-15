# ADR-0001: A lock naming a test by its sentence

- **Status:** Accepted
- **Date:** 2026-08-09
- **Lock:** `scripts/adr-fixtures/support/Locked.swift::a lock that resolves`

## Context

The phrase inside `@Test("...")` really is in that file, and the shape is
refused anyway. A lock that breaks when someone rewords a sentence teaches
people to edit the record to keep the build green, which is the opposite of what
the record is for.

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
