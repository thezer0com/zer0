import AppKit
import SwiftUI
import Testing
import Zer0Core

@testable import Zer0Shell

/// The licensed icon set as the shell draws it, and the find bar that wears
/// the first five icons of the migration (ADR-0116).
///
/// The geometry suites vouch for the numbers; only a pair of eyes can vouch
/// that a stroke-drawn set reads at 13pt — the smallest size this design
/// draws an icon at — which is exactly the revisit condition ADR-0116 names.
/// The big row is for looking at the shapes; the small row wears the sides
/// the find bar actually uses.
///
/// Opt-in. `ZER0_SHOT=1 swift test --filter ZZLucide`. See
/// `ZZShotHarness.swift`.
@Suite("ZZ lucide shots")
struct ZZLucideShots {
    /// The set: each icon large enough to judge as a shape, then all five at
    /// the sides the find bar draws them at (its `Metrics` are private, so
    /// the numbers are repeated here — a board, not an assertion).
    private func board() -> some View {
        VStack(alignment: .leading, spacing: Design.Space.section) {
            HStack(alignment: .top, spacing: Design.Space.loose) {
                ForEach(LucideIcon.allCases, id: \.self) { icon in
                    VStack(spacing: Design.Space.tight) {
                        LucideGlyph(icon: icon, side: 64)
                        Text(String(describing: icon)).font(Design.Text.mono)
                    }
                }
            }

            HStack(spacing: Design.Space.regular) {
                LucideGlyph(icon: .search, side: 14)
                LucideGlyph(icon: .chevronUp, side: Design.Glyph.control)
                LucideGlyph(icon: .chevronDown, side: Design.Glyph.control)
                LucideGlyph(icon: .check, side: 11)
                LucideGlyph(icon: .x, side: Design.Glyph.control)
                // A word beside the small row, at the size the strip sets:
                // what "reads at 13pt" is judged against.
                Text("Find in page").font(Design.Text.detail)
            }
        }
        .padding(Design.Space.section)
    }

    /// The panel over something, so a translucent material has something to
    /// be translucent about. Same gradient the command bar shots use.
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

    @Test(
        "the set, light and dark",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    @MainActor
    func theSet() async throws {
        for dark in [false, true] {
            let shot = Shot(size: CGSize(width: 640, height: 260)) {
                board()
                    .foregroundStyle(.primary)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .colorScheme(dark ? .dark : .light)
            }

            // Each big glyph paints: an empty path renders as confidently as
            // a full one, and ink is the cheapest thing a board can assert.
            // The big row lays the icons left to right, 24pt apart inside
            // 32pt padding, so cell `i` starts at 32 + i × 88.
            let rep = shot.frame()
            for (index, icon) in LucideIcon.allCases.enumerated() {
                let cell = CGRect(x: 32 + index * 88, y: 20, width: 88, height: 100)
                #expect(
                    rep.ink(in: cell, unlike: rep.colour(x: 4, y: 4)) != nil,
                    "\(icon) painted nothing"
                )
            }

            shot.write("lucide-set-\(dark ? "dark" : "light")")
        }
    }

    @Test(
        "the find bar wearing them",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    @MainActor
    func theFindBar() async throws {
        // Idle, which is how the bar opens: the lens, the two chevrons and
        // the close are on it. The found check is on the set board — driving
        // a real search to completion needs an engine, and a board that
        // faked the state would verify the fake.
        let model = BrowserModel(storagePath: nil)

        let shot = Shot(size: CGSize(width: 1000, height: 300)) {
            ZStack(alignment: .topTrailing) {
                page()
                FindBar()
                    .padding(Design.Space.regular)
            }
            .environment(model)
        }
        shot.advance(0.4)
        shot.write("lucide-find-bar")

        let rep = shot.frame()
        let strip = CGRect(x: 500, y: 0, width: 500, height: 300)
        #expect(
            rep.ink(in: strip, unlike: rep.colour(x: 4, y: 4)) != nil,
            "the find bar painted nothing"
        )
    }
}
