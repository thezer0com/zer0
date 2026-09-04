import AppKit
import SwiftUI
import Testing
import Zer0Core

@testable import Zer0Shell

// MARK: - The sidebar's header is fixed furniture, not part of the list

/// The composition: a two-row header at the top — spaces, then the sidebar's
/// own actions — a divider, and the tab list below it as the only vertical
/// scroll owner. Before it, every one of those controls lived *under* the
/// list, and the list's own New Tab row ended the scroll content.
///
/// **What is measured, and through what.** This suite renders the real
/// `Sidebar` in a real window and reads the frames of the `NSScrollView`s
/// SwiftUI installs for it — public AppKit all the way down, the same
/// discipline as `SidebarWidthTests`, because matching the private view names
/// in the hierarchy is a test that goes red the first time Apple renames one.
/// Two scroll views exist on a default model: the tab list's viewport and the
/// space chips' row. Their order, and whether one contains the other, is the
/// whole of the composition stated as geometry.
///
/// The scroll regions are measured through the AppKit view tree; New Tab emits
/// its SwiftUI geometry through an inert observer because a custom button has no
/// corresponding `NSView` of its own.
@MainActor
struct SidebarLayoutTests {
    /// A rendered sidebar, and the scroll views it installed. Main-actor like
    /// the suite around it: a nested type does not inherit the isolation, and
    /// every member reads AppKit state.
    @MainActor
    private struct Rendered {
        let hosting: NSHostingView<AnyView>
        let window: NSWindow
        /// The tab list's viewport: the tallest scroll view, by construction —
        /// it is the region that gets everything the header does not spend.
        let tabs: NSScrollView
        /// The space chips' row: the short one. A chip is 21pt; nothing else
        /// in a default sidebar draws a scroll view anywhere near that small.
        let chips: NSScrollView
        let newTabFrame: CGRect
        let scrollOffset: CGFloat
        /// How many tabs the rendered Space actually holds, so a precondition
        /// cannot pass on tabs hidden in another Space.
        let visibleTabs: Int

        /// Frames in the hosting view's own coordinates, y growing down from
        /// the top of the sidebar. The two scroll views sit in different
        /// superviews, so their raw `frame`s are not comparable with each
        /// other and every assertion converts first.
        var tabsFrame: CGRect { tabs.convert(tabs.bounds, to: hosting) }
        var chipsFrame: CGRect { chips.convert(chips.bounds, to: hosting) }
        var bounds: CGRect { hosting.bounds }
    }

    @MainActor
    private final class FrameProbe {
        var newTab: CGRect = .zero
        var scrollOffset: CGFloat = 0
    }

    private func render(
        tabs tabCount: Int,
        spaces: [String] = ["Work"],
        inTitledWindow: Bool = false,
        scroll: ScrollPosition = ScrollPosition(edge: .top)
    ) -> Rendered {
        let model = BrowserModel(storagePath: nil)
        for name in spaces { model.createSpace(named: name) }
        for index in 0..<tabCount {
            model.send(.openTab(space: nil, url: nil, parent: nil))
            guard let tab = model.snapshot.activeTab else { continue }
            model.send(.navigationCommitted(tab: tab, url: "https://example.org/\(index)"))
            model.send(.titleChanged(tab: tab, title: "Page \(index)"))
            model.send(.navigationFinished(tab: tab))
        }

        let probe = FrameProbe()
        let hosting = NSHostingView(rootView: AnyView(
            Sidebar(
                scroll: scroll,
                onNewTabFrame: { probe.newTab = $0 },
                onScrollOffset: { probe.scrollOffset = $0 }
            )
                .environment(model)
                .zer0Palette()
        ))
        hosting.frame = CGRect(x: 0, y: 0, width: Sidebar.Metrics.idealWidth, height: 520)
        let styleMask: NSWindow.StyleMask = inTitledWindow
            ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            : [.borderless]
        let window = testWindow(hosting.frame, styleMask: styleMask)
        if inTitledWindow {
            window.claimTheTopForThePage()
        }
        window.contentView = hosting
        // Far off any display, like the rest of this suite's windows; a window
        // has to be ordered in for SwiftUI to install the platform views.
        window.setFrameOrigin(CGPoint(x: -10000, y: -10000))
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        hosting.layoutSubtreeIfNeeded()

        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] }
                ?? view.subviews.flatMap(scrollViews)
        }
        let found = scrollViews(hosting)
        // The harness proving it can see the thing it is about to measure. If
        // SwiftUI stopped installing scroll views for either region, every
        // assertion below would be measuring nothing and passing for it.
        precondition(
            found.count >= 2,
            "the harness stopped finding the sidebar's scroll views"
        )
        precondition(!probe.newTab.isEmpty, "the harness stopped measuring New Tab")
        let sorted = found.sorted { $0.frame.height < $1.frame.height }
        return Rendered(
            hosting: hosting,
            window: window,
            tabs: sorted.last!,
            chips: sorted.first!,
            newTabFrame: probe.newTab,
            scrollOffset: probe.scrollOffset,
            visibleTabs: model.favoriteTabs().count
                + model.pinnedTabs().count
                + model.todayTabs().count
        )
    }

    /// The header is *above* the list. The old composition had the spaces at
    /// the bottom, under the list and the shelf — the same controls, drawn as
    /// furniture the list sat on rather than furniture it hangs from.
    @Test("the spaces row sits above the tab list")
    func theSpacesRowSitsAboveTheTabList() {
        let side = render(tabs: 3)
        defer { side.window.orderOut(nil) }

        #expect(side.chipsFrame.maxY <= side.tabsFrame.minY + 0.5, """

            The space chips end at \(side.chipsFrame.maxY) and the tab list starts at \
            \(side.tabsFrame.minY).
              Spaces are the header's first row and the list follows the header; chips that end
              below where the list begins are the old composition, with the spaces as a footer
              under the list rather than a header above it.
            """)
    }

    /// The sidebar is the window's chrome while it is visible, so its first row
    /// uses the same strip `WindowChrome` uses when the sidebar is hidden. The
    /// traffic lights reserve width, not a blank row above every control.
    @Test("the spaces row shares the window strip without covering the traffic lights")
    func theSpacesRowSharesTheWindowStripWithoutCoveringTheTrafficLights() {
        let side = render(tabs: 3)
        defer { side.window.orderOut(nil) }

        #expect(side.chipsFrame.maxY <= WindowChrome.height + 0.5, """

            The space chips end at \(side.chipsFrame.maxY), below the window's \
            \(WindowChrome.height)pt strip.
              With the sidebar visible, that strip belongs to the sidebar; leaving it empty
              puts a blank titlebar-sized band above the first useful control.
            """)
        #expect(
            side.chipsFrame.minX >= WindowChrome.Metrics.trafficLightWidth - 0.5,
            """

                The space chips start at x=\(side.chipsFrame.minX), inside the \
                \(WindowChrome.Metrics.trafficLightWidth)pt reserved for the traffic lights.
                  Sharing the strip removes vertical waste; the horizontal reservation is what
                  keeps the window's controls clear and clickable.
                """
        )
    }

    @Test("the spaces row occupies the actual titled window strip")
    func theSpacesRowOccupiesTheActualTitledWindowStrip() {
        let side = render(tabs: 3, inTitledWindow: true)
        defer { side.window.orderOut(nil) }

        #expect(side.chipsFrame.maxY <= WindowChrome.height + 0.5, """

            The space chips end at \(side.chipsFrame.maxY) in a titled window, below the \
            \(WindowChrome.height)pt strip.
              The window has already claimed full-size content. Its safe area must not add a
              second titlebar-sized band above the sidebar's own window strip.
            """)
    }

    @Test("the primary action stays between spaces and the tab list")
    func thePrimaryActionStaysBetweenSpacesAndTheTabList() {
        let side = render(tabs: 3)
        defer { side.window.orderOut(nil) }

        #expect(side.newTabFrame.minY >= side.chipsFrame.maxY - 0.5, """

            New Tab starts at \(side.newTabFrame.minY), above where the space chips end at \
            \(side.chipsFrame.maxY).
              The primary action belongs after the current space, not inside its window strip.
            """)
        #expect(side.newTabFrame.maxY <= side.tabsFrame.minY + 0.5, """

            New Tab ends at \(side.newTabFrame.maxY) and the tab list starts at \
            \(side.tabsFrame.minY).
              Moving the action into the list makes it scroll away when the list overflows.
            """)
    }

    /// The list scrolls; the header does not. A chip row dragged inside the
    /// tab list's scroll view would travel with it — the header would be
    /// visible with three tabs and gone with thirty, which is the failure
    /// this catches structurally: containment, not position.
    @Test("an overflowing list scrolls and the header holds still")
    func anOverflowingListScrollsAndTheHeaderHoldsStill() {
        let side = render(tabs: 40, scroll: ScrollPosition(y: 700))
        defer { side.window.orderOut(nil) }

        // The seeded list overflows its viewport several times over, but
        // SwiftUI's scroll-view shim keeps its document view sized to the
        // viewport, so the overflow itself is not measurable through the
        // AppKit surface and is not asserted. Containment below is what
        // carries the decision, and it is the stronger fact: an
        // `NSScrollView` can only translate its own descendants, so a chips
        // row that is not inside the list's scroll view cannot scroll with
        // it — on any machine, at any list length.
        #expect(side.visibleTabs > 30, "the harness stopped seeding a list that overflows")
        #expect(side.scrollOffset > 100, """

            The list was asked to scroll 700pt and reported an offset of \(side.scrollOffset).
              Containment alone does not prove that the list moves. The overflowing rows must
              actually travel while the fixed header stays where it is.
            """)

        #expect(!side.chips.isDescendant(of: side.tabs), """

            The space chips' scroll view is inside the tab list's scroll view.
              The chips would scroll with the list — a header that is on screen with three tabs
              and has scrolled away by the thirtieth is not a header, it is the first row of
              the list wearing a header's clothes.
            """)
        #expect(side.chipsFrame.maxY <= side.tabsFrame.minY + 0.5, """

            With forty tabs overflowing the viewport, the chips end at \
            \(side.chipsFrame.maxY) and the list starts at \(side.tabsFrame.minY).
              Overflow is exactly when the header has to hold still: a list that pushes the
              spaces out of the window to fit its rows has spent the wrong region's height.
            """)
        #expect(side.chipsFrame.maxY <= side.bounds.maxY, """

            The chips row ends at \(side.chipsFrame.maxY) and the sidebar is \(side.bounds.maxY) \
            tall.
              A header is furniture that is always reachable; chips past the bottom edge are
              furniture the list's rows have spent.
            """)
    }

    @Test("the extension rail keeps two targets and scrolls the rest")
    func theExtensionRailKeepsTwoTargetsAndScrollsTheRest() async throws {
        let profile = FileManager.default.temporaryDirectory
            .appending(path: "zer0-sidebar-extension-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: profile) }
        let extensions = profile.appending(path: "extensions")
        try FileManager.default.createDirectory(at: extensions, withIntermediateDirectories: true)

        var fixtures: [ExtensionFixture] = []
        for index in 0..<3 {
            fixtures.append(try ExtensionFixture(
                id: String(repeating: String(index + 1), count: 32),
                in: extensions
            ))
        }
        let hiddenFixture = try ExtensionFixture(
            id: String(repeating: "4", count: 32),
            backgroundScript: "chrome.action.setBadgeText({ text: '4' });",
            in: extensions
        )

        let model = BrowserModel(storagePath: profile.appending(path: "session.sqlite").path)
        model.loadInstalledExtensions()
        for installed in model.installedExtensions {
            await model.applyConsent(
                defaultConsentDecision(request: model.consentRequest(for: installed), decidedAtMs: 1_000)
            )
        }
        model.setExtensionPinned(hiddenFixture.installed.id, false)
        let extensionHost = try #require(model.extensions)
        let activeTab = try #require(model.snapshot.activeTab)
        #expect(await eventually {
            extensionHost.action(for: hiddenFixture.installed.id, tab: activeTab)?.badgeText == "4"
        })
        #expect(model.pinnedExtensions.count == 3)
        #expect(model.extensionWaitingOffRow)

        let floor = ExtensionActionBar.minimumUsableWidth(pinnedCount: 3, hasUnread: true)
        let hosting = NSHostingView(rootView: AnyView(
            ExtensionActionBar(
                ink: .primary,
                popoverEdge: .maxX,
                scroll: ScrollPosition(x: 1_000)
            )
                .frame(width: floor)
                .environment(model)
                .zer0Palette()
        ))
        hosting.frame = CGRect(x: 0, y: 0, width: floor, height: 60)
        let window = testWindow(hosting.frame)
        window.contentView = hosting
        window.setFrameOrigin(CGPoint(x: -10000, y: -10000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        hosting.layoutSubtreeIfNeeded()

        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] }
                ?? view.subviews.flatMap(scrollViews)
        }
        let rail = try #require(scrollViews(hosting).first)
        let viewport = rail.contentView.bounds.width
        let content = try #require(rail.documentView).bounds.width

        #expect(floor == ExtensionActionBar.Metrics.target * 3 + Design.Space.hair)
        #expect(content > viewport + 1, """

            Three extension targets occupy \(content)pt inside a \(viewport)pt viewport.
              The header reserves two readable targets; further targets must overflow into the
              horizontal rail instead of squeezing every button smaller.
            """)
        #expect(rail.contentView.bounds.minX > 1, """

            A rail asked to reveal its far edge stayed at \(rail.contentView.bounds.minX)pt.
              Overflow that cannot move is clipping, not scrolling.
            """)
        let unreadPoint = CGPoint(
            x: floor - ExtensionActionBar.Metrics.target / 2,
            y: hosting.bounds.midY
        )
        #expect(hosting.hitTest(unreadPoint) != nil)
        let windowPoint = hosting.convert(unreadPoint, to: nil)
        let press = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
        window.sendEvent(press)
        let release = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: windowPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 0
        ))
        window.sendEvent(release)
        #expect(model.showingSettings)
        #expect(model.settingsSection == .extensions)
    }
}
