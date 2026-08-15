import Foundation
import Observation
import WebKit
import Zer0Core

/// Compiles the core's rule list and hands it to the engine.
///
/// The division is the one the whole project runs on: **which rules exist and
/// which sites are excepted is the core's answer** (`blocking.rs`), and this
/// only performs it. Nothing here decides what a tracker is, what an exception
/// covers, or whether a host is one — it asks, compiles what it is given, and
/// reports what happened.
///
/// What it does own is the part that is genuinely platform: `WKContentRuleList`
/// is compiled by WebKit into bytecode, cached on disk by identifier, and
/// attached to a `WKUserContentController`. A Linux host reaches the same
/// engine through `WebKitUserContentFilterStore` and will write its own version
/// of this file against the same JSON.
@MainActor
@Observable
final class ContentBlocking {
    /// What is true right now, and nothing more than that.
    ///
    /// `failed` exists because of the case that would otherwise be silent and
    /// is the worst one here: the Settings toggle says blocking is on, the
    /// compile refused the list, and every tracker loads. A switch that is on
    /// and does nothing is the lie ADR-0018 is about, so the failure is a state
    /// with a screen rather than a line in the console.
    enum State: Equatable {
        /// Switched off in Settings. Nothing is compiled and nothing is
        /// attached.
        case off
        /// A compile is in flight. First launch only — after that the answer
        /// comes out of the cache in a fraction of a millisecond.
        case compiling
        /// Attached and enforcing, over this many hosts.
        ///
        /// Hosts and not rules, though rules are what WebKit compiled. Both are
        /// true and only one is meaningful: "77 rules" beside "76 hosts" on the
        /// same pane reads as a contradiction, and the number a person can do
        /// anything with is the one counting sites.
        case active(hosts: Int)
        /// WebKit refused the list. `reason` is whatever it said.
        case failed(reason: String)
    }

    private(set) var state: State = .off

    /// The compiled list currently attached to every controller, if any.
    private var compiled: WKContentRuleList?
    /// The identifier `compiled` was built for, so a no-op refresh stays a
    /// no-op rather than a round trip through the store.
    private var appliedIdentifier: String?

    /// Every controller a rule list has to reach, asked for when it is needed.
    ///
    /// A closure rather than a registry this object maintains, and that is a
    /// correctness point rather than a style one. `WKWebView` **copies** the
    /// configuration it is handed, so the `WKUserContentController` a caller
    /// passed to `attach(to:)` is not reliably the object the live view ends up
    /// using. A list kept in here would go stale in exactly the case that
    /// matters — an exception added while tabs are open — and the symptom would
    /// be a page that stays broken after somebody switched blocking off on it.
    ///
    /// Asking the engine each time means the answer is always the live set, and
    /// closed tabs drop out of it for free.
    var liveControllers: (@MainActor () -> [WKUserContentController])?

    private let store: WKContentRuleListStore?

    /// The default store, or a private one for tests.
    ///
    /// Tests take their own directory so a run cannot read, write or evict
    /// anything the installed browser compiled — a shared on-disk cache keyed
    /// by identifier is exactly the kind of thing two processes fight over.
    init(storeDirectory: URL? = nil) {
        store = storeDirectory.map { WKContentRuleListStore(url: $0) } ?? .default()
    }

    // MARK: - Attaching

    /// Put the current list on a web view that is about to be built.
    ///
    /// Called while the configuration is still being assembled, so a view never
    /// exists — never mind loads — without whatever rules were already
    /// compiled. Later changes reach it through `liveControllers` instead.
    func attach(to controller: WKUserContentController) {
        controller.removeAllContentRuleLists()
        if let compiled {
            controller.add(compiled)
        }
    }

    // MARK: - Bringing the list up to date

    /// Make the attached rule list match what the core currently says.
    ///
    /// Cheap to call whenever anything might have changed: when the identifier
    /// already matches what is applied, this returns without touching the store
    /// at all. That matters because it is called on launch and after every
    /// preference change.
    ///
    /// `completion` fires once the engine has whatever it is going to get —
    /// including on failure. The caller uses it to reload the page, so a
    /// version that stayed quiet on the error path would leave a broken site
    /// broken with no explanation.
    func refresh(from core: Zer0, completion: (@MainActor () -> Void)? = nil) {
        guard let store, let identifier = core.contentRuleListIdentifier() else {
            // Off, or nothing to compile. Both are "no rules", and the engine
            // has to be told, or switching blocking off leaves the last list
            // attached and still enforcing.
            detach()
            state = .off
            completion?()
            return
        }

        guard identifier != appliedIdentifier else {
            completion?()
            return
        }

        // The cheap path, and the one taken on every launch after the first: a
        // lookup memory-maps bytecode that is already compiled. Measured at
        // 0.1ms against lists from 100 to 50,000 rules, where compiling the
        // same 50,000 took 119ms.
        store.lookUpContentRuleList(forIdentifier: identifier) { [weak self] list, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let list {
                    self.apply(list, identifier: identifier, core: core)
                    completion?()
                    return
                }
                // A miss and an I/O error are the same code (`LookUpFailed`),
                // and there is nothing useful to do differently: both mean
                // "there is no usable compile under this name".
                self.compile(identifier: identifier, from: core, completion: completion)
            }
        }
    }

    private func compile(
        identifier: String,
        from core: Zer0,
        completion: (@MainActor () -> Void)?
    ) {
        guard let store, let json = core.contentRuleListJson() else {
            detach()
            state = .off
            completion?()
            return
        }

        state = .compiling
        store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) {
            [weak self] list, error in
            // Deliberately tolerant of being called before `compileContentRuleList`
            // returns. WebKit parses the JSON synchronously on this thread and
            // calls back **reentrantly** when the parse fails, so a handler
            // written on the assumption that it always runs later would set
            // `.compiling` *after* the failure it is meant to report.
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let list else {
                    self.detach()
                    self.state = .failed(reason: Self.explain(error))
                    completion?()
                    return
                }
                self.apply(list, identifier: identifier, core: core)
                self.pruneEverythingBut(identifier)
                completion?()
            }
        }
    }

    private func apply(_ list: WKContentRuleList, identifier: String, core: Zer0) {
        compiled = list
        appliedIdentifier = identifier
        state = .active(hosts: Int(core.blockedHostCount()))

        for controller in liveControllers?() ?? [] {
            controller.removeAllContentRuleLists()
            controller.add(list)
        }
    }

    private func detach() {
        compiled = nil
        appliedIdentifier = nil
        for controller in liveControllers?() ?? [] {
            controller.removeAllContentRuleLists()
        }
    }

    /// Throw away compiles nobody will ask for again.
    ///
    /// The identifier carries a hash of the rules, so every exception added or
    /// removed mints a new one and orphans the old — and the store keeps
    /// compiled lists on disk forever unless somebody removes them. Without
    /// this, toggling one site on and off a few hundred times leaves a few
    /// hundred compiled lists in the profile.
    ///
    /// Only ours: the prefix is checked before anything is removed, because
    /// `WKContentRuleListStore.default()` is shared and deleting a name we do
    /// not recognise would be this browser reaching into something that is not
    /// its own.
    private func pruneEverythingBut(_ keep: String) {
        guard let store else { return }
        store.getAvailableContentRuleListIdentifiers { identifiers in
            MainActor.assumeIsolated {
                for identifier in identifiers ?? []
                where identifier != keep && identifier.hasPrefix(Self.identifierPrefix) {
                    store.removeContentRuleList(forIdentifier: identifier) { _ in }
                }
            }
        }
    }

    /// The namespace the core files its lists under. Kept in step with
    /// `blocking.rs` by the test that reads a real identifier and checks it.
    static let identifierPrefix = "zer0-block-"

    /// What WebKit actually said, or an admission that it said nothing useful.
    ///
    /// The specific parse error — "Disjunctions are not supported yet", "Empty
    /// extension", and the rest — is only ever available as prose in
    /// `NSHelpAnchorErrorKey`; every compile failure collapses to the same
    /// error code on the way out. So that string is read when it is there, and
    /// when it is not, the code is named rather than dressed up.
    static func explain(_ error: (any Error)?) -> String {
        guard let error = error as NSError? else {
            return "WebKit refused the rule list and did not say why."
        }
        if let detail = error.userInfo[NSHelpAnchorErrorKey] as? String, !detail.isEmpty {
            return detail
        }
        return "\(error.domain) \(error.code): \(error.localizedDescription)"
    }
}

// MARK: - What may be said about it

extension ContentBlocking.State {
    /// One line for a settings pane, and every word of it something that can be
    /// backed up.
    ///
    /// There is no count of what was blocked on the page here, and that is not
    /// an omission. `WKContentRuleList` exposes exactly one member, its
    /// identifier — no counter, no delegate callback, no notification anywhere
    /// in WebKit's public headers. The only thing that reports a blocked load
    /// is `_WKContentRuleListAction`, which is SPI. So the shield badge every
    /// other browser prints is a number this one cannot obtain honestly, and it
    /// is not invented to fill the space (ADR-0018, ADR-0058).
    var summary: String {
        switch self {
        case .off:
            "Off. Nothing is being filtered."
        case .compiling:
            "Preparing the rules…"
        case let .active(hosts):
            "On, covering \(hosts) tracking and advertising hosts."
        case let .failed(reason):
            "Not running: WebKit could not build the rule list. \(reason)"
        }
    }

    /// Whether this state is the one that needs somebody to look at it.
    var isFailure: Bool {
        switch self {
        case .off, .compiling, .active: false
        case .failed: true
        }
    }
}
