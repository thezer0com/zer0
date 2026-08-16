import AppKit
import Foundation
import Network
import Testing
import WebKit
import Zer0Core

@testable import Zer0Shell

/// A page that opens a window, and the flow that depends on it (ADR-0075).
///
/// **These ask the page, not the delegate.** A test that proves
/// `createWebViewWith` returned something non-nil proves a method exists; it
/// says nothing about whether a sign-in works. What a sign-in is made of is
/// three things a page does *after* the view arrives — read `window.opener`,
/// `postMessage` home, `window.close()` — and each of them fails silently if the
/// view was built from the wrong configuration. So each is asked from inside a
/// real pop-up, over a real origin.
///
/// **Over http, not `file://`.** Two `file://` pages have opaque origins that
/// never match each other, so `window.opener.document` is refused there for a
/// reason that has nothing to do with this code — measured, and it is exactly
/// the shape of green-looking evidence that proves nothing.
///
/// **Serialized on purpose**, for the reason `EnginePolicyTests` is: several
/// `BrowserModel`s, page loads and windows on the main actor at once starve the
/// debounce `SessionPersistenceTests` waits on, and the failure lands on that
/// test rather than on this file.
@MainActor
@Suite(.serialized)
struct PopupTests {
    /// A page that opens another, and a page to be opened.
    private func serve() async throws -> TinyHTTPServer {
        try await TinyHTTPServer(routes: [
            "/parent": .html("""
            <html><body>
              <a id="go" href="/child" target="_blank">go</a>
              <p id="parent">parent</p>
              <script>
                window.heard = 'nothing';
                window.addEventListener('message', function (e) { window.heard = String(e.data); });
              </script>
            </body></html>
            """),
            "/child": .html("<html><body><p id=\"child\">child</p></body></html>"),
            // Opens a window itself, at load, with nobody having touched
            // anything. It has to be the page that does it: `evaluateJavaScript`
            // carries a user gesture, so driving it from the test would answer
            // a different question and answer it green (ADR-0074).
            "/unprompted": .html("""
            <html><body><script>
              var w = window.open('/child', '_blank', 'width=300,height=300');
              window.outcome = (w === null ? 'null' : 'object');
            </script></body></html>
            """),
        ])
    }

    private func openParent(
        _ model: BrowserModel,
        at origin: String
    ) async throws -> (tab: TabId, view: WKWebView) {
        let tab = try #require(model.snapshot.activeTab)
        model.send(.navigateTo(tab: tab, input: "\(origin)/parent"))
        #expect(await eventually { model.activeTab?.loadingComplete == true })
        return (tab, try #require(model.engine.webView(for: tab)))
    }

    /// A pop-up has to be in a window to behave like one, the same way the
    /// autoplay test needs one: a `WKWebView` with no window hosts a document
    /// WebKit reports as hidden.
    private func show(_ views: WKWebView..., in window: NSWindow) {
        let container = window.contentView ?? NSView(frame: window.contentLayoutRect)
        window.contentView = container
        for view in views {
            view.frame = container.bounds
            container.addSubview(view)
        }
        window.orderFront(nil)
    }

    /// **This is the one that was broken, and it was broken for everybody.**
    ///
    /// Before this, `window.open` returned `null` and nothing happened at all —
    /// no window, no tab, no error, no console message. So did every
    /// `target="_blank"` link, because WebKit routes those through the same
    /// delegate method. Measured before the fix: a real click on a real link
    /// left the tab count at 1.
    ///
    /// This asks for the whole flow a sign-in button needs, in order.
    @Test("a page opens a window, and the sign-in flow it exists for works")
    func aPageOpensAWindowAndTheFlowItExistsForWorks() async throws {
        let server = try await serve()
        defer { server.stop() }
        let origin = "http://127.0.0.1:\(server.port)"

        let model = BrowserModel(storagePath: nil)
        let (openerTab, parent) = try await openParent(model, at: origin)
        let window = testWindow(NSRect(x: 0, y: 0, width: 800, height: 600))
        defer { window.close() }
        show(parent, in: window)

        // The OAuth shape: a named window with a size on it.
        _ = try? await parent.evaluateJavaScript("""
        window.child = window.open('\(origin)/child', 'oauth', 'width=480,height=640');
        window.child === null ? 'null' : 'object'
        """)
        _ = await eventually { model.snapshot.tabs.count > 1 }

        let popup = try #require(
            model.snapshot.tabs.first { $0.openedByPage },
            """
            `window.open` opened nothing. With no `webView(_:createWebViewWith:…)` the call
            returns null and the page has no way to know — so "Sign in with Google" is a button
            that does nothing at all (ADR-0075).
            """
        )
        #expect(
            popup.space == model.snapshot.tabs.first { $0.id == openerTab }?.space,
            "the pop-up landed in a different space, which means a different cookie jar"
        )
        let popupView = try #require(model.engine.webView(for: popup.id))
        show(popupView, in: window)
        _ = await eventually { popupView.url?.absoluteString.hasSuffix("/child") == true }

        #expect(
            popupView.url?.absoluteString == "\(origin)/child",
            "the engine navigates the view it made; nothing here should have to"
        )

        // 1. `window.opener`, same origin. This is what fails first, and
        //    silently, if the view was built from a configuration of our own
        //    rather than from the one WebKit handed over.
        let reached = try await popupView.evaluateJavaScript("""
        (function () {
          try {
            if (!window.opener) { return 'no opener'; }
            return window.opener.document.getElementById('parent').textContent;
          } catch (e) { return 'threw: ' + e; }
        })()
        """) as? String
        #expect(reached == "parent", """
            the pop-up cannot see the page that opened it. `window.opener` is null when the view
            handed back was not built from the configuration WebKit passed in — and half of
            OAuth is the pop-up talking to its opener (ADR-0075).
            """)

        // 2. `postMessage` home, which is the cross-origin half and the one a
        //    real provider uses.
        _ = try? await popupView.evaluateJavaScript("window.opener.postMessage('done', '*'); 'sent'")
        func heardSoFar() async -> String? {
            try? await parent.evaluateJavaScript("window.heard") as? String
        }
        _ = await eventually { await heardSoFar() == "done" }
        let heard = await heardSoFar()
        #expect(heard == "done", """
            a message sent home from the pop-up never arrived. This is how a provider tells the
            page it opened that the sign-in finished (ADR-0075).
            """)

        // 3. `window.close()`, which is how the flow ends.
        let windowsBefore = model.snapshot.windows.count
        _ = try? await popupView.evaluateJavaScript("window.close(); 'called'")
        _ = await eventually { !model.snapshot.tabs.contains { $0.id == popup.id } }

        #expect(!model.snapshot.tabs.contains { $0.id == popup.id }, """
            the pop-up could not close itself, so a finished sign-in leaves its window sitting
            there for somebody to tidy up by hand (ADR-0075).
            """)
        #expect(model.snapshot.windows.count == windowsBefore - 1, """
            the page went and its window stayed: an empty frame with nothing in it and nothing
            to press (ADR-0075).
            """)
    }

    /// Every `<a target="_blank">` on the web arrives through the same delegate
    /// method, so this was dead too — and it is the far commoner case.
    @Test("a link that asks for a new tab opens one, beside the page it came from")
    func aLinkThatAsksForANewTabOpensOne() async throws {
        let server = try await serve()
        defer { server.stop() }
        let origin = "http://127.0.0.1:\(server.port)"

        let model = BrowserModel(storagePath: nil)
        let (openerTab, parent) = try await openParent(model, at: origin)
        let window = testWindow(NSRect(x: 0, y: 0, width: 800, height: 600))
        defer { window.close() }
        show(parent, in: window)

        let windowsBefore = model.snapshot.windows.count
        _ = try? await parent.evaluateJavaScript("document.getElementById('go').click(); 'clicked'")
        _ = await eventually { model.snapshot.tabs.count > 1 }

        let opened = try #require(model.snapshot.tabs.first { $0.id != openerTab }, """
            a link carrying `target="_blank"` did nothing at all. WebKit routes those through
            `createWebViewWith` exactly like `window.open`, so this is not a pop-up bug — it is
            every "open in a new tab" on the web (ADR-0075).
            """)

        #expect(model.snapshot.windows.count == windowsBefore, """
            an ordinary new-tab link opened a whole window. The page described no window, and a
            page that described none asked for a tab (ADR-0075).
            """)
        #expect(opened.window == model.snapshot.tabs.first { $0.id == openerTab }?.window, """
            the new tab landed in a window other than the one holding the page that was clicked.
            """)
        #expect(model.snapshot.activeTab == opened.id, "a tab you asked for arrives in front")
        #expect(opened.parent == openerTab, "the tree lost where this page came from")
    }

    /// A pop-up opened inside a private window must not leave it (ADR-0065).
    ///
    /// Asserted twice over, because the two are different claims: the core put
    /// the tab in the opener's space, **and** the engine gave it the opener's
    /// cookie jar. The second is the one that would actually write something to
    /// disk, and it holds structurally — WebKit hands over a configuration
    /// carrying the opener's store, and this host uses it as given.
    @Test("a pop-up from a private window stays private")
    func aPopUpFromAPrivateWindowStaysPrivate() async throws {
        let server = try await serve()
        defer { server.stop() }
        let origin = "http://127.0.0.1:\(server.port)"

        let model = BrowserModel(storagePath: nil)
        model.send(.openWindow(onto: .newPrivateSpace(
            name: "Private",
            dataStoreId: UUID().uuidString
        )))
        let (openerTab, parent) = try await openParent(model, at: origin)
        let ephemeral = try #require(model.snapshot.tabs.first { $0.id == openerTab }?.space)

        let window = testWindow(NSRect(x: 0, y: 0, width: 800, height: 600))
        defer { window.close() }
        show(parent, in: window)

        _ = try? await parent.evaluateJavaScript(
            "window.open('\(origin)/child', 'oauth', 'width=480,height=640'); 'ok'"
        )
        _ = await eventually { model.snapshot.tabs.contains { $0.openedByPage } }

        let popup = try #require(model.snapshot.tabs.first { $0.openedByPage })
        #expect(popup.space == ephemeral, """
            a page in a private space opened a pop-up in another space, which is another cookie
            jar — and a persistent one writes that session to disk (ADR-0065, ADR-0075).
            """)

        let popupView = try #require(model.engine.webView(for: popup.id))
        #expect(!popupView.configuration.websiteDataStore.isPersistent, """
            a pop-up opened from a private window got a store that writes to disk. This is the
            leak ADR-0007 deletes jars to avoid.
            """)
        #expect(
            popupView.configuration.websiteDataStore === parent.configuration.websiteDataStore,
            """
            the pop-up is on a different store from the page that opened it, so it is signed
            into nothing the opener is signed into — and `window.opener` is refused with it.
            """
        )
    }

    /// The pop-up gets the browser's engine settings, and gets them by
    /// inheritance rather than by being reconfigured to match.
    @Test("a pop-up is the same kind of client as the page that opened it")
    func aPopUpIsTheSameKindOfClientAsItsOpener() async throws {
        let server = try await serve()
        defer { server.stop() }
        let origin = "http://127.0.0.1:\(server.port)"

        let model = BrowserModel(storagePath: nil)
        let (_, parent) = try await openParent(model, at: origin)
        let window = testWindow(NSRect(x: 0, y: 0, width: 800, height: 600))
        defer { window.close() }
        show(parent, in: window)

        _ = try? await parent.evaluateJavaScript(
            "window.open('\(origin)/child', 'oauth', 'width=480,height=640'); 'ok'"
        )
        _ = await eventually { model.snapshot.tabs.contains { $0.openedByPage } }

        let popup = try #require(model.snapshot.tabs.first { $0.openedByPage })
        let config = try #require(model.engine.webView(for: popup.id)).configuration

        // Every value on `EnginePolicy`'s sheet, asked of a view this host
        // never configured. They are here because the configuration WebKit
        // hands over carries them, and a host that built its own would have a
        // pop-up on WebKit's embedded-view defaults with nothing to notice it
        // (ADR-0074, ADR-0075).
        #expect(config.mediaTypesRequiringUserActionForPlayback == .audio)
        #expect(config.preferences.isElementFullscreenEnabled)
        #expect(config.preferences.inactiveSchedulingPolicy == .throttle)
        #expect(!config.preferences.javaScriptCanOpenWindowsAutomatically)
        #expect(config.applicationNameForUserAgent == HostedWebView.safariUserAgentToken)
    }

    /// The engine's gate is wider than a browser's should be, and this is where
    /// the difference is held.
    ///
    /// Measured on this SDK: WebKit lets **any** view whose back-forward list
    /// holds a single entry close itself, whoever opened it. So a page you
    /// typed the address of, in a tab you opened, can make that tab vanish —
    /// Safari does exactly that. `zer0` does not: a page may close only a tab a
    /// page opened.
    @Test("a page cannot close a tab a person opened")
    func aPageCannotCloseATabAPersonOpened() async throws {
        let server = try await serve()
        defer { server.stop() }
        let origin = "http://127.0.0.1:\(server.port)"

        let model = BrowserModel(storagePath: nil)
        let (mine, view) = try await openParent(model, at: origin)
        let window = testWindow(NSRect(x: 0, y: 0, width: 800, height: 600))
        defer { window.close() }
        show(view, in: window)

        #expect(model.snapshot.tabs.first { $0.id == mine }?.openedByPage == false)

        _ = try? await view.evaluateJavaScript("window.close(); 'called'")

        // **The request arriving is what makes the refusal ours.** This used to
        // be a one-second sleep, and a sleep can only ever fail to observe the
        // tab disappearing — it is equally green when `webViewDidClose` never
        // fires, when the delegate was never wired to the view, and when the
        // script never ran. Every one of those is a browser in which a page
        // *can* close your tab and this test would never say so.
        //
        // So the arrival is waited for as a fact. `pageAskedToCloseATab` is set
        // on the way into the core, before it decides anything, which is why a
        // tab that survives afterwards survived a refusal rather than a
        // silence.
        #expect(await eventually { model.pageAskedToCloseATab == mine }, """
            `window.close()` never reached the browser at all. WebKit reports it through
            `webViewDidClose`, and with no delegate on the view there is nothing to report it to
            — so this says nothing about whether a page may close somebody's tab, because no page
            asked (ADR-0075).
            """)

        #expect(model.snapshot.tabs.contains { $0.id == mine }, """
            a page closed a tab somebody opened themselves. WebKit permits it whenever the
            back-forward list holds one entry, which is every tab you have just navigated once —
            and a tab vanishing under somebody is a loss no key brings back (ADR-0075).
            """)
    }

    /// The pop-up blocker, which only became a setting worth having the day
    /// `window.open` could open anything (ADR-0074 refused it a row for exactly
    /// that reason; ADR-0075 is the day).
    ///
    /// Both halves are behavioural and both are asked of the page. The second
    /// half is the one that matters to a person: they turn the switch off
    /// *because* a site did not work, so it has to reach the page they are
    /// already looking at — which it can, because this value lives on
    /// `WKPreferences` and lands on the next load rather than on the next tab.
    @Test("a page cannot open a window unprompted, and the switch is what lets it")
    func aPageCannotOpenAWindowUnpromptedAndTheSwitchIsWhatLetsIt() async throws {
        let server = try await serve()
        defer { server.stop() }
        let origin = "http://127.0.0.1:\(server.port)"

        let model = BrowserModel(storagePath: nil)
        #expect(model.preferences.blockUnpromptedWindows, "ships on")

        let tab = try #require(model.snapshot.activeTab)
        model.send(.navigateTo(tab: tab, input: "\(origin)/unprompted"))
        #expect(await eventually { model.activeTab?.loadingComplete == true })
        let view = try #require(model.engine.webView(for: tab))
        let window = testWindow(NSRect(x: 0, y: 0, width: 800, height: 600))
        defer { window.close() }
        show(view, in: window)

        let blocked = try await view.evaluateJavaScript("window.outcome") as? String
        #expect(blocked == "null", """
            a page opened a window with nobody having touched anything.
            `javaScriptCanOpenWindowsAutomatically` defaults to YES on macOS, which is the
            embedded-web-view answer; every browser ships a pop-up blocker (ADR-0075).
            """)
        #expect(model.snapshot.tabs.count == 1, "and nothing arrived anywhere")

        // Off, then reload the page that is already open. Nothing about the
        // tab changes and no new tab is made: this is the same view, told
        // something new.
        model.updatePreferences { $0.blockUnpromptedWindows = false }
        model.send(.reload(tab: tab, fromOrigin: false))
        #expect(await eventually { model.activeTab?.loadingComplete == true })

        func outcome() async -> String? {
            try? await view.evaluateJavaScript("window.outcome") as? String
        }
        _ = await eventually { await outcome() == "object" }
        let allowed = await outcome()
        #expect(allowed == "object", """
            turning the pop-up blocker off did not reach the page that is open, so the switch
            does nothing for the person who went looking for it — they turned it off *because*
            this page did not work. The value lives on `WKPreferences`, which an open view still
            shares, so `EngineHost.policy` has to push it at every live view (ADR-0075).
            """)
        #expect(model.snapshot.tabs.count == 2, "and the window it opened became a tab")
    }

    /// Two `window.open` calls in the same script, both approved, both owed a
    /// view.
    ///
    /// The delegate has to answer synchronously, and the slot that pairs an
    /// adoption with its `AdoptWebView` used to hold exactly one pending
    /// configuration. A second open that arrived while the first was still
    /// being adopted was answered with `nil` — which is the page's spelling of
    /// a pop-up blocker nobody configured. The core had already said yes to
    /// both; refusing the second was a limit of the mechanism wearing a
    /// decision's clothes.
    @Test("two approved windows opened in the same breath both arrive")
    func twoApprovedWindowsOpenedTogetherBothArrive() async throws {
        let server = try await serve()
        defer { server.stop() }
        let origin = "http://127.0.0.1:\(server.port)"

        let model = BrowserModel(storagePath: nil)
        let (openerTab, parent) = try await openParent(model, at: origin)
        let window = testWindow(NSRect(x: 0, y: 0, width: 800, height: 600))
        defer { window.close() }
        show(parent, in: window)

        // One gesture, two opens: each call is approved on its own, and the
        // page is owed an answer for both. The outcomes are read back from the
        // page rather than from our own delegate, so a `null` here is what a
        // site would have seen.
        _ = try? await parent.evaluateJavaScript("""
        var a = window.open('\(origin)/child', 'one', 'width=300,height=300');
        var b = window.open('\(origin)/child', 'two', 'width=300,height=300');
        [a === null ? 'null' : 'object', b === null ? 'null' : 'object'].join()
        """)
        _ = await eventually { model.snapshot.tabs.filter { $0.openedByPage }.count == 2 }

        let opened = model.snapshot.tabs.filter { $0.openedByPage }
        #expect(opened.count == 2, """
            \(2 - opened.count) of the two windows a page opened with one gesture died. The core
            approved both; only the shell's single adoption slot stands between them (ADR-0075).
            """)
        for tab in opened {
            #expect(
                model.engine.webView(for: tab.id) != nil,
                "the tab arrived without a view of its own"
            )
        }
        #expect(opened.allSatisfy { $0.parent == openerTab }, "the tree lost where these came from")
    }

    /// One door, counted rather than trusted.
    ///
    /// `createWebViewWith` is the only place a pop-up can come from, and
    /// `EngineHost.adopt` is the only place a view is built from a configuration
    /// this host did not make. A second implementation of either would be a
    /// second answer to which space a page's window lands in, and every
    /// behavioural test above would stay green because they all go through the
    /// first one.
    @Test("a page's window is opened in one place and adopted in one place")
    func aPagesWindowIsOpenedInOnePlaceAndAdoptedInOnePlace() throws {
        var delegates: [String] = []
        var adopters: [String] = []

        for source in try SourceScan.shellSources() {
            if !SourceScan.occurrences(of: "createWebViewWith", in: source.code).isEmpty {
                delegates.append(source.name)
            }
            // Both spellings. Every view is a `PageView` since ADR-0091 — the
            // context menu is reached through an `NSView` override, so a plain
            // `WKWebView` is one that silently has no menu — and a second door
            // opened with either name is the same defect this counts.
            if !SourceScan.occurrences(of: "WKWebView(frame:", in: source.code).isEmpty
                || !SourceScan.occurrences(of: "PageView(frame:", in: source.code).isEmpty
            {
                adopters.append(source.name)
            }
        }

        #expect(delegates == ["PopupHost.swift"], """
            `createWebViewWith` is implemented somewhere other than PopupHost.swift: \(delegates).
            A rule enforced at N call sites has N−1 bugs waiting, and the missing one here is a
            pop-up in the wrong cookie jar (ADR-0075).
            """)
        #expect(adopters == ["EngineHost.swift"], """
            a `WKWebView` is built outside EngineHost.swift: \(adopters). The pop-up path must
            build its view from the configuration WebKit handed over and from no other, or
            `window.opener`, `postMessage` home and `window.close()` all fail quietly
            (ADR-0075).
            """)
    }
}
