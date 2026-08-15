# ADR-0001: A decision missing a section

- **Status:** Accepted
- **Date:** 2026-08-09
- **Lock:** `scripts/adr-fixtures/support/locked.rs::a_lock_that_resolves`

## Context

Valid but for the missing `## Consequences`, removed below. All five
sections are mandatory; a record that can drop one drops the two that pay.

## Decision

The fixture stands still so the checker can be measured against it.

## How this regresses

Someone edits this file to make a run green. Then the fixture stops describing
the case it was written for, and the checker loses its only witness.

## When to revisit

When the rule this fixture pins is deliberately dropped from the checker.
