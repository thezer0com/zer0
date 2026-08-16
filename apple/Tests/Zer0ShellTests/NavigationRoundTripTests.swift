import Testing
import WebKit
import Zer0Core

@testable import Zer0Shell

/// End-to-end checks: a real `WKWebView` runs, and what WebKit reports about it
/// ends up inside the Rust state.
///
/// Pages are local files, so results depend on the code under test and not on
/// the network.
@MainActor
struct NavigationRoundTripTests {
    /// In-memory only. A test must never touch the real session on disk.
    private func model() -> BrowserModel {
        BrowserModel(storagePath: nil)
    }

    private func makePage(title: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zer0-test-\(UUID().uuidString)")
            .appendingPathExtension("html")
        try "<html><head><title>\(title)</title></head><body>hi</body></html>"
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("a page's title travels from WebKit into the Rust state")
    func titleReachesTheCore() async throws {
        let page = try makePage(title: "zer0 phase zero")
        let m = model()

        let tab = try #require(m.snapshot.activeTab)
        m.send(.navigateTo(tab: tab, input: page.absoluteString))

        #expect(await eventually { m.activeTab?.title == "zer0 phase zero" })

        let committed = try #require(m.activeTab?.url)
        #expect(committed.hasSuffix(page.lastPathComponent))
        #expect(m.activeTab?.loadingComplete == true)
        #expect(m.activeTab?.pendingUrl == nil)
    }

    @Test("opening a tab creates a live web view, closing it tears one down")
    func webViewLifecycleFollowsTheCore() async throws {
        let m = model()
        let first = try #require(m.snapshot.activeTab)
        #expect(m.engine.webView(for: first) != nil)

        m.send(.openTab(space: nil, url: nil, parent: nil))
        let second = try #require(m.snapshot.activeTab)
        #expect(second != first)
        #expect(m.engine.webView(for: second) != nil)

        m.closeActiveTab()
        #expect(m.engine.webView(for: second) == nil, "the web view must not outlive its tab")
        #expect(m.snapshot.activeTab == first, "focus falls back to the surviving tab")
    }

    @Test("each space navigates with its own cookie jar")
    func spacesGetSeparateDataStores() async throws {
        let m = model()
        let tab = try #require(m.snapshot.activeTab)
        let webView = try #require(m.engine.webView(for: tab))

        // A space-scoped store is what keeps two logins to one site apart. The
        // default store would silently share them.
        #expect(webView.configuration.websiteDataStore != WKWebsiteDataStore.default())
        #expect(webView.configuration.websiteDataStore.isPersistent)
    }

    /// Whether a tab can go back and forward is the core's state, written by
    /// the engine's report and read off the snapshot. The shell never puts the
    /// question to its own engine — that is the shape each platform would
    /// answer its own way, and ⌘[ cannot mean different things on two of them
    /// (ADR-0002).
    @Test("back and forward availability reaches the core as state")
    func backForwardAvailabilityReachesTheCore() async throws {
        let m = model()
        let tab = try #require(m.snapshot.activeTab)
        let first = try makePage(title: "one")
        let second = try makePage(title: "two")

        func flags() -> (back: Bool, forward: Bool) {
            let t = m.snapshot.tabs.first { $0.id == tab }
            return (t?.canGoBack ?? false, t?.canGoForward ?? false)
        }

        #expect(flags() == (false, false), "no engine has spoken for a fresh tab")

        m.send(.navigateTo(tab: tab, input: first.absoluteString))
        #expect(await eventually { flags() == (false, false) && m.activeTab?.loadingComplete == true })
        // One page in the list: nothing behind it, and the core has to agree
        // with the engine about that or Back is a key that acts on nothing.

        m.send(.navigateTo(tab: tab, input: second.absoluteString))
        #expect(
            await eventually { flags() == (true, false) },
            "two pages deep and the core still says there is nothing behind: every reader that trusts it acts blind"
        )

        m.send(.goBack(tab: tab))
        #expect(
            await eventually { flags() == (false, true) },
            "going back has to reach the core, or the second ⌘[ acts on stale state"
        )
    }
}

/// The engine's back/forward answer, and what it costs the core to hear it.
///
/// Every report is a full dispatch and refresh, so the count is the contract:
/// a navigation that settles a new pair reports it exactly once, and an
/// observation that repeats the last pair reports nothing at all. Measured
/// 2026-08-16, the doubled reports were the largest per-navigation addition
/// in the tree, and they are what this suite exists to keep removed.
@MainActor
struct NavigationStackReportTests {
    private func model() -> BrowserModel {
        BrowserModel(storagePath: nil)
    }

    private func makePage(title: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zer0-stack-\(UUID().uuidString)")
            .appendingPathExtension("html")
        try "<html><head><title>\(title)</title></head><body>hi</body></html>"
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// The reports that reached the core's door, counted on the way in. The
    /// original door is chained behind the counter, so counting is the only
    /// thing that changed. A struct rather than a tuple because the count is
    /// the assertion, and tuples cannot be compared as a list.
    private struct Report: Equatable {
        let back: Bool
        let forward: Bool
    }

    @MainActor
    private final class StackCounter {
        var reports: [Report] = []
    }

    private func countStackReports(on m: BrowserModel) -> StackCounter {
        let counter = StackCounter()
        let onward = m.engine.emit
        m.engine.emit = { action in
            if case let .navigationStackChanged(_, back, forward) = action {
                counter.reports.append(Report(back: back, forward: forward))
            }
            onward?(action)
        }
        return counter
    }

    /// The core's copy of the engine's answer, read the way the UI reads it.
    private func flags(_ m: BrowserModel, tab: TabId) -> (back: Bool, forward: Bool) {
        let t = m.snapshot.tabs.first { $0.id == tab }
        return (t?.canGoBack ?? false, t?.canGoForward ?? false)
    }

    @Test("a Back that flips both flags reaches the core as one report")
    func backFlippingBothFlagsReportsOnce() async throws {
        let m = model()
        let tab = try #require(m.snapshot.activeTab)
        let first = try makePage(title: "one")
        let second = try makePage(title: "two")

        m.send(.navigateTo(tab: tab, input: first.absoluteString))
        #expect(await eventually { m.activeTab?.loadingComplete == true })
        m.send(.navigateTo(tab: tab, input: second.absoluteString))
        #expect(await eventually { flags(m, tab: tab) == (true, false) })

        let counter = countStackReports(on: m)
        m.send(.goBack(tab: tab))
        #expect(
            await eventually { flags(m, tab: tab) == (false, true) },
            "the Back never settled"
        )
        // The settled pair is only in the snapshot because the last report
        // landed, so the count is final the moment the wait ends.
        #expect(
            counter.reports == [Report(back: false, forward: true)],
            "expected exactly one report carrying the settled pair, found \(counter.reports)"
        )
    }

    /// The other half of the contract, at the door itself: KVO delivers for
    /// a flag that did not move, and that fire must cost nothing. Driven by
    /// calling the door directly because WebKit offers no way to make it
    /// re-fire on demand — the navigation above proves the real fires land;
    /// this one proves the repeated pair is refused.
    @Test("an observation that repeats the last pair reports nothing")
    func refiredObservationReportsNothing() {
        let counter = StackCounter()
        let host = HostedWebView(
            tab: TabId(1),
            webView: PageView(frame: .zero, configuration: WKWebViewConfiguration()),
            adoptDownload: { _, _ in },
            permissions: SitePermissionLedger(),
            dialogs: PageDialogLedger(),
            authChallenges: AuthChallengeLedger(),
            openWindow: { _, _, _ in nil }
        ) { action in
            if case let .navigationStackChanged(_, back, forward) = action {
                counter.reports.append(Report(back: back, forward: forward))
            }
        }

        // A view that has never navigated reads (false, false), the way a
        // fresh tab does, and the first report of a pair must arrive.
        host.reportNavigationStack()
        #expect(counter.reports == [Report(back: false, forward: false)], "the first report must arrive")

        // The re-fire: KVO delivering again for values that did not move.
        host.reportNavigationStack()
        host.reportNavigationStack()
        #expect(
            counter.reports == [Report(back: false, forward: false)],
            "a repeated pair costs a dispatch to change nothing"
        )
    }
}

/// Space profiles: the half of isolation the cookie jar does not cover.
@MainActor
struct SpaceProfileTests {
    private func model() -> BrowserModel { BrowserModel(storagePath: nil) }

    @Test("an ephemeral space gets a store that never touches disk")
    func ephemeralSpaceIsNonPersistent() async throws {
        let m = model()
        let space = m.snapshot.activeSpace

        m.setProfile(space, SpaceProfile(userAgent: nil, ephemeral: true))

        let tab = try #require(m.snapshot.activeTab)
        let webView = try #require(m.engine.webView(for: tab))
        #expect(
            !webView.configuration.websiteDataStore.isPersistent,
            "an ephemeral space that writes to disk is a broken promise"
        )
    }

    @Test("a space's user agent reaches the web view")
    func userAgentIsApplied() async throws {
        let m = model()
        let space = m.snapshot.activeSpace

        m.setProfile(space, SpaceProfile(userAgent: "zer0/0.1 (test)", ephemeral: false))

        let tab = try #require(m.snapshot.activeTab)
        let webView = try #require(m.engine.webView(for: tab))
        #expect(webView.customUserAgent == "zer0/0.1 (test)")
    }

    @Test("changing a profile rebuilds the view rather than leaving it stale")
    func profileChangeRebuildsTheView() async throws {
        let m = model()
        let tab = try #require(m.snapshot.activeTab)
        let before = try #require(m.engine.webView(for: tab))

        m.setProfile(m.snapshot.activeSpace, SpaceProfile(userAgent: "zer0/0.1", ephemeral: false))

        let after = try #require(m.engine.webView(for: tab))
        #expect(before !== after, "a rebuilt view must be a different object")
    }
}

/// Air traffic: URLs land in the space that owns them.
@MainActor
struct AirTrafficTests {
    private func model() -> BrowserModel { BrowserModel(storagePath: nil) }

    @Test("a routed URL opens in its space, with that space's cookie jar")
    func routedUrlLandsInTheRightSpace() async throws {
        let m = model()
        let personal = m.snapshot.activeSpace
        m.createSpace(named: "Work")
        let work = m.snapshot.activeSpace
        #expect(work != personal)

        m.addRoute(.domain(host: "github.com"), to: work)
        m.activate(space: personal)

        let tab = try #require(m.snapshot.activeTab)
        m.send(.navigateTo(tab: tab, input: "github.com"))

        let landed = try #require(m.snapshot.activeTab)
        #expect(m.snapshot.tabs.first { $0.id == landed }?.space == work)
        #expect(m.snapshot.activeSpace == work)

        // The routed page must be in the target space's store, not the one it
        // was typed from.
        let personalStore = m.snapshot.spaces.first { $0.id == personal }?.dataStoreId
        let landedStore = m.engine.webView(for: landed)?.configuration.websiteDataStore
        let personalUUID = personalStore.flatMap { UUID(uuidString: $0) }
        let personalDataStore = personalUUID.map { WKWebsiteDataStore(forIdentifier: $0) }
        #expect(landedStore != personalDataStore)
    }

    @Test("the command bar shows where a link will land before you follow it")
    func routeDestinationIsVisibleUpFront() async throws {
        let m = model()
        m.createSpace(named: "Work")
        let work = m.snapshot.activeSpace
        m.addRoute(.domain(host: "github.com"), to: work)

        #expect(m.routeDestination(for: "https://github.com/avelino") == work)
        #expect(m.routeDestination(for: "https://avelino.run/") == nil)
    }
}

/// The session survives a restart.
@MainActor
struct PersistenceTests {
    @Test("tabs, spaces and rules come back after a relaunch")
    func sessionSurvivesRelaunch() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zer0-persist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("session.sqlite").path

        let tabCount: Int
        let spaceCount: Int
        do {
            let first = BrowserModel(storagePath: path)
            first.createSpace(named: "Work")
            let work = first.snapshot.activeSpace
            first.addRoute(.domain(host: "github.com"), to: work)

            let tab = try #require(first.snapshot.activeTab)
            first.setKind(tab, .pinned)

            tabCount = first.snapshot.tabs.count
            spaceCount = first.snapshot.spaces.count
            first.save()
        }

        // A brand new model against the same file, the way a relaunch works.
        let second = BrowserModel(storagePath: path)

        #expect(second.snapshot.spaces.count == spaceCount)
        #expect(second.snapshot.tabs.count == tabCount)
        #expect(second.snapshot.routes.count == 1)
        #expect(second.snapshot.tabs.contains { $0.kind == .pinned })

        // Restored tabs need live web views, not just rows in a list.
        for tab in second.snapshot.tabs {
            #expect(second.engine.webView(for: tab.id) != nil, "tab \(tab.id) has no view")
        }
    }
}

/// The User-Agent, which is why Gmail was showing an "unsupported browser"
/// banner: a third-party WKWebView reports no browser token at all.
@MainActor
struct UserAgentTests {
    private func newModel() -> BrowserModel { BrowserModel(storagePath: nil) }

    @Test("pages see a User-Agent with a browser in it")
    func userAgentCarriesABrowserToken() async throws {
        let m = newModel()
        let tab = try #require(m.snapshot.activeTab)
        let webView = try #require(m.engine.webView(for: tab))

        let agent = try await webView.evaluateJavaScript("navigator.userAgent") as? String
        let ua = try #require(agent)

        // These are what a sniffer looks for. Without them Google decides we
        // are an unsupported browser and says so at the top of the page.
        #expect(ua.contains("AppleWebKit/"), "no engine token: \(ua)")
        #expect(ua.contains("Version/"), "no Version token: \(ua)")
        #expect(ua.contains("Safari/"), "no Safari token: \(ua)")
        // And this is us, saying who we are.
        #expect(ua.contains("zer0/"), "no zer0 token: \(ua)")
    }

    @Test("we name ourselves after the Safari signature, never in place of it")
    func ourTokenComesLast() async throws {
        let m = newModel()
        let tab = try #require(m.snapshot.activeTab)
        let webView = try #require(m.engine.webView(for: tab))

        let ua = try #require(
            try await webView.evaluateJavaScript("navigator.userAgent") as? String
        )
        let safari = try #require(ua.range(of: "Safari/"))
        let zer0 = try #require(ua.range(of: "zer0/"))

        // Edge appends Edg/ and Vivaldi appends Vivaldi/ for the same reason:
        // putting our name first is what breaks the sniffing.
        #expect(zer0.lowerBound > safari.lowerBound, "zer0/ must come after Safari/: \(ua)")
    }

    @Test("we name no browser we are not")
    func theUserAgentNamesNoOtherBrowser() async throws {
        let m = newModel()
        let tab = try #require(m.snapshot.activeTab)
        let webView = try #require(m.engine.webView(for: tab))

        let ua = try #require(
            try await webView.evaluateJavaScript("navigator.userAgent") as? String
        )

        // Measured against the real store rather than assumed (ADR-0073):
        // sending a Chrome token does take Google's "Switch to Chrome?" dialog
        // away, and it replaces it with "Item currently unavailable", leaves
        // the store's own install button disabled exactly as before, and buys
        // nothing at all — while making every other site on the web a lie.
        //
        // `Safari/` is ours by ADR-0008 and is the one borrowed token, because
        // it names the engine we actually are.
        for token in ["Chrome/", "Chromium/", "CriOS/", "Edg/", "Firefox/", "OPR/"] {
            #expect(!ua.contains(token), "the UA claims to be \(token): \(ua)")
        }
    }

    @Test("the Safari signature tracks the installed copy, not a frozen string")
    func signatureIsDerivedFromTheSystem() async throws {
        // Read off the composed token rather than a `safariSignature`
        // constant: composition moved to the core (ADR-0119) and the shell
        // now holds only the input. What this still proves is the thing it
        // always did — that the version the installed Safari reports arrives
        // in the string the browser announces, and not a literal frozen at
        // build time.
        let token = HostedWebView.safariUserAgentToken

        #expect(token.hasPrefix("Version/"))
        #expect(token.contains("Safari/605.1.15"))

        if let installed = Bundle(path: "/Applications/Safari.app")?
            .infoDictionary?["CFBundleShortVersionString"] as? String
        {
            #expect(token.contains(installed), "should follow the installed Safari")
        }
    }

    @Test("our own token carries a version")
    func browserTokenHasAVersion() async throws {
        // The `zer0/x.y.z` token is the last space-separated word of the UA
        // the core composes; there is no separate `browserToken` constant to
        // read since ADR-0119 moved composition out of the shell.
        let ours = HostedWebView.safariUserAgentToken
            .split(separator: " ").last.map(String.init) ?? ""

        #expect(ours.hasPrefix("zer0/"))
        let version = ours.dropFirst("zer0/".count)
        #expect(!version.isEmpty)
        #expect(version.first?.isNumber == true, "expected a version number: \(ours)")
    }

    @Test("a space's own user agent still wins")
    func spaceOverrideBeatsTheDefault() async throws {
        let m = newModel()

        m.setProfile(m.snapshot.activeSpace, SpaceProfile(
            userAgent: "zer0/0.1 (custom)",
            ephemeral: false
        ))

        let tab = try #require(m.snapshot.activeTab)
        let webView = try #require(m.engine.webView(for: tab))
        #expect(webView.customUserAgent == "zer0/0.1 (custom)")
    }
}

/// Not an assertion, a record: prints the User-Agent sites will actually see,
/// so a change to it shows up in test output rather than in a bug report.
@MainActor
struct UserAgentRecordTests {
    @Test("record the User-Agent")
    func printUserAgent() async throws {
        let m = BrowserModel(storagePath: nil)
        let tab = try #require(m.snapshot.activeTab)
        let webView = try #require(m.engine.webView(for: tab))

        let ua = try #require(
            try await webView.evaluateJavaScript("navigator.userAgent") as? String
        )
        print("[zer0] User-Agent: \(ua)")
        #expect(!ua.isEmpty)
    }
}
