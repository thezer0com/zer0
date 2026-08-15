import AppKit
import SwiftUI
import Testing
import Zer0Core

@testable import Zer0Shell

// MARK: - ADR-0014: the sidebar is the primary navigation, so its titles fit

/// How wide the sidebar column **actually ends up**, in a real window.
///
/// ADR-0014's whole argument for giving up the horizontal tab strip is that a
/// vertical list is readable where a strip is not: *"from the eighth tab on,
/// each tab gets 90px, the title becomes 'Goo…'"*. Nothing measured whether the
/// column that replaced it gets more than 90px either. `BrowserView` declared
/// `min: 200`, and a declaration is a wish until something reads it back.
///
/// **The gap this closes, in the order it has to be closed.** Two different
/// questions, and passing the first says nothing about the second:
///
/// 1. Did the floor reach AppKit at all — is `minimumThickness` 200?
/// 2. Did the column that got drawn actually get 200 points?
///
/// A session was spent on a report that the floor "was not being honoured by
/// something", and neither question had an instrument pointed at it. Both are
/// asked here, of a real `.titled` window hosting the real `BrowserView`, at
/// the two widths that matter: the narrowest window the app allows, and a wide
/// one where there is width to spare and nothing left to blame.
///
/// **What is deliberately not asserted:** an exact width. The column is 268
/// points wide on macOS 26 for a 260-point pane — the concentric glass
/// container insets its contents — and pinning either number would be a test
/// about this year's sidebar material rather than about whether a title fits.
/// Serialized: each case builds a browser window and pumps the run loop, and
/// three of those in flight together is three live `WKWebView`s and three cores
/// racing for the same run loop.
@Suite(.serialized)
@MainActor
struct SidebarWidthTests {
    /// The window the browser is used in, built the way the app builds it:
    /// titled, full-size content, no toolbar of ours.
    private func browserWindow(_ model: BrowserModel, width: CGFloat) -> NSWindow {
        let window = testWindow(
            CGRect(x: 0, y: 0, width: width, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        let hosting = NSHostingView(rootView: AnyView(BrowserView().environment(model)))
        window.contentView = hosting
        // Far off any display, like the rest of this suite's windows. A window
        // has to be ordered in for AppKit to build the split view at all.
        window.setFrameOrigin(CGPoint(x: -10000, y: -10000))
        window.orderFrontRegardless()
        settle(window)
        return window
    }

    private func settle(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    /// The controller SwiftUI drives the two columns with.
    ///
    /// Public AppKit all the way down, on purpose: reading widths off the
    /// private view names in the hierarchy would be a test that goes red the
    /// first time Apple renames one, which is the kind of red that teaches
    /// people to delete tests.
    private func columns(_ window: NSWindow) -> NSSplitViewController? {
        func find(_ view: NSView) -> NSSplitView? {
            if let split = view as? NSSplitView { return split }
            for sub in view.subviews { if let found = find(sub) { return found } }
            return nil
        }
        guard let root = window.contentView, let split = find(root) else { return nil }
        return split.delegate as? NSSplitViewController
    }

    /// A couple of pages with real titles on them, so the column has rows in it
    /// rather than an empty state that would size itself.
    private func seed(_ model: BrowserModel) {
        for (host, title) in [
            ("news.ycombinator.com", "Hacker News"),
            ("en.wikipedia.org", "Bauhaus — Wikipedia, the free encyclopedia"),
            ("developer.mozilla.org", "WKWebView - Web APIs | MDN"),
        ] {
            model.send(.openTab(space: nil, url: nil, parent: nil))
            guard let tab = model.snapshot.activeTab else { continue }
            model.send(.navigationCommitted(tab: tab, url: "https://\(host)/"))
            model.send(.titleChanged(tab: tab, title: title))
            model.send(.navigationFinished(tab: tab))
        }
    }

    /// Question one: the floor reaches AppKit.
    ///
    /// `.navigationSplitViewColumnWidth(min:ideal:max:)` is a modifier that
    /// fails silently — deleted, the build is green and the sidebar is 140
    /// points wide, which still looks like a sidebar. This is what notices.
    @Test("the sidebar column declares its floor to the window")
    func theSidebarColumnDeclaresItsFloorToTheWindow() {
        let model = BrowserModel(storagePath: nil)
        seed(model)
        let window = browserWindow(model, width: 1200)
        defer { window.orderOut(nil) }

        let sidebar = columns(window)?.splitViewItems.first
        #expect(sidebar != nil, "the harness stopped finding the split view it measures")
        #expect(sidebar?.minimumThickness == Sidebar.Metrics.minWidth, """

            The sidebar column's minimum is \(sidebar?.minimumThickness ?? -1)pt, and \
            Sidebar.Metrics.minWidth is \(Sidebar.Metrics.minWidth)pt.
              SwiftUI's own default for a sidebar column is 140. ADR-0014 gave up the horizontal
              tab strip because a vertical list is one where the title fits; at 140 a title is
              about ten characters and three rows read the same, which is the defect that was
              being escaped, in the other dimension.
            """)
        #expect(sidebar?.maximumThickness == Sidebar.Metrics.maxWidth)
    }

    /// Question two, and the one nobody was asking: the column that got drawn
    /// really is at least that wide.
    ///
    /// Measured at the narrowest window the app allows and at a wide one,
    /// because "the sidebar collapses" is a report about a real window and a
    /// column width read at one convenient size is not an answer to it.
    @Test("the sidebar is drawn no narrower than its floor", arguments: [860.0, 1600.0])
    func theSidebarIsDrawnNoNarrowerThanItsFloor(windowWidth: CGFloat) {
        let model = BrowserModel(storagePath: nil)
        seed(model)
        let window = browserWindow(model, width: windowWidth)
        defer { window.orderOut(nil) }

        guard let sidebar = columns(window)?.splitViewItems.first else {
            Issue.record("no split view in the browser window")
            return
        }

        // The harness proving its instrument can see a change. The split view's
        // wrapper keeps its width when the column is collapsed, so a number
        // that stays the same in both states is not the sidebar's width and
        // every assertion built on it is measuring nothing (AGENTS.md).
        model.sidebarVisible = false
        settle(window)
        #expect(sidebar.isCollapsed, """

            Hiding the sidebar left the column uncollapsed, so this file cannot tell an open
            column from a closed one and the width it reads below is not evidence of anything.
            """)
        model.sidebarVisible = true
        settle(window)
        #expect(!sidebar.isCollapsed)

        let drawn = sidebar.viewController.view.frame.width
        #expect(drawn >= Sidebar.Metrics.minWidth, """

            The sidebar was drawn \(drawn)pt wide in a \(windowWidth)pt window, and its floor is \
            \(Sidebar.Metrics.minWidth)pt.
              A row spends 84pt on furniture before the title gets any of it, so a column under
              the floor is a list of first letters — which is worse than the tab strip ADR-0014
              replaced, because it costs width on every page as well.
            """)
        // And it opens at the ideal rather than at the floor: a browser whose
        // sidebar starts at its own minimum has spent the range for nothing.
        #expect(drawn >= Sidebar.Metrics.idealWidth, """

            The sidebar opened at \(drawn)pt rather than at its ideal of \
            \(Sidebar.Metrics.idealWidth)pt.
            """)
        #expect(drawn <= Sidebar.Metrics.maxWidth + 16, """

            The sidebar was drawn \(drawn)pt wide, past its ceiling of \
            \(Sidebar.Metrics.maxWidth)pt. Past that it stops being navigation beside a page.
            """)
    }
}
