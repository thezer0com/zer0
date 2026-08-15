import Foundation
import Testing
@testable import Zer0Shell

/// The two channels a build can ship as — stable and canary — each carry a
/// different bundle id, so a person who installs both gets two profiles, two
/// 1Password enrolments and two update feeds rather than one app that pretends
/// to be two (ADR-0109).
///
/// The id mapping lives at one door: `apple/scripts/resolve-bundle.sh`. Every
/// script that wraps, signs or embeds into the `.app` reads it from there, and
/// this test reads it from there too — by running the script. That is the
/// shape the ADR's lock names (`build_bundle_id_parametrized`), and the shape
/// that catches the regression the ADR warns about: a typo that produces a
/// `.app` running as the wrong channel, weeks from being noticed.
///
/// Running the real script rather than re-deriving the mapping in Swift is
/// deliberate. A second implementation drifts from the first; the lock here
/// defends against the mapping the scripts actually use, not the mapping the
/// test wishes they did.
@Suite struct BundleIdTests {
    /// Where this test file lives, lifted two directories to reach `apple/`.
    /// `Package.swift` knows the test target's path; a test does not, so this
    /// walks the file path the compiler hands it through the same layout.
    private static let appleRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Zer0ShellTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // apple

    private static let resolver = appleRoot
        .appendingPathComponent("scripts/resolve-bundle.sh").path

    /// Runs `resolve-bundle.sh <channel>` and returns the value of `KEY=` for
    /// the requested key. The script is the source of truth; this test is its
    /// mirror, so reading the printed lines keeps the two from disagreeing
    /// silently.
    private static func resolve(_ channel: String, key: String) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [resolver, channel]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        try task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0] == key else { continue }
            return String(parts[1])
        }
        throw NSError(
            domain: "BundleIdTests", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "no \(key) in resolve-bundle.sh output:\n\(output)"]
        )
    }

    @Test
    func theStableBundleHasTheStableIdAndTheCanaryHasTheCanaryId() throws {
        // Self. is forced: swift-testing's `#expect` macro carries its own
        // `resolve(_:_:)` overload, and an unqualified call resolves to that
        // rather than to the helper below.
        #expect(try Self.resolve("stable", key: "BUNDLE_ID") == "com.thezer0.browser",
                "ZER0_CHANNEL=stable must produce com.thezer0.browser")
        #expect(try Self.resolve("canary", key: "BUNDLE_ID") == "com.thezer0.canary",
                "ZER0_CHANNEL=canary must produce com.thezer0.canary")
    }

    @Test
    func theAppPathDiffersBetweenChannelsSoTheBundlesCoexist() throws {
        // Two `.app`s in the same `.build/` directory, distinguished by name:
        // the structural reason a canary build does not clobber a stable one
        // (ADR-0109 §Decision).
        let stable = try Self.resolve("stable", key: "APP_REL")
        let canary = try Self.resolve("canary", key: "APP_REL")
        #expect(stable != canary,
                "stable and canary must not share an .app path; got \(stable) twice")
        #expect(stable == "Zer0.app", "stable path is the historical one")
        #expect(canary == "Zer0 Canary.app", "canary path names the channel")
    }

    /// The regression ADR-0109 §"How this regresses" names last: a bundle
    /// built as canary must read its profile from a different directory than
    /// one built as stable, so a canary session never overwrites a stable one
    /// (or vice versa). The rule lives in `BrowserModel.storageDir(forBundleId:)`
    /// — a pure function of the bundle id, because `Bundle.main.bundleIdentifier`
    /// under `swift test` is the runner's id, not a built `.app`'s, so the
    /// assertion runs against the rule rather than against the runner.
    @Test
    func theStableAndCanaryStoragePathsDoNotCollide() {
        let stable = BrowserModel.storageDir(forBundleId: "com.thezer0.browser")
        let canary = BrowserModel.storageDir(forBundleId: "com.thezer0.canary")
        #expect(stable != canary,
                "stable and canary must not share a storage directory; both resolved to \(stable.path)")
        #expect(stable.lastPathComponent == "com.thezer0.browser",
                "the stable directory follows the bundle id; got \(stable.lastPathComponent)")
        #expect(canary.lastPathComponent == "com.thezer0.canary",
                "the canary directory follows the bundle id; got \(canary.lastPathComponent)")
    }

    /// `defaultStoragePath()` must delegate to the bundle-id rule rather than
    /// hold a literal of its own — a literal was the bug, and a pure-function
    /// test above cannot see a revert that bypasses the helper. Under
    /// `swift test` the bundle id is the runner's, not a built `.app`'s; what
    /// matters is that the path equals what the rule produces for whatever id
    /// the process carries, proving derivation rather than coincidence.
    @Test
    func defaultStoragePathFollowsTheBundleIdRule() {
        let bundleId = Bundle.main.bundleIdentifier ?? "com.thezer0.browser"
        let expected = BrowserModel.storageDir(forBundleId: bundleId)
            .appendingPathComponent("session.sqlite").path
        #expect(BrowserModel.defaultStoragePath() == expected,
                "defaultStoragePath must build on storageDir(forBundleId:); it produced a path the rule does not explain")
    }
}
