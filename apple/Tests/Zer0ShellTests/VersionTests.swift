import Foundation
import Testing

/// ADR-0111: `CFBundleVersion` is a monotonic integer, and it is the same
/// number the appcast publishes as `sparkle:version`. Sparkle ranks updates by
/// that number, so a bundle frozen at build `1` makes every release look older
/// or equal to the installed one — no canary would ever update, and a stable
/// point release would be offered forever.
///
/// The formula lives at one door — `bundle_version_for_channel` in
/// `apple/scripts/resolve-bundle.sh` — and both sides of the release pipeline
/// derive from it: the workflow's compute step (whose result reaches
/// `bundle.sh` as `ZER0_BUNDLE_VERSION` and is stamped into the plist) and
/// `publish-appcast.sh`, which recomputes it and refuses a disagreement. This
/// test runs the real function rather than restating the formula in Swift, for
/// the same reason `BundleIdTests` runs `resolve-bundle.sh`: a second
/// implementation drifts from the first, and the lock must defend the formula
/// the scripts actually use.
@Suite struct VersionTests {
    /// Where this test file lives, lifted two directories to reach `apple/`
    /// (same walk as BundleIdTests).
    private static let appleRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Zer0ShellTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // apple

    private static let resolver = appleRoot
        .appendingPathComponent("scripts/resolve-bundle.sh").path

    /// Runs `bundle_version_for_channel <channel> <version>` by sourcing the
    /// door and calling the function — the same shape `bundle.sh`'s callers
    /// use. Returns stdout and the exit status, so refusal is testable too.
    private static func derive(
        channel: String, version: String
    ) throws -> (output: String, status: Int) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [
            "-c", ". \"$1\"; bundle_version_for_channel \"$2\" \"$3\"",
            "VersionTests", resolver, channel, version,
        ]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        try task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (output, Int(task.terminationStatus))
    }

    /// The derived number as an `Int`, for ranking assertions. Throws rather
    /// than traps: a non-numeric derivation is a broken door, and the failure
    /// should read as one.
    private static func ranked(_ version: String, channel: String = "stable") throws -> Int {
        let result = try derive(channel: channel, version: version)
        guard result.status == 0, let n = Int(result.output, radix: 10) else {
            throw NSError(
                domain: "VersionTests", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "door did not produce an integer for \(channel) \(version): \(result.output)"]
            )
        }
        return n
    }

    /// Stable packs X.Y.Z into M*10000 + m*100 + p. The exact values matter:
    /// they are the numbers the stable workflow's inline formula already
    /// published into the appcast — this door reproduces that series, it does
    /// not invent a new one.
    @Test
    func stableVersionPacksXYZIntoAMonotonicInteger() throws {
        #expect(try Self.derive(channel: "stable", version: "0.1.0").output == "100")
        #expect(try Self.derive(channel: "stable", version: "0.2.10").output == "210")
        #expect(try Self.derive(channel: "stable", version: "1.0.0").output == "10000")
        #expect(try Self.derive(channel: "stable", version: "1.2.3").output == "10203")
    }

    /// The packing exists so ranking is numeric: 0.2.10 above 0.2.9 (a string
    /// compare would say "10" < "9"), and 1.0.0 above every 0.x.
    @Test
    func aLaterStableReleaseRanksAboveAnEarlierOne() throws {
        #expect(try Self.ranked("0.2.10") > Self.ranked("0.2.9"))
        #expect(try Self.ranked("0.10.0") > Self.ranked("0.9.99"))
        #expect(try Self.ranked("1.0.0") > Self.ranked("0.99.99"))
    }

    /// A stable version that is not clean X.Y.Z is refused rather than
    /// guessed: a wrong build number is not a visible defect — the build
    /// works, the feed validates — it silently breaks update ranking, which
    /// is the one thing this number exists to hold.
    @Test
    func stableRefusesAVersionThatIsNotXYZ() throws {
        for bad in ["0.1", "0.1.0.0", "v0.1.0", "0.1.0-rc1", ""] {
            #expect(try Self.derive(channel: "stable", version: bad).status != 0,
                    "stable '\(bad)' must be refused, not guessed")
        }
    }

    /// Canary's human version already carries the UTC build timestamp; the
    /// timestamp *is* the bundle version — 12 digits, monotonic by
    /// construction, and far above every stable code so even a hypothetical
    /// cross-channel comparison could not go wrong.
    @Test
    func canaryCarriesItsTimestampAsTheBundleVersion() throws {
        #expect(
            try Self.derive(
                channel: "canary", version: "0.0.0-canary.202608121500-abc1234"
            ).output == "202608121500")
    }

    @Test
    func aLaterCanaryRanksAboveAnEarlierOne() throws {
        #expect(
            try Self.ranked("0.0.0-canary.202608121501-def5678", channel: "canary")
                > Self.ranked("0.0.0-canary.202608121500-abc1234", channel: "canary"))
    }

    /// A canary version without a 12-digit timestamp — or a stable-shaped
    /// version on the canary channel — is refused: each channel accepts only
    /// its own shape, so the two series can never be mixed up.
    @Test
    func canaryRefusesAVersionWithoutATwelveDigitTimestamp() throws {
        for bad in [
            "0.0.0-canary.2026081-abc1234", "0.0.0-canary.notats-abc1234",
            "1.2.3", "0.1.0",
        ] {
            #expect(try Self.derive(channel: "canary", version: bad).status != 0,
                    "canary '\(bad)' must be refused, not guessed")
        }
    }
}
