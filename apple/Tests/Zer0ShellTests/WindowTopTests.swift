import AppKit
import SwiftUI
import Testing

@testable import Zer0Shell

// MARK: - ADR-0055: the system reserves nothing above the page but the traffic lights

/// The defect these lock is the one every other test in this suite was blind
/// to, and the reason is worth stating: they render `WindowChrome` into a
/// borderless `NSWindow` and photograph it. There is no title bar in a
/// borderless window, so there is nothing to cover the strip, and a suite that
/// only ever looks at the strip cannot see anything drawn *over* it.
///
/// So these build the window instead. A real `.titled` window, with the mask
/// and the flags SwiftUI's `.hiddenTitleBar` leaves, and the `NSToolbar` that
/// `NavigationSplitView` puts there — which is the whole defect — and then
/// measure what the system is holding.
///
/// **What could not be measured, and why it is not here.** The band itself is
/// invisible to every instrument available in this process. `cacheDisplay` over
/// the frame view reads the strip's own colour whether the toolbar is there or
/// not; so does `CALayer.render(in:)`. Both were tried against a strip forced
/// to pure magenta, and both reported magenta in the state where the screen
/// showed white. `CGWindowListCreateImage` is gone from the macOS 26 SDK, and
/// ScreenCaptureKit wants a permission and a screen. The pixel reading is a
/// manual procedure, written into ADR-0055; what is automated here is the
/// geometry, which moves 66 → 32 with the fix and is the thing ADR-0010 was
/// always really claiming.
@MainActor
struct WindowTopTests {
    /// A window in the state SwiftUI leaves the browser's on macOS 26: hidden
    /// title bar, full-size content — and a toolbar nobody asked for.
    private func windowAsSwiftUILeavesIt() -> NSWindow {
        let window = testWindow(
            CGRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbar = NSToolbar(identifier: "zer0.test")
        window.toolbarStyle = .unified

        // A 38pt strip over a dark page: the layout ADR-0010 describes, and
        // the one the defect appears in.
        let hosting = NSHostingView(rootView: AnyView(
            VStack(spacing: 0) {
                Color.pink.frame(height: WindowChrome.height)
                Color.black
            }
            .ignoresSafeArea(.container, edges: .top)
        ))
        window.contentView = hosting
        // Far off any display, like the rest of this suite's windows. A window
        // has to be ordered in for AppKit to build its frame view.
        window.setFrameOrigin(CGPoint(x: -10000, y: -10000))
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        return window
    }

    /// The invariant ADR-0010 states and nothing measured: with the sidebar
    /// away, the only thing above the page is our own 38pt strip. The system
    /// may reserve height for the traffic lights inside it; it may not reserve
    /// more than it.
    @Test("the system reserves no more above the page than the strip does")
    func theSystemReservesNoMoreAboveThePageThanTheStripDoes() {
        let window = windowAsSwiftUILeavesIt()
        defer { window.orderOut(nil) }

        // The harness proving itself. If this stops being true, the window
        // below is no longer the window the defect lives in, and everything
        // after it is measuring nothing.
        #expect(window.systemChromeHeight > WindowChrome.height, """

            The unfixed window is no longer reserving more than \(WindowChrome.height)pt.
              This test builds the state the defect lives in on purpose — a toolbar makes the
              title bar container 66pt tall, which is what covered the strip. If AppKit stopped
              doing that, this file is measuring a window nobody has, and the assertion below
              would pass for the wrong reason.
            """)

        window.claimTheTopForThePage()

        #expect(window.systemChromeHeight <= WindowChrome.height, """

            The system is holding \(window.systemChromeHeight)pt above the page, and \
            WindowChrome is \(WindowChrome.height)pt.
              ADR-0010 is that the page starts at the top of the window and that the strip is
              the only thing up there. Anything the system reserves beyond the strip is drawn
              over whatever the strip painted — including the page's own colour (ADR-0047),
              which is how this came back as a white band above a black page.
            """)
    }

    /// The mechanism, named separately from the measurement above: the band was
    /// the toolbar's glass, and the toolbar is also where the duplicate sidebar
    /// toggle lived — a system platter drawn on top of ours, two buttons deep.
    @Test("the browser window carries no toolbar")
    func theBrowserWindowCarriesNoToolbar() {
        let window = windowAsSwiftUILeavesIt()
        defer { window.orderOut(nil) }

        #expect(window.toolbar != nil, "the harness stopped building the state under test")
        window.claimTheTopForThePage()

        #expect(window.toolbar == nil, """

            The window has a toolbar again.
              On macOS 26 that is an NSToolbarView -> NSGlassContainerView inside the title bar
              container, a sibling composited after the hosting view: it covers the strip, and
              the sidebar toggle it carries is drawn over ours. `.toolbar(removing:)` and
              `.toolbar(.hidden, for: .windowToolbar)` do not remove it on this SDK; taking the
              NSToolbar off the window does.
            """)
    }

    /// Everything the title bar was still doing for us. Removing the toolbar
    /// must not turn into removing the title bar: the traffic lights are the
    /// system's, people expect them where they are, and full screen, tiling,
    /// resizing and dragging all hang off the same style mask.
    @Test("the traffic lights and the window's own controls survive")
    func theTrafficLightsAndTheWindowsOwnControlsSurvive() {
        let window = windowAsSwiftUILeavesIt()
        defer { window.orderOut(nil) }
        window.claimTheTopForThePage()

        for (button, name) in [
            (NSWindow.ButtonType.closeButton, "close"),
            (.miniaturizeButton, "minimise"),
            (.zoomButton, "zoom"),
        ] {
            let control = window.standardWindowButton(button)
            #expect(control != nil, "the \(name) button is gone")
            #expect(control?.isHidden == false, "the \(name) button is hidden")
            // Inside the strip, which is what makes the reservation in
            // `WindowChrome.Metrics.trafficLightWidth` the right size. Its own
            // `frame` is in the title bar's coordinates, so it says nothing
            // about where it lands in the window until it is converted.
            let inWindow = control?.convert(control?.bounds ?? .zero, to: nil) ?? .zero
            let top = window.frame.height - inWindow.maxY
            #expect(top >= 0 && top < WindowChrome.height, """

                The \(name) button sits \(top)pt from the top of the window, and the strip is \
                \(WindowChrome.height)pt.
                  WindowChrome reserves space for them at both ends; a button outside the strip
                  is a button drawn on the page.
                """)
        }

        #expect(window.styleMask.contains(.titled), """

            The title bar is gone, and with it the traffic lights and the thing you grab to move
            the window. Removing the *toolbar* is the fix; removing the title bar is a different
            change, and it costs everything in this test.
            """)
        // Resizable is also what makes a window full-screen capable, and full
        // screen is what macOS tiling is built out of: a window that cannot be
        // a full-screen space cannot be half of one either.
        #expect(window.styleMask.contains(.resizable), "the window stopped being resizable")
        #expect(!window.collectionBehavior.contains(.fullScreenNone), """

            The window has been told it cannot go full screen, which takes macOS tiling with it.
            """)
        #expect(window.systemChromeHeight > 0, """

            There is no title bar left to grab. WindowChrome carries a WindowDragGesture, but
            the system's own drag region is what a person's hand expects at the top of a window,
            and it comes with the title bar.
            """)
    }

    /// One call is not enough. SwiftUI installs the split view's toolbar after
    /// the hosting view is in the window, and puts it back as the sidebar comes
    /// and goes — which is exactly the moment `WindowChrome` appears.
    @Test("a toolbar put back afterwards is taken away again")
    func aToolbarPutBackAfterwardsIsTakenAwayAgain() {
        let window = windowAsSwiftUILeavesIt()
        defer { window.orderOut(nil) }

        let keeper = WindowTopKeeper()
        keeper.attach(to: window)
        defer { keeper.detach() }
        #expect(window.toolbar == nil)

        window.toolbar = NSToolbar(identifier: "zer0.test.again")
        // What AppKit posts once per update cycle, which is the hook this
        // hangs on. Posting it is the test standing in for the run loop.
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)

        #expect(window.toolbar == nil, """

            A toolbar installed after the window was claimed stayed. The claim has to survive
            SwiftUI putting one back, or the band returns the first time the sidebar is toggled.
            """)
        #expect(window.systemChromeHeight <= WindowChrome.height)
    }

    /// And the wiring. `browserWindow(_:)` is the one door that knows a window
    /// hosts pages, so it is where this is done; a second door would be a
    /// second place to forget.
    @Test("the window that hosts pages claims its own top")
    func theWindowThatHostsPagesClaimsItsOwnTop() {
        let window = windowAsSwiftUILeavesIt()
        defer { window.orderOut(nil) }
        #expect(window.systemChromeHeight > WindowChrome.height)

        window.contentView?.addSubview(BrowserWindowTag(model: nil))

        #expect(window.toolbar == nil, """

            BrowserWindowTag no longer claims the top. It is the view `browserWindow(_:)` plants,
            and `browserWindow(_:)` is applied exactly once, to the scene that hosts pages — which
            is what keeps this from having to be remembered anywhere else.
            """)
        #expect(window.systemChromeHeight <= WindowChrome.height)
    }
}
