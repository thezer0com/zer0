import AppKit
import Foundation
import Testing
import WebKit
import Zer0Core

@testable import Zer0Shell

/// `window.print()`, which reaches nothing on its own (ADR-0101).
///
/// Nothing here opens a print panel, and that is deliberate rather than a gap: a
/// panel is app-modal, so a test that let one open would never return. What can
/// be asserted is everything up to it — that the page's own function is ours,
/// that calling it produces the action, and that a page in no window opens
/// nothing at all.
@MainActor
struct PagePrintTests {
    /// The whole shell half in one test: the replacement lands on a view built
    /// the ordinary way, the page's `window.print` is the one we wrote, and
    /// calling it arrives as the action the core answers.
    @Test("window.print is replaced and what it says reaches the browser")
    func windowPrintIsReplacedAndReachesTheBrowser() async throws {
        // Through the model, so this is a view built the way the browser builds
        // them. A test that only attached a channel of its own would prove the
        // script works and nothing about whether anybody attaches it.
        let m = BrowserModel(storagePath: nil)
        let tab = try #require(m.snapshot.activeTab)
        m.send(.navigateTo(tab: tab, input: "about:blank"))
        let webView = try #require(m.engine.webView(for: tab))
        #expect(await eventually { webView.url != nil })

        let source = try await webView.evaluateJavaScript("String(window.print)") as? String
        #expect(
            source?.contains("postMessage") == true,
            "the page's print function is still the engine's dead one: \(source ?? "nil")"
        )

        // And the road it takes. The channel reads the tab and the reporter
        // off the view rather than holding either, so swapping the reporter is
        // enough to watch what the page says — and it watches it on a view the
        // browser built, which is the only view whose behaviour is the product.
        //
        // A bare `WKWebView` of the test's own was tried here and is what this
        // deliberately avoids: one that has loaded a page and is then dropped
        // takes its web content process with it, and under a full parallel suite
        // that tears a `WKProcessPool` down inside an IPC dispatch — measured, an
        // `EXC_BREAKPOINT` in `WebProcessPool::~WebProcessPool` that kills the
        // runner rather than failing a test.
        var said: [Action] = []
        let page = try #require(webView as? PageView)
        page.emit = { said.append($0) }

        _ = try? await page.evaluateJavaScript("window.print()")

        #expect(await eventually(timeout: .seconds(10)) { !said.isEmpty })
        #expect(said == [.pageAskedToPrint(tab: tab)])
    }

    /// Two views over one content controller, which is what a pop-up is.
    ///
    /// ADR-0075 hands an adopted view the **opener's** configuration, object for
    /// object, so `attach` runs twice over one controller. `add(_:name:)` under
    /// a name that already exists raises `NSInvalidArgumentException`, which
    /// Swift cannot catch — it took the whole test process down rather than
    /// failing a test, and read to three agents as an unattributable crash.
    ///
    /// The assertion is that the second attach returns at all, and that the
    /// second view still gets the replaced function. A test that only opened a
    /// pop-up would prove the same thing, and would prove it by killing the
    /// process rather than by going red.
    @Test("attaching twice over one content controller is not a crash")
    func attachingTwiceOverOneControllerIsNotACrash() async throws {
        let configuration = WKWebViewConfiguration()
        let opener = PageView(frame: .zero, configuration: configuration)
        PagePrintChannel.attach(to: opener)

        // The pop-up path: a second view built from the same configuration.
        // Neither is ever loaded, so neither starts a web content process —
        // what is being asked is whether the second attach returns at all.
        let opened = PageView(frame: .zero, configuration: configuration)
        PagePrintChannel.attach(to: opened)

        let controller = opened.configuration.userContentController
        #expect(
            controller.userScripts.filter { $0.source == PagePrintScript.source }.count == 1,
            "one controller carried two copies of the script"
        )
        #expect(opener.configuration.userContentController === controller)
    }

    /// The panel is a sheet, and a sheet needs the window the page is in. The
    /// line this replaces passed `NSWindow()` when there was none, which opens
    /// the panel on a window nobody can see and nobody can dismiss.
    ///
    /// Asserted as a refusal rather than as a panel, and it has to be: a test
    /// that waited for a panel on an invisible window would hang, which is how
    /// this stayed invisible.
    @Test("printing a page that is in no window opens nothing")
    func printingAPageInNoWindowOpensNothing() async throws {
        let m = BrowserModel(storagePath: nil)
        let tab = try #require(m.snapshot.activeTab)
        m.send(.navigateTo(tab: tab, input: "about:blank"))
        let webView = try #require(m.engine.webView(for: tab))
        #expect(webView.window == nil, "the premise of this test")

        #expect(m.engine.printPage(tab) == false)
        #expect(NSApp.modalWindow == nil, "a modal opened on a window nobody can see")
    }

    /// A tab with no view at all — closed, or one of the browser's own pages,
    /// which are native views with nothing for a print operation to run over.
    @Test("printing a tab with no page opens nothing")
    func printingATabWithNoPageOpensNothing() async throws {
        let m = BrowserModel(storagePath: nil)
        let tab = try #require(m.snapshot.activeTab)
        m.send(.closeTab(tab: tab))

        #expect(m.engine.printPage(tab) == false)
        #expect(NSApp.modalWindow == nil)
    }
}
