# ADR-0135: Engine-built menu tests run one case per process

- **Status:** Accepted
- **Date:** 2026-09-02
- **Lock:** `scripts/check.sh::run_page_menu_tests`

## Context

`PageMenuTests` opens the real context menu WebKit builds out of process. On
macOS 27, cancelling that menu synchronously from `willOpenMenu` can happen
before AppKit enters its tracking loop and leave the helper blocked forever.
Scheduling cancellation in the tracking run loop and waiting for the same
`PageView`'s `didCloseMenu` callback closes each gesture correctly, including
twelve repeated gestures inside one test.

The suite still cannot carry all nine test cases in one helper. Measured after
the lifecycle fix: eight cases pass, the ninth starts, then Swift Testing's
async entry point returns without a result, run summary or xUnit file. The same
ninth case passes in 0.374 seconds in a fresh helper. The screenshot harness had
already measured the same process boundary from the other direction: a second
engine-built menu may be swallowed while a prior AppKit menu session still owns
process state.

ADR-0115's two shared Swift processes solve a different system failure: a
WebKit process-mesh crash above a measured suite size. Moving this suite between
those two lists cannot give each context-menu case a clean AppKit process.

## Decision

The two shared Swift runs continue to cover every ordinary test as ADR-0115
specifies. `PageMenuTests` is excluded from both shared runs and each of its
cases runs through a separate `swift test` invocation.

The gate discovers those cases from `swift test list` using the fully qualified
suite name. It does not carry a second hand-written list of methods, and it
fails closed if discovery finds none. A newly added menu case therefore enters
the isolated run automatically.

Inside each case, the test view schedules cancellation for the exact `NSMenu`
that opened and treats `didCloseMenu` on that same view as the completion
barrier. A timer firing or a process returning zero without a test summary is
not completion evidence.

## Consequences

The nine menu cases pay nine short helper launches instead of sharing one. That
cost is bounded and honest; it replaces an unbounded hang and prevents a green
exit without a recorded result.

The gate has more than the two shared Swift processes named by ADR-0115, but
the mesh-size decision and its two complementary filters are unchanged. The
extra helpers exist only for the AppKit tracking lifecycle that cannot be reset
inside a process.

## How this regresses

`PageMenuTests` is put back into either shared filter because one invocation
looks simpler. The gate reaches the final case and exits or hangs without a
summary, so some context-menu behaviour is never recorded despite an apparent
zero exit. Or the discovered cases are replaced with a manual method list and
a new test is silently omitted.

The lock names the one runner that discovers every current case, refuses an
empty discovery and starts a fresh helper for each result.

## When to revisit

Revisit when one unfiltered `swift test --filter Zer0ShellTests.PageMenuTests`
records all cases, prints its suite and run summaries, writes a complete xUnit
file, and does so in three consecutive runs on the supported macOS release.
Passing individual cases is not evidence that the process boundary is gone.
