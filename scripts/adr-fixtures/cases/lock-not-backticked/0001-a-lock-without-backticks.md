# ADR-0001: A lock without backticks

- **Status:** Accepted
- **Date:** 2026-08-09
- **Lock:** scripts/adr-fixtures/support/locked.rs::a_lock_that_resolves

## Context

The lock resolves, and it is still refused. Only what sits inside backticks
is read as a lock, because that is the contract that lets several locks share a
line with commas as punctuation.

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
