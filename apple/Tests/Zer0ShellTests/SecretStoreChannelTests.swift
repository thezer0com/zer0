import Foundation
import Testing
@testable import Zer0Shell

/// The Keychain jar a channel reads is decided by its bundle id (ADR-0112):
/// stable's credentials live under `com.thezer0.browser`, canary's under
/// `com.thezer0.canary`, and stable alone carried over the jar the
/// shared-service era left under `zer0`.
///
/// Both halves are tested as pure functions rather than against the real
/// Keychain, on purpose. The rule `service(forBundleId:)` and the decision
/// `shouldMigrate(legacyCount:newCount:service:)` take everything they need
/// as arguments, because under `swift test` `Bundle.main.bundleIdentifier`
/// is the runner's id, not a built `.app`'s — and because a suite that
/// touched the machine's real jars would be testing the developer's
/// keychain, not the rule. What stays uncovered is the wiring between the
/// two (the loop in `migrateLegacyCredentials`); ADR-0112 §"How this
/// regresses" names that gap rather than pretending a test watches it.
@Suite struct SecretStoreChannelTests {
    /// The rule the lock names: two channels must land in two services. If
    /// `service(forBundleId:)` ever returns a constant — the shared jar this
    /// ADR removed — the two ids collapse and this goes red. The last
    /// expectation proves `service` delegates to the rule rather than holding
    /// a literal of its own, whatever id the process carries.
    @Test
    func stableAndCanaryServicesDoNotCollide() {
        let stable = Keychain.service(forBundleId: "com.thezer0.browser")
        let canary = Keychain.service(forBundleId: "com.thezer0.canary")

        #expect(stable == "com.thezer0.browser",
                "the stable service is the stable bundle id; got \(stable)")
        #expect(canary == "com.thezer0.canary",
                "the canary service is the canary bundle id; got \(canary)")
        #expect(stable != canary,
                "stable and canary resolved to one Keychain service; a shared jar is the collision ADR-0112 removed")

        // Same shape as BundleIdTests/defaultStoragePathFollowsTheBundleIdRule:
        // assert the derivation, not the coincidence. A revert to a literal
        // fails here because the runner's id is not the literal.
        let runnerId = Bundle.main.bundleIdentifier ?? "com.thezer0.browser"
        #expect(Keychain.service == Keychain.service(forBundleId: runnerId),
                "Keychain.service must be the rule applied to this process's bundle id, not a literal")
    }

    /// The inheritance half: only stable inherits the legacy jar, and only
    /// while its own service is still empty. Canary starting clean is a
    /// structural refusal — the service check lives inside `shouldMigrate`,
    /// not at the call site — and the empty-check is what keeps the
    /// carry-over one-shot rather than a merge.
    @Test
    func onlyStableInheritsTheLegacyJarAndOnlyOnce() {
        #expect(Keychain.shouldMigrate(legacyCount: 3, newCount: 0, service: "com.thezer0.browser"),
                "stable with an empty jar inherits the legacy entries")
        #expect(!Keychain.shouldMigrate(legacyCount: 3, newCount: 1, service: "com.thezer0.browser"),
                "any entry already present means the carry-over ran; a second run is a merge, not a migration")
        #expect(!Keychain.shouldMigrate(legacyCount: 0, newCount: 0, service: "com.thezer0.browser"),
                "a fresh install has nothing to inherit")
        #expect(!Keychain.shouldMigrate(legacyCount: 3, newCount: 0, service: "com.thezer0.canary"),
                "canary starts clean; importing the legacy jar would be canary touching stable's history")
        #expect(!Keychain.shouldMigrate(legacyCount: 0, newCount: 2, service: "com.thezer0.canary"),
                "nothing to inherit, nothing to do")
    }
}
