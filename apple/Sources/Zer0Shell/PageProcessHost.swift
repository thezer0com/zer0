import Foundation
import WebKit
import Zer0Core

/// The two things a `WKWebView` knows about a tab's page that nothing else
/// does: where it has been, and whether the process drawing it is still alive.
///
/// Both are reported and neither is decided. What a dead page looks like is
/// ADR-0016's screen, and whether a refused history costs the tab is the
/// reducer's answer.
extension HostedWebView {
    // MARK: - The page died

    /// The web content process rendering this page ended.
    ///
    /// Not implemented at all until now, which is why a crashed tab was a tab
    /// nothing could bring back: with no delegate method WebKit's answer is a
    /// blank view, `url` at `nil`, and no notification anywhere — measured, and
    /// measured with an instrument shown catching the crash first, because a
    /// callback that never fires and a callback nobody wrote look identical
    /// from inside the code.
    ///
    /// **Nothing is loaded from here.** A page that ends its process *during*
    /// its own load would be loaded again into the same crash, forever, with
    /// nothing on screen to say why. The core is told the fact and the person
    /// is given the address and one key, which is the same bargain every other
    /// failed page in this browser gets.
    ///
    /// The view is kept. It was measured working: an ordinary load into the
    /// same `WKWebView` after its process was killed outright recovers the page
    /// in under 50ms, whether it is asked for from inside this callback, a run
    /// loop later or three seconds later, and whether or not the view is on
    /// screen. Replacing it would cost the tab its scroll, its zoom and its
    /// place in the view hierarchy to buy nothing.
    func webViewWebContentProcessDidTerminate(_: WKWebView) {
        emitAction(.pageProcessEnded(tab: tab))
    }

    // MARK: - Where the tab has been

    /// Hand the engine a back/forward list it wrote down in a previous run, and
    /// say whether it took it.
    ///
    /// `interactionState` is opaque on both sides — the core stores bytes it
    /// cannot read and this cannot read them either — so "was that a real
    /// archive" has exactly one authority, and it is the engine. Measured on
    /// macOS 26.5: a whole state leaves `backForwardList.currentItem` set on
    /// the very next line, and a truncated one, a random one, an empty one and
    /// a value that is not `Data` all leave it `nil` with the view otherwise
    /// untouched and perfectly able to load. So the answer is synchronous, it
    /// is the only signal there is, and a refusal costs nothing.
    ///
    /// **The implicit load can fail, and it fails quietly.** Setting
    /// `interactionState` makes the engine load the current item by itself,
    /// and measured 2026-08-16 — chasing a gate that was intermittently red
    /// under a loaded tree and clean without it (0 failures in 6 runs on
    /// HEAD, 11 in 19 with the WIP) — under UI-process contention that load
    /// fails transiently: a "Cannot open file" failure, the view's `url`
    /// still `nil`, and the tab on ADR-0016's dead-page screen where retry
    /// is the person's. Nothing here detects or retries it: reloading a page
    /// whose load died of contention is the same bargain as one whose
    /// process died on load, and the fact is written down so the next person
    /// recognises WebKit's cliff instead of suspecting the core.
    ///
    /// Returning it rather than acting on it: the core held back this tab's
    /// `LoadUrl` when it handed the state over, and whether to send it now is
    /// the core's call.
    func restore(navigationState: Data) -> Bool {
        webView.interactionState = navigationState
        return webView.backForwardList.currentItem != nil
    }

    /// Tell the core where this tab has been, as the engine has it now.
    ///
    /// Called when a navigation settles rather than continuously: the archive
    /// only grows when the back/forward list does. Measured, it is 730 bytes
    /// after one page and 4,457 after twelve — around 340 bytes an entry — so
    /// one of these per page load is a smaller thing to carry than the history
    /// row the same commit already wrote.
    ///
    /// A view that has never navigated still reports 137 bytes of nothing, so
    /// the guard is on having committed a page rather than on the archive being
    /// empty: `NavigationStates` would keep those 137 bytes for every blank tab
    /// in the browser and hand them back at the next launch as a history of
    /// nowhere.
    func reportNavigationState() {
        guard webView.url != nil, let state = webView.interactionState as? Data else { return }
        emitAction(.navigationStateChanged(tab: tab, state: state))
    }

    /// Tell the core whether this tab can go back and forward, as the engine
    /// answers it right now.
    ///
    /// Whether ⌘[ does anything is behaviour, so the answer is the core's to
    /// hold and every reader's to take from the snapshot — never a question
    /// this shell puts to its own engine, which is the shape each platform
    /// would answer its own way (ADR-0002). The *reading* is still the host's,
    /// because only the engine holds the list; that is the whole division of
    /// labour here.
    ///
    /// Called from the observations on the two properties, which is one door
    /// covering every path that moves the engine's answer — a commit, a Back,
    /// a restore — rather than an emission point per path that a new one
    /// could forget. (Measured: a same-document `history.pushState` does not
    /// move `canGoBack` at all — WebKit keeps those entries in the page's own
    /// history and out of the back/forward list — so there is genuinely
    /// nothing to report on that path, and the core and the engine stay in
    /// agreement by both saying no.)
    ///
    /// Deduplicated against the last pair this view reported: both
    /// observers fire for one navigation — measured 2026-08-16, when the
    /// doubled reports were the largest per-navigation addition in the tree
    /// — and the unchanged flag's fire repeats what the changed flag's
    /// already said. A repeated pair would cost a full core dispatch and
    /// refresh to change nothing, so it is not sent.
    func reportNavigationStack() {
        let back = webView.canGoBack
        let forward = webView.canGoForward
        if let last = lastReportedStack, last.canGoBack == back, last.canGoForward == forward {
            return
        }
        lastReportedStack = (canGoBack: back, canGoForward: forward)
        emitAction(.navigationStackChanged(
            tab: tab,
            canGoBack: back,
            canGoForward: forward
        ))
    }
}
