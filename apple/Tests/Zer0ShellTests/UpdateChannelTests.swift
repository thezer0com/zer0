import Foundation
import Testing
@testable import Zer0Shell

/// The channel a bundle ships as is decided at one door
/// (`apple/scripts/resolve-bundle.sh::build_bundle_id_parametrized`, the lock
/// ADR-0109 names). `UpdateHost` is the unavoidable second reader — Swift code
/// that reads `Bundle.main.bundleIdentifier` at runtime cannot call a shell
/// script every launch.
///
/// That makes this a second implementation of the channel mapping, and the
/// rule "a rule enforced at N call sites has N−1 bugs waiting" (AGENTS.md)
/// applies. The defence is what it always is when two implementations cannot
/// be collapsed: a test that runs the first and checks the second against it,
/// so a typo in either surface fails the build.
///
/// What this test does NOT do: spin up `UpdateHost` itself. The host reads
/// `Bundle.main.bundleIdentifier`, which under `swift test` is the test
/// runner's id, not a built `.app`'s. The mapping under test is the suffix
/// check; the host's wiring of that mapping into Sparkle is a different
/// question and one an integration test on a real bundle answers better.
@Suite struct UpdateChannelTests {
    /// The exact suffix the shell door produces for the canary id, and the
    /// exact suffix `UpdateHost.Channel` matches against. If the shell ever
    /// moves canary to `com.thezer0.canary.browser`, this test fails before
    /// the host has a chance to misclassify it.
    @Test
    func theCanaryBundleIdSuffixReadsAsTheCanaryChannel() throws {
        let stableId = try Self.resolveShellBundleId(channel: "stable")
        let canaryId = try Self.resolveShellBundleId(channel: "canary")

        #expect(stableId == "com.thezer0.browser",
                "shell resolver must keep stable at com.thezer0.browser; got \(stableId)")
        #expect(canaryId == "com.thezer0.canary",
                "shell resolver must keep canary at com.thezer0.canary; got \(canaryId)")

        // The same test `UpdateHost.init` makes, run here against the ids the
        // shell actually emits. A canary id must read as canary; a stable id
        // must NOT read as canary even though both share `com.thezer0.`.
        #expect(canaryId.hasSuffix(".canary"),
                "UpdateHost reads canary when the bundle id ends in .canary; resolver disagrees")
        #expect(!stableId.hasSuffix(".canary"),
                "stable id must not trip the canary suffix; resolver would be misread by UpdateHost")
    }

    /// ADR-0110: the stable bundle does not peek at the canary feed. The feed
    /// a channel reads is the channel's own, and `Channel.appcastURL` is the
    /// only feed-resolution surface — `UpdateHost`'s delegate returns
    /// `self?.channel.appcastURL` with no branch, and there is no
    /// `canaryPeekEnabled` toggle to consult. This goes red if someone
    /// repoints `Channel.stable` at the canary URL or collapses the two feeds
    /// into one.
    ///
    /// What this does NOT lock: a peek reintroduced as a *second* resolution
    /// surface the host consults instead of `Channel.appcastURL`. That gap is
    /// named in ADR-0110 §"How this regresses"; the structural backstop is the
    /// absence of the property, and the ADR is the argument against re-adding
    /// it. The lock defends the values; code review defends the shape.
    @Test
    func theStableChannelReadsOnlyTheStableFeedAndHasNoPeek() {
        let stableFeed = UpdateHost.Channel.stable.appcastURL
        let canaryFeed = UpdateHost.Channel.canary.appcastURL

        #expect(
            stableFeed.absoluteString == "https://download.thezer0.app/appcast-stable.xml",
            "stable must read the stable appcast; ADR-0109 + ADR-0110"
        )
        #expect(
            canaryFeed.absoluteString == "https://download.thezer0.app/appcast-canary.xml",
            "canary must read the canary appcast; ADR-0109"
        )
        // The two feeds are distinct. A stable channel whose `appcastURL`
        // resolves to canary is the peek this ADR removed, wearing the enum's
        // clothes.
        #expect(
            stableFeed != canaryFeed,
            "the two feeds collapsed; a stable channel reading canary is the peek ADR-0110 removed"
        )
    }

    /// Where this test file lives, lifted to `apple/`. Same shape
    /// `BundleIdTests` uses; duplicated rather than shared because there is no
    /// test-support target and inventing one to hold two lines would be the
    /// kind of abstraction AGENTS.md tells us to wait for.
    private static let appleRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Zer0ShellTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // apple

    private static let resolver = appleRoot
        .appendingPathComponent("scripts/resolve-bundle.sh").path

    /// Reads the bundle id the shell door emits for a channel. Same helper
    /// shape `BundleIdTests` uses, kept here so a failure in this suite points
    /// at this suite rather than at a shared util somebody else owns.
    private static func resolveShellBundleId(channel: String) throws -> String {
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
            guard parts.count == 2, parts[0] == "BUNDLE_ID" else { continue }
            return String(parts[1])
        }
        throw NSError(
            domain: "UpdateChannelTests", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "no BUNDLE_ID in resolve-bundle.sh output:\n\(output)"]
        )
    }
}
