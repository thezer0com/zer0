# ADR-0115: The Swift suite runs in two processes, and the size of each is the decision

- **Status:** Accepted
- **Date:** 2026-08-14
- **Lock:** none — debt

## Context

On 2026-08-14 at 06:02 this machine installed macOS 27.0 beta 5. Every full
`check.sh` after that failed with 53–54 issues in the same seven suites
(`DownloadEndToEndTests`, `DownloadResumeTests`, `NavigationStateTests`,
`PageProcessTests`, `NavigationRoundTripTests`, `ExtensionApiTests`,
`EnginePolicyTests`), every symptom a hang: tests that finish in under 4 s in
isolation burned their 90 s `eventually` deadlines for 181–451 s. Two full
runs produced the same numbers; every isolated or small-subset run was green.
Nothing in the repository delta had anything to do with it — measured, not
assumed: the new `VersionTests` passed in 0.289 s inside a failing run, the
Keychain migration had already completed days earlier and was a no-op, and
moving away both the 107 629-directory `swiftpm-testing-helper` WebsiteDataStore
pile and the real profile's session database changed nothing.

The wedge was in the system, and it was visible the moment the runs were
timestamped. Everything passes fast for seven seconds; then, in one second,
every WebKit load in the process stops completing for the rest of the run. In
that same second `~/Library/Logs/DiagnosticReports/` gains
`com.apple.WebKit.WebContent-*.ips` files: **a WebContent process dying with
`EXC_ARM_PAC_FAIL` inside `IPC::Connection::dispatchDidCloseAndInvalidate`** —
an Apple crash in the code that handles a sibling process's IPC teardown. Green
runs of suites that kill web content processes leave no such reports; a run
large enough leaves two, every time, at the wedge.

swift-testing starts all tests at once, so the run's WKWebView mesh
(≈55 WebContent processes at peak, one network session per identified data
store, ~355 stores per run) is as large as it can be. `PageProcessTests` kills
web content processes on purpose — that is the behaviour under test — so every
run hands the beta's crash a trigger. Whether the cascade fires is a function
of the mesh size the death lands in: 482 tests in one process stay green,
662 go red deterministically.

One repository-side defect did fall out of the bisection and is fixed
structurally rather than here: an `ExtensionHost` dropped with loaded contexts
left them in WebKit's process-wide extension machinery (background service
workers included) with no owner, and the fixture then deleted their packages
from disk. A small subset containing that suite plus the load-heavy victims
reproduced the same all-loads-hang wedge with no OS trigger needed. The host
now unloads its contexts in `deinit`.

## Decision

`scripts/check.sh` runs the Swift suite as **two `swift test` invocations in
two processes**: everything except a named list, then the named list. The list
(extension suites, split/window suites, store-install, user agent, inspector,
the `ZZ*` harnesses) is one regex held in one variable, and run one is built
as `--skip` of that same regex so **no suite can fall between the two runs** —
a new suite lands in run one by default, and run one has headroom (482 tests
green against a cliff somewhere above it and below 662).

The split is not a permanent shape. It exists because a beta OS crash-cascades
above a mesh size this suite's scheduling produces; when the OS no longer does
that (verify by running the single full `swift test` and watching
DiagnosticReports), merge the two invocations back and delete this record's
reason, keeping only the memory of why it was ever two.

## Consequences

- The gate stays fast (both processes together measured 25.8 s + 4.0 s) and
  green on the machine that develops against the beta.
- The mesh-size cliff is empirical, not derived. If run one starts flaking red
  as suites are added, the answer is to grow the second list, not to raise
  deadlines — `Eventually.swift` already documents why the deadline is capped.
- A regression that re-adds a third of the suites to one process is caught by
  the gate itself: this record's lock is the check going red again.
- The `ExtensionHost.deinit` unload is a guarantee, not a courtesy: a context
  loaded by a host must not outlive it, whatever the OS does with it.

## How this regresses

The comfortable "improvement" that undoes this is merging the two `swift test`
invocations back into one, because two of them look like clutter and the
comment above them looks like superstition. On an OS with the beta-5 crash the
gate itself goes red within ten minutes of that merge — same seven suites, same
53 issues — which is the lock in practice. On an OS without it, nothing goes
red, which is why the lock above says debt rather than naming a test: no
assertion in this repository can see a WebKit crash cascade, only the gate
running on an affected machine can.

The quieter regression is the list shrinking in meaning: if run one is ever
changed from `--skip` of the same variable run two filters, a suite with a
custom display name (the MCP and palette suites carry them) can fall between
the two runs and the gate reports green having run less than everything. The
sum of the two runs' test counts is the number to eyeball for that: 662 today.

## When to revisit

When a macOS release without the `EXC_ARM_PAC_FAIL`-
in-`dispatchDidCloseAndInvalidate` crash is installed (verify: one full
`swift test`, green, and no new `com.apple.WebKit.WebContent-*.ips` in
DiagnosticReports), merge the invocations and shrink this record to its
memory. If run one starts failing as suites are added, the cliff has moved,
not the machine: grow the second list.
