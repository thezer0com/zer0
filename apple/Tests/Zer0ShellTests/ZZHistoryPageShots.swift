import AppKit
import SwiftUI
import Testing
import Zer0Core

@testable import Zer0Shell

/// Looking at the two screens that stopped being Settings panes.
///
/// A pane and a page are not the same drawing problem. A pane lived inside a
/// 640-point column with a section list beside it; these have a whole tab, and
/// the things that go wrong at that width — a row stretched to 1400 points, a
/// strip with nothing on the left of it, an empty state marooned in the middle
/// of a very large rectangle — are not visible from source (ADR-0063).
///
/// Four screens, and the empty ones matter most: on day one they are the only
/// ones anybody sees.
///
/// Opt-in. See `ZZShotHarness.swift`.
@MainActor
struct ZZHistoryPageShots {
    private static let pageSize = CGSize(width: 1100, height: 700)

    private let visited: [(url: String, title: String)] = [
        ("https://github.com/WebKit/WebKit", "WebKit/WebKit: Home of the WebKit project"),
        ("https://doc.rust-lang.org/book/ch15-05-interior-mutability.html",
         "RefCell<T> and the Interior Mutability Pattern"),
        ("https://developer.apple.com/documentation/swiftui/view/focused(_:)",
         "focused(_:) | Apple Developer Documentation"),
        ("https://news.ycombinator.com/item?id=41000000", "Show HN: a browser with a Rust core"),
        ("https://avelino.run/posts/a-title-long-enough-that-it-has-to-truncate-somewhere",
         "A title long enough that it has to truncate somewhere sensible"),
        ("https://example.com/", "Example Domain"),
    ]

    /// A history spread over three days, so the day headers are really doing
    /// something rather than being one header over everything.
    private func model(withHistory: Bool) -> BrowserModel {
        let m = BrowserModel(storagePath: nil)
        guard withHistory else { return m }

        let tab = m.snapshot.activeTab!
        for (index, entry) in visited.enumerated() {
            // Two visits for some, so the "×" count appears on some rows and
            // not others — the case where a row reserves space it usually has
            // nothing to put in.
            for _ in 0...(index % 2) {
                m.send(.navigationCommitted(tab: tab, url: entry.url))
                m.send(.titleChanged(tab: tab, title: entry.title))
            }
        }
        m.send(.navigationCommitted(tab: tab, url: "https://elsewhere.example/"))
        return m
    }

    private func page(_ m: BrowserModel) -> some View {
        HistoryPage()
            .environment(m)
            .frame(width: Self.pageSize.width, height: Self.pageSize.height)
    }

    @Test(
        "the history page, full and empty",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    func historyPage() async throws {
        let full = Shot(size: Self.pageSize) { page(model(withHistory: true)) }
        full.advance(0.4)
        print("history-full: \(full.write("history-full"))")

        let empty = Shot(size: Self.pageSize) { page(model(withHistory: false)) }
        empty.advance(0.4)
        print("history-empty: \(empty.write("history-empty"))")
    }

    @Test(
        "the downloads page, full and empty",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    func downloadsPage() async throws {
        let full = Shot(size: Self.pageSize) {
            DownloadsPage()
                .environment(downloading())
                .frame(width: Self.pageSize.width, height: Self.pageSize.height)
        }
        full.advance(0.4)
        print("downloads-full: \(full.write("downloads-full"))")

        let empty = Shot(size: Self.pageSize) {
            DownloadsPage()
                .environment(BrowserModel(storagePath: nil))
                .frame(width: Self.pageSize.width, height: Self.pageSize.height)
        }
        empty.advance(0.4)
        print("downloads-empty: \(empty.write("downloads-empty"))")
    }

    /// One of each state ADR-0027 draws differently: arriving with a length,
    /// arriving without one, finished, and failed.
    private func downloading() -> BrowserModel {
        let m = BrowserModel(storagePath: nil)

        m.send(.downloadStarted(
            id: "d1", tab: nil, url: "https://example.com/report.pdf",
            suggestedFilename: "report.pdf", totalBytes: 8_400_000, defaultDirectory: "/tmp"
        ))
        m.send(.downloadProgressed(id: "d1", receivedBytes: 3_100_000, totalBytes: 8_400_000))

        m.send(.downloadStarted(
            id: "d2", tab: nil, url: "https://example.com/stream.bin",
            suggestedFilename: "an-archive-with-a-long-name.zip", totalBytes: nil,
            defaultDirectory: "/tmp"
        ))
        m.send(.downloadProgressed(id: "d2", receivedBytes: 412_000, totalBytes: nil))

        m.send(.downloadStarted(
            id: "d3", tab: nil, url: "https://example.com/notes.txt",
            suggestedFilename: "notes.txt", totalBytes: 4_200, defaultDirectory: "/tmp"
        ))
        m.send(.downloadFinished(id: "d3"))

        m.send(.downloadStarted(
            id: "d4", tab: nil, url: "https://example.com/big.dmg",
            suggestedFilename: "big.dmg", totalBytes: 900_000_000, defaultDirectory: "/tmp"
        ))
        m.send(.downloadFailed(id: "d4", kind: .noSpace, message: ""))

        return m
    }
}
