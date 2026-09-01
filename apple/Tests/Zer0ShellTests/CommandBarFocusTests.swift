import AppKit
import SwiftUI
import Testing
import Zer0Core

@testable import Zer0Shell

/// Focus is behaviour, not decoration: a command bar you have to click into is
/// broken. These drive the real AppKit field in a real window.
@MainActor
struct CommandBarFocusTests {
    private func newModel() -> BrowserModel { BrowserModel(storagePath: nil) }

    /// Puts the field in a key window, the way SwiftUI would.
    private func mount(
        text: String,
        onSubmit: @escaping () -> Void = {},
        onCancel: @escaping () -> Void = {},
        onMove: @escaping (Int) -> Void = { _ in }
    ) -> (
        window: NSWindow,
        field: NSTextField,
        coordinator: CommandBarField.Coordinator,
        representable: CommandBarField
    ) {
        var storage = text
        let representable = CommandBarField(
            text: Binding(get: { storage }, set: { storage = $0 }),
            onSubmit: onSubmit,
            onCancel: onCancel,
            onMove: onMove
        )
        let coordinator = representable.makeCoordinator()
        let field = representable.buildField(delegate: coordinator)

        let window = testWindow(
            NSRect(x: 0, y: 0, width: 620, height: 60),
            styleMask: [.titled]
        )
        field.frame = NSRect(x: 10, y: 10, width: 600, height: 28)
        window.contentView?.addSubview(field)
        window.makeKeyAndOrderFront(nil)

        representable.sync(field, coordinator: coordinator)
        return (window, field, coordinator, representable)
    }

    /// The mounted field, with the opening take already accounted for and
    /// nothing in flight against the field itself.
    ///
    /// `mount`'s sync arms a `takeFocus` that the main queue may hold for
    /// several turns — long enough to land after a later steal and hand
    /// focus back on its own, which let the reclaim test pass with nothing
    /// implemented. Here the take is armed against a scratch field that
    /// never reaches a window, and `takeFocus` refuses a field with no
    /// window, so the mounted field starts with a clean queue and any
    /// focus it later gets or loses can only be the test's doing.
    private func mountWithLatchPrimed(text: String) -> (
        window: NSWindow,
        field: NSTextField,
        coordinator: CommandBarField.Coordinator,
        representable: CommandBarField
    ) {
        var storage = text
        let representable = CommandBarField(
            text: Binding(get: { storage }, set: { storage = $0 }),
            onSubmit: {},
            onCancel: {},
            onMove: { _ in }
        )
        let coordinator = representable.makeCoordinator()
        let field = representable.buildField(delegate: coordinator)

        let scratch = representable.buildField(delegate: coordinator)
        representable.sync(scratch, coordinator: coordinator)

        let window = testWindow(
            NSRect(x: 0, y: 0, width: 620, height: 60),
            styleMask: [.titled]
        )
        field.frame = NSRect(x: 10, y: 10, width: 600, height: 28)
        window.contentView?.addSubview(field)
        window.makeKeyAndOrderFront(nil)

        return (window, field, coordinator, representable)
    }

    /// Focus is taken a run-loop cycle after mounting, so wait for it to have
    /// happened rather than for a duration that looked long enough once.
    private func focused(_ field: NSTextField) async -> Bool {
        await eventually { field.currentEditor() != nil }
    }

    private func ownsFocus(_ field: NSTextField, in window: NSWindow) -> Bool {
        guard let editor = field.currentEditor() else { return false }
        return window.firstResponder === editor
    }

    // MARK: - What the core decides

    @Test("⌘L opens the bar seeded with the current URL")
    func openLocationSeedsTheUrl() async throws {
        let model = newModel()
        let tab = try #require(model.snapshot.activeTab)
        model.send(.navigationCommitted(tab: tab, url: "https://avelino.run/"))

        model.focusCommandBar()

        #expect(model.commandBarOpen)
        #expect(model.commandBarQuery == "https://avelino.run/")
    }

    @Test("⌘T opens an empty bar rather than the current URL")
    func newTabStartsEmpty() async throws {
        let model = newModel()
        let tab = try #require(model.snapshot.activeTab)
        model.send(.navigationCommitted(tab: tab, url: "https://avelino.run/"))

        model.openTab()

        #expect(model.commandBarOpen)
        #expect(model.commandBarQuery.isEmpty)
    }

    @Test("⌘L while loading shows where you are going, not where you were")
    func pendingUrlWins() async throws {
        let model = newModel()
        let tab = try #require(model.snapshot.activeTab)
        model.send(.navigationCommitted(tab: tab, url: "https://old.com/"))
        model.send(.navigateTo(tab: tab, input: "avelino.run"))

        model.focusCommandBar()

        #expect(model.commandBarQuery == "https://avelino.run")
    }

    // MARK: - What the field does

    @Test("the field takes first responder without anyone clicking it")
    func fieldTakesFocus() async throws {
        let mounted = mount(text: "https://avelino.run/")
        defer { mounted.window.orderOut(nil) }

        // AppKit hands editing to a shared field editor, so the first
        // responder is that text view rather than the field itself.
        #expect(
            await focused(mounted.field),
            "nothing took focus, so the user would have to click first"
        )
        #expect(mounted.window.firstResponder is NSTextView)
    }

    @Test("the existing text comes selected, so typing replaces it")
    func existingTextIsSelected() async throws {
        let url = "https://avelino.run/"
        let mounted = mount(text: url)
        defer { mounted.window.orderOut(nil) }

        // Focus and the select-all happen in the same hop, so waiting on the
        // selection covers both.
        #expect(
            await eventually {
                mounted.field.currentEditor()?.selectedRange.length == url.utf16.count
            },
            "the whole URL must be selected, or typing appends to it"
        )
    }

    @Test("focus is taken once, not stolen back on every redraw")
    func focusIsTakenOnce() async throws {
        let text = "avelino.run"
        let mounted = mountWithLatchPrimed(text: text)
        defer { mounted.window.orderOut(nil) }

        // The window keys the field and selects what is in it; waiting for
        // that means nothing asynchronous is left to touch the selection.
        #expect(
            await eventually {
                mounted.field.currentEditor()?.selectedRange.length == text.utf16.count
            }
        )

        // Typing narrows the selection to a caret. A redraw that re-took
        // focus would redo select-all and the next keystroke would wipe the
        // word — the "it deletes what I am typing" failure, not a detail.
        mounted.field.currentEditor()?.selectedRange =
            NSRange(location: text.utf16.count, length: 0)
        mounted.representable.sync(mounted.field, coordinator: mounted.coordinator)

        // The main queue is FIFO: once a block queued after the sync has
        // run, anything the sync queued has run too — so the caret below
        // survived every take the redraw could have armed, not just the
        // first instants of one.
        let settled = QueueLatch()
        DispatchQueue.main.async { settled.run = true }
        #expect(await eventually { settled.run })

        #expect(
            mounted.field.currentEditor()?.selectedRange.length == 0,
            "a redraw re-took focus and re-selected the text mid-typing"
        )
        #expect(ownsFocus(mounted.field, in: mounted.window))
        #expect(mounted.coordinator.hasTakenFocus)
    }

    @Test("reopening find takes focus back after another field wins it")
    func focusReturnsAfterItIsLost() async throws {
        let text = "avelino.run"
        let mounted = mountWithLatchPrimed(text: text)
        defer { mounted.window.orderOut(nil) }

        // The field owns the keyboard before focus goes elsewhere, or there
        // is nothing to take back.
        #expect(
            await eventually { ownsFocus(mounted.field, in: mounted.window) }
        )

        let other = NSButton()
        other.frame = NSRect(x: 10, y: 40, width: 200, height: 24)
        mounted.window.contentView?.addSubview(other)
        #expect(mounted.window.makeFirstResponder(other))
        #expect(await eventually { !ownsFocus(mounted.field, in: mounted.window) })

        mounted.representable.sync(mounted.field, coordinator: mounted.coordinator)

        #expect(
            await eventually { ownsFocus(mounted.field, in: mounted.window) },
            "⌘F must reclaim the find field after focus moves elsewhere"
        )
    }

    @Test("escape cancels and enter submits")
    func keysReachTheHandlers() async throws {
        var cancelled = false
        var submitted = false
        let mounted = mount(text: "", onSubmit: { submitted = true }, onCancel: { cancelled = true })
        defer { mounted.window.orderOut(nil) }

        let scratch = NSTextView()
        _ = mounted.coordinator.control(
            NSControl(), textView: scratch,
            doCommandBy: #selector(NSResponder.cancelOperation(_:))
        )
        _ = mounted.coordinator.control(
            NSControl(), textView: scratch,
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        )

        #expect(cancelled)
        #expect(submitted)
    }

    @Test("arrow keys move the highlight, but only up and down")
    func arrowsAreIntercepted() async throws {
        var moves: [Int] = []
        let mounted = mount(text: "", onMove: { moves.append($0) })
        defer { mounted.window.orderOut(nil) }

        let scratch = NSTextView()
        let handledDown = mounted.coordinator.control(
            NSControl(), textView: scratch,
            doCommandBy: #selector(NSResponder.moveDown(_:))
        )
        let handledUp = mounted.coordinator.control(
            NSControl(), textView: scratch,
            doCommandBy: #selector(NSResponder.moveUp(_:))
        )
        let handledLeft = mounted.coordinator.control(
            NSControl(), textView: scratch,
            doCommandBy: #selector(NSResponder.moveLeft(_:))
        )

        #expect(moves == [1, -1])
        #expect(handledDown)
        #expect(handledUp)
        #expect(!handledLeft, "left arrow belongs to the text, not to the list")
    }

    @Test("⌘T and ⌘L open the same bar with different intents")
    func gesturesCarryTheirIntent() async throws {
        let model = newModel()

        model.openTab()
        #expect(model.commandBarIntent == .openNewTab)

        model.focusCommandBar()
        #expect(model.commandBarIntent == .navigateCurrentTab)
    }

    @Test("typing in the field reaches the binding")
    func typingUpdatesTheBinding() async throws {
        var text = ""
        let representable = CommandBarField(
            text: Binding(get: { text }, set: { text = $0 }),
            onSubmit: {}, onCancel: {}, onMove: { _ in }
        )
        let coordinator = representable.makeCoordinator()
        let field = representable.buildField(delegate: coordinator)

        field.stringValue = "avelino.run"
        coordinator.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: field)
        )

        #expect(text == "avelino.run")
    }
}

/// A flag a main-queue block sets, so a test can ask "has the queue reached
/// this point yet" instead of sleeping for a guess at it.
final class QueueLatch: @unchecked Sendable {
    var run = false
}

/// Where a chosen row lands.
///
/// The bar is one panel serving two gestures, so this is the half that can go
/// wrong without anything looking broken: ⌘L quietly opening tabs instead of
/// navigating is exactly the Chrome divergence ADR-0011 exists to prevent.
/// A `data:` URL keeps every one of these off the network.
@MainActor
struct CommandBarDestinationTests {
    private func newModel() -> BrowserModel { BrowserModel(storagePath: nil) }

    private let page = "data:text/html,hello"

    @Test("⌘L navigates the tab you are on rather than opening another")
    func openLocationNavigatesHere() async throws {
        let model = newModel()
        let tab = try #require(model.snapshot.activeTab)
        let before = model.snapshot.tabs.count

        model.focusCommandBar()
        model.accept(.navigate(url: page))

        #expect(model.snapshot.tabs.count == before, "⌘L must not pile up tabs")
        #expect(model.snapshot.activeTab == tab)
        // Read before the engine can report anything back, so this is the
        // core's decision and not a race with WebKit.
        #expect(model.activeTab?.pendingUrl == page)
        #expect(!model.commandBarOpen)
    }

    @Test("⌘L with nothing open still gets you somewhere")
    func openLocationWithNoTabs() async throws {
        let model = newModel()
        model.closeActiveTab()
        #expect(model.snapshot.tabs.isEmpty)

        model.focusCommandBar()
        model.accept(.navigate(url: page))

        #expect(model.snapshot.tabs.count == 1, "there was no tab to navigate, so make one")
        #expect(model.activeTab?.pendingUrl == page)
    }

    @Test("⌘T opens the destination in a tab of its own")
    func newTabOpensBeside() async throws {
        let model = newModel()
        let tab = try #require(model.snapshot.activeTab)
        let before = model.snapshot.tabs.count

        model.openTab()
        model.accept(.navigate(url: page))

        #expect(model.snapshot.tabs.count == before + 1)
        #expect(model.snapshot.activeTab != tab)
    }

    @Test("picking an open tab switches to it, whichever gesture opened the bar")
    func pickingATabSwitches() async throws {
        let model = newModel()
        let first = try #require(model.snapshot.activeTab)
        model.send(.openTab(space: nil, url: nil, parent: nil))
        let before = model.snapshot.tabs.count
        let switchToFirst = Suggestion.switchToTab(tab: first, title: "First", url: nil)

        model.focusCommandBar()
        model.accept(switchToFirst)

        #expect(model.snapshot.activeTab == first)
        #expect(model.snapshot.tabs.count == before, "switching must not open a copy")
    }

    @Test("⌘↩ opens over there even when the bar was opened with ⌘L")
    func deliberateNewTabOverridesTheIntent() async throws {
        let model = newModel()
        let tab = try #require(model.snapshot.activeTab)
        let before = model.snapshot.tabs.count

        model.focusCommandBar()
        model.accept(.navigate(url: page), inNewTab: true)

        #expect(model.snapshot.tabs.count == before + 1)
        #expect(model.snapshot.activeTab != tab)
        #expect(model.activeTab?.pendingUrl == page)
    }
}
