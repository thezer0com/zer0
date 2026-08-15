// Lock targets for the adr-check fixtures. Not part of the Zer0Shell test
// target: it sits outside `apple/`, so `swift build` never sees it and nobody
// ever has a reason to rename what is in here.
//
// The disabled cases mirror the real screenshot harnesses in
// `apple/Tests/ZZ*.swift`, which are all `.disabled(if: ZER0_SHOT == nil)` and
// therefore never run on an ordinary `swift test`. A lock is allowed to name a
// test; it is not allowed to name one that never runs.

import Foundation
import Testing

struct FixtureSuite {
    /// The happy path: a lock naming `FixtureSuite/aLockThatResolves` resolves.
    @Test("a lock that resolves")
    func aLockThatResolves() async throws {
        #expect(1 + 1 == 2)
    }

    /// Present in the file, disabled unless someone opts in — the shape every
    /// screenshot harness in this repo has.
    @Test(
        "a test that only runs when someone asks for it",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    func aTestThatNeverRuns() async throws {
        #expect(1 + 1 == 2)
    }
}

/// A suite disabled as a whole. Every method inside it is live-looking and dead,
/// which is the same hole one level up.
@Suite(.disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil))
struct DisabledFixtureSuite {
    @Test("a lock that resolves inside a suite that never runs")
    func aLockThatResolves() async throws {
        #expect(1 + 1 == 2)
    }
}
