import Foundation
import SwiftUI
import Testing
import Zer0Core

@testable import Zer0Shell

/// Two pages side by side.
///
/// The pair is the core's to decide, so most of what is checked here is that
/// the shell asks for it and reads the answer back rather than keeping a
/// second opinion. What cannot be checked here is what it *looks* like: the
/// slide, the divider and the elevation are pixels, and pixels are not what
/// this suite is for.
@MainActor
struct SplitTests {
    private func model() -> BrowserModel { BrowserModel(storagePath: nil) }

    @Test("⌘\\ shows two pages, and again puts them away")
    func splitIsCreatedAndDismissed() async throws {
        let m = model()
        let first = try #require(m.snapshot.activeTab)
        m.send(.openTab(space: nil, url: nil, parent: nil))
        m.send(.activateTab(tab: first))

        m.perform(.toggleSplitView)

        let split = try #require(m.activeSplit, "⌘\\ must produce a pair")
        #expect(split.leading == first)
        #expect(m.snapshot.activeTab == first, "the page in hand keeps the keyboard")

        m.perform(.toggleSplitView)

        #expect(m.activeSplit == nil)
        #expect(m.snapshot.activeTab == first, "the surviving pane takes the whole area")
    }

    @Test("splitting a space with one tab opens the second pane and aims at it")
    func splittingAloneOpensAPane() async throws {
        let m = model()
        let only = try #require(m.snapshot.activeTab)

        m.perform(.toggleSplitView)

        let split = try #require(m.activeSplit)
        #expect(split.leading == only)
        #expect(split.trailing != only)
        // A blank pane is where you are about to type. Leaving the bar closed
        // over half a window of nothing is the one outcome worth avoiding.
        #expect(m.snapshot.activeTab == split.trailing)
        #expect(m.commandBarOpen, "an empty pane opens the bar rather than sitting blank")
    }

    @Test("the keyboard crosses the split without touching the mouse")
    func focusMovesByKeyboard() async throws {
        let m = model()
        let first = try #require(m.snapshot.activeTab)
        m.send(.openTab(space: nil, url: nil, parent: nil))
        let second = try #require(m.snapshot.activeTab)
        m.send(.activateTab(tab: first))
        m.perform(.toggleSplitView)

        m.perform(.focusOtherPane)
        #expect(m.snapshot.activeTab == second)
        #expect(m.activeSplit != nil, "crossing the split must not dismiss it")

        m.perform(.focusOtherPane)
        #expect(m.snapshot.activeTab == first, "one binding is enough for two panes")
    }

    @Test("closing one side gives the other the whole area")
    func closingOnePaneKeepsTheOther() async throws {
        let m = model()
        let first = try #require(m.snapshot.activeTab)
        m.send(.openTab(space: nil, url: nil, parent: nil))
        let second = try #require(m.snapshot.activeTab)
        m.send(.activateTab(tab: first))
        m.perform(.toggleSplitView)

        m.close(second)

        #expect(m.activeSplit == nil)
        #expect(m.snapshot.activeTab == first)
        #expect(m.engine.webView(for: second) == nil, "the closed pane's view goes with it")
        #expect(m.engine.webView(for: first) != nil, "the survivor keeps its page")
    }

    @Test("a page moved into a split is not reloaded on the way")
    func panesKeepTheirLiveViews() async throws {
        let m = model()
        let first = try #require(m.snapshot.activeTab)
        let view = try #require(m.engine.webView(for: first))
        m.send(.openTab(space: nil, url: nil, parent: nil))
        m.send(.activateTab(tab: first))

        m.perform(.toggleSplitView)

        // Reparented, not rebuilt. A different object here would mean every
        // split threw away the page you were reading and fetched it again.
        #expect(m.engine.webView(for: first) === view)
    }

    @Test("going to a third tab puts the split away")
    func activatingElsewhereDismissesTheSplit() async throws {
        let m = model()
        let first = try #require(m.snapshot.activeTab)
        m.send(.openTab(space: nil, url: nil, parent: nil))
        m.send(.openTab(space: nil, url: nil, parent: nil))
        let third = try #require(m.snapshot.activeTab)
        m.send(.activateTab(tab: first))
        m.perform(.toggleSplitView)

        m.activate(third)

        // Otherwise the sidebar would mark a row that is not on screen.
        #expect(m.activeSplit == nil)
        #expect(m.snapshot.activeTab == third)
    }

    @Test("the sidebar says which rows are on screen together")
    func theSidebarKnowsAboutBothPanes() async throws {
        let m = model()
        let first = try #require(m.snapshot.activeTab)
        m.send(.openTab(space: nil, url: nil, parent: nil))
        let second = try #require(m.snapshot.activeTab)
        m.send(.openTab(space: nil, url: nil, parent: nil))
        let third = try #require(m.snapshot.activeTab)
        m.send(.activateTab(tab: first))

        m.splitWith(second)

        #expect(m.isInSplit(first))
        #expect(m.isInSplit(second))
        #expect(!m.isInSplit(third), "a tab that is not on screen must not be marked")
        #expect(m.splitCompanion(of: second) == first)
        #expect(m.splitPanes == [first, second])
    }

    @Test("a tab from another space cannot be brought in beside this one")
    func splittingAcrossSpacesIsRefused() async throws {
        let m = model()
        let personal = m.snapshot.activeSpace
        let mine = try #require(m.snapshot.activeTab)
        m.createSpace(named: "Work")
        let theirs = try #require(m.snapshot.activeTab)
        m.activate(space: personal)
        m.activate(mine)

        m.splitWith(theirs)

        // Two panes drawing from two cookie jars would be one window claiming
        // to be two.
        #expect(m.activeSplit == nil)
    }

    @Test("the divider cannot be dragged until one side is gone")
    func theDividerHasLimits() async throws {
        let m = model()
        let first = try #require(m.snapshot.activeTab)
        m.send(.openTab(space: nil, url: nil, parent: nil))
        m.send(.activateTab(tab: first))
        m.perform(.toggleSplitView)

        // The same rule the drag consults on every frame, so what you see while
        // dragging is what you get when you let go.
        #expect(clampSplitRatio(ratio: 0.99) == clampSplitRatio(ratio: 5))
        #expect(clampSplitRatio(ratio: 0.5) == 0.5)

        m.setSplitRatio(0.99)
        let wide = try #require(m.activeSplit).ratio
        #expect(wide < 0.9 && wide > 0.5, "a pane may not be squeezed to nothing")

        m.setSplitRatio(-1)
        let narrow = try #require(m.activeSplit).ratio
        #expect(narrow > 0.1 && narrow < 0.5)

        // Double-clicking the divider goes back to where a split opens, not to
        // a number the shell picked for itself.
        m.setSplitRatio(defaultSplitRatio())
        #expect(try #require(m.activeSplit).ratio == defaultSplitRatio())
    }

    @Test("an extension sees two ordinary tabs, one of them selected")
    func extensionsSeeBothPanesAsTabs() async throws {
        let m = model()
        let first = try #require(m.snapshot.activeTab)
        m.send(.openTab(space: nil, url: nil, parent: nil))
        let second = try #require(m.snapshot.activeTab)
        m.send(.activateTab(tab: first))

        m.perform(.toggleSplitView)

        // `WKWebExtensionTab` has no way to say "visible beside another", so
        // this is the compromise: both panes are listed, and exactly one is
        // active — the one with the keyboard, which is the one a popup should
        // act on.
        let ids = m.snapshot.tabs.map(\.id)
        #expect(ids.contains(first) && ids.contains(second))
        #expect(m.snapshot.activeTab == first)

        m.perform(.focusOtherPane)
        #expect(m.snapshot.activeTab == second, "moving pane moves what an extension calls active")
    }
}

/// The shortcut, which had to be chosen rather than inherited: Chrome has no
/// split, so nothing existed to copy.
@MainActor
struct SplitShortcutTests {
    @Test("split view is on ⌘\\, and moving across it is ⇧⌘\\")
    func theBindingsAreWhereTheyWereChosen() async throws {
        let m = BrowserModel(storagePath: nil)

        let split = try #require(m.chord(for: .toggleSplitView))
        #expect(split.key == .char(value: "\\"))
        #expect(split.modifiers.primary)
        #expect(!split.modifiers.shift)

        let other = try #require(m.chord(for: .focusOtherPane))
        #expect(other.key == .char(value: "\\"))
        #expect(other.modifiers.primary)
        #expect(other.modifiers.shift)
    }

    @Test("neither binding takes a chord something else already had")
    func theBindingsStepOnNothing() async throws {
        let m = BrowserModel(storagePath: nil)

        for chord in [m.chord(for: .toggleSplitView), m.chord(for: .focusOtherPane)] {
            let chord = try #require(chord)
            let owners = m.keymap.filter { $0.chord == chord }
            #expect(owners.count == 1, "\(chord) is bound \(owners.count) times")
        }
    }

    @Test("both survive the trip into a SwiftUI shortcut")
    func theBindingsConvert() async throws {
        let m = BrowserModel(storagePath: nil)
        let chord = try #require(m.chord(for: .toggleSplitView))

        let shortcut = try #require(chord.keyboardShortcut)

        #expect(shortcut.key == KeyEquivalent("\\"))
        #expect(shortcut.modifiers.contains(.command))
    }
}

/// A split that came back as two loose tabs would keep every page and lose the
/// one thing the person actually arranged.
@MainActor
struct SplitPersistenceTests {
    @Test("a split comes back after a relaunch")
    func splitSurvivesRelaunch() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zer0-split-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("session.sqlite").path

        let panes: [TabId]
        do {
            let first = BrowserModel(storagePath: path)
            let leading = try #require(first.snapshot.activeTab)
            first.send(.openTab(space: nil, url: nil, parent: nil))
            first.send(.activateTab(tab: leading))
            first.perform(.toggleSplitView)
            first.setSplitRatio(0.35)

            panes = try #require(first.splitPanes)
            first.save()
        }

        // A brand new model against the same file, the way a relaunch works.
        let second = BrowserModel(storagePath: path)

        #expect(second.splitPanes == panes, "the pair must come back as a pair")
        let ratio = try #require(second.activeSplit).ratio
        #expect(abs(ratio - 0.35) < 0.0001, "the divider must come back where it was left")
        for pane in panes {
            #expect(second.engine.webView(for: pane) != nil, "a restored pane needs a live view")
        }
    }
}
