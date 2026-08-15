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
        let signature = HostedWebView.safariSignature

        #expect(signature.hasPrefix("Version/"))
        #expect(signature.hasSuffix("Safari/605.1.15"))

        if let installed = Bundle(path: "/Applications/Safari.app")?
            .infoDictionary?["CFBundleShortVersionString"] as? String
        {
            #expect(signature.contains(installed), "should follow the installed Safari")
        }
    }

    @Test("our own token carries a version")
    func browserTokenHasAVersion() async throws {
        let token = HostedWebView.browserToken

        #expect(token.hasPrefix("zer0/"))
        let version = token.dropFirst("zer0/".count)
        #expect(!version.isEmpty)
        #expect(version.first?.isNumber == true, "expected a version number: \(token)")
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
