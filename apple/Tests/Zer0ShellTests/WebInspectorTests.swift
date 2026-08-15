import AppKit
import SwiftUI
import Testing
import WebKit
import Zer0Core

@testable import Zer0Shell

/// ⌥⌘I and ⇧⌘I open the Web Inspector (ADR-0067).
///
/// **The interesting failure here is not "we forgot to call it", it is "the
/// thing we call stopped existing."** Opening the inspector has no public API;
/// it is reached through `_WKInspector`, which Apple can delete in a point
/// release with no deprecation and no compile-time warning. A test that the
/// call happened would stay green through exactly that. So the first test below
/// asks the runtime whether the symbol is still there, which is the question
/// whose answer can change without anybody in this repository touching
/// anything.
@MainActor
struct WebInspectorTests {
    /// In-memory only. A test must never touch the real session on disk.
    private func model() -> BrowserModel {
        BrowserModel(storagePath: nil)
    }

    /// Where WebKit remembers whether the inspector was last docked. Not used
    /// by the shell — the shell detaches by asking, not by writing preferences
    /// — but a test that does not reset it is a test whose result depends on
    /// what ran on this machine yesterday.
    private let inspectorStartsAttachedKey =
        "__WebInspectorPageGroupLevel1__.WebKit2InspectorStartsAttached"

    /// Both chords, spelled the way a real keyboard spells them.
    ///
    /// `everyDefaultChordIsReachable` already walks the whole keymap, so this
    /// is not the general lock — it is the one press the owner asked for,
    /// pinned with the key code and the characters a keyboard actually sends.
    /// ⇧⌘I arrives as key code 34 reporting `"I"`, because
    /// `charactersIgnoringModifiers` ignores Command and Option and keeps
    /// Shift; ⌥⌘I arrives on the same key reporting `"i"`. Measured off a real
    /// press rather than assumed, because assuming it is how a keymap test
    /// stays green over a chord that never arrives.
    @Test("both inspector chords arrive from a real press")
    func bothInspectorChordsArriveFromARealPress() throws {
        let m = model()
        let iKey: UInt16 = 34

        #expect(
            m.command(forKeyCode: iKey, characters: "I", modifiers: [.command, .shift])
                == .toggleDevTools
        )
        #expect(
            m.command(forKeyCode: iKey, characters: "i", modifiers: [.command, .option])
                == .toggleDevTools
        )
    }

    /// **This is the canary.** When it goes red, the machine running it has a
    /// WebKit with no `_WKInspector` in it, and ADR-0067's named consequence
    /// has arrived: ⌥⌘I stops opening anything and says so, the public routes
    /// carry on working, and the exception is due for withdrawal.
    ///
    /// Every name asked about is read off `WebInspector` rather than written
    /// out again here, so the test cannot drift into asking about a symbol the
    /// shell no longer uses and passing on it.
    @Test("the inspector is still behind the door WebInspector knocks on")
    func theInspectorIsStillBehindTheDoor() throws {
        let inspectorClass: NSObject.Type = try #require(
            NSClassFromString(WebInspector.inspectorClassName) as? NSObject.Type,
            """

            WebKit no longer has \(WebInspector.inspectorClassName).
              Opening the Web Inspector has no public API, so this class is the only door
              (ADR-0067). Nothing crashes — WebInspector looks it up at runtime and ⌥⌘I now
              reports that it cannot open, while Safari's Develop menu keeps working because
              `isInspectable` is public. What is owed is a decision: check whether WebKit has
              grown a public way to open the inspector, and supersede ADR-0067 either way.
            """
        )

        // `show` and `hide` are the two this file sends, and `isVisible` is
        // what it reads to decide between them. A class that survived with the
        // methods renamed is the same outage.
        for selector in ["show", "hide", "isVisible"] {
            #expect(
                inspectorClass.instancesRespond(to: Selector((selector))),
                "\(WebInspector.inspectorClassName) no longer responds to \(selector)"
            )
        }

        #expect(
            WKWebView.instancesRespond(to: Selector((WebInspector.inspectorAccessor))),
            "WKWebView no longer has \(WebInspector.inspectorAccessor), so no page can reach its inspector"
        )

        // **The second switch, and the one whose absence would crash rather
        // than degrade.** `show` opens nothing without it — measured, not
        // assumed — and writing the key when the accessor is gone raises
        // `NSUnknownKeyException`, which Swift cannot catch. `allowInspection`
        // asks this same question before writing; if the answer ever changes,
        // this test says so instead of a launch crash saying it.
        #expect(
            WKPreferences.instancesRespond(to: Selector((WebInspector.developerExtrasSetter))),
            """
            WKPreferences no longer has \(WebInspector.developerExtrasSetter).
              Nothing crashes — allowInspection guards on exactly this — but pages are no longer
              inspectable from inside the app, and only Safari's Develop menu is left (ADR-0067).
            """
        )

        // The same question, asked the way the shell asks it. If these two ever
        // disagree, `isAvailable` is lying to the alert.
        #expect(WebInspector.isAvailable)
    }

    /// Both switches, on every page, set when the view is built rather than
    /// when somebody first presses ⌥⌘I. That timing is the whole of the fix
    /// below: neither reaches a page that has already loaded, which is why the
    /// old code reloaded.
    ///
    /// `isInspectable` is the public one and the one that survives Apple
    /// deleting the private half — it is what lets Safari's Develop menu
    /// attach. The preference is what lets the inspector open from inside the
    /// app at all.
    @Test("a page is inspectable before anybody asks")
    func aPageIsInspectableBeforeAnybodyAsks() throws {
        let m = model()
        let tab = try #require(m.snapshot.activeTab)
        let webView = try #require(m.engine.webView(for: tab))

        #expect(webView.isInspectable, """
            a page that is not inspectable cannot be reached by Safari's Develop menu, which is
            the devtools route that survives whatever Apple does to the private one. Set it
            where the view is built (ADR-0067); setting it later means reloading the page.
            """)

        let extras = webView.configuration.preferences
            .value(forKey: WebInspector.developerExtrasKey) as? Bool
        #expect(extras == true, """
            developer extras are off, so ⌥⌘I will report that it cannot open the inspector even
            though `_WKInspector` is right there — WebKit gates the local inspector on this
            preference, and `show` returns cleanly and opens nothing without it (ADR-0067).
            """)
    }

    /// **The bug this replaced.** `toggleDevTools` used to switch
    /// `isInspectable` on and reload, so the entire observable effect of the
    /// shortcut was that the page came back — scroll position gone, form
    /// contents gone, and no inspector.
    ///
    /// Asked through the page rather than through `webView.url`, because a
    /// reload lands on the same URL and would leave a URL check green. A value
    /// set on `window` survives a toggle and does not survive a reload.
    @Test("opening the inspector does not throw the page away")
    func openingTheInspectorDoesNotThrowThePageAway() async throws {
        let m = model()
        let tab = try #require(m.snapshot.activeTab)
        let webView = try #require(m.engine.webView(for: tab))

        // **The web view is hosted the way the shell hosts it, and that is
        // load-bearing.** WebKit docks the inspector into the inspected view's
        // superview, so a bare web view with no window cannot tell a docked
        // inspector from a detached one — the version of this test without a
        // window stayed green with the fix removed. `WebViewContainer` inside
        // an `NSHostingView` is what `BrowserView` does.
        let window = testWindow(
            NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .resizable]
        )
        window.contentView = NSHostingView(rootView: WebViewContainer(webView: webView))
        window.orderFront(nil)
        defer { window.close() }

        // **Start from WebKit's own default, which is docked.** WebKit writes
        // the dock side into the running process's user defaults the first time
        // anything detaches, and after that it opens detached on its own —
        // which would leave this test green on a machine that has run it before
        // and red only on CI. Clearing it makes every run exercise the detach.
        // This is the test process's defaults domain, not anybody's app.
        UserDefaults.standard.removeObject(forKey: inspectorStartsAttachedKey)

        webView.loadHTMLString(
            "<html><head><title>inspect me</title></head><body>hi</body></html>",
            baseURL: nil
        )
        #expect(await eventually { m.activeTab?.title == "inspect me" })

        _ = try await webView.evaluateJavaScript("window.zer0Survived = 'yes'")

        #expect(m.engine.toggleDevTools(tab) == .shown)
        // It really came up, rather than the call merely returning. WebKit
        // reports the inspector visible about 150ms after `show`, once the
        // frontend is up, so this is waited for rather than assumed.
        #expect(await eventually { WebInspector.isShowing(webView) }, """
            the inspector never appeared. `show` returned without opening anything, which is
            what it does when developer extras are off (ADR-0067).
            """)

        // **And it came up somewhere a person could see it.** `isVisible` was
        // `true` in the arrangement where WebKit docked the frontend into the
        // SwiftUI view hosting the page and SwiftUI laid the page straight back
        // over it — visible by WebKit's account, invisible on screen. A window
        // of its own is the thing that cannot be true while nothing shows.
        #expect(
            await eventually {
                let home = WebInspector.window(for: webView)
                return home != nil && home !== window
            },
            """
            the inspector is docked inside the window showing the page. Under SwiftUI that means
            it is behind the page and nobody will ever see it, while `isVisible` cheerfully
            reports true — detach it into a window of its own (ADR-0067).
            """
        )

        // Put it away again, so a run of the suite does not leave an inspector
        // window behind.
        #expect(m.engine.toggleDevTools(tab) == .hidden)
        #expect(!WebInspector.isShowing(webView))

        let survived = try await webView.evaluateJavaScript("window.zer0Survived") as? String
        #expect(survived == "yes", """
            the page was reloaded. Opening the inspector must not touch the page: the view is
            inspectable from birth, so there is nothing to switch on and nothing to reload
            (ADR-0067).
            """)
    }

    /// An internal page — History, Downloads — is native views, so there is no
    /// web view and nothing to inspect. That has to read as "nothing here",
    /// never as "WebKit refused", because the second one puts an alert on
    /// screen blaming WebKit for a question it was never asked.
    @Test("a page with no web view is nothing to inspect, not a failure")
    func aPageWithNoWebViewIsNothingToInspect() throws {
        let m = model()
        let tab = try #require(m.snapshot.activeTab)
        m.closeActiveTab()

        #expect(m.engine.webView(for: tab) == nil)
        #expect(m.engine.toggleDevTools(tab) == nil)
    }
}
