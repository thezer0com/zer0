import AppKit
import Foundation
import WebKit
import Zer0Core

/// Handing an address to another application.
///
/// Measured on this machine before any of this was written, with a real
/// navigation to a real `mailto:` in a real web view:
///
/// ```
/// mailto:someone@example.com  ->  policy delegate answers .allow
///                             ->  didFailProvisionalNavigation
///                                 NSURLErrorDomain -1002 "unsupported URL"
/// ```
///
/// `-1002` is `NSURLErrorUnsupportedURL`, which this host reports as
/// `.unsupportedUrl`, which the reducer records as a navigation failure, which
/// ADR-0016 hands the whole screen. So **clicking "Contact us" destroyed the
/// page somebody was reading** — not a silent nothing, an error screen where
/// the page had been.
///
/// `NSWorkspace` on the same machine, asked what opens each of them:
///
/// | address | handler |
/// | --- | --- |
/// | `mailto:` | Mimestream |
/// | `tel:` | Phone |
/// | `facetime:` | FaceTime |
/// | `sms:` | Messages |
/// | `weirdscheme:` | **nothing on this Mac** |
/// | `zer0://` | **nothing on this Mac** |
///
/// See ADR-0092.
enum ExternalScheme {
    /// What this browser does about a navigation to a scheme it does not load.
    ///
    /// A value rather than an effect, so the decision can be asked a question
    /// in a test without another application starting up on somebody's Mac.
    enum Outcome: Equatable {
        /// None of our business. The engine carries on, which for an address
        /// nothing can open means the failure screen that already says "That
        /// address can't be opened" — a true sentence, in the one place this
        /// browser has for saying it.
        case leaveAlone
        /// Cancel it and do nothing else.
        case refuse
        /// Cancel it and ask the system to open this.
        case open(URL)
    }

    /// Take responsibility for this navigation, or leave it alone.
    ///
    /// `true` means the navigation must be cancelled. The two halves are split
    /// so that `decide` can be tested and this cannot silently grow a second
    /// rule of its own.
    @MainActor
    static func takeOver(_ navigationAction: WKNavigationAction) -> Bool {
        switch decide(
            url: navigationAction.request.url,
            navigationType: navigationAction.navigationType
        ) {
        case .leaveAlone:
            return false
        case .refuse:
            return true
        case let .open(url):
            Self.hand(url, to: NSWorkspace.shared)
            return true
        }
    }

    /// **Only a person's click.** `.linkActivated` is the one navigation type
    /// somebody performed with a pointer. A page that assigns `location.href`
    /// reports `.other` — measured — and is refused, because starting another
    /// program is not something a script may do unprompted, and because a page
    /// that could would be able to do it on a timer.
    ///
    /// The cost is stated rather than hidden: an "Email us" button written as a
    /// script that assigns `location.href` does nothing here. It does nothing
    /// useful today either — it costs the page — so nothing that worked stops
    /// working.
    ///
    /// Which schemes may be handed over at all is the core's list and never a
    /// second one written here. A shell with its own idea of what leaves the
    /// browser is the half that is wrong.
    static func decide(url: URL?, navigationType: WKNavigationType) -> Outcome {
        guard let url, handToTheSystem(url: url.absoluteString) else { return .leaveAlone }
        guard navigationType == .linkActivated else { return .refuse }
        return .open(url)
    }

    /// Ask the system to open it, and say nothing if it did.
    ///
    /// Refuses rather than repairs: the workspace is asked what opens this
    /// first, so an address nothing on this Mac answers to is not handed over
    /// in the hope that something turns up. There is no second guess and no
    /// fallback to a web search — a `webcal:` on a Mac with no calendar app is
    /// a link that goes nowhere.
    ///
    /// The beep is what this browser has for "that did nothing", and it is
    /// already what a failed Save Page As does. It is not a sentence, and the
    /// sentence is missing: see ADR-0092.
    @MainActor
    static func hand(_ url: URL, to workspace: NSWorkspace) {
        guard workspace.urlForApplication(toOpen: url) != nil else {
            NSSound.beep()
            return
        }
        workspace.open(url)
    }
}
