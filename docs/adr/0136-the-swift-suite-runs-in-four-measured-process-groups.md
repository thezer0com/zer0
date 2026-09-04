# ADR-0136: The Swift suite runs in four measured process groups

- **Status:** Superseded by ADR-0137
- **Date:** 2026-09-03
- **Lock:** none — debt

## Context

ADR-0115 split the ordinary Swift suite into two processes after macOS 27 beta
5 made a sufficiently large WebKit process mesh crash-cascade. That split was
load-bearing, but its named process grew from 180 tests to 250 as the product
grew. It crossed the same scheduling cliff: 32 issues appeared across extension,
download and navigation suites whose cases complete in under four seconds when
they have a viable WebKit process.

All five affected suites passed immediately in isolation. Process composition
was the distinguishing variable: a 238-test remainder still failed in one of
three runs, and putting all 31 affected tests together passed once and failed
once. A 219-test remainder, 19 WebKit I/O tests and 12 ExtensionHost tests each
passed three consecutive runs. The test code and the assertions did not change
between those outcomes.

## Decision

The ordinary Swift suite runs in four process groups: the default main group,
the existing named remainder, WebKit I/O, and ExtensionHost. One union of the
three named filters is skipped by the main group, and each named filter is then
run exactly once. A new or renamed suite therefore falls into main rather than
between groups.

The measured groups contain 461, 219, 19 and 12 enabled tests respectively.
`SidebarLayoutTests` keeps its dedicated process, and ADR-0135 continues to run
each discovered `PageMenuTests` case in a fresh process; those solve different
AppKit scheduling and lifecycle failures.

## Consequences

The gate starts two more short Swift helpers and keeps every ordinary test in
exactly one complementary group. It does not retry a failed run, increase a
deadline over orphaned loads, or turn intermittent failure into apparent
success.

The group sizes remain empirical rather than derived. Their names describe the
failure boundaries that survived repeated execution, not a taxonomy every new
suite must join. New suites still enter main unless runtime evidence requires a
different boundary.

## How this regresses

The three named filters are merged because one process looks simpler, or main
stops skipping the same union the later processes filter. In the first case a
WebContent teardown wedges otherwise unrelated loads and fast tests burn their
deadlines. In the second case tests run twice or disappear between filters while
the gate can still print green.

No source-level test can force or observe the operating system's process-mesh
crash reliably, so this decision retains explicit debt rather than naming a
lock that proves only the spelling of a filter.

## When to revisit

Revisit the number and membership of these groups when one unfiltered `swift
test` passes three consecutive times on the supported macOS release without a
new `com.apple.WebKit.WebContent-*.ips` report. Rebalance sooner if any shared
group reproduces the same fast-in-isolation, timeout-in-group signature in two
full gate runs.
