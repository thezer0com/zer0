import Foundation
import WebKit
import Zer0Core

/// The `WKUIDelegate` for an extension's popup (ADR-0098).
///
/// ## Why this object exists at all
///
/// `WKWebExtensionAction.popupPopover` is built inside WebKit around a web view
/// this shell never constructs — measured, a private `_WKWebExtensionActionWebView`
/// carrying a private `_WKWebExtensionActionWebViewDelegate`. So the popup does
/// not go anywhere near `SitePermissionDelegate`, and ADR-0089's answer to
/// `alert()`, `confirm()` and `prompt()` did not reach it. Measured in a real
/// popup before this existed:
///
/// | the popup calls | evaluated to | what a person saw |
/// | --- | --- | --- |
/// | `alert('x')` | returned at once | nothing |
/// | `confirm('q?')` | **`false`** | nothing, and the answer was Cancel |
/// | `prompt('q?', 'ada')` | **`null`** | nothing, and the answer was Cancel |
///
/// ## Why it forwards instead of replacing
///
/// **The delegate WebKit installed is kept and is asked everything this one does
/// not answer.** It is not dead weight: measured, it implements
/// `runOpenPanelWithParameters:` — so a file control in a popup already opens a
/// real picker — as well as `createWebViewWithConfiguration:` and
/// `webViewDidClose:`, which are how a link in a popup opens a tab and how
/// `window.close()` closes the popover. Simplify Gmail's own popup calls
/// `window.close()`.
///
/// `uiDelegate` is one property, so taking it means taking all three of those
/// away. Forwarding is what makes this **an addition rather than a
/// substitution**, and it is structural: a method WebKit adds to that private
/// delegate in a future release keeps working here without anybody noticing,
/// where a hand-written list of "the ones to pass on" would go stale silently.
///
/// Two facts make it safe, and both were measured rather than assumed: setting
/// `uiDelegate` does **not** deallocate WebKit's own object — it is retained by
/// the action — and WebKit does **not** put its own back when the popover is
/// built or when `popupWebView` is read again.
///
/// ## What it decides
///
/// Nothing. Which tab the question belongs to, whether the panel may interrupt,
/// how much of the message is drawn and who gets named are all in
/// `page_dialogs.rs`, the same as for a page.
final class ExtensionPopupDialogDelegate: NSObject, WKUIDelegate {
    /// The name the person installed it under, already resolved through
    /// `_locales` by the core, so it is the name on the button rather than
    /// `__MSG_extName__`.
    ///
    /// Read once at construction rather than per question: a name that changed
    /// between the popup opening and the panel appearing would be an extension
    /// renaming itself mid-question, which is the one thing the identity line
    /// must not let happen.
    private let name: String

    /// Which tab this popup's question belongs to, asked at the moment it is
    /// asked.
    ///
    /// A closure rather than a stored `TabId`, for ADR-0068's reason about the
    /// row: an action is per-tab and everything about it is read fresh as it
    /// draws. A stored tab is a cache, and a question drawn on the window a
    /// popover left ten minutes ago is worse than no question.
    private let currentTab: @MainActor () -> TabId?

    private let dialogs: PageDialogLedger
    private let emit: @MainActor (Action) -> Void

    /// The delegate WebKit installed, kept so everything this object does not
    /// answer is still answered by it. See the note above.
    ///
    /// `nonisolated(unsafe)` because `responds(to:)` and
    /// `forwardingTarget(for:)` are `NSObject`'s and are not actor-isolated.
    /// WebKit calls both on the main thread — it is the only thread a
    /// `WKWebView` may be touched from — and nothing here mutates it.
    private nonisolated(unsafe) let engines: (any WKUIDelegate)?

    @MainActor
    init(
        name: String,
        currentTab: @escaping @MainActor () -> TabId?,
        dialogs: PageDialogLedger,
        engines: (any WKUIDelegate)?,
        emit: @escaping @MainActor (Action) -> Void
    ) {
        self.name = name
        self.currentTab = currentTab
        self.dialogs = dialogs
        self.engines = engines
        self.emit = emit
    }

    // MARK: - The three the engine does not answer

    // The completion types are the gated `typealias`s in `PageDialogHost.swift`:
    // which isolation the 26.3 CI SDK and the 26.6 author SDK declare for
    // these handlers disagrees, and the witness has to agree with its SDK.

    func webView(
        _: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame _: WKFrameInfo,
        completionHandler: @escaping AlertCompletion
    ) {
        report(.alert({ completionHandler() }), kind: .alert, message: message) {
            completionHandler()
        }
    }

    func webView(
        _: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame _: WKFrameInfo,
        completionHandler: @escaping ConfirmCompletion
    ) {
        report(.confirm({ completionHandler($0) }), kind: .confirm, message: message) {
            completionHandler(false)
        }
    }

    func webView(
        _: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame _: WKFrameInfo,
        completionHandler: @escaping PromptCompletion
    ) {
        report(
            .prompt({ completionHandler($0) }),
            kind: .prompt(defaultText: defaultText ?? ""),
            message: prompt
        ) {
            completionHandler(nil)
        }
    }

    // MARK: - The one door

    /// Hold the handler and tell the core, or refuse and answer now.
    ///
    /// `refuse` is the neutral answer to whichever of the three this is, and it
    /// runs when there is no tab to hang the question on — a popup open with no
    /// browser window in front, which is reachable because an extension may
    /// open its own popup. **Refusing rather than repairing** (AGENTS.md): a
    /// question drawn on a window guessed at is worse than one that was
    /// cancelled, and a handler that is neither held nor called is a popup
    /// frozen inside `alert()` with nothing on screen.
    @MainActor
    private func report(
        _ handler: PageDialogHandler,
        kind: PageDialogKind,
        message: String,
        refuse: @MainActor () -> Void
    ) {
        guard let tab = currentTab() else {
            refuse()
            return
        }
        raisePageDialog(
            handler,
            kind: kind,
            message: message,
            // **No origin, and there is no field one fits in.** Measured, a
            // popup's document reports `webkit-extension://` and a UUID: it
            // looks like a domain, it is not one, and nobody has seen it before
            // (ADR-0098).
            source: .extension(name: name),
            tab: tab,
            dialogs: dialogs,
            emit: emit
        )
    }

    // MARK: - Everything else is still the engine's

    override nonisolated func forwardingTarget(for selector: Selector!) -> Any? {
        guard let engines, (engines as? NSObject)?.responds(to: selector) == true else {
            return super.forwardingTarget(for: selector)
        }
        return engines
    }

    /// `WKWebView` reads this **once, when `uiDelegate` is assigned**, and
    /// caches the answers. A forwarding target the receiver does not admit to
    /// is a method WebKit never calls, which is exactly how the popup would
    /// silently lose its file picker.
    override nonisolated func responds(to selector: Selector!) -> Bool {
        if super.responds(to: selector) { return true }
        return (engines as? NSObject)?.responds(to: selector) == true
    }
}
