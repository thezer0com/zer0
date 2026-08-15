import Testing
import WebKit
import Zer0Core

@testable import Zer0Shell

/// An extension's **own** pages: its options screen, its onboarding, anything
/// it opens for itself with `chrome.tabs.create`.
///
/// Every test here drives a real `WKWebExtensionController` with a real package
/// on disk and asks the page whether it loaded. Nothing depends on any
/// particular extension being installed: the package is three files written in
/// the fixture, which is what makes these locks and not a probe.
@MainActor
struct ExtensionPageTests {
    static let welcome = """
    <!doctype html><html><head><title>Options</title></head>
    <body><h1 id="heading">an extension's own page</h1></body></html>
    """

    /// A model with one extension loaded, and the address of a page inside it.
    ///
    /// The host is read off `context.baseURL` rather than composed, because it
    /// is a uuid **WebKit** minted for this context and there is nowhere else
    /// to get it.
    ///
    /// **The fixture is handed back and every caller holds it.** It deletes its
    /// own directory when it is released, and a package deleted a moment before
    /// the page is asked for is a test that fails for the wrong reason — or
    /// worse, one that *passes* for the wrong reason, which is what the control
    /// below did until this was noticed.
    private func loadedExtension(
        _ model: BrowserModel,
        id: String = String(repeating: "b", count: 32)
    ) async throws -> (fixture: ExtensionFixture, context: WKWebExtensionContext, page: String) {
        let host = try #require(model.extensions)
        let fixture = try ExtensionFixture(id: id, pages: ["options.html": Self.welcome])
        let context = try await host.load(fixture.installed, granting: fixture.everything)
        let base = try #require(context.baseURL.absoluteString.isEmpty ? nil : context.baseURL)
        return (fixture, context, base.absoluteString + "options.html")
    }

    private func text(of view: WKWebView?) async -> String {
        guard let view else { return "" }
        let value = try? await view.evaluateJavaScript(
            "document.body ? document.body.innerText : ''"
        )
        return (value as? String) ?? ""
    }

    /// **The defect, end to end.** An extension's own page could not be opened
    /// in this browser at all — the address became a web search in the core,
    /// and carried intact it was cancelled in the shell, because every tab's
    /// view was built from a plain configuration.
    ///
    /// This drives the whole path a person or a `chrome.tabs.create` takes:
    /// `Action.openTab` with the address, the core deciding what the view is
    /// built from, and the page answering for itself.
    @Test("an extension's own page opens and renders")
    func anExtensionsOwnPageOpensAndRenders() async throws {
        let m = BrowserModel(storagePath: nil)
        let (fixture, _, page) = try await loadedExtension(m)

        m.send(.openTab(space: nil, url: page, parent: nil))
        let tab = try #require(m.snapshot.activeTab)

        #expect(
            await eventually { await text(of: m.engine.webView(for: tab)).contains("own page") },
            """
            the extension's page did not render. Measured before this fix: the address became
            `Search("https://duckduckgo.com/?q=webkit-extension%3A%2F%2F…")` in the core, and
            carried intact the view was left at `about:blank` because it was built from a plain
            `WKWebViewConfiguration` rather than from the extension's (ADR-0086).
            """
        )
        #expect(m.engine.webView(for: tab)?.url?.absoluteString == page)
        withExtendedLifetime(fixture) {}
    }

    /// The instrument for the test above: a bare `WKWebView` built from
    /// `context.webViewConfiguration` really does load one of these addresses,
    /// so a failure up there is this browser's and not WebKit's.
    ///
    /// **What this deliberately does not assert is the other half**, and the
    /// reason is worth carrying: whether an *ordinary* configuration is refused
    /// one of these addresses did not reproduce. Measured standalone, in a fresh
    /// process, sampled out to 34 seconds, with the extension controller
    /// attached and without it: the view stays at `about:blank` — which is what
    /// ADR-0086 reported and what makes the defect real on a browser launch.
    /// Measured *inside this test process*, where other suites have already
    /// loaded extensions into the default controller configuration, the same
    /// address loads in a plain configuration in under a second.
    ///
    /// So the refusal is real and is not a property this suite can hold. An
    /// assertion either way would be a lock that goes red on how the run was
    /// scheduled, which ADR-0018 is exactly about — and an earlier draft of this
    /// test did precisely that, passing alone and failing under the suite.
    @Test("an extension's own configuration is what loads its pages")
    func anExtensionsOwnConfigurationIsWhatLoadsItsPages() async throws {
        let m = BrowserModel(storagePath: nil)
        let (fixture, context, page) = try await loadedExtension(m)
        let address = try #require(URL(string: page))

        let view = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 300),
            configuration: try #require(context.webViewConfiguration)
        )
        view.load(URLRequest(url: address))
        #expect(
            await eventually { view.url?.scheme == "webkit-extension" },
            "the address did not load even in the extension's own configuration"
        )

        withExtendedLifetime(fixture) {}
    }

    /// The store on an extension's configuration is WebKit's shared one and is
    /// handed on untouched.
    ///
    /// **Measured, and the reason this is asserted rather than trusted:**
    /// assigning a space's identified store — or a non-persistent one — to this
    /// configuration leaves `WKWebView.init` never returning, while the same
    /// two assignments on an ordinary configuration build a view and load a
    /// page. A substitution therefore fails as a hang somewhere else entirely,
    /// which is the worst way for it to fail; this says so where it happens.
    @Test("an extension's page keeps the store its configuration arrived with")
    func anExtensionsPageKeepsTheStoreItArrivedWith() async throws {
        let m = BrowserModel(storagePath: nil)
        let (fixture, context, _) = try await loadedExtension(m)
        let host = try #require(m.extensions)
        let baseHost = try #require(context.baseURL.host)

        let configuration = try #require(host.pageConfiguration(forBaseHost: baseHost))
        #expect(configuration.websiteDataStore === WKWebsiteDataStore.default())
        #expect(configuration.webExtensionController != nil, """
            the extension's own configuration arrived without its controller, so a content
            script would never reach this page
            """)
        withExtendedLifetime(fixture) {}
    }

    /// A host nothing loaded is an address to no extension. Refused rather than
    /// attributed to whichever extension happens to be at hand — which is what
    /// would let one extension's screens be opened out of another's address.
    @Test("a base host no extension answers to is refused rather than guessed at")
    func aBaseHostNoExtensionAnswersToIsRefused() async throws {
        let m = BrowserModel(storagePath: nil)
        let (fixture, context, _) = try await loadedExtension(m)
        let host = try #require(m.extensions)

        // The instrument first: the one that does exist resolves, so a `nil`
        // below is this refusal and not a host that answers nothing ever.
        let real = try #require(context.baseURL.host)
        #expect(host.pageConfiguration(forBaseHost: real) != nil)

        #expect(host.pageConfiguration(forBaseHost: "0f0f0f0f-dead-4000-8000-000000000000") == nil)
        withExtendedLifetime(fixture) {}
    }

    /// ADR-0023: an ephemeral space records nothing. An extension's page cannot
    /// be made ephemeral — the configuration is WebKit's and its store will not
    /// be replaced — so a private window has nowhere to put one and says so.
    @Test("a private window refuses an extension's page rather than writing it down")
    func aPrivateWindowRefusesAnExtensionsPage() async throws {
        let m = BrowserModel(storagePath: nil)
        let (fixture, _, page) = try await loadedExtension(m)

        m.send(.createSpace(name: "Private", dataStoreId: "ds-private", ephemeral: true))
        let space = m.snapshot.activeSpace
        m.send(.openTab(space: space, url: page, parent: nil))
        let tab = try #require(m.snapshot.activeTab)

        _ = await eventually(timeout: .seconds(2)) { false }
        let landed = m.engine.webView(for: tab)?.url?.absoluteString ?? ""
        #expect(!landed.hasPrefix("webkit-extension:"), """
            a private window loaded a page whose data store is WebKit's shared persistent one:
            \(landed)
            """)
        #expect(
            m.snapshot.tabs.first { $0.id == tab }?.lastError?.kind == .unsupportedUrl,
            "it was refused in silence rather than saying so"
        )
        withExtendedLifetime(fixture) {}
    }

    /// An extension may open its own pages and nobody else's.
    ///
    /// `openNewTabUsing` is the one delegate that knows *who is asking*, so it
    /// is the only place this can be settled. A page opened out of another
    /// extension's address is drawn from that extension's configuration and
    /// carries its storage and its origin, which is one extension reaching into
    /// another through a call meant to open a tab.
    ///
    /// Driven through a real `chrome.tabs.create` from a real background worker,
    /// because `WKWebExtension.TabConfiguration` cannot be constructed — its
    /// `init` is `NS_UNAVAILABLE` — and because a test of a helper the delegate
    /// merely *happens* to call would stay green with the check deleted.
    ///
    /// The worker asks twice: once for its own page and once for the other
    /// extension's. One of those has to open and the other has to not, which is
    /// what makes a single count meaningful.
    @Test("one extension cannot open another's page")
    func oneExtensionCannotOpenAnothersPage() async throws {
        let m = BrowserModel(storagePath: nil)
        let host = try #require(m.extensions)

        // The extension whose screens somebody else is about to ask for.
        let theirs = try ExtensionFixture(
            id: String(repeating: "c", count: 32),
            pages: ["options.html": Self.welcome]
        )
        let theirsContext = try await host.load(theirs.installed, granting: theirs.everything)
        let theirsPage = theirsContext.baseURL.absoluteString + "options.html"

        // And the one that asks. Its own page first, so a count of one below is
        // this rule and not a delegate that opens nothing at all.
        let mine = try ExtensionFixture(
            id: String(repeating: "d", count: 32),
            backgroundScript: """
            chrome.tabs.create({ url: chrome.runtime.getURL('options.html') });
            chrome.tabs.create({ url: '\(theirsPage)' });
            """,
            pages: ["options.html": Self.welcome]
        )
        let mineContext = try await host.load(mine.installed, granting: mine.everything)
        #expect(mineContext.baseURL != theirsContext.baseURL)

        func opened() -> [String] {
            m.snapshot.tabs
                .compactMap { $0.url ?? $0.pendingUrl }
                .filter { $0.hasPrefix("webkit-extension:") }
        }

        #expect(await eventually { !opened().isEmpty }, "the worker never asked for a tab")
        // Long enough that a second tab, if it were going to open, would have.
        _ = await eventually(timeout: .seconds(2)) { opened().count > 1 }

        #expect(
            opened().allSatisfy { $0.hasPrefix(mineContext.baseURL.absoluteString) },
            "one extension opened another's page: \(opened())"
        )

        withExtendedLifetime(mine) {}
        withExtendedLifetime(theirs) {}
    }
}
