import Foundation
import Testing
import Zer0Core

@testable import Zer0Shell

/// History and downloads as pages, and the Settings panes they replaced.
///
/// ADR-0063. The point of the change is not that there are two more screens —
/// it is that there is now exactly *one* screen for each of these two things.
/// Most of what is locked here is that the second one is gone.
@Suite("history and downloads are pages")
@MainActor
struct HistoryAndDownloadPageTests {
    // MARK: - The chord opens a page

    @Test("⌘Y opens history as a tab rather than a settings window")
    func historyOpensAsATab() {
        let model = BrowserModel(storagePath: nil)
        let reading = try! #require(model.snapshot.activeTab)
        model.send(.navigationCommitted(tab: reading, url: "https://example.com/reading"))
        model.showingSettings = false

        model.perform(.showHistory)

        #expect(model.showingSettings == false, "⌘Y opened the Settings window")
        let opened = try! #require(model.snapshot.activeTab)
        #expect(opened != reading, "⌘Y took the page being read")
        #expect(
            model.snapshot.tabs.first { $0.id == opened }?.url
                == internalAddressUrl(address: .history)
        )
        #expect(
            model.snapshot.tabs.first { $0.id == reading }?.url == "https://example.com/reading",
            "the page being read was navigated away"
        )
    }

    @Test("⇧⌘J opens downloads as a tab rather than a settings window")
    func downloadsOpensAsATab() {
        let model = BrowserModel(storagePath: nil)
        model.showingSettings = false

        model.perform(.showDownloads)

        #expect(model.showingSettings == false, "⇧⌘J opened the Settings window")
        let opened = try! #require(model.snapshot.activeTab)
        #expect(
            model.snapshot.tabs.first { $0.id == opened }?.url
                == internalAddressUrl(address: .downloads)
        )
    }

    /// Pressing it again returns to the list rather than opening a second copy.
    /// Two tabs showing one history are two views of one state, and the stale
    /// one is always the one being read.
    @Test("pressing it twice returns to the page rather than opening a second")
    func pressingItTwiceReturnsToThePage() {
        let model = BrowserModel(storagePath: nil)

        model.perform(.showHistory)
        let opened = try! #require(model.snapshot.activeTab)
        let count = model.snapshot.tabs.count

        model.send(.openTab(space: nil, url: nil, parent: nil))
        model.perform(.showHistory)

        #expect(model.snapshot.activeTab == opened)
        #expect(model.snapshot.tabs.count == count + 1, "a second history tab was opened")
    }

    // MARK: - The panes are gone

    /// Not merely unreachable — gone. A pane still in the enum is a pane one
    /// line of code away from being on screen again beside the page that
    /// replaced it, and nothing about which of the two was stale would be
    /// visible from either.
    @Test("settings has no history pane and no downloads pane")
    func settingsHasNeitherPane() {
        let sections = SettingsSection.allCases.map(\.rawValue)

        #expect(sections.contains("history") == false)
        #expect(sections.contains("downloads") == false)
        // The rest of the window is untouched, so this is not passing because
        // the enum emptied out.
        #expect(sections.contains("privacy"))
        #expect(sections.contains("general"))
    }

    /// The views themselves, by name, in the sources. The enum could lose a
    /// case while the pane it drew sits there waiting to be wired up again.
    @Test("no settings pane draws history or downloads")
    func noSettingsPaneDrawsEither() throws {
        for source in try SourceScan.shellSources() {
            for name in ["HistorySettings", "DownloadsSettings"] {
                let complaint = "\(source.path) still has \(name). History and downloads are "
                    + "pages at addresses of their own, and a Settings pane holding a second "
                    + "copy of either is two screens for one thing (ADR-0063)."
                #expect(SourceScan.occurrences(of: name, in: source.code).isEmpty, "\(complaint)")
            }
        }
    }

    /// One "Clear History…" in the browser, and it is beside the list it
    /// clears. A second one two panes away is a second path to a destructive
    /// act, with the copy on one of them going stale the first time the other
    /// gains a span.
    @Test("clearing history has one home and it is the page")
    func clearingHistoryHasOneHome() throws {
        let settings = try #require(
            try SourceScan.shellSources().first { $0.path.hasSuffix("SettingsView.swift") }
        )
        #expect(
            SourceScan.occurrences(of: "clearHistory", in: settings.code).isEmpty,
            "SettingsView still clears history (ADR-0063)"
        )

        let page = try #require(
            try SourceScan.shellSources().first { $0.path.hasSuffix("HistoryPage.swift") }
        )
        #expect(!SourceScan.occurrences(of: "DestructiveButton", in: page.code).isEmpty)
    }

    // MARK: - Search

    /// The page's search is the command bar's ranking, not a second one.
    ///
    /// Asserted through the shell rather than in Rust, because the failure this
    /// guards against is a shell that quietly filters the list itself — which
    /// is the tidier-looking thing to write and would leave every core test
    /// green.
    @Test("the page's search is the ranking the core does")
    func searchIsTheCoresRanking() {
        let model = BrowserModel(storagePath: nil)
        let tab = try! #require(model.snapshot.activeTab)

        // A weak match visited constantly against a strong one visited once:
        // the pair a substring filter or an uncapped frecency would order
        // differently.
        for _ in 0..<10 {
            model.send(.navigationCommitted(tab: tab, url: "https://g.example.com/h"))
        }
        model.send(.navigationCommitted(tab: tab, url: "https://github.com/"))
        model.send(.titleChanged(tab: tab, title: "GitHub"))
        // And off it again, to somewhere with no `g` before an `h` in it. A tab
        // sitting on one of these addresses is offered as a tab and suppresses
        // the history row for it, which would make this compare two lists with
        // different membership rather than two orders.
        model.send(.navigationCommitted(tab: tab, url: "https://elsewhere.example/"))

        model.openCommandBar(intent: .openNewTab)
        model.commandBarQuery = "gh"
        model.updateSuggestions()

        let page = model.searchHistory("gh").map(\.url)
        let bar = model.suggestions.compactMap { row -> String? in
            switch row {
            case let .openHistory(url, _): url
            case .switchToTab, .openBookmark, .navigate, .search, .askChat: nil
            }
        }

        #expect(!bar.isEmpty, "the bar offered no history, so this proves nothing")
        #expect(Array(page.prefix(bar.count)) == bar, "two rankings of one history")
    }

    /// A search that matches nothing shows nothing. Falling back to the whole
    /// list is a screen that says "no matches" by showing you everything.
    @Test("a search that matches nothing returns nothing")
    func aSearchThatMatchesNothingReturnsNothing() {
        let model = BrowserModel(storagePath: nil)
        let tab = try! #require(model.snapshot.activeTab)
        model.send(.navigationCommitted(tab: tab, url: "https://github.com/"))

        #expect(model.searchHistory("zzzzq").isEmpty)
        #expect(model.searchHistory("").isEmpty == false, "an empty search hid the whole list")
    }

    // MARK: - Deleting

    @Test("forgetting one page reaches the core and leaves the rest")
    func forgettingOnePageReachesTheCore() {
        let model = BrowserModel(storagePath: nil)
        let tab = try! #require(model.snapshot.activeTab)
        model.send(.navigationCommitted(tab: tab, url: "https://a.example/"))
        model.send(.navigationCommitted(tab: tab, url: "https://b.example/"))

        model.forgetHistory(url: "https://a.example/")

        let left = model.recentHistory(limit: 10).map(\.url)
        #expect(left.contains("https://a.example/") == false)
        #expect(left.contains("https://b.example/"))
    }

    /// Clearing takes a span, and the span is what goes. A "Clear" that always
    /// meant everything would be a control whose menu was decoration.
    @Test("clearing a span reaches the core and takes only that span")
    func clearingASpanReachesTheCore() {
        let model = BrowserModel(storagePath: nil)
        let tab = try! #require(model.snapshot.activeTab)
        model.send(.navigationCommitted(tab: tab, url: "https://recent.example/"))

        // Nothing is older than an hour in a fresh session, so the narrow span
        // is the one that proves the span is read rather than ignored.
        model.clearHistory(.lastHour)
        #expect(model.recentHistory(limit: 10).isEmpty)

        model.send(.navigationCommitted(tab: tab, url: "https://again.example/"))
        model.clearHistory(.everything)
        #expect(model.recentHistory(limit: 10).isEmpty)
    }

    // MARK: - It behaves like a page

    /// ⌘F on the history page means its search field, not a find bar over a
    /// page with no document in it. WebKit's find would report "not found"
    /// about a screen full of rows, which is a lie shaped like an answer.
    @Test("⌘F on the history page asks the page to search rather than opening a find bar")
    func findOnTheHistoryPageAsksThePage() {
        let model = BrowserModel(storagePath: nil)
        let tab = try! #require(model.snapshot.activeTab)
        model.send(.navigateTo(tab: tab, input: internalAddressUrl(address: .history)))

        let before = model.pageSearchRequests
        model.perform(.findInPage)

        #expect(model.pageSearchRequests == before + 1, "the page was never asked to search")
        #expect(model.finder.isOpen == false, "a find bar opened over a page with no document")
    }

    /// And on a web page it is still WebKit's find, unchanged.
    @Test("⌘F on a web page still opens the find bar")
    func findOnAWebPageStillOpensTheBar() {
        let model = BrowserModel(storagePath: nil)
        let tab = try! #require(model.snapshot.activeTab)
        model.send(.navigationCommitted(tab: tab, url: "https://example.com/"))

        model.perform(.findInPage)

        #expect(model.finder.isOpen)
    }

    /// ⌘W closes it like any other tab, because it is one. Nothing had to be
    /// built for this, and that is the whole argument for the shape.
    @Test("⌘W closes a history tab the way it closes any tab")
    func closingWorksLikeAnyTab() {
        let model = BrowserModel(storagePath: nil)
        model.perform(.showHistory)
        let opened = try! #require(model.snapshot.activeTab)

        model.perform(.closeTab)

        #expect(model.snapshot.tabs.contains { $0.id == opened } == false)
    }

    /// And with two browser windows open, the page lands in the window the
    /// chord was pressed in. A list appearing in a window behind this one is
    /// the same failure ADR-0053 named, one dimension along: it is not that
    /// nothing happened, it is that it happened somewhere you cannot see.
    @Test("the page opens in the window the chord was pressed in")
    func thePageOpensInTheWindowTheChordWasPressedIn() throws {
        let model = BrowserModel(storagePath: nil)
        let first = model.snapshot.keyWindow
        model.send(.openWindow(onto: .currentSpace))
        let second = model.snapshot.keyWindow
        try #require(second != first)
        let theirTabs = model.snapshot.tabs.filter { $0.window == second }.map(\.id)

        // What `handleKeyDown` does with a press from `first`: point the core
        // at that window, then run the command. Asserted here rather than
        // through the key monitor because what is being locked is where the
        // page lands, not how a chord is decoded.
        model.focusWindow(first)
        model.perform(.showHistory)
        model.focusWindow(first)
        model.perform(.showDownloads)

        #expect(
            model.snapshot.tabs.filter { $0.window == second }.map(\.id) == theirTabs,
            "a page opened in the window behind the one the chord came from"
        )
        let landed = model.snapshot.tabs.filter { $0.window == first }.compactMap(\.url)
        #expect(landed.contains(internalAddressUrl(address: .history)))
        #expect(landed.contains(internalAddressUrl(address: .downloads)))
    }

    /// A command that opens a tab must not run from the Settings window: the
    /// tab would open behind it, out of sight. They used to cross because they
    /// raised a window of their own; they do not any more.
    @Test("a page command does not run from a window that is not the browser")
    func aPageCommandDoesNotCrossIntoAnAuxiliaryWindow() {
        #expect(UiCommand.showHistory.scope == .browserWindow)
        #expect(UiCommand.showDownloads.scope == .browserWindow)
        #expect(UiCommand.showHistory.reaches(.auxiliary) == false)
        #expect(UiCommand.showDownloads.reaches(.auxiliary) == false)
        // The one that still opens a window still crosses.
        #expect(UiCommand.showSettings.reaches(.auxiliary))
    }
}
