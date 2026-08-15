import AppKit
import SwiftUI
import Testing
import Zer0Core

@testable import Zer0Shell

/// The sidebar at each end of the range it is allowed to take, so the floor is
/// an argument somebody can look at rather than a number in a comment.
///
/// `Sidebar.Metrics.minWidth` claims that 140 — SwiftUI's own default for a
/// sidebar column — leaves a list of first syllables, and that 200 leaves
/// titles. That claim is the whole reason ADR-0014 gave up the horizontal tab
/// strip, and it cannot be settled by an assertion: `SidebarWidthTests` proves
/// the column is at least 200 wide, and nothing anywhere proves 200 is enough.
/// These boards are where that is decided, and the 140 board is on them
/// deliberately — it is what the sidebar becomes the day the width modifier is
/// dropped.
///
/// **Opt-in.** `ZER0_SHOT=1 swift test --filter ZZSidebarWidth`.
@Suite("ZZ sidebar width shots")
struct ZZSidebarWidthShots {
    /// Four levels up from this file is the repository root, where `design/`
    /// already holds the palette and icon boards.
    private static let output = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "design/sidebar")

    /// Titles long enough to truncate and different enough from one another
    /// that whether they are still distinguishable is a question with an answer.
    private static let pages: [(host: String, title: String)] = [
        ("news.ycombinator.com", "Hacker News"),
        ("en.wikipedia.org", "Bauhaus — Wikipedia, the free encyclopedia"),
        ("developer.mozilla.org", "WKWebView - Web APIs | MDN"),
        ("github.com", "avelino/zer0-browser: a WebKit browser with a Rust core"),
        ("avelino.run", "Thiago Avelino"),
        ("figma.com", "zer0 — design system — Figma"),
    ]

    @Test(
        "the sidebar at its floor, its ideal and its ceiling",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    @MainActor
    func theSidebarAcrossItsRange() throws {
        try FileManager.default.createDirectory(
            at: Self.output, withIntermediateDirectories: true
        )

        let model = BrowserModel(storagePath: nil)
        seed(model)

        // 140 is not in the range. It is on the board because it is what the
        // column becomes when nothing declares a floor.
        let widths: [(String, CGFloat)] = [
            ("01-undeclared-140", 140),
            ("02-floor-\(Int(Sidebar.Metrics.minWidth))", Sidebar.Metrics.minWidth),
            ("03-ideal-\(Int(Sidebar.Metrics.idealWidth))", Sidebar.Metrics.idealWidth),
            ("04-ceiling-\(Int(Sidebar.Metrics.maxWidth))", Sidebar.Metrics.maxWidth),
        ]

        for (name, width) in widths {
            for dark in [false, true] {
                let shot = Shot(size: CGSize(width: width, height: 620)) {
                    Sidebar()
                        .environment(model)
                        .zer0Palette()
                        .preferredColorScheme(dark ? .dark : .light)
                }
                shot.hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                shot.settle()
                let path = Self.output
                    .appending(path: "\(name)-\(dark ? "dark" : "light").png")
                    .path
                let rep = shot.frame()
                try rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: path))
                print("shot: \(path)")
            }
        }
    }

    /// Pages in all three groups, so every heading is on the board.
    @MainActor
    private func seed(_ model: BrowserModel) {
        for page in Self.pages {
            model.send(.openTab(space: nil, url: nil, parent: nil))
            guard let tab = model.snapshot.activeTab else { continue }
            model.send(.navigationCommitted(tab: tab, url: "https://\(page.host)/"))
            model.send(.titleChanged(tab: tab, title: page.title))
            model.send(.navigationFinished(tab: tab))
        }
        let home = model.snapshot.activeSpace
        model.createSpace(named: "Work")
        model.createSpace(named: "Errands")
        model.activate(space: home)

        let tabs = model.snapshot.tabs.map(\.id)
        if tabs.count > 2 {
            model.setKind(tabs[0], .favorite)
            model.setKind(tabs[1], .pinned)
        }
    }
}
