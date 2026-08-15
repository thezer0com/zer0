import AppKit
import SwiftUI
import Testing
import Zer0Core

@testable import Zer0Shell

/// Looking at the two surfaces a kept page has: the shelf in the sidebar and
/// the panel ⌘D opens.
///
/// Both are new, and neither had been rendered. The shelf's empty state in
/// particular is what everybody sees on day one and nobody sees again, so it is
/// the screen most likely to ship wrong.
///
/// Opt-in. See `ZZShotHarness.swift`.
@MainActor
struct ZZBookmarkShots {
    private func model(keeping count: Int, tabs: Int = 3) -> BrowserModel {
        let m = BrowserModel(storagePath: nil)
        for index in 0 ..< tabs {
            m.send(.openTab(space: nil, url: "https://site-\(index).example.com/", parent: nil))
            if let tab = m.snapshot.activeTab {
                m.send(.navigationCommitted(tab: tab, url: "https://site-\(index).example.com/"))
                m.send(.titleChanged(tab: tab, title: "A page with a title long enough to be real"))
            }
        }
        for index in 0 ..< count {
            m.send(.openTab(space: nil, url: "https://kept-\(index).example.com/read", parent: nil))
            guard let tab = m.snapshot.activeTab else { continue }
            m.send(.navigationCommitted(tab: tab, url: "https://kept-\(index).example.com/read"))
            m.send(.titleChanged(tab: tab, title: keptTitles[index % keptTitles.count]))
            m.send(.saveBookmark(tab: tab))
            m.send(.closeTab(tab: tab))
        }
        // Labels on some and not others, because a row that reserves space for
        // a second line it usually has nothing to put on is what has to be
        // looked at.
        for (index, bookmark) in m.bookmarks.enumerated() where index.isMultiple(of: 2) {
            m.rename(bookmark, to: bookmark.title, tags: "rust, read later")
        }
        m.bookmarksVisible = true
        return m
    }

    private let keptTitles = [
        "The Rust Programming Language",
        "Writing a browser engine from scratch, part four",
        "Notes on WebKit's compositing model",
        "A very long article title that has to truncate somewhere sensible",
    ]

    private func sidebar(_ m: BrowserModel) -> some View {
        Sidebar()
            .environment(m)
            .frame(width: 260, height: 620)
    }

    @Test(
        "the shelf, empty and full",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    func theShelf() async throws {
        for (name, count) in [("empty", 0), ("full", 4)] {
            let m = model(keeping: count)
            let shot = Shot(size: CGSize(width: 260, height: 620)) { sidebar(m) }
            shot.advance(0.4)
            shot.write("bookmark-shelf-\(name)")
            print("\(name): \(m.bookmarks.count) kept, \(m.snapshot.tabs.count) tabs")
            #expect(m.bookmarks.count == count)
        }
    }

    /// Shut, which is how it spends most of its life, and the state where the
    /// promise "keeping a page costs you no room" is either kept or broken.
    @Test(
        "the shelf shut costs one row",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    func theShelfShut() async throws {
        let m = model(keeping: 4)
        m.bookmarksVisible = false
        let shot = Shot(size: CGSize(width: 260, height: 620)) { sidebar(m) }
        shot.advance(0.4)
        shot.write("bookmark-shelf-shut")
        #expect(!m.bookmarksVisible)
    }

    /// The panel over a page, so a translucent material has something to be
    /// translucent about. A flat colour behind it makes any material look like
    /// a flat colour.
    @Test(
        "the panel a keep opens, new and already kept",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    func thePanel() async throws {
        for name in ["new", "again"] {
            let m = BrowserModel(storagePath: nil)
            m.send(.openTab(space: nil, url: nil, parent: nil))
            guard let tab = m.snapshot.activeTab else { continue }
            m.send(.navigationCommitted(tab: tab, url: "https://doc.rust-lang.org/book/ch04-01.html"))
            m.send(.titleChanged(tab: tab, title: "What is Ownership? - The Rust Programming Language"))

            m.perform(.addBookmark)
            if name == "again" {
                m.stopKeeping()
                m.perform(.addBookmark)
            }
            let kept = try #require(m.keeping)

            let shot = Shot(size: CGSize(width: 1000, height: 620)) {
                ZStack(alignment: .topTrailing) {
                    LinearGradient(
                        colors: [
                            Color(red: 0.10, green: 0.34, blue: 0.62),
                            Color(red: 0.86, green: 0.36, blue: 0.20),
                            Color(red: 0.97, green: 0.95, blue: 0.90),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    BookmarkPanel(kept: kept)
                        .padding(Design.Space.regular)
                }
                .environment(m)
                .frame(width: 1000, height: 620)
            }
            shot.advance(0.4)
            shot.write("bookmark-panel-\(name)")
            print("\(name): isNew \(kept.isNew)")
            #expect(kept.isNew == (name == "new"))
        }
    }
}
