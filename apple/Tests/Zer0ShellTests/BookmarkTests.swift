import Testing
import Zer0Core

@testable import Zer0Shell

/// What the shell owes a kept page.
///
/// The ranking, the ordering and what a bookmark *is* all live in the core and
/// are tested there. What is here is the half a shell can get wrong on its own:
/// whether the press produces something you can see, whether a chord that
/// changes state changes the screen, and whether what you type is written down.
@MainActor
struct BookmarkTests {
    private func modelWithAPage(_ url: String = "https://avelino.run/") -> (BrowserModel, TabId) {
        let m = BrowserModel(storagePath: nil)
        m.send(.openTab(space: nil, url: nil, parent: nil))
        let tab = m.snapshot.activeTab!
        m.send(.navigationCommitted(tab: tab, url: url))
        m.send(.titleChanged(tab: tab, title: "Avelino"))
        return (m, tab)
    }

    @Test("keeping a page says so")
    func keepingAnswers() async throws {
        // A key that changes nothing you can see is the worst failure a
        // shortcut has: no error, no feedback, and the person presses it three
        // more times.
        let (m, _) = modelWithAPage()

        m.perform(.addBookmark)

        let kept = try #require(m.keeping, "⌘D must answer")
        #expect(kept.isNew)
        #expect(kept.bookmark.url == "https://avelino.run/")
        #expect(m.bookmarks.count == 1)
    }

    @Test("keeping a page twice does not take it back")
    func keepingTwiceIsNotDestructive() async throws {
        let (m, _) = modelWithAPage()

        m.perform(.addBookmark)
        m.stopKeeping()
        m.perform(.addBookmark)

        #expect(m.bookmarks.count == 1)
        let kept = try #require(m.keeping)
        // And it says which of the two happened rather than claiming a save
        // that did not occur.
        #expect(!kept.isNew)
    }

    @Test("keeping a page leaves the tab where it was")
    func keepingLeavesTheTabAlone() async throws {
        // The distinction the whole feature rests on: a bookmark is not a tab,
        // so ⌘D must not move one between sidebar groups the way it used to.
        let (m, tab) = modelWithAPage()
        let kindBefore = m.snapshot.tabs.first { $0.id == tab }?.kind
        let countBefore = m.snapshot.tabs.count

        m.perform(.addBookmark)

        #expect(m.snapshot.tabs.first { $0.id == tab }?.kind == kindBefore)
        #expect(m.snapshot.tabs.count == countBefore)
    }

    @Test("a page with nothing loaded keeps nothing")
    func anEmptyTabKeepsNothing() async throws {
        let m = BrowserModel(storagePath: nil)
        m.send(.openTab(space: nil, url: nil, parent: nil))

        m.perform(.addBookmark)

        #expect(m.bookmarks.isEmpty)
        #expect(m.keeping == nil)
    }

    @Test("showing the shelf opens the sidebar it lives in")
    func theShelfBringsItsSidebarWithIt() async throws {
        // A shelf revealed inside a panel that is not on screen is a shortcut
        // that responds and does nothing, which is ADR-0014's failure mode.
        let m = BrowserModel(storagePath: nil)
        m.sidebarVisible = false
        m.bookmarksVisible = false

        m.perform(.toggleBookmarks)

        #expect(m.bookmarksVisible)
        #expect(m.sidebarVisible)
    }

    @Test("the shelf toggles once it is actually visible")
    func theShelfTogglesWhenItIsOnScreen() async throws {
        let m = BrowserModel(storagePath: nil)
        m.sidebarVisible = true
        m.bookmarksVisible = true

        m.perform(.toggleBookmarks)

        #expect(!m.bookmarksVisible)
    }

    @Test("the shelf starts rolled up")
    func theShelfStartsShut() async throws {
        // Keeping a page must not cost room in the list you look at all day,
        // and a shelf that unrolled itself every launch would charge it back.
        let m = BrowserModel(storagePath: nil)
        #expect(!m.bookmarksVisible)
    }

    @Test("renaming what you kept is written down")
    func renamingSticks() async throws {
        let (m, _) = modelWithAPage()
        m.perform(.addBookmark)
        let bookmark = try #require(m.keeping?.bookmark)

        m.rename(bookmark, to: "Read in March", tags: "Rust, read later, rust")

        let stored = try #require(m.bookmarks.first)
        #expect(stored.title == "Read in March")
        // Two spellings of one label are one label, decided in the core.
        #expect(stored.tags == ["rust", "read later"])
    }

    @Test("the tags field is read the way it is typed")
    func tagsAreSplitOnCommas() async throws {
        #expect(BrowserModel.tagList("rust, read later") == ["rust", "read later"])
        #expect(BrowserModel.tagList("  rust ,, ,  browsers ") == ["rust", "browsers"])
        #expect(BrowserModel.tagList("").isEmpty)
        #expect(BrowserModel.tagList("   ").isEmpty)
    }

    @Test("removing takes the panel with it")
    func removingClosesThePanel() async throws {
        let (m, _) = modelWithAPage()
        m.perform(.addBookmark)
        let bookmark = try #require(m.keeping?.bookmark)

        m.forget(bookmark)

        #expect(m.bookmarks.isEmpty)
        #expect(m.keeping == nil, "a panel about something that is gone is a panel about nothing")
    }

    @Test("a kept page opens in a tab of its own")
    func openingAKeptPageLeavesTheOneYouAreOnAlone() async throws {
        let (m, _) = modelWithAPage()
        m.perform(.addBookmark)
        m.stopKeeping()
        let bookmark = try #require(m.bookmarks.first)
        let countBefore = m.snapshot.tabs.count

        m.openBookmark(bookmark)

        #expect(
            m.snapshot.tabs.count == countBefore + 1,
            "you went looking for it, not to lose where you were"
        )
    }

    @Test("a page kept in a throwaway space says it will outlive it")
    func keepingFromAnEphemeralSpaceIsSaidOutLoud() async throws {
        // The behaviour is deliberate (ADR-0059) and therefore has to be
        // announced before the fact rather than discovered after it.
        let m = BrowserModel(storagePath: nil)
        let space = m.snapshot.activeSpace
        m.send(.setSpaceProfile(
            space: space,
            profile: SpaceProfile(userAgent: nil, ephemeral: true)
        ))
        m.send(.openTab(space: nil, url: nil, parent: nil))
        let tab = try #require(m.snapshot.activeTab)
        m.send(.navigationCommitted(tab: tab, url: "https://avelino.run/"))

        m.perform(.addBookmark)

        let kept = try #require(m.keeping)
        #expect(kept.fromEphemeralSpace)
    }

    @Test("opening the command bar puts the keep panel away")
    func theCommandBarTakesOver() async throws {
        // Two floating panels answering two different questions at once is one
        // too many.
        let (m, _) = modelWithAPage()
        m.perform(.addBookmark)

        m.perform(.openLocation)

        #expect(m.keeping == nil)
        #expect(m.commandBarOpen)
    }

    @Test("a kept page shows up in the command bar above history")
    func theBarOffersWhatYouKept() async throws {
        // The ranking is the core's and is tested there. This is the wiring:
        // the shell asks the core, and what comes back reaches the list the
        // panel draws.
        let (m, tab) = modelWithAPage("https://avelino.run/keep")
        m.perform(.addBookmark)
        m.stopKeeping()
        // Closed, because an open tab outranks everything and would be offered
        // instead — which is the ranking working, and not what this checks.
        // It is also the job a bookmark exists for: the tab is gone and the
        // page is still reachable.
        m.send(.closeTab(tab: tab))

        m.openCommandBar(intent: .openNewTab)
        m.commandBarQuery = "avelino"
        m.updateSuggestions()

        #expect(
            m.suggestions.contains { suggestion in
                if case let .openBookmark(url, _) = suggestion {
                    return url == "https://avelino.run/keep"
                }
                return false
            },
            "got \(m.suggestions)"
        )
    }
}
