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
}
