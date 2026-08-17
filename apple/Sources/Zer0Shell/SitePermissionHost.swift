import Foundation
import WebKit
import Zer0Core

/// Every decision handler the engine has given us and we have not called yet.
///
/// **The one invariant here is that each handler is called exactly once.** A
/// `getUserMedia` promise settles when the handler runs and never otherwise, so
/// a handler dropped on the floor is a page that spins with no error, no
/// timeout and nothing on screen. That is worse than any refusal, and it is the
/// failure a delegate written the obvious way falls into the first time a tab
/// closes mid-question.
///
/// So the handlers live here, on the host, rather than on the per-tab delegate
/// that received them: a web view can be destroyed while the core is still
/// deciding, and the answer has to survive the view it came from.
@MainActor
final class SitePermissionLedger {
    private var outstanding: [UInt64: (WKPermissionDecision) -> Void] = [:]
    /// Monotonic, never reused. An id that came round again would let a stale
    /// answer settle a live question.
    private var nextRequest: UInt64 = 1

    /// Take a handler and return the number the core will name it by.
    func hold(_ handler: @escaping (WKPermissionDecision) -> Void) -> UInt64 {
        let request = nextRequest
        nextRequest += 1
        outstanding[request] = handler
        return request
    }

    /// Tell the page. Removing before calling, so a handler cannot be called
    /// twice even if an answer somehow arrives twice.
    func answer(_ request: UInt64, _ decision: SiteDecision) {
        guard let handler = outstanding.removeValue(forKey: request) else { return }
        handler(decision.engineDecision)
    }

    /// How many pages are waiting. Read by the tests, because "the handler was
    /// called" is only half the claim — the other half is that nothing is left.
    var outstandingCount: Int { outstanding.count }
}

extension SiteDecision {
    /// `WKPermissionDecision` has three cases and the core has two. The one
    /// missing is `.prompt`, which hands the question back to WebKit's own
    /// dialog — the state this browser was in before ADR-0056, where the answer
    /// was chosen by nobody and written down nowhere.
    var engineDecision: WKPermissionDecision {
        switch self {
        case .allow: .grant
        case .deny: .deny
        }
    }
}

/// The `WKUIDelegate` for one tab, doing nothing but reporting.
///
/// It decides nothing at all — not whether the origin is readable, not whether
/// the tab is in front, not whether this page has already been refused, not
/// whether a page that asked for a window gets one. All of that is in the core,
/// where it can be tested without a camera and where a Linux host inherits it.
///
/// This one protocol carries four separate decisions, so it is written across
/// four files and this is the object all of them hang off — `uiDelegate` is one
/// property and a view has one of them. The camera is here (ADR-0056),
/// `window.open` and `window.close()` are in `PopupHost.swift` (ADR-0075), and
/// `alert()`, `confirm()`, `prompt()` and the file control are in
/// `PageDialogHost.swift` (ADR-0089).
///
/// **Every optional method on this protocol is now implemented**, and that
/// sentence is the whole of ADR-0089's context. An unimplemented optional here
/// is not a missing feature and is not a refusal: measured, WebKit answered
/// `alert()` by doing nothing, `confirm()` with `false` — a Cancel nobody
/// pressed — `prompt()` with `null`, and a file control by never opening a
/// panel at all. Adding a method to this protocol without implementing it puts
/// the browser straight back there, silently.
///
/// **The conformance is here and the page-dialog panels are one class below
/// it**, on `PageDialogDelegateBase`, and that gap is load-bearing rather than
/// tidy: a witness the compiler compares against a WebKit header it disagrees
/// with is dropped silently (ADR-0127). Nothing else about this object cares,
/// because `tab`, `dialogs` and `emit` are inherited and read the same way.
@MainActor
final class SitePermissionDelegate: PageDialogDelegateBase, WKUIDelegate {
    private let ledger: SitePermissionLedger
    /// Hand a configuration the engine built to whoever can turn it into a tab.
    /// A closure rather than a reference, for the reason every other seam here
    /// is one: this object reports and does not decide.
    let openWindow: PopupOpener

    init(
        tab: TabId,
        ledger: SitePermissionLedger,
        dialogs: PageDialogLedger,
        openWindow: @escaping PopupOpener,
        emit: @escaping @MainActor (Action) -> Void
    ) {
        self.ledger = ledger
        self.openWindow = openWindow
        super.init(tab: tab, dialogs: dialogs, emit: emit)
    }

    /// The only site-permission callback macOS has.
    ///
    /// This was established from the installed SDK rather than from memory.
    /// `WKUIDelegate.h` on the macOS 26 SDK carries exactly two permission
    /// methods, and the second —
    /// `requestDeviceOrientationAndMotionPermissionForOrigin:` — is marked
    /// `API_UNAVAILABLE(macos)`. There is no geolocation callback, no
    /// notification callback, no display-capture callback and no clipboard
    /// callback anywhere in the public WebKit headers. ADR-0056 says what that
    /// means for each of them.
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
    ) {
        let request = ledger.hold(decisionHandler)

        emit(.sitePermissionRequested(request: SitePermissionRequest(
            request: request,
            tab: tab,
            // The frame that actually called `getUserMedia`. The grant goes to
            // whoever asked, which for an embedded widget is not the site whose
            // name is in the address bar.
            origin: reportedOrigin(frame.securityOrigin),
            // What the tab is showing. For a main-frame request these are the
            // same and the core says nothing about embedding; for anything else
            // this is what lets it name the page the asking frame was inside.
            pageOrigin: frame.isMainFrame
                ? reportedOrigin(origin)
                : Self.pageOrigin(of: webView, fallingBackTo: origin),
            capture: Self.capture(type),
            // The core has no clock (ADR-0002), and the window this is measured
            // against is half a second — far under the minute `Action.tick`
            // moves the browser's clock by.
            askedAtMs: UInt64(Date().timeIntervalSince1970 * 1000)
        )))
    }

    /// The address the tab is on, for saying what an embedded frame was inside.
    private static func pageOrigin(
        of webView: WKWebView,
        fallingBackTo origin: WKSecurityOrigin
    ) -> ReportedOrigin {
        guard let url = webView.url, let host = url.host() else {
            return reportedOrigin(origin)
        }
        return ReportedOrigin(
            scheme: url.scheme ?? "",
            host: host,
            port: url.port.map { UInt32(max(0, $0)) } ?? 0
        )
    }

    static func capture(_ type: WKMediaCaptureType) -> CaptureRequest {
        switch type {
        case .camera: .camera
        case .microphone: .microphone
        case .cameraAndMicrophone: .cameraAndMicrophone
        // `WKMediaCaptureType` is an Objective-C enum, which Swift treats as an
        // open set: a case added by a future SDK arrives here as a raw value
        // with no Swift name. The pessimistic reading is the only safe one —
        // whatever it is, it is at least as much as both — and this is not the
        // vocabulary ADR-0031 forbids a wildcard over, which is `Action`,
        // `EngineCommand`, `UiCommand` and `Suggestion`.
        @unknown default: .cameraAndMicrophone
        }
    }
}

/// A `WKSecurityOrigin` as three fields, uninterpreted.
///
/// Nothing is normalised here. Whether `https://x` and `https://x:443` are one
/// site or two is a decision, and it is made once, in
/// `site_permissions::canonical_origin`.
///
/// A free function for the reason `raisePageDialog` is one: two callers on two
/// classes — the camera's request here, the four panels' `source(of:)` on
/// `PageDialogDelegateBase` — and an origin read two ways is two answers to
/// "is this the same site".
@MainActor
func reportedOrigin(_ origin: WKSecurityOrigin) -> ReportedOrigin {
    ReportedOrigin(
        scheme: origin.protocol,
        host: origin.host,
        // `WKSecurityOrigin.port` is 0 for an address that did not spell one,
        // which is exactly what the core reads as "the scheme's default".
        // Anything negative is not a port; the core refuses an origin it cannot
        // read, so passing 0 lands in the same place.
        port: origin.port > 0 ? UInt32(origin.port) : 0
    )
}

extension HostedWebView {
    /// Stop this view capturing, now.
    ///
    /// This is what makes taking an answer back in Settings reach the engine
    /// rather than repaint a row. Answering the next request with a refusal is
    /// not enough: a page that already holds a stream keeps it until something
    /// takes it away, and a row reading "blocked" over a camera that is on is
    /// the exact shape of lie ADR-0028 exists to end.
    ///
    /// `setCameraCaptureState(.none)` is WebKit's own way to do it and is
    /// documented as stopping any capture in progress. There is no way to do
    /// this per origin — the state belongs to the view — which is why the core
    /// works out which tabs are on the site and names each one.
    func stopCapture(_ capability: SiteCapability) {
        switch capability {
        case .camera:
            webView.setCameraCaptureState(.none, completionHandler: nil)
        case .microphone:
            webView.setMicrophoneCaptureState(.none, completionHandler: nil)
        }
    }
}
