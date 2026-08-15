import AppKit
import SwiftUI
import Testing

@testable import Zer0Shell

// MARK: - ADR-0066: the marker is handed its model

/// The gap these close is the one that cost a launch: **every other window test
/// in this suite builds `BrowserWindowTag` by hand.** `ShortcutTests` adds one
/// to a content view; `WindowTopTests` adds one to a frame view. Not one of
/// them applies `browserWindow(_:)`, which is the modifier the app actually
/// uses — so the whole of SwiftUI's part of the path, the `background` and the
/// `NSViewRepresentable` inside it, was covered by nothing at all.
///
/// That is where the app died. The marker read `BrowserModel` out of the
/// environment, a `background` is a *sibling* of the view it sits behind rather
/// than a descendant, and the model applied inside the chain never reached it.
/// `@Environment(BrowserModel.self)` traps when it finds nothing, on the first
/// layout pass, before any window is on screen: "zer0 quit unexpectedly", with
/// a suite that stayed green because the suite never went through the modifier.
///
/// So these go through the modifier, into a real hosting view, in a real
/// window. What they assert is small — the window ends up claimed — but the
/// assertion is downstream of every step that was uncovered.
@MainActor
struct BrowserWindowClaimTests {
    /// A window in the shape the app hosts the browser in, with `root` in it.
    private func hosting(_ root: some View) -> NSWindow {
        let window = testWindow(
            NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView]
        )
        let host = NSHostingView(rootView: AnyView(root))
        window.contentView = host
        // Far off any display, like the rest of this suite's windows. A window
        // has to be ordered in before AppKit will lay its content out, and the
        // representable inside the background is made during that layout.
        window.setFrameOrigin(CGPoint(x: -10000, y: -10000))
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        return window
    }

    /// The decision, stated as the arrangement that used to be fatal: the model
    /// goes in *under* `browserWindow(_:)`, where a background cannot see it,
    /// and the window is claimed anyway because nothing looks it up.
    ///
    /// Put `@Environment(BrowserModel.self)` back into the marker and this does
    /// not fail politely — it traps and takes the test process with it, which
    /// is the same way it took the app.
    @Test("the marker claims its window whatever the environment does")
    func theMarkerClaimsItsWindowWhateverTheEnvironmentDoes() {
        BrowserWindows.forgetEverything()
        let model = BrowserModel(storagePath: nil)

        let window = hosting(
            Color.clear
                // Inside the chain, which is where it was the day the app
                // stopped launching. It is here to be in the wrong place.
                .environment(model)
                .browserWindow(model)
        )
        defer { window.orderOut(nil) }

        #expect(BrowserWindows.identity(of: window) == model.snapshot.keyWindow, """

            The window `browserWindow(_:)` was applied in is not registered as a browser window.
              Everything that decides where a key press lands reads this registry (ADR-0065), so
              an unclaimed window is a window where ⌘T, ⌘W and ⌘L do nothing — and the marker
              is also what takes the top of the window back off the system (ADR-0055).
            """)
        #expect(WindowRole(of: window) == .browser(model.snapshot.keyWindow))
    }

    /// And the same window with no `environment` anywhere near it. The model
    /// reaches the marker because it was handed over, which is what makes the
    /// ordering above stop being something anybody has to remember.
    @Test("the model reaches the marker with no environment in the chain")
    func theModelReachesTheMarkerWithNoEnvironmentInTheChain() {
        BrowserWindows.forgetEverything()
        let model = BrowserModel(storagePath: nil)

        let window = hosting(Color.clear.browserWindow(model))
        defer { window.orderOut(nil) }

        #expect(BrowserWindows.identity(of: window) == model.snapshot.keyWindow)
    }

    /// The marker's other job, reached the same way. `WindowTopTests` proves a
    /// hand-built tag claims the top; this proves the modifier plants one that
    /// does, which is the step between the two that nothing was checking.
    @Test("the modifier plants a marker that claims the top of the window")
    func theModifierPlantsAMarkerThatClaimsTheTopOfTheWindow() {
        BrowserWindows.forgetEverything()
        let model = BrowserModel(storagePath: nil)

        let window = hosting(Color.clear.browserWindow(model))
        defer { window.orderOut(nil) }

        window.toolbar = NSToolbar(identifier: "zer0.test.claim")
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)

        #expect(window.toolbar == nil, """

            A toolbar installed after the window was claimed stayed there. `browserWindow(_:)` is
            the one door that knows a window hosts pages, and taking the system's band off the top
            of it is part of what it is for (ADR-0055).
            """)
    }
}
