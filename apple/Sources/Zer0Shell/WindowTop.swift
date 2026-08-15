import AppKit

/// Who owns the top of the browser window.
///
/// ADR-0010 decides that the page starts at the top of the window and that the
/// only thing allowed up there is `WindowChrome`, 38pt, and only while the
/// sidebar is away. On macOS 26 the system disagreed and won, silently.
///
/// **What was happening.** `NavigationSplitView` puts an `NSToolbar` on the
/// window whether or not anything is in it, and a window with a toolbar grows
/// an `NSTitlebarContainerView` — a *sibling* of the hosting view, composited
/// after it — holding `NSToolbarView` → `NSGlassContainerView`. That glass is
/// what painted the white band. Our strip was drawn, at the right size, in the
/// right place, in the right colour, and covered. Forcing it to pure magenta
/// changed nothing on screen, which is how the paint was ruled out.
///
/// `.windowStyle(.hiddenTitleBar)`, `.toolbar(.hidden, for: .windowToolbar)`,
/// `.toolbarBackground(.hidden, ...)` and `.scrollEdgeEffectHidden(_:for:)`
/// all leave the toolbar in place on this SDK. Removing the `NSToolbar` itself
/// is what removes it, and it has to be done to the window rather than asked
/// for in the view tree.
///
/// **What stays.** The title bar. It is where the traffic lights live, they are
/// the system's, and people expect them where they are. Transparent and
/// unlabelled it paints nothing — `NSTitlebarBackgroundView` is hidden by the
/// flag — and reserves about 28pt, which is inside the 38pt `WindowChrome`
/// already draws. Dragging, full screen, tiling and resizing are all the title
/// bar's, and all of them keep working because it is still there.
extension NSWindow {
    /// How much height the system is holding above the content, in points.
    ///
    /// This is the number ADR-0010 is really about, and it is the one nobody
    /// was measuring. A toolbar makes it 66; the bare title bar makes it 32.
    /// `contentLayoutRect` is the public answer to "what is not under system
    /// chrome", so this stays true if the system changes what it puts there.
    var systemChromeHeight: CGFloat {
        max(0, frame.height - contentLayoutRect.height)
    }

    /// Take the top of the window back for the page.
    ///
    /// Idempotent, and cheap enough to call on every window update — which is
    /// what `keepsItsTop` does, because SwiftUI puts the toolbar back.
    func claimTheTopForThePage() {
        // The whole of the band. Nothing in it was ours: the sidebar toggle it
        // carried is the one `.toolbar(removing: .sidebarToggle)` was meant to
        // take away, and on this SDK it does not — the platter was drawn over
        // our own toggle, two buttons deep, the system's on top.
        if toolbar != nil { toolbar = nil }

        // Setting the mask rebuilds the frame view, so only when it would
        // change anything.
        if !styleMask.contains(.fullSizeContentView) {
            styleMask.insert(.fullSizeContentView)
        }
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
    }
}

/// Keeps the top claimed, for as long as the window is around.
///
/// A single call at `viewDidMoveToWindow` is not enough: SwiftUI installs the
/// split view's toolbar after the hosting view is in the window, and puts it
/// back when the sidebar comes and goes. `didUpdateNotification` is the one
/// hook that fires after every one of those, and the work behind it is a nil
/// check.
@MainActor
final class WindowTopKeeper {
    // nonisolated so `deinit` can take the observer back down. Only ever
    // written from the main actor, which is where both methods run.
    private nonisolated(unsafe) var token: NSObjectProtocol?

    func attach(to window: NSWindow) {
        detach()
        window.claimTheTopForThePage()
        // Weak: the observer must not be the reason a closed window stays
        // alive, and a window that has gone has no top to claim.
        token = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification,
            object: window,
            queue: .main
        ) { [weak window] _ in
            MainActor.assumeIsolated { window?.claimTheTopForThePage() }
        }
    }

    func detach() {
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
    }

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }
}
