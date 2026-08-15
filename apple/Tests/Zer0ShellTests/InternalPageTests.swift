import Foundation
import Testing
import WebKit
import Zer0Core

@testable import Zer0Shell

/// The browser's own addresses, and the one decision the whole scheme rests on.
///
/// ADR-0054: WebKit is never told this scheme exists. Everything else about
/// `zer0://` — that a page cannot navigate to one, cannot frame one, cannot be
/// redirected to one, and that there is no origin to reason about — follows from
/// that single fact, so that single fact is what is locked here.
@Suite("the browser's own addresses")
@MainActor
struct InternalPageTests {
    /// The security decision, as one assertion.
    ///
    /// `+[WKWebView handlesURLScheme:]` answers whether WebKit itself will
    /// resolve a scheme. For ours the answer has to be no, for ever: the moment
    /// it is yes, a page can put `zer0://chat` in an iframe and the handler that
    /// answers cannot tell that from somebody typing it — `WKURLSchemeTask`
    /// carries a request and nothing else, no frame, no initiator, no navigation
    /// type.
    @Test("WebKit is never told our scheme exists")
    func webKitIsNeverToldOurSchemeExists() {
        let scheme = internalScheme()
        let complaint = "WebKit resolves \(scheme):, which means a web page can reach one of "
            + "the browser's own addresses. Nothing may register a handler for it (ADR-0054)."
        #expect(WKWebView.handlesURLScheme(scheme) == false, "\(complaint)")
    }

    /// The other half of the same decision, and the one a refactor can undo.
    ///
    /// `handlesURLScheme` is a fact about WebKit's built-in schemes and would
    /// keep answering `false` even after somebody registered a handler on a
    /// configuration. So the registration itself is what is scanned for: there
    /// is exactly one API that gives a scheme away, and no shell source may name
    /// it on a configuration a **page** is built from.
    ///
    /// **One file is allowed to, and it is named here rather than exempted by a
    /// pattern.** `ExtensionHost` registers `ExtensionApiHost` on
    /// `WKWebExtensionController.Configuration.webViewConfiguration`, which is
    /// the configuration extension contexts are built from and not the one
    /// `EngineHost` builds pages from (ADR-0103). What makes that safe is
    /// measured rather than argued, and the measurement is the test below —
    /// without it this exemption is a hole with a comment over it.
    @Test("nothing registers a scheme handler on a configuration a page is built from")
    func nothingRegistersASchemeHandler() throws {
        for source in try SourceScan.shellSources() {
            let found = SourceScan.occurrences(of: "setURLSchemeHandler", in: source.code)
            let complaint = "\(source.path) registers a URL scheme handler. A registered "
                + "scheme is reachable from web content: a page can frame it, redirect to "
                + "it, or fetch it as a subresource, and the handler cannot tell any of "
                + "that from somebody typing an address, because WKURLSchemeTask carries "
                + "no frame and no initiator. zer0's own pages are drawn natively for "
                + "exactly this reason (ADR-0054). The one exemption is ExtensionHost, "
                + "which registers on the extension controller's own configuration."
            let exempt = source.path.hasSuffix("ExtensionHost.swift")
            #expect(found.isEmpty || exempt, "\(complaint)")
        }
    }

    /// The measurement the exemption above rests on.
    ///
    /// A page whose view carries the extension controller asks for the scheme
    /// three ways — `fetch`, an iframe and an image — and the handler is asked
    /// nothing. **The control is the point**: the same page, the same three
    /// asks, with the handler on the page's own configuration, and the image
    /// reaches it. Without that half a negative here would be an instrument that
    /// cannot see rather than a scheme that cannot be reached (AGENTS.md).
    @Test("a page cannot reach the extension API scheme")
    func aPageCannotReachTheExtensionApiScheme() async throws {
        func asks(of page: WKWebView) async {
            page.loadHTMLString(
                """
                <html><body>
                <iframe src="\(ExtensionApiHost.scheme)://call/downloads.search"></iframe>
                <img src="\(ExtensionApiHost.scheme)://call/downloads.erase">
                </body></html>
                """,
                baseURL: URL(string: "https://example.com/")!
            )
            _ = try? await page.evaluateJavaScript(
                "fetch(\"\(ExtensionApiHost.scheme)://call/downloads.search\").catch(() => 0)"
            )
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }

        let control = CountingSchemeHandler()
        let controlConfiguration = WKWebViewConfiguration()
        controlConfiguration.setURLSchemeHandler(control, forURLScheme: ExtensionApiHost.scheme)
        await asks(of: WKWebView(frame: .zero, configuration: controlConfiguration))
        #expect(
            control.asked > 0,
            """
            the instrument cannot see a page reaching a handler, so the expectation below             would pass over a scheme that is wide open
            """
        )

        let watched = CountingSchemeHandler()
        let forExtensions = WKWebExtensionController.Configuration.nonPersistent()
        let extensionViews = forExtensions.webViewConfiguration
        extensionViews?.setURLSchemeHandler(watched, forURLScheme: ExtensionApiHost.scheme)
        forExtensions.webViewConfiguration = extensionViews

        let pageConfiguration = WKWebViewConfiguration()
        pageConfiguration.webExtensionController =
            WKWebExtensionController(configuration: forExtensions)
        await asks(of: WKWebView(frame: .zero, configuration: pageConfiguration))

        #expect(
            watched.asked == 0,
            """
            a web page reached the extension API scheme. Everything in ExtensionApiHost             assumes only an extension's own contexts can (ADR-0103), and the Origin check             is not a substitute: a page carries its own origin and would be refused, but             the handler would still be doing work at a page's word.
            """
        )
    }

    /// Four addresses, and every one of them goes somewhere. An address that
    /// parses and then does nothing is a dead link inside the browser.
    @Test("every address in the scheme routes")
    func everyAddressInTheSchemeRoutes() {
        let addresses: [(String, InternalAddress)] = [
            ("zer0://chat", .chat(conversation: nil)),
            ("zer0://settings", .settings),
            ("zer0://history", .history),
            ("zer0://downloads", .downloads),
        ]

        for (url, expected) in addresses {
            #expect(internalAddress(url: url) == expected, "\(url)")
        }

        // Three of the four name themselves. A conversation does not, and
        // deliberately: it is named after what it is *about*, which an address
        // cannot know, so the core keeps the tab's own title in step with the
        // thread instead (ADR-0088). Asking an address for it would be the one
        // call that could only ever answer with the word "Chat".
        for (url, expected) in addresses.filter({ $0.1 != .chat(conversation: nil) }) {
            #expect(internalTitle(address: expected)?.isEmpty == false, "\(url) has no name")
        }
        #expect(internalTitle(address: .chat(conversation: nil)) == nil)
    }

    /// The scheme does not decide the shape; each address does. A conversation,
    /// a history and a list of downloads are tabs because you keep them, search
    /// them and come back to them; configuration is a window because you close
    /// it (ADR-0063).
    @Test("an address decides whether it is a page or a window")
    func anAddressDecidesWhetherItIsAPageOrAWindow() {
        #expect(internalEffect(address: .chat(conversation: nil)) == .page)
        #expect(internalEffect(address: .history) == .page)
        #expect(internalEffect(address: .downloads) == .page)
        #expect(internalEffect(address: .settings) == .window(command: .showSettings))
    }

    /// Every address that says it is a page really lands in a tab. The effect
    /// and the screen are two halves of one claim, and an address that resolved
    /// to `.page` with nothing drawn behind it would be a blank tab with a name.
    @Test("every page address commits into the tab that went to it")
    func everyPageAddressCommitsIntoTheTabThatWentToIt() {
        for address in [InternalAddress.chat(conversation: nil), .history, .downloads] {
            let url = internalAddressUrl(address: address)
            let model = BrowserModel(storagePath: nil)
            let tab = try! #require(model.snapshot.activeTab)

            model.send(.navigateTo(tab: tab, input: url))

            let state = model.snapshot.tabs.first { $0.id == tab }
            #expect(state?.url?.hasPrefix(url) == true, "\(url) did not commit")
            #expect(state?.loadingComplete == true, "\(url) left the tab loading")
            #expect(
                model.engine.webView(for: tab)?.url == nil,
                "an engine was pointed at \(url)"
            )
        }
    }

    /// An address of ours that names nothing we have is still ours to refuse.
    /// Handing it to an engine would report it as a site that does not exist,
    /// which is a lie about whose address it was.
    @Test("an address we do not have is refused as ours")
    func anAddressWeDoNotHaveIsRefusedAsOurs() {
        #expect(internalAddress(url: "zer0://nonsense") == nil)
        #expect(internalClaimsScheme(url: "zer0://nonsense"))
        #expect(internalClaimsScheme(url: "https://example.com") == false)
        // A site cannot dress itself up as us.
        #expect(internalClaimsScheme(url: "https://zer0.example/chat") == false)
    }

    /// Going to one of our own addresses never asks an engine to load anything,
    /// and a page address is showing by the time the navigation returns.
    @Test("going to one of our addresses never reaches an engine")
    func goingToOneOfOurAddressesNeverReachesAnEngine() {
        let model = BrowserModel(storagePath: nil)
        let tab = try! #require(model.snapshot.activeTab)

        model.send(.navigateTo(tab: tab, input: "zer0://chat"))

        let state = model.snapshot.tabs.first { $0.id == tab }
        #expect(state?.url == "zer0://chat")
        #expect(state?.loadingComplete == true)
        #expect(model.engine.webView(for: tab)?.url == nil, "an engine was pointed at zer0://")
    }

    /// Settings is a window. Going to it leaves you on the page you were
    /// reading, which is what pressing ⌘, does.
    @Test("a window address raises a window and leaves the tab alone")
    func aWindowAddressRaisesAWindowAndLeavesTheTabAlone() {
        let model = BrowserModel(storagePath: nil)
        let tab = try! #require(model.snapshot.activeTab)
        model.send(.navigationCommitted(tab: tab, url: "https://example.com/reading"))
        model.showingSettings = false

        model.send(.navigateTo(tab: tab, input: "zer0://settings"))

        #expect(model.showingSettings, "zer0://settings did not open Settings")
        #expect(model.settingsSection == .general)
        #expect(
            model.snapshot.tabs.first { $0.id == tab }?.url == "https://example.com/reading",
            "opening a window moved the tab"
        )
    }

    /// ⌘E puts a conversation on screen, in a tab, and pressing it again returns
    /// to the same one rather than opening a second.
    @Test("asking about a page opens one tab and returns to it")
    func askingAboutAPageOpensOneTabAndReturnsToIt() {
        let model = BrowserModel(storagePath: nil)
        let page = try! #require(model.snapshot.activeTab)
        model.send(.navigationCommitted(tab: page, url: "https://example.com/a"))

        model.perform(.openChat)
        let opened = try! #require(model.snapshot.activeTab)
        #expect(opened != page)
        #expect(model.snapshot.tabs.first { $0.id == opened }?.url?.hasPrefix("zer0://chat") == true)

        let count = model.snapshot.tabs.count
        model.perform(.openChat)
        #expect(model.snapshot.tabs.count == count, "a second press opened a second tab")
        #expect(model.snapshot.activeTab == opened)
    }

    /// The privacy rule the scheme adds: a conversation never sends the page
    /// that is showing it. An internal page has no document, so a capture would
    /// be the browser reading itself and posting the result to a provider.
    @Test("a conversation never sends the page that is showing it")
    func aConversationNeverSendsThePageThatIsShowingIt() {
        let model = BrowserModel(storagePath: nil)
        let page = try! #require(model.snapshot.activeTab)
        model.send(.navigationCommitted(tab: page, url: "https://example.com/a"))
        model.perform(.openChat)
        let chatTab = try! #require(model.snapshot.activeTab)

        // A question asked from inside the chat tab, about the chat tab.
        model.send(.openChat(about: .page(tab: chatTab), ask: "hello"))

        // Asserted over every thread rather than one looked up by tab. Since
        // ADR-0060 a thread is anchored to a page, and one of the browser's own
        // addresses is not anchorable — so the question lands in the space's
        // thread, and the guarantee is that *no* thread ends up holding one of
        // our pages, wherever the question went.
        let threads = model.conversations
        #expect(
            threads.contains { thread in thread.messages.contains { $0.text == "hello" } },
            "the question went nowhere, so this test proves nothing"
        )
        #expect(
            threads.allSatisfy { $0.awaitingPage == false },
            "the browser started reading one of its own pages to answer a question"
        )
        #expect(
            threads.allSatisfy { thread in
                thread.messages.allSatisfy { $0.role != .pageContext }
            },
            "one of the browser's own pages was attached to a conversation"
        )
    }

    /// The whole of ADR-0060 through the shell: a page you have discussed
    /// before gives its conversation back, by the one gesture anybody would try.
    @Test("a page discussed before gives its conversation back")
    func aPageDiscussedBeforeGivesItsConversationBack() {
        let model = BrowserModel(storagePath: nil)
        let page = try! #require(model.snapshot.activeTab)
        model.send(.navigationCommitted(tab: page, url: "https://example.com/a"))
        model.perform(.openChat)
        let chatTab = try! #require(model.snapshot.activeTab)
        let thread = try! #require(model.conversations.last).id
        model.send(.sendChatMessage(conversation: thread, text: "what is this"))

        // Both views of it go: the tab the page was in, and the tab the
        // conversation was in.
        model.send(.closeTab(tab: chatTab))
        model.send(.closeTab(tab: page))

        model.send(.openTab(space: nil, url: nil, parent: nil))
        let reopened = try! #require(model.snapshot.activeTab)
        model.send(.navigationCommitted(tab: reopened, url: "https://example.com/a"))
        model.perform(.openChat)

        #expect(model.conversations.count == 1, "a second thread was minted for one page")
        let back = try! #require(model.conversations.first)
        #expect(back.id == thread)
        #expect(back.messages.contains { $0.text == "what is this" })
    }
}

/// Counts what a scheme handler is asked for and answers nothing useful.
///
/// Answering at all matters: a handler that never calls `didFinish` leaves the
/// load hanging, and a test that timed out would read as flakiness rather than
/// as the reach it is meant to detect.
@MainActor
final class CountingSchemeHandler: NSObject, WKURLSchemeHandler {
    private(set) var asked = 0

    func webView(_: WKWebView, start task: any WKURLSchemeTask) {
        asked += 1
        guard let url = task.request.url else { return }
        let body = Data("{}".utf8)
        guard let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "application/json",
                "Content-Length": "\(body.count)",
                "Access-Control-Allow-Origin": "*",
            ]
        ) else { return }
        task.didReceive(response)
        task.didReceive(body)
        task.didFinish()
    }

    func webView(_: WKWebView, stop _: any WKURLSchemeTask) {}
}
