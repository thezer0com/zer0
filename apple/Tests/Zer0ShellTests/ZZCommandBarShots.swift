import AppKit
import SwiftUI
import Testing
import Zer0Core

@testable import Zer0Shell

/// Looking at the command bar, which is the surface of the product a person
/// stares at most and the one nobody had rendered short.
///
/// Opt-in. See `ZZShotHarness.swift`.
@MainActor
struct ZZCommandBarShots {
    /// A model whose bar is open with roughly `wanted` suggestions in it.
    ///
    /// Tabs rather than history, because a tab's title is settable from here
    /// and a visited page's is not without an engine.
    private func openBar(suggestions wanted: Int, query: String = "orbit") -> BrowserModel {
        let model = BrowserModel(storagePath: nil)
        // Two suggestions is the bar with nothing matching but the query
        // itself: what it reads as, and the way into chat. Everything between
        // those two is open tabs.
        for index in 0 ..< max(0, wanted - 2) {
            model.send(.openTab(space: nil, url: "https://\(query)-\(index).example.com/", parent: nil))
            if let tab = model.snapshot.activeTab {
                model.send(.titleChanged(
                    tab: tab,
                    title: "\(query.capitalized) \(index): a page with a title long enough to be real"
                ))
            }
        }
        model.openCommandBar(intent: .navigateCurrentTab)
        model.commandBarQuery = query
        model.updateSuggestions()
        return model
    }

    /// The panel over something, so a translucent material has something to be
    /// translucent about. A flat colour behind it would make any material look
    /// like a flat colour.
    private func page() -> some View {
        LinearGradient(
            colors: [
                Color(red: 0.10, green: 0.34, blue: 0.62),
                Color(red: 0.86, green: 0.36, blue: 0.20),
                Color(red: 0.97, green: 0.95, blue: 0.90),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func scene(_ model: BrowserModel) -> some View {
        ZStack(alignment: .top) {
            page()
            Color.black.opacity(0.15)
            CommandBar()
                .padding(.top, 100)
        }
        .environment(model)
        .frame(width: 1000, height: 620)
    }

    @Test(
        "the command bar, short list and long",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    func theBar() async throws {
        for (name, count) in [("short", 2), ("long", 8)] {
            let model = openBar(suggestions: count)
            let shot = Shot(size: CGSize(width: 1000, height: 620)) { scene(model) }
            shot.advance(0.4)
            shot.write("command-bar-\(name)")

            let rep = shot.frame()
            // Where the panel starts and stops, read off the pixels rather than
            // off the layout: the whole defect being chased is a panel that
            // claims more height than it has content for.
            let column = rep.pixelsWide / 2
            let top = rep.firstRow(inColumn: column, unlike: rep.colour(x: 4, y: 4))
            print("\(name): \(model.suggestions.count) suggestions, panel top row \(top ?? -1)")
            #expect(model.suggestions.count > 0)
        }
    }

    /// How tall the panel is, measured off the view rather than off a
    /// screenshot, for two and for eight rows.
    ///
    /// The short list is the whole point: a panel that is the same height for
    /// two rows as for eight is a panel with a hole in it.
    @Test(
        "the panel is as tall as its list",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    func panelHeightFollowsContent() async throws {
        var measured: [Int: CGFloat] = [:]

        for count in [2, 8] {
            let model = openBar(suggestions: count)
            let track = Track()
            let shot = Shot(size: CGSize(width: 1000, height: 620)) {
                ZStack(alignment: .top) {
                    page()
                    CommandBar().tracked(by: track).padding(.top, 100)
                }
                .environment(model)
                .frame(width: 1000, height: 620)
            }
            shot.advance(0.4)
            measured[model.suggestions.count] = track.samples.last?.height ?? 0
            print("suggestions \(model.suggestions.count): panel \(track.samples.last?.height ?? 0)pt")
        }

        let short = measured.filter { $0.key <= 3 }.values.max() ?? 0
        let long = measured.filter { $0.key >= 6 }.values.max() ?? 0
        #expect(short > 0 && long > 0, "nothing measured: \(measured)")
        #expect(
            long > short + 100,
            "a two-row panel (\(short)pt) and an eight-row panel (\(long)pt) are the same height"
        )
    }
}
