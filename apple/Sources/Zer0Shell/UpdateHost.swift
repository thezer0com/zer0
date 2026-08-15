import AppKit
import Foundation
import Sparkle
import SwiftUI

// Auto-update, owned by the shell.
//
// The *decision* to ship two channels and to sign appcasts with one EdDSA key
// is ADR-0109's; this file is the runtime half of that decision. What lives
// here: read the channel the bundle was built as, and answer Sparkle's
// `feedURLString(for:)` with the matching appcast. That is the whole job.
//
// The channel is *derived* from `Bundle.main.bundleIdentifier`, never written
// here. The bundle id is decided at one door
// (`apple/scripts/resolve-bundle.sh::build_bundle_id_parametrized`, the lock
// ADR-0109 names); this is the unavoidable second reader of what that door
// wrote. Keeping the suffix test the only reader in Swift is what stops a
// third implementation from drifting in — and the test
// `UpdateChannelTests/theCanaryBundleIdSuffixReadsAsTheCanaryChannel` is what
// keeps the second honest against the first.
//
// The feed URL is delivered through `SPUUpdaterDelegate.feedURLString(for:)`,
// the API Sparkle 2.x points at dynamic feeds. The deprecated `setFeedURL:`
// persists to UserDefaults and fights the next refactor; this delegate is
// called on every check, so the feed is resolved live each time with no
// persisted override to drift.
//
// There is no "peek at canary" toggle here, and ADR-0110 is why. An appcast
// enclosure is a full `.app` whose `Info.plist` carries the channel's bundle
// id; Sparkle swaps the on-disk bundle whole, so a stable binary that read
// the canary feed would have its bundle id mutate to `com.thezer0.canary` on
// the first canary update — orphaning the stable profile and breaking the
// 1Password enrolment ADR-0108/0109 name. The feed a channel reads is
// `Channel.appcastURL` and nothing else.
@MainActor
final class UpdateHost: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = UpdateHost()

    /// The two feeds a bundle can read from. ADR-0109: "stable users read
    /// `appcast-stable.xml`; canary users read `appcast-canary.xml`."
    ///
    /// Hostname is the one ADR-0109's release pipeline writes to; the path is
    /// the file the workflow publishes. Both URLs are `!`-forced because a nil
    /// here is a build-time typo, not a runtime condition this code can
    /// recover from.
    enum Channel {
        case stable
        case canary

        var appcastURL: URL {
            switch self {
            case .stable:
                URL(string: "https://download.thezer0.app/appcast-stable.xml")!
            case .canary:
                URL(string: "https://download.thezer0.app/appcast-canary.xml")!
            }
        }
    }

    /// Which channel this bundle ships as. Derived from the bundle id; never
    /// set externally. See the file header for why this is a reader, not a
    /// decider.
    let channel: Channel

    private let controller: SPUStandardUpdaterController

    /// Holds the strong reference the `SPUStandardUpdaterController` documents
    /// as the caller's responsibility (its delegate is `weak`). Lives on
    /// `self` so the delegate lives as long as the host does.
    private let feedResolver: FeedResolver

    private override init() {
        let bundleId = Bundle.main.bundleIdentifier ?? ""
        // Same suffix `resolve-bundle.sh` decides on. The test named above
        // keeps the two from drifting; an empty bundle id (a SwiftPM binary
        // run outside a `.app`) falls through to stable because that is what
        // the scripts default to.
        channel = bundleId.hasSuffix(".canary") ? .canary : .stable

        // The delegate answers `feedURLString(for:)` from Sparkle. Swift's
        // two-phase init forbids passing `self` to a stored property's
        // initialiser, so the resolver is built first as a local, then the
        // controller is wired against it, then both are bound to `self` —
        // all before `super.init()`, which is what the phase rule requires.
        // The provider closure is set after `super.init()` because it
        // captures `self`.
        let resolver = FeedResolver()
        feedResolver = resolver
        controller = SPUStandardUpdaterController(
            updaterDelegate: resolver,
            userDriverDelegate: nil
        )
        super.init()

        // Late wiring that needs a fully initialised `self`. The controller
        // does not start the updater until the next runloop tick (see
        // `-startUpdater` docs), so this lands before any check runs.
        // The feed is the channel's own, read fresh on every check; there is
        // no override and no `activeFeedURL` to keep in sync (ADR-0110).
        feedResolver.feedURLProvider = { [weak self] in
            self?.channel.appcastURL
        }
        controller.updater.automaticallyChecksForUpdates = true
        // Sparkle's default interval is 24h, matching the contract a browser
        // updater owes a person: not on every launch (rude), not weekly (a CVE
        // sits unfixed for days). Kept explicit because the next person to
        // reach for "how often do we check" should not have to read Sparkle's
        // headers to find out.
        controller.updater.updateCheckInterval = 86_400
    }

    /// `SPUUpdaterDelegate` adapter. Exists only because Swift's two-phase
    /// init forbids passing `self` into a stored property's initialiser; the
    /// host owns the policy, this type owns the conforming surface, and the
    /// `feedURLProvider` closure is the seam between them.
    private final class FeedResolver: NSObject, SPUUpdaterDelegate {
        var feedURLProvider: (() -> URL?)?

        func feedURLString(for updater: SPUUpdater) -> String? {
            // `SPUUpdater` calls its delegate on the main thread (per the
            // header), and the provider reads `channel` off the `@MainActor`
            // host. The assumeIsolated turns that contract into a checked
            // invariant rather than a hope.
            MainActor.assumeIsolated {
                feedURLProvider?()?.absoluteString
            }
        }
    }

    /// The menu item / settings button verb: check now, regardless of the
    /// 24h interval. Sparkle's own UI is what the user sees.
    func checkForUpdatesManually() {
        controller.updater.checkForUpdates()
    }

    /// Whether Sparkle checks on its own. Exposed to the settings pane so the
    /// switch reflects the real state Sparkle holds, not a shadow of it.
    var automaticallyChecksForUpdates: Bool {
        controller.updater.automaticallyChecksForUpdates
    }

    func setAutomaticallyChecksForUpdates(_ on: Bool) {
        controller.updater.automaticallyChecksForUpdates = on
    }
}
