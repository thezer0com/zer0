# ADR-0137: The Swift suite runs in eleven measured process groups

- **Status:** Accepted
- **Date:** 2026-09-03
- **Lock:** none — debt

## Context

ADR-0136 kept every test green by splitting the ordinary Swift suite into four
processes. Its 461-test main process nevertheless left two
`com.apple.WebKit.WebContent` crash reports after exiting. Both were
`EXC_ARM_PAC_FAIL` failures in
`IPC::Connection::dispatchDidCloseAndInvalidate`, with the SwiftPM testing
helper named as the responsible process. A green test result was therefore not
evidence of a clean WebKit lifecycle.

The crash did not belong to one test. `PageProcessTests`, every individually
discovered `PageMenuTests` case, WebKit I/O and ExtensionHost all remained clean
in their own processes. Removing `PageProcessTests` from main still produced
the reports. Exact groups of 34, 40, 42, 47, 71, 74, 87 and 89 tests remained
clean, while measured recombinations of 74, 89, 145, 176, 285, 372 and 461 tests
produced one or two reports.

The investigation also exposed that the existing filters matched substrings
anywhere in a test identifier. `SettingsTests`, for example, matched methods in
`ChatSettingsTests`. That could split one suite across processes while the gate
still printed green.

## Decision

The ordinary Swift suite runs in eleven process groups: the default main group,
the three groups retained from ADR-0136, and seven groups split from the former
main process. Every group filter is anchored to the complete target and suite
prefix. A named suite therefore runs wholly in one process, and a new or renamed
suite falls into main.

The seven added groups are the measured 47-test AppKit-state group, 42-test page
surface group, 87-test WebKit-runtime group, 89-test chat-and-identity group,
74-test input-and-downloads group, 71-test MCP-runtime group and 34-test
persistence-and-trust group. Main retains the remaining 40 enabled tests.
`SidebarLayoutTests` and the individually discovered `PageMenuTests` cases keep
their dedicated lifecycle rules.

## Consequences

The gate starts seven more short Swift helpers. It trades process startup time
for a clean WebKit lifecycle and keeps the default group small enough for new
suites to enter without immediately returning to the measured cliff.

The names are readable handles for measured boundaries, not a claim that the
operating-system failure follows product domains. Combining independently clean
groups can reproduce the crash even when the combined test count is small.

## How this regresses

Two groups are merged because each passes alone, or suite-prefix anchors are
removed because substring filters look shorter. The tests can all pass while
WebKit leaves a PAC-failure report behind, or one suite can be silently divided
between helpers and lose the lifecycle isolation this decision exists to give
it.

No source-level test can force or observe the operating system's delayed crash
report reliably, so this decision retains explicit debt. Its process boundaries
were verified by executing the real Swift test surface and inspecting macOS
DiagnosticReports after teardown.

## When to revisit

Revisit the number and membership of these groups when one unfiltered `swift
test` passes three consecutive times on the supported macOS release without a
new `com.apple.WebKit.WebContent-*.ips` report. Rebalance sooner if any shared
group produces a new report in two full gate runs.
