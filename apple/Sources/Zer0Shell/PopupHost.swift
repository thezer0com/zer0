import Foundation
import WebKit
import Zer0Core

/// Turn a configuration the engine built into a view, or refuse.
///
/// Returning `nil` is what a blocked pop-up looks like from inside the page:
/// `window.open` evaluates to `null` and nothing happens anywhere.
typealias PopupOpener = @MainActor (WKWebViewConfiguration, TabId, WindowRequest) -> WKWebView?

/// `window.open`, `target="_blank"`, and `window.close()` (ADR-0075).
///
/// Both methods are on `SitePermissionDelegate` because `WKWebView.uiDelegate`
/// is one property and a view has one of them. They are in a file of their own
/// because they are a different decision from the camera, and because the
/// sentence that matters here is short enough to be worth not burying.
extension SitePermissionDelegate {
    /// A page asked for a view of its own.
    ///
    /// **The configuration is used exactly as handed over.** WebKit is not
    /// asking for *a* web view, it is asking for one built from *this*
    /// configuration: that object is what carries the browsing-context
    /// relationship, and measured on this SDK it carries the opener's
    /// `websiteDataStore`, `userContentController` and `WKPreferences` as the
    /// same objects. Substitute one and `window.opener` is `null`, a
    /// `postMessage` home goes nowhere and `window.close()` does nothing — the
    /// three things an OAuth pop-up is made of, each failing quietly.
    ///
    /// Nothing here decides anything. What the page asked for is reported as
    /// [`WindowRequest`] and the core decides whether that is a tab or a
    /// window, which space it lands in and which window it belongs to.
    ///
    /// **This is also every `target="_blank"` link.** WebKit routes those
    /// through here too, which is why their absence was not a pop-up bug — it
    /// was every "open in a new tab" on the web doing nothing at all.
    ///
    /// Not implementing this is *not* the same as blocking it, and that
    /// distinction is the whole reason the method has to exist even if the
    /// answer is sometimes no: with no implementation there is no place to say
    /// no from, no place to count it, and nothing a person could ever turn
    /// back on.
    func webView(
        _: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for _: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        openWindow(configuration, tab, Self.requested(windowFeatures))
    }

    /// What the page wrote in the feature string, uninterpreted.
    ///
    /// Every field is a `WKWindowFeatures` optional and stays optional: `nil`
    /// means the page said nothing about it, which is the difference between
    /// `window.open(url)` and `window.open(url, name, 'width=480,height=640')`
    /// and therefore the only thing there is to go on. What it adds up to is
    /// `WindowRequest::asked_for_a_window`, in the core.
    ///
    /// `allowsResizing` is left out because it says nothing about whether a
    /// window was wanted, and because leaving it out is a decision rather than
    /// an oversight.
    static func requested(_ features: WKWindowFeatures) -> WindowRequest {
        WindowRequest(
            width: features.width?.doubleValue,
            height: features.height?.doubleValue,
            x: features.x?.doubleValue,
            y: features.y?.doubleValue,
            menuBarVisible: features.menuBarVisibility?.boolValue,
            statusBarVisible: features.statusBarVisibility?.boolValue,
            toolbarsVisible: features.toolbarsVisibility?.boolValue
        )
    }

    /// A page called `window.close()`.
    ///
    /// Reported, not obeyed. The engine's own gate is wider than a browser's
    /// should be — measured, WebKit lets any view whose back-forward list holds
    /// a single entry close itself, whoever opened it — so whether this tab may
    /// go is answered in the core against the fact of who asked for it
    /// (ADR-0075).
    func webViewDidClose(_: WKWebView) {
        emit(.pageClosedWindow(tab: tab))
    }
}
