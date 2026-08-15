import AppKit
import Foundation
import Testing
import WebKit
import Zer0Core

@testable import Zer0Shell

/// The rows this browser puts in the engine's context menu, and the addresses
/// it hands to another application. ADR-0091 and ADR-0092.
///
/// Served over `http://127.0.0.1` rather than `file://`, for the reason
/// `PopupTests` gives: a `file://` page has an opaque origin, and a suite that
/// asserts around one is asserting about the origin rather than about the code.
@MainActor
@Suite(.serialized)
struct PageMenuTests {
    /// A page with one of each thing a right-click can land on.
    private func serve() async throws -> TinyHTTPServer {
        try await TinyHTTPServer(routes: [
            "/page": .html("""
            <html><body style="font:16px -apple-system;margin:0;padding:0">
            <div style="height:60px"><a id="link" href="/target">a link here</a></div>
            <div style="height:60px"><a id="ours" href="zer0://settings">ours</a></div>
            <div style="height:60px"><img id="img" width="40" height="40"
              src="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"></div>
            <div style="height:60px"><p id="sel">selectable words in a paragraph</p></div>
            <div style="height:60px"><p id="plain">plain page area</p></div>
            </body></html>
            """),
            "/target": .html("<html><body><p id=\"target\">target</p></body></html>"),
        ])
    }

    /// A `PageView` that reads the menu and then empties it.
    ///
    /// Emptying is what makes the test finish: an engine-built menu tracks
    /// modally, and a menu with no items ends tracking at once. Watching
    /// `NSMenu.didBeginTrackingNotification` and cancelling from the handler was
    /// tried first and hangs — measured, five minutes with no return.
    private final class Watched: PageView {
        /// The engine's menu, as it arrived.
        var engineMenu: [NSMenuItem] = []
        /// The same menu after this browser amended it. Not called `menu`:
        /// `NSResponder` already has one of that name.
        var amendedMenu: [NSMenuItem] = []
        var hitTestWasInHand: [Bool] = []
        var menus = 0

        override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
            hitTestWasInHand.append(sawTargetBeforeTheMenu)
            engineMenu = menu.items
            super.willOpenMenu(menu, with: event)
            amendedMenu = menu.items
            menus += 1
            // What lets the test finish, and it is `cancelTracking` doing the
            // work rather than the emptying. Measured: with the items removed
            // but the session left running, the *first* gesture answered and
            // the second never produced a menu at all — AppKit swallows a
            // right-click while a menu session is open, and the failure reads
            // as "the engine never handed over a menu".
            //
            // Spinning the run loop also clears it, and that was the first
            // version of this. It is the wrong fix: this suite runs five
            // hundred tests on one main actor, and a test that blocks that
            // thread starves every other suite into a wall-clock flake.
            menu.removeAllItems()
            menu.cancelTracking()
        }
    }

    /// A browser, a served page, and a view of ours showing it.
    private struct Harness {
        let model: BrowserModel
        let server: TinyHTTPServer
        let view: Watched
        let window: NSWindow
        let tab: TabId
        var origin: String { "http://127.0.0.1:\(server.port)" }
    }

    private func harness(searchTemplate: String? = nil) async throws -> Harness {
        let server = try await serve()
        let model = BrowserModel(storagePath: nil)
        if let searchTemplate {
            model.setSearchTemplate(searchTemplate)
        }
        let tab = try #require(model.snapshot.activeTab ?? model.snapshot.tabs.first?.id)

        let view = Watched(frame: NSRect(x: 0, y: 0, width: 640, height: 420))
        view.tab = tab
        view.emit = { model.send($0) }
        view.searchEngineName = { model.currentSearchEngineName }

        let window = testWindow(NSRect(x: 0, y: 0, width: 640, height: 420))
        window.contentView?.addSubview(view)
        window.orderFrontRegardless()

        view.load(URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/page")!))
        #expect(await eventually { !view.isLoading && view.url?.path == "/page" })

        return Harness(model: model, server: server, view: view, window: window, tab: tab)
    }

    /// Right-click the middle of an element and wait for the menu.
    private func rightClick(
        _ id: String,
        in harness: Harness,
        atStart: Bool = false
    ) async throws {
        let spot = try await centre(of: id, in: harness.view, atStart: atStart)
        let before = harness.view.menus
        let event = try #require(
            NSEvent.mouseEvent(
                with: .rightMouseDown,
                location: harness.view.convert(spot, to: nil),
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: harness.window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        )
        harness.view.rightMouseDown(with: event)

        #expect(
            await eventually { harness.view.menus > before },
            """
            The engine never handed over a menu. `willOpenMenu(_:with:)` is the
            only route to a WKWebView's context menu on macOS — WKUIDelegate's
            context-menu methods are iOS-only in this SDK (ADR-0091).
            """
        )
    }

    private func centre(
        of id: String,
        in view: WKWebView,
        atStart: Bool
    ) async throws -> CGPoint {
        let inset = atStart ? "r.left + 8" : "r.left + r.width / 2"
        let script = """
        (function () {
          var r = document.getElementById('\(id)').getBoundingClientRect();
          return [\(inset), r.top + r.height / 2];
        })()
        """
        let answer = try await view.evaluateJavaScript(script)
        let pair = try #require(answer as? [Double])
        // A `WKWebView` is flipped, so its own coordinates already run from the
        // top the way the page's do. The caller converts to the window, which
        // is where the flip is undone; doing it here as well put every click a
        // screen away from what it was aiming at.
        return CGPoint(x: pair[0], y: pair[1])
    }

    private func titles(_ items: [NSMenuItem]) -> [String] {
        items.map { $0.isSeparatorItem ? "---" : $0.title }
    }

    private func index(of identifier: String, in items: [NSMenuItem]) -> Int? {
        items.firstIndex { $0.identifier?.rawValue == identifier }
    }

    private func index(ofTitle title: String, in items: [NSMenuItem]) -> Int? {
        items.firstIndex { $0.title == title }
    }

    // MARK: - The engine's own menu

    /// The anchors this browser places its rows against are WebKit's, and they
    /// are **not** declared in the public SDK — `WKMenuItemIdentifier*` appears
    /// in no header on this machine. They were read off a real menu.
    ///
    /// So this is the test that notices a rename. Without it, a spelling that
    /// changed would silently move every row of ours to the top of the menu and
    /// leave the engine's wrong ones in place, and every other test here would
    /// stay green because they ask about the row rather than about its
    /// neighbours.
    @Test("the engine still names its rows the way this browser expects")
    func menuIdentifiersAreStillWhatWebKitSets() async throws {
        let harness = try await harness()
        defer { harness.server.stop(); harness.window.close() }

        try await rightClick("link", in: harness)
        for identifier in [
            "WKMenuItemIdentifierOpenLinkInNewWindow",
            "WKMenuItemIdentifierDownloadLinkedFile",
        ] {
            #expect(
                index(of: identifier, in: harness.view.engineMenu) != nil,
                "\(identifier) is gone from the engine's link menu: \(titles(harness.view.engineMenu))"
            )
        }
        #expect(
            index(ofTitle: "Open Link in New Tab", in: harness.view.engineMenu) == nil,
            """
            The engine's own link menu now has a new-tab row. That is the whole
            reason this browser adds one, so if WebKit has grown its own the
            addition is a duplicate and ADR-0091 needs rewriting.
            """
        )

        try await rightClick("img", in: harness)
        for identifier in [
            "WKMenuItemIdentifierOpenImageInNewWindow",
            "WKMenuItemIdentifierDownloadImage",
        ] {
            #expect(
                index(of: identifier, in: harness.view.engineMenu) != nil,
                "\(identifier) is gone from the engine's image menu: \(titles(harness.view.engineMenu))"
            )
        }

        try await rightClick("plain", in: harness)
        #expect(
            index(of: "WKMenuItemIdentifierReload", in: harness.view.engineMenu) != nil,
            "the engine's page menu no longer carries Reload: \(titles(harness.view.engineMenu))"
        )

        try await select("sel", upTo: 10, in: harness.view)
        try await rightClick("sel", in: harness, atStart: true)
        #expect(
            index(of: "WKMenuItemIdentifierSearchWeb", in: harness.view.engineMenu) != nil,
            """
            The engine's selection menu no longer carries a search row: \
            \(titles(harness.view.engineMenu)). That row is the one this browser
            replaces because it names an engine Settings may not be using, and
            without it the replacement lands at the top of the menu instead.
            """
        )
    }

    /// The ordering the whole design rests on. The hit test and the engine's
    /// menu are both asynchronous, and the engine is not told about the click
    /// until the hit test has answered — so the menu cannot arrive first.
    ///
    /// Repeated, because a race that holds once holds by luck.
    @Test("what was under the pointer is known before the engine builds a menu")
    func theHitTestIsInHandBeforeTheEngineBuildsItsMenu() async throws {
        let harness = try await harness()
        defer { harness.server.stop(); harness.window.close() }

        for _ in 0 ..< 6 {
            try await rightClick("link", in: harness)
            try await rightClick("img", in: harness)
        }
        #expect(harness.view.hitTestWasInHand.count == 12)
        #expect(
            harness.view.hitTestWasInHand.allSatisfy { $0 },
            """
            The engine built a menu before the page had been read. Forwarding
            the event from inside the hit test's completion handler is what
            makes that impossible (ADR-0091).
            """
        )
    }

    // MARK: - What this browser adds

    /// The item this browser exists to add. The engine's link menu offers
    /// "Open Link in New Window" and nothing about a tab at all, in a browser
    /// whose whole navigation model is a list of tabs.
    @Test("a link gets the row the engine does not have, above the engine's own")
    func aLinkGetsANewTabRowAboveTheEnginesNewWindowRow() async throws {
        let harness = try await harness()
        defer { harness.server.stop(); harness.window.close() }

        try await rightClick("link", in: harness)
        let items = harness.view.amendedMenu
        let ours = try #require(
            index(ofTitle: "Open Link in New Tab", in: items),
            "no new-tab row: \(titles(items))"
        )
        let window = try #require(index(ofTitle: "Open Link in New Window", in: items))
        #expect(ours < window, "the new-tab row sits below the new-window one: \(titles(items))")
    }

    /// The engine's row of that name asks through `createWebViewWith` with
    /// every window feature unset, and ADR-0075 answers that with a **tab**.
    /// So the engine's row said New Window and produced a tab, and the row
    /// carrying that title has to be ours.
    @Test("the row that says New Window is ours, because the engine's opens a tab")
    func theNewWindowRowIsOursRatherThanTheEngines() async throws {
        let harness = try await harness()
        defer { harness.server.stop(); harness.window.close() }

        try await rightClick("link", in: harness)
        let items = harness.view.amendedMenu
        #expect(
            index(of: "WKMenuItemIdentifierOpenLinkInNewWindow", in: items) == nil,
            "the engine's new-window row survived beside ours: \(titles(items))"
        )
        #expect(index(ofTitle: "Open Link in New Window", in: items) != nil)

        // Same shape, for the two rows measured to reach nothing at all.
        #expect(index(of: "WKMenuItemIdentifierDownloadLinkedFile", in: items) == nil)
        #expect(index(ofTitle: "Download Linked File", in: items) != nil)

        try await rightClick("img", in: harness)
        #expect(index(of: "WKMenuItemIdentifierDownloadImage", in: harness.view.amendedMenu) == nil)
        #expect(index(ofTitle: "Download Image", in: harness.view.amendedMenu) != nil)
    }

    /// ADR-0054, reached from the one direction a menu opens. The navigation
    /// door already refuses our scheme, so the engine's rows here are offers to
    /// travel a road that dead-ends, and a row that cannot act earns no place.
    @Test("a link to one of our own addresses offers nothing at all")
    func aLinkToOneOfOurOwnAddressesOffersNothing() async throws {
        let harness = try await harness()
        defer { harness.server.stop(); harness.window.close() }

        try await rightClick("ours", in: harness)
        let items = harness.view.amendedMenu
        #expect(index(ofTitle: "Open Link in New Tab", in: items) == nil)
        #expect(index(ofTitle: "Open Link in New Window", in: items) == nil)
        for identifier in [
            "WKMenuItemIdentifierOpenLink",
            "WKMenuItemIdentifierOpenLinkInNewWindow",
            "WKMenuItemIdentifierDownloadLinkedFile",
            "WKMenuItemIdentifierCopyLink",
        ] {
            #expect(
                index(of: identifier, in: items) == nil,
                "\(identifier) still offers to reach one of our addresses: \(titles(items))"
            )
        }
    }

    /// The whole point of the row: it opens a tab, through the core, the way
    /// every other tab in this browser is opened.
    @Test("choosing Open Link in New Tab opens one through the core")
    func choosingOpenLinkInNewTabOpensOneThroughTheCore() async throws {
        let harness = try await harness()
        defer { harness.server.stop(); harness.window.close() }

        let before = harness.model.snapshot.tabs.count
        try await rightClick("link", in: harness)
        let row = try #require(
            harness.view.amendedMenu.first { $0.title == "Open Link in New Tab" }
        )
        let action = try #require(row.action)
        _ = (row.target as AnyObject?)?.perform(action, with: row)

        #expect(harness.model.snapshot.tabs.count == before + 1)
        let openedId = try #require(harness.model.snapshot.activeTab)
        let opened = try #require(harness.model.snapshot.tabs.first { $0.id == openedId })
        #expect(
            opened.pendingUrl == "\(harness.origin)/target"
                || opened.url == "\(harness.origin)/target",
            "the new tab went to \(opened.pendingUrl ?? opened.url ?? "nowhere")"
        )
        #expect(opened.parent == harness.tab, "the new tab did not land beside the page it came from")
    }

    /// The engine's row says "Search with Google" whatever Settings names, which
    /// is this interface stating something false about itself.
    @Test("the search row names the configured engine")
    func theSearchRowNamesTheConfiguredEngine() async throws {
        let harness = try await harness(searchTemplate: "https://duckduckgo.com/?q={}")
        defer { harness.server.stop(); harness.window.close() }

        try await select("sel", upTo: 10, in: harness.view)
        try await rightClick("sel", in: harness, atStart: true)
        let items = harness.view.amendedMenu

        #expect(
            index(of: "WKMenuItemIdentifierSearchWeb", in: items) == nil,
            "the engine's own search row survived: \(titles(items))"
        )
        let named = titles(items).first { $0.hasPrefix("Search ") }
        let row = try #require(named, "no search row at all: \(titles(items))")
        #expect(
            !row.contains("Google"),
            "the menu named an engine Settings does not: \(row)"
        )
        #expect(row.contains("selectable"), "the row did not say what it would search for: \(row)")
    }

    /// A selection somewhere else on the page is not what this gesture was
    /// about — and it matters more here than elsewhere, because a menu drawn
    /// this way never lets the engine clear the selection, so a stale one would
    /// follow the pointer around the page forever.
    @Test("a selection the pointer is not on is not offered for searching")
    func aSelectionThePointerIsNotOnIsNotOffered() async throws {
        let harness = try await harness(searchTemplate: "https://duckduckgo.com/?q={}")
        defer { harness.server.stop(); harness.window.close() }

        try await select("sel", upTo: 10, in: harness.view)
        try await rightClick("plain", in: harness)
        #expect(
            !titles(harness.view.amendedMenu).contains { $0.hasPrefix("Search ") && $0.contains("selectable") },
            "a selection elsewhere on the page followed the pointer: \(titles(harness.view.amendedMenu))"
        )
    }

    /// The engine's page menu is one row, and a browser's is not.
    @Test("the page itself gets Back and Forward, and only where there is somewhere to go")
    func thePageGetsBackAndForwardOnlyWhereThereIsSomewhereToGo() async throws {
        let harness = try await harness()
        defer { harness.server.stop(); harness.window.close() }

        try await rightClick("plain", in: harness)
        #expect(
            index(ofTitle: "Back", in: harness.view.amendedMenu) == nil,
            "a fresh page offered to go back: \(titles(harness.view.amendedMenu))"
        )

        harness.view.load(URLRequest(url: URL(string: "\(harness.origin)/target")!))
        #expect(await eventually { !harness.view.isLoading && harness.view.canGoBack })

        try await rightClick("target", in: harness)
        let items = harness.view.amendedMenu
        let back = try #require(index(ofTitle: "Back", in: items), "no Back row: \(titles(items))")
        let reload = try #require(index(of: "WKMenuItemIdentifierReload", in: items))
        #expect(back < reload, "Back sits below Reload: \(titles(items))")
        #expect(
            index(ofTitle: "Forward", in: items) == nil,
            "it offered to go forward from the end of the list: \(titles(items))"
        )
    }

    private func select(_ id: String, upTo: Int, in view: WKWebView) async throws {
        _ = try await view.evaluateJavaScript(
            """
            (function () {
              var n = document.getElementById('\(id)').firstChild;
              var r = document.createRange();
              r.setStart(n, 0);
              r.setEnd(n, \(upTo));
              var s = getSelection();
              s.removeAllRanges();
              s.addRange(r);
              return String(s);
            })()
            """
        )
    }
}

/// Addresses handed to another application. ADR-0092.
@MainActor
@Suite(.serialized)
struct ExternalSchemeTests {
    /// The gate that makes this safe enough to do without asking. A script
    /// assigning `location.href` reports `.other` — measured — and gets
    /// nothing; only a pointer on a link reports `.linkActivated`.
    @Test("a scheme the system owns is handed over only when a person clicked")
    func aSchemeTheSystemOwnsIsHandedOverOnlyWhenAPersonClicked() {
        let mail = URL(string: "mailto:someone@example.com?subject=hi")!

        #expect(
            ExternalScheme.decide(url: mail, navigationType: .linkActivated) == .open(mail)
        )
        for scripted in [WKNavigationType.other, .formSubmitted, .reload, .backForward] {
            #expect(
                ExternalScheme.decide(url: mail, navigationType: scripted) == .refuse,
                "a \(scripted) navigation started another application"
            )
        }
    }

    /// ADR-0054, at the one call in this browser that starts another program.
    @Test("one of our own addresses is never handed to the system")
    func oneOfOurOwnAddressesIsNeverHandedToTheSystem() {
        for address in [
            "zer0://settings",
            "zer0://chat?conversation=7",
            "ZER0://history",
            "zer0://nonsense",
        ] {
            let url = URL(string: address)!
            #expect(
                ExternalScheme.decide(url: url, navigationType: .linkActivated) == .leaveAlone,
                "\(address) reached the door that hands an address to another application"
            )
        }
    }

    /// Everything else is left exactly as it was, so a scheme nothing can open
    /// still reaches the failure screen that already says "That address can't
    /// be opened" — and so an application scheme is refused by being ignored
    /// rather than by a second rule written in the shell.
    @Test("what the engine loads, and what nobody opens, are both left alone")
    func whatTheEngineLoadsIsLeftAlone() {
        for address in [
            "https://example.com",
            "http://example.com",
            "file:///etc/hosts",
            "about:blank",
            "data:text/html,hi",
            "blob:https://example.com/abc",
            "slack://channel?id=1",
            "zoommtg://zoom.us/join",
            "weirdscheme:whatever",
        ] {
            let url = URL(string: address)!
            #expect(
                ExternalScheme.decide(url: url, navigationType: .linkActivated) == .leaveAlone,
                "\(address) was taken over"
            )
        }
        #expect(ExternalScheme.decide(url: nil, navigationType: .linkActivated) == .leaveAlone)
    }

    /// A page that scripts its way to a `mailto:` used to cost the person the
    /// page they were reading: WebKit fails it as `-1002`, which arrives as
    /// `.unsupportedUrl`, which ADR-0016 hands the whole screen. Now the
    /// navigation is cancelled and the page is still there.
    @Test("a page that scripts its way to a mailto keeps the page it was on")
    func aScriptedMailtoKeepsThePageItWasOn() async throws {
        let server = try await TinyHTTPServer(routes: [
            "/page": .html("<html><body><p id=\"here\">still here</p></body></html>"),
        ])
        defer { server.stop() }

        let model = BrowserModel(storagePath: nil)
        let tab = try #require(model.snapshot.activeTab ?? model.snapshot.tabs.first?.id)
        model.send(.navigateTo(tab: tab, input: "http://127.0.0.1:\(server.port)/page"))
        #expect(await eventually { model.snapshot.tabs.first { $0.id == tab }?.loadingComplete == true })

        let view = try #require(model.engine.webView(for: tab))
        _ = try? await view.evaluateJavaScript("location.href = 'mailto:someone@example.com'")
        // Long enough for a failure to have arrived if one were coming.
        try await Task.sleep(for: .milliseconds(400))

        #expect(
            model.snapshot.tabs.first { $0.id == tab }?.lastError == nil,
            "the page was replaced by an error screen"
        )
        let still = try await view.evaluateJavaScript("document.getElementById('here').textContent")
        #expect(still as? String == "still here")
    }
}

/// One door, and one only.
@MainActor
@Suite
struct ExternalSchemeDoorTests {
    /// A second place that hands an address to another application would be a
    /// second answer to whether a script may start one, and every test above
    /// would stay green because they all ask the first one.
    @Test("exactly one place in the shell hands an address to another application")
    func exactlyOnePlaceHandsAnAddressToAnotherApplication() throws {
        let sources = try SourceScan.shellSources()
        let asked = sources.reduce(0) { total, source in
            total + SourceScan.occurrences(of: "ExternalScheme.takeOver", in: source.code).count
        }
        #expect(asked == 1, """
            ExternalScheme.takeOver is called \(asked) times rather than once. A second
            door is a second answer to whether a script may start another application,
            and every other test here would stay green because they all ask the first
            one (ADR-0092).
            """)

        // The one function that actually starts something, called from the one
        // place that decided to.
        let opened = sources.reduce(0) { total, source in
            total + SourceScan.occurrences(of: "Self.hand(", in: source.code).count
                + SourceScan.occurrences(of: "ExternalScheme.hand(", in: source.code).count
        }
        #expect(
            opened == 1,
            "a page's address reaches NSWorkspace from \(opened) places in the shell"
        )
    }
}
