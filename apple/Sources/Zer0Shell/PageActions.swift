import AppKit
import Foundation
import Observation
import WebKit
import Zer0Core

/// Things you do to the page in front of you: save it, print it, read its
/// source, search inside it.
///
/// These are effects rather than state, so they live on the engine host and
/// never round-trip through the reducer. Nothing about the browser changes
/// because you printed something.
@MainActor
extension EngineHost {
    /// Save the page as HTML.
    ///
    /// The document is taken from the live DOM rather than re-fetched, so what
    /// you save is what you were looking at, script-rendered content included.
    func savePage(_ tab: TabId, suggestedName: String) {
        guard let webView = webView(for: tab) else { return }

        webView.evaluateJavaScript("document.documentElement.outerHTML") { result, _ in
            MainActor.assumeIsolated {
                guard let html = result as? String else {
                    NSSound.beep()
                    return
                }
                let panel = NSSavePanel()
                panel.nameFieldStringValue = Self.filename(from: suggestedName)
                panel.allowedContentTypes = [.html]
                panel.canCreateDirectories = true

                guard panel.runModal() == .OK, let url = panel.url else { return }
                try? html.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Fetch a URL as a file through `tab`'s web view, and answer with the id
    /// the download will have.
    ///
    /// Through that tab's view so the space's cookies come with it. A view that
    /// is gone means there is no jar to use, and fetching through the wrong one
    /// would download a sign-in page and call it the file (ADR-0027) — so this
    /// answers `nil` rather than picking another view, and the extension that
    /// asked is told the download did not start rather than told an id for
    /// nothing.
    @discardableResult
    func startDownload(_ url: String, in tab: TabId) -> String? {
        guard let view = webView(for: tab) else { return nil }
        return downloads.start(url, in: view, tab: tab)
    }

    /// Put the print panel up for `tab`.
    ///
    /// Reports whether it opened rather than saying so, the same arrangement
    /// `toggleDevTools` has: a host that puts a sheet on screen to explain
    /// itself is a host a test cannot call.
    ///
    /// Both refusals below used to be one line: `runModal(for: webView.window ??
    /// NSWindow())`. A fresh `NSWindow` is never ordered in, so the panel opened
    /// on a window nobody could see and nobody could dismiss — the browser
    /// waiting on an answer to a question it never asked. There is no repair for
    /// "this page is in no window"; the panel is a sheet, and a sheet needs one.
    @discardableResult
    func printPage(_ tab: TabId) -> Bool {
        guard let webView = webView(for: tab), let window = webView.window else { return false }
        // AppKit queues a second sheet behind the first rather than refusing it,
        // and a print panel that surfaces minutes later under whatever is on
        // screen by then is a modal with no cause anybody can name.
        guard window.attachedSheet == nil else { return false }

        let info = NSPrintInfo.shared
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic

        let operation = webView.printOperation(with: info)
        operation.view?.frame = webView.bounds
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        return true
    }

    /// Stop whatever is loading. Bound to Escape, like Chrome.
    func stopLoading(_ tab: TabId) {
        webView(for: tab)?.stopLoading()
    }

    /// Open the Web Inspector, or put it away.
    ///
    /// The page is left alone: everything that makes it inspectable was set
    /// when the view was built, so there is nothing to switch on here and
    /// nothing to reload (ADR-0067).
    ///
    /// Reports what happened rather than saying it. Telling somebody the
    /// inspector could not open means putting a sheet on screen, and a host
    /// that puts sheets on screen is a host a test cannot call.
    ///
    /// `nil` is "there is no page here" — an internal page is native views, so
    /// there is nothing for an inspector to attach to. Distinct from
    /// `.unavailable`, which is a real page WebKit refused to open; answering
    /// that one with "this WebKit cannot open the inspector" would be blaming
    /// WebKit for something it was never asked.
    @discardableResult
    func toggleDevTools(_ tab: TabId) -> WebInspector.Outcome? {
        guard let webView = webView(for: tab) else { return nil }
        return WebInspector.toggle(webView)
    }

    /// A file name that will not embarrass anyone, derived from the title.
    static func filename(from title: String) -> String {
        let cleaned = title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let base = cleaned.isEmpty ? "Page" : String(cleaned.prefix(80))
        return "\(base).html"
    }
}

/// `window.print()`, which reaches nothing on its own.
///
/// Measured on a real `WKWebView` with exactly the delegate this shell sets:
/// `typeof window.print` is `function`, calling it returns immediately, and
/// afterwards `NSApp.modalWindow` and the window's `attachedSheet` are both
/// `nil`. The instrument was established first — `alert()` on the same view
/// reached a `WKUIDelegate` we do implement — so that is WebKit's answer rather
/// than the harness missing it. Safari's own route is `_webView:printFrame:`,
/// which is SPI, and ADR-0067 confines SPI to one file and says in as many words
/// that it is not a precedent for a second.
///
/// So the page's own function is replaced with one that posts a message. Three
/// things about that are decisions rather than mechanics:
///
/// - **The page world, necessarily.** Every other script this browser injects
///   runs in a world of its own so its channel is out of the page's reach. This
///   one cannot: a named world shares the DOM and not the globals, so a
///   `window.print` replaced there is not the one the page calls. The channel is
///   therefore reachable as `window.webkit.messageHandlers.zer0Print` — and what
///   it grants is exactly what `window.print()` grants, to exactly the same
///   caller, through exactly the same gate in the core. There is nothing here to
///   escalate to.
/// - **The main frame only.** A cross-origin subframe — an advert — calling
///   `print()` would otherwise put a panel over the page somebody is reading, on
///   behalf of a document they never chose. The cost is that a subframe's
///   `window.print()` still does nothing, which is the same nothing it does
///   today.
/// - **The core decides, not this file.** The message is a report, and
///   `Action::PageAskedToPrint` is where "may this page print right now" is
///   answered — on the same ground ADR-0089 uses for the panels a page raises.
enum PagePrintScript {
    /// The name the script posts to, and the name Swift listens on.
    static let channel = "zer0Print"

    static let source = """
    (() => {
      "use strict";
      const handlers = window.webkit && window.webkit.messageHandlers;
      const channel = handlers ? handlers.\(channel) : null;
      if (!channel) return;
      // Named, so a page that logs `window.print` sees a function rather than
      // an anonymous one — the engine's own is named too.
      window.print = function print() {
        try { channel.postMessage(null); } catch (e) { /* the view went away */ }
      };
    })();
    """
}

/// Carries `window.print()` from a page back to the core.
///
/// **Stateless, unlike every other channel in this shell**, and that is forced
/// rather than chosen. `StoreInstallChannel` holds its tab because a channel
/// that has to work out which tab it belongs to is one that can answer for the
/// wrong one — but that only works where each view has a content controller of
/// its own, and a pop-up does not: the engine hands over the **opener's**
/// configuration, and the controller inside it is the same object (ADR-0075).
/// A per-view handler would therefore have to answer for two views, and it
/// would answer for the wrong one.
///
/// So the tab is read off the view the message came from, and it cannot be
/// wrong because `PageView.tab` is what the context menu already reads
/// (ADR-0091). The message body is never looked at: there is nothing a page
/// could say here that would change the answer.
@MainActor
final class PagePrintChannel: NSObject, WKScriptMessageHandler {
    /// Attach to a view. Both ways a view comes into being end up here, so a
    /// pop-up's `window.print()` works exactly as an ordinary page's does.
    ///
    /// Idempotent per content controller, because it has to be. Two views
    /// sharing one — the pop-up case again — reach this twice, and
    /// `addScriptMessageHandler` under a name that already exists raises
    /// `NSInvalidArgumentException`, which is not something Swift can catch:
    /// measured, it took the whole test process down the first time a pop-up
    /// test ran.
    static func attach(to webView: PageView) {
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: PagePrintScript.channel)
        controller.add(PagePrintChannel(), name: PagePrintScript.channel)

        // The same sentence for the script. A controller carrying two copies
        // would replace `window.print` twice — harmless today, and the sort of
        // thing that stops being harmless the moment the script keeps state.
        guard !controller.userScripts.contains(where: { $0.source == PagePrintScript.source })
        else { return }

        controller.addUserScript(WKUserScript(
            // At document start: a page is free to call `print()` from its first
            // inline script, and a replacement that lands afterwards would miss
            // it and leave the engine's dead one in place for that one call.
            source: PagePrintScript.source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
    }

    /// `nonisolated`, and it is not a formality. Written as an actor-isolated
    /// method it compiles, conforms, and is **never called** — measured: the
    /// same view whose `window.print` was demonstrably ours delivered nothing at
    /// all until this word was added. It is the trap ADR-0089 records one
    /// protocol along, and it reads exactly like the handler not being attached.
    nonisolated func userContentController(
        _: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        MainActor.assumeIsolated {
            // The script is injected into the main frame only, so a message
            // from anywhere else did not come from it.
            guard message.frameInfo.isMainFrame,
                  let view = message.webView as? PageView,
                  let tab = view.tab
            else { return }

            view.emit?(.pageAskedToPrint(tab: tab))
        }
    }
}

/// Finding text in the page.
///
/// WebKit does the searching and the highlighting; this only remembers what
/// was asked for, so ⌘G can repeat it.
@MainActor
@Observable
final class PageFinder {
    private(set) var query: String = ""
    private(set) var isOpen = false
    private(set) var lastSearchFound = true
    /// A search is in flight. WebKit answers asynchronously, and a bar that
    /// says nothing while it waits looks broken on a long page.
    private(set) var isSearching = false

    func open(seededWith selection: String?) {
        if let selection, !selection.isEmpty {
            query = selection
        }
        isOpen = true
    }

    func close() {
        isOpen = false
        isSearching = false
    }

    func setQuery(_ value: String) {
        query = value
    }

    /// Search `webView`, wrapping at the end the way every browser does.
    func find(
        in webView: WKWebView?,
        forwards: Bool,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        guard let webView, !query.isEmpty else {
            isSearching = false
            completion(true)
            return
        }
        isSearching = true
        let configuration = WKFindConfiguration()
        configuration.backwards = !forwards
        configuration.caseSensitive = false
        configuration.wraps = true

        webView.find(query, configuration: configuration) { [weak self] result in
            MainActor.assumeIsolated {
                self?.isSearching = false
                self?.lastSearchFound = result.matchFound
                completion(result.matchFound)
            }
        }
    }
}
