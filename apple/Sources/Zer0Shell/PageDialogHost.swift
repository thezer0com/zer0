#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import Foundation
import WebKit
import Zer0Core

// One spelling, chosen by us rather than by any one SDK: the two WebKit SDKs
// this tree builds against disagree about the @MainActor on these blocks
// (26.3 leaves it off, 26.6 puts it on), the compiler version does not tell
// them apart, and no signature matches both. So the witnesses that receive
// them no longer try to match anything — the popup's sit outside the
// conforming declaration and are @objc, dispatched by selector under either
// SDK (see `ExtensionPopupDialogBase`). That frees these aliases to spell
// what the browser means and what `PageDialogHandler` below holds: the
// completions run on the main actor.
typealias AlertCompletion = @MainActor @Sendable () -> Void
typealias ConfirmCompletion = @MainActor @Sendable (Bool) -> Void
typealias PromptCompletion = @MainActor @Sendable (String?) -> Void
typealias FilesCompletion = @MainActor @Sendable ([URL]?) -> Void

/// A completion handler the engine handed over and nobody has called yet.
///
/// One case per method, holding the block that method was given, because the
/// four take four different arguments and a single `(Any?) -> Void` would put
/// the mapping at every call site. [`answer(_:)`] is the mapping, and it exists
/// exactly once.
///
/// Every block is `@MainActor @Sendable` because that is where WebKit calls
/// them from — the main thread — whatever the header of any one SDK says
/// about it.
///
/// The two SDKs this tree builds against disagree about that annotation (26.6
/// carries `WK_SWIFT_UI_ACTOR` on these blocks, 26.3 does not), the compiler
/// version does not track which one a build sees, and no single signature
/// matches both. So nothing here tries to match: the popup's witnesses live
/// outside the conforming declaration and are dispatched by selector (see
/// `ExtensionPopupDialogBase`), and the aliases at the top of this file spell
/// the completions the way this enum holds them. Every construction site
/// wraps the handler in a closure literal, which takes its isolation from
/// this enum.
enum PageDialogHandler {
    case alert(@MainActor @Sendable () -> Void)
    case confirm(@MainActor @Sendable (Bool) -> Void)
    case prompt(@MainActor @Sendable (String?) -> Void)
    case files(@MainActor @Sendable ([URL]?) -> Void)

    /// Tell the page.
    ///
    /// **Nothing here can turn an absence into a yes.** A `Cancelled` answer
    /// reaches `confirm()` as `false`, `prompt()` as `null` and a file control
    /// as no selection, and every answer that does not carry what a handler
    /// needs is treated as one — a `Typed` answer arriving at a file panel is a
    /// bug somewhere, and a bug must not resolve to "the person said yes".
    @MainActor
    func answer(_ answer: PageDialogAnswer) {
        switch self {
        // An alert takes no value in either direction. Cancel and OK are the
        // same call, because there was never a question.
        case let .alert(reply):
            reply()

        case let .confirm(reply):
            switch answer {
            case .accepted: reply(true)
            case .typed, .chose, .cancelled: reply(false)
            }

        case let .prompt(reply):
            switch answer {
            case let .typed(text): reply(text)
            // OK with nothing typed is an empty string, which is a real answer
            // and is not `null`.
            case .accepted: reply("")
            case .chose, .cancelled: reply(nil)
            }

        case let .files(reply):
            switch answer {
            case let .chose(paths): reply(paths.map { URL(fileURLWithPath: $0) })
            case .accepted, .typed, .cancelled: reply(nil)
            }
        }
    }
}

/// Every page-dialog handler the engine has given us and we have not called yet.
///
/// The same object, for the same reason, as `SitePermissionLedger`: **each
/// handler is called exactly once.** These calls are worse than the camera's if
/// dropped — `alert()` blocks the script that made it, so a handler nobody
/// calls is not a missing feature, it is a tab that has stopped, with nothing
/// on screen and nothing to press.
///
/// So the handlers live here on the host rather than on the per-tab delegate
/// that received them: a web view can be destroyed while the core is still
/// deciding, and the answer has to outlive the view it came from.
@MainActor
final class PageDialogLedger {
    private var outstanding: [UInt64: PageDialogHandler] = [:]
    /// Monotonic, never reused. An id that came round again would let a stale
    /// answer settle a live question.
    private var nextRequest: UInt64 = 1

    /// Take a handler and return the number the core will name it by.
    func hold(_ handler: PageDialogHandler) -> UInt64 {
        let request = nextRequest
        nextRequest += 1
        outstanding[request] = handler
        return request
    }

    /// Let the page carry on. Removing before calling, so a handler cannot be
    /// called twice even if an answer somehow arrives twice — and calling a
    /// WebKit completion block twice is a crash rather than a duplicate.
    func answer(_ request: UInt64, _ answer: PageDialogAnswer) {
        guard let handler = outstanding.removeValue(forKey: request) else { return }
        handler.answer(answer)
    }

    /// How many pages are waiting. Read by the tests, because "the handler was
    /// called" is only half the claim — the other half is that nothing is left.
    var outstandingCount: Int { outstanding.count }
}

/// `alert()`, `confirm()`, `prompt()` and `<input type="file">` (ADR-0089).
///
/// All four are on `SitePermissionDelegate` because `WKWebView.uiDelegate` is
/// one property and a view has one of them. They are in a file of their own
/// because they are a different decision from the camera and from
/// `window.open`.
///
/// **Nothing here decides anything.** Not whether the tab is one you are
/// looking at, not whether this page has already been told to stop, not how
/// much of the page's text is shown, not who gets named. All of that is in
/// `page_dialogs.rs`, where it is tested without a window and where a Linux
/// host inherits it.
extension SitePermissionDelegate {
    /// `alert(message)`.
    ///
    /// Measured before this existed: unimplemented, the call returned in 94ms
    /// having drawn nothing at all.
    func webView(
        _: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping AlertCompletion
    ) {
        report(
            .alert({ completionHandler() }),
            kind: .alert,
            message: message,
            source: Self.source(of: frame)
        )
    }

    /// `confirm(message)`.
    ///
    /// **The dangerous one.** Measured before this existed: the call returned
    /// `false`, which is a Cancel nobody pressed and nothing on screen saying
    /// so.
    func webView(
        _: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ConfirmCompletion
    ) {
        report(
            .confirm({ completionHandler($0) }),
            kind: .confirm,
            message: message,
            source: Self.source(of: frame)
        )
    }

    /// `prompt(message, default)`.
    ///
    /// Measured before this existed: the call returned `null`.
    func webView(
        _: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping PromptCompletion
    ) {
        report(
            .prompt({ completionHandler($0) }),
            kind: .prompt(defaultText: defaultText ?? ""),
            message: prompt,
            source: Self.source(of: frame)
        )
    }

    /// `<input type="file">`, anywhere on the web.
    ///
    /// Measured before this existed: clicking one opened nothing, fired no
    /// `change` event and left `files.length` at zero — so attaching a file was
    /// impossible in this browser, on every site.
    ///
    /// `WKOpenPanelParameters` carries exactly two facts and both are passed
    /// on. **It does not carry `accept`**: there is no public property for the
    /// control's type filter, so this browser cannot narrow the panel and does
    /// not pretend to (ADR-0018).
    func webView(
        _: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping FilesCompletion
    ) {
        report(
            .files({ completionHandler($0) }),
            kind: .chooseFiles(
                multiple: parameters.allowsMultipleSelection,
                directories: parameters.allowsDirectories
            ),
            // A file control says nothing. The panel names the site instead.
            message: "",
            source: Self.source(of: frame)
        )
    }

    // MARK: - The one door

    /// Hold the handler, and tell the core a page asked something.
    ///
    /// Every one of the four goes through here, so there is one place that
    /// decides what the core is told and one place that can fail to hold a
    /// handler.
    private func report(
        _ handler: PageDialogHandler,
        kind: PageDialogKind,
        message: String,
        source: PageDialogSource
    ) {
        raisePageDialog(
            handler,
            kind: kind,
            message: message,
            source: source,
            tab: tab,
            dialogs: dialogs,
            emit: emit
        )
    }

    /// The frame that called, not the tab's address. An `alert()` from an
    /// advert inside a page you trust is the advert talking, and the panel has
    /// to name the advert.
    static func source(of frame: WKFrameInfo) -> PageDialogSource {
        .frame(origin: reported(frame.securityOrigin))
    }
}

/// Hold a handler and tell the core somebody asked something.
///
/// **A free function because there are two callers and there must be one
/// door.** A page's frame reaches it through `SitePermissionDelegate`; an
/// extension's popup reaches it through `ExtensionPopupDialogDelegate`, whose
/// web view WebKit builds itself and which therefore cannot share the same
/// delegate object (ADR-0098). Two copies of these six lines is two places a
/// handler can fail to be held, and a handler that is not held is a page frozen
/// with nothing on screen.
@MainActor
func raisePageDialog(
    _ handler: PageDialogHandler,
    kind: PageDialogKind,
    message: String,
    source: PageDialogSource,
    tab: TabId,
    dialogs: PageDialogLedger,
    emit: @MainActor (Action) -> Void
) {
    let request = dialogs.hold(handler)
    emit(.pageRaisedDialog(request: PageDialogRequest(
        request: request,
        tab: tab,
        kind: kind,
        source: source,
        message: message,
        // The core has no clock (ADR-0002), and the window this is measured
        // against is half a second.
        askedAtMs: UInt64(Date().timeIntervalSince1970 * 1000)
    )))
}

/// What a file picker was asked to be, before any AppKit exists.
///
/// A value rather than a configured `NSOpenPanel`, so what the browser decided
/// can be read without a panel being on screen — and so the one thing that
/// genuinely cannot be driven offscreen (see [`FilePanelPresenter`]) is the only
/// thing left untested.
struct FilePanelRequest: Equatable {
    /// The browser naming the site, in the browser's own furniture. The same
    /// guarantee the drawn panels make with their identity line: whatever is
    /// about to read a file off this Mac is named before anything is picked.
    let message: String
    let multiple: Bool
    /// A control that asked for a directory is not answered by a file, so this
    /// also decides `canChooseFiles`. `allowsDirectories` is
    /// `<input webkitdirectory>` and nothing else — measured, an ordinary file
    /// control reports it false — so it is the control's own question rather
    /// than a guess about what it meant.
    let directories: Bool
}

/// The window a panel-having platform would hang its sheet on. Spelled once
/// so the runner and the presenter agree on it; on iOS the refusing runner
/// below ignores it, but the shape stays so callers are written once.
#if canImport(AppKit)
typealias PanelWindow = NSWindow
#else
typealias PanelWindow = UIWindow
#endif

/// Put a picker in front of somebody and report what came back.
///
/// `nil` is a cancel, and it must arrive: a picker that answers nothing leaves
/// the page's promise unsettled forever.
typealias FilePanelRunner = @MainActor (
    FilePanelRequest,
    PanelWindow?,
    @escaping @MainActor ([URL]?) -> Void
) -> Void

/// The one of the four that is not drawn by us: the system's file picker.
///
/// It is on the same seam as the other three — the core gates it, holds it and
/// answers it — and a different presentation, because a browser has no business
/// drawing its own file browser. What this owns is deciding what the panel is,
/// putting it on the right window, and making sure Cancel still answers.
///
/// **Presented once per request.** The core hands the same dialog back on every
/// snapshot until it is answered, which is the property that keeps the drawn
/// sheet honest and would otherwise put a second panel up on every dispatch.
///
/// **`run` is a seam, and it is one because of a measurement.** An
/// `NSOpenPanel` presented inside this suite never comes back: the panel is put
/// up from inside `WKUIDelegate.runOpenPanelWith`, which is inside WebKit's own
/// message handling with the web process waiting on the far end, and in a test
/// process that has no `NSApplication.run` the sheet's modal session and the
/// engine's reply want the same thread. Driven from a real app it is fine —
/// the same `beginSheetModal` `DownloadHost` already uses for the save panel.
/// So everything up to AppKit is behind this closure and is asserted; what
/// AppKit then draws is verified by running the browser and looking.
@MainActor
final class FilePanelPresenter {
    /// Requests a panel has already been opened for. Never cleared on answer:
    /// request numbers are monotonic and never reused, so this only ever grows
    /// by one per file control somebody actually used.
    private var presented: Set<UInt64> = []

    private let run: FilePanelRunner

    /// The default a host gets. macOS puts the system panel up; iOS answers
    /// `.cancelled` — this host has no file picker yet (`UIDocumentPicker` is
    /// UI it has not built), and a cancel is the honest answer because it
    /// settles the page's promise instead of leaving the control frozen on a
    /// picker that will never appear.
    init(run: @escaping FilePanelRunner = FilePanelPresenter.systemPanel) {
        self.run = run
    }

    /// Put the panel up, if this dialog is one and it has not been put up yet.
    ///
    /// `window` resolves the window holding the tab's own web view, so the
    /// sheet lands on the window the page is in rather than on whichever one
    /// happens to be in front.
    func present(
        _ dialogs: [PageDialog],
        window: @escaping @MainActor (TabId) -> PanelWindow?,
        answer: @escaping @MainActor (UInt64, PageDialogAnswer) -> Void
    ) {
        for dialog in dialogs {
            present(dialog, window: window, answer: answer)
        }
    }

    private func present(
        _ dialog: PageDialog,
        window: @escaping @MainActor (TabId) -> PanelWindow?,
        answer: @escaping @MainActor (UInt64, PageDialogAnswer) -> Void
    ) {
        let allows: (multiple: Bool, directories: Bool)
        switch dialog.kind {
        case let .chooseFiles(multiple, directories):
            allows = (multiple, directories)
        // Drawn by `PageDialogSheet`, not by AppKit. Listed rather than swept
        // up by a `default:`, so a fifth kind breaks this build until somebody
        // decides which side draws it.
        case .alert, .confirm, .prompt:
            return
        }
        guard presented.insert(dialog.request).inserted else { return }

        let asked = FilePanelRequest(
            message: Self.message(for: dialog.speaker),
            multiple: allows.multiple,
            directories: allows.directories
        )
        let request = dialog.request
        run(asked, window(dialog.tab)) { urls in
            guard let urls, !urls.isEmpty else {
                // **The line every upload button depends on.** An answer that
                // does not arrive on Cancel leaves the page's promise unsettled
                // forever and the control dead until the tab is reloaded.
                answer(request, .cancelled)
                return
            }
            answer(request, .chose(paths: urls.map(\.path)))
        }
    }

    /// The iOS default: no picker, answered at once. A host that stayed quiet
    /// would leave `<input type="file">` frozen forever. Spelled
    /// `systemPanel` too, so the initialiser names one door on both platforms
    /// and each platform's spelling of it lives beside its own doc.
    #if !canImport(AppKit)
    static func systemPanel(
        _: FilePanelRequest, _: PanelWindow?, answer: @escaping @MainActor ([URL]?) -> Void
    ) {
        answer(nil)
    }
    #endif

    /// The real thing: an `NSOpenPanel` as a sheet on the page's own window.
    ///
    /// **Off this turn of the run loop, on purpose.** The call arrives inside
    /// WebKit's delegate callback with the web process waiting on the far end;
    /// putting an AppKit sheet up from in there is asking one thread to do two
    /// things. A turn later costs a frame nobody can see.
    #if canImport(AppKit)
    static func systemPanel(
        _ asked: FilePanelRequest,
        window: NSWindow?,
        answer: @escaping @MainActor ([URL]?) -> Void
    ) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let panel = NSOpenPanel()
                panel.message = asked.message
                panel.allowsMultipleSelection = asked.multiple
                panel.canChooseDirectories = asked.directories
                panel.canChooseFiles = !asked.directories
                // Nothing is being saved, so there is nothing to make a folder
                // for.
                panel.canCreateDirectories = false
                // No `allowedContentTypes`. `WKOpenPanelParameters` has no
                // `accept` and no public equivalent of one, and a filter derived
                // from a guess hides the file somebody came to pick (ADR-0018).

                let settle: @MainActor (NSApplication.ModalResponse) -> Void = { response in
                    answer(response == .OK ? panel.urls : nil)
                }
                if let window {
                    panel.beginSheetModal(for: window) { response in
                        MainActor.assumeIsolated { settle(response) }
                    }
                } else {
                    // No window to hang it on — a tab whose view is not in one
                    // yet. Better a panel with no parent than a page frozen on a
                    // picker that never opened.
                    panel.begin { response in
                        MainActor.assumeIsolated { settle(response) }
                    }
                }
            }
        }
    }
    #endif

    /// Whose file this is about to become.
    ///
    /// The wording is the shell's, per ADR-0053; the name in it is the core's,
    /// and it is the canonical spelling — punycode where the real host was not
    /// ASCII, so nothing here can be drawn as somebody else.
    static func message(for speaker: PageDialogSpeaker) -> String {
        switch speaker {
        case let .site(_, host):
            "Choose what \(host) may upload."
        // **"An extension" leads, and the name follows it**, rather than the
        // name standing where a host stands. A package may call itself
        // `google.com`, and "Choose what google.com may read" over a panel one
        // is about to pick a file in is the whole of the spoof (ADR-0098). A
        // package that declares no name gets no name rather than an invented
        // one.
        case let .extension(name, _) where !name.isEmpty:
            "An extension is asking for a file: \(name)"
        case .extension:
            "An extension you installed is asking for a file. It does not say "
                + "what it is called."
        case .nameless:
            "Choose what this page may upload. It has no address of its own."
        }
    }
}
