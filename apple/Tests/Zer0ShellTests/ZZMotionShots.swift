import AppKit
import SwiftUI
import Testing
import Zer0Core

@testable import Zer0Shell

/// Whether the motion in this shell moves anything.
///
/// The reason this file exists: a doc comment in `SplitView` records an
/// animation that was described three ways in prose and never shifted a pixel
/// in any of them. Prose is not evidence. Every case here drives the real view
/// with the real curve and reads where the thing was across every layout pass.
/// One position means nothing moved, whatever the code says.
///
/// **What this harness can and cannot see**, established by probing rather than
/// assumed, because a measurement that cannot fail is worth nothing:
///
/// - **A transition that changes layout is visible in pixels.** The sidebar's
///   space switch reads 16 → 112 → 16 points as the outgoing list leaves and
///   the incoming one arrives. That is what `spaceSwitchTravels` uses.
/// - **A transition that only transforms is visible in neither.** `cacheDisplay`
///   on an `NSHostingView` draws the *model* layer, so a view part way through
///   a `.scale` or `.offset` transition rasterises where it is going to be; and
///   `onGeometryChange` reports layout, which a transform does not touch. Five
///   probes of the command bar's arrival — a plain white rectangle with no
///   AppKit in it, `.move(edge: .top)` instead of the custom transition, an
///   explicit `withAnimation`, and both of the real compositions — all read as
///   "never moved", and an `onGeometryChange` recorder built to second-guess
///   them agreed, reporting one position for the whole arrival. **That is the
///   same false negative the `SplitView` doc comment records**, and it is a
///   property of the capture, not of the animation.
/// - **Opacity is visible in pixels.** Which is how the command bar's arrival
///   is checked at all: the scrim it brings with it darkens the window, and a
///   scrim that steps through intermediate values is a transaction that
///   carried an animation. That is precisely the thing that used to be broken.
///
/// So: the panel's own 12pt drop and 3% scale are asserted by the transition
/// and are **not separately measured here**. What is measured is that the event
/// they belong to is animated rather than instantaneous, and that Reduce Motion
/// removes travel where travel can be seen.
///
/// Opt-in. See `ZZShotHarness.swift`.
@MainActor
struct ZZMotionShots {
    // MARK: - The command bar arriving

    /// The panel over the page, composed the way `BrowserView` composes it:
    /// a scrim that fades and a panel that comes forward, both on one curve.
    private struct Summoning: View {
        @Environment(BrowserModel.self) private var model

        var body: some View {
            ZStack {
                Color(red: 0.12, green: 0.14, blue: 0.18)
                if model.commandBarOpen {
                    ZStack(alignment: .top) {
                        Color.black.opacity(0.15).transition(.opacity)
                        CommandBar()
                            .padding(.top, CommandBar.Metrics.dropFromTop)
                            .summoned()
                    }
                }
            }
            .motion(.entrance, value: model.commandBarOpen)
        }
    }

    private func barModel() -> BrowserModel {
        let model = BrowserModel(storagePath: nil)
        model.commandBarQuery = "orbit"
        model.updateSuggestions()
        return model
    }

    @Test(
        "the command bar arrives over time rather than between two frames",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    func commandBarArrivalIsAnimated() async throws {
        let model = barModel()
        // Small, so a bitmap per tick is cheap enough to sample the curve
        // densely. Nothing here reads anything but one corner pixel.
        let size = CGSize(width: 400, height: 300)
        let shot = Shot(size: size) {
            Summoning().environment(model)
                .frame(width: size.width, height: size.height)
        }
        shot.advance(0.3)

        // The undimmed page, in a corner the panel never reaches.
        let page = shot.frame().colour(x: 6, y: 6)
        let base = page.usingColorSpace(.deviceRGB)!.brightnessComponent

        model.commandBarOpen = true

        var levels: [Double] = []
        for _ in 0 ..< 60 {
            shot.advance(0.004)
            let now = shot.frame().colour(x: 6, y: 6).usingColorSpace(.deviceRGB)!
            levels.append((Double(now.brightnessComponent) * 1000).rounded() / 1000)
        }
        shot.write("summon-settled")

        let seen = levels.reduce(into: [Double]()) { out, value in
            if out.last != value { out.append(value) }
        }
        print("scrim, page brightness per frame: \(levels)")
        print("distinct: \(seen)")

        #expect(
            seen.count >= 3,
            "the window dimmed in \(seen.count) step(s): the bar did not arrive, it appeared"
        )
        #expect(seen.last! < Double(base), "the window has to end up dimmed")
    }

    // MARK: - Switching spaces

    private func twoSpaces() -> BrowserModel {
        let model = BrowserModel(storagePath: nil)
        if let tab = model.snapshot.activeTab {
            model.send(.titleChanged(tab: tab, title: "Personal one"))
        }
        model.createSpace(named: "Work")
        model.send(.openTab(space: nil, url: "https://work.example.com/", parent: nil))
        if let tab = model.snapshot.activeTab {
            model.send(.titleChanged(tab: tab, title: "Work one"))
        }
        // Back to the first, so the measured switch is a deliberate one.
        if let first = model.snapshot.spaces.first?.id {
            model.activate(space: first)
        }
        return model
    }

    /// Where the leftmost mark in the sidebar sits, frame by frame, while a
    /// space change is in flight.
    ///
    /// Mid-switch there are two lists in the column — the one being left and
    /// the one arriving — so this single number takes intermediate values only
    /// while something is travelling. It is a layout change rather than a
    /// transform, which is why pixels can see it at all.
    private func switchSpaces(reduceMotion: Bool) -> [CGFloat] {
        let model = twoSpaces()
        let size = CGSize(width: 280, height: 500)
        let shot = Shot(size: size) {
            Sidebar()
                .reduceMotion(reduceMotion)
                .environment(model)
                .frame(width: size.width, height: size.height)
        }
        shot.advance(0.4)
        if !reduceMotion { shot.write("space-before") }

        let background = shot.frame().colour(x: Int(size.width / 2), y: 6)

        guard let second = model.snapshot.spaces.last?.id else { return [] }
        model.activate(space: second)

        var edges: [CGFloat] = []
        for _ in 0 ..< 40 {
            shot.advance(0.004)
            if let ink = shot.frame().ink(
                in: CGRect(x: 0, y: 40, width: size.width * 2, height: size.height * 2 - 100),
                unlike: background,
                tolerance: 0.10
            ) {
                edges.append(ink.minX)
            }
        }
        shot.write(reduceMotion ? "space-settled-reduced" : "space-settled")

        return edges.reduce(into: [CGFloat]()) { out, value in
            if out.last != value { out.append(value) }
        }
    }

    @Test(
        "switching a space moves the list instead of replacing it",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    func spaceSwitchTravels() async throws {
        let model = twoSpaces()
        let second = try #require(model.snapshot.spaces.last?.id)
        model.activate(space: second)
        #expect(model.spaceTravel == 1, "moving to the second chip is travel to the right")

        let seen = switchSpaces(reduceMotion: false)
        print("space switch, leftmost column: \(seen.map { Int($0) })")
        #expect(seen.count >= 3, "the list was at \(seen.count) position(s): it did not travel")
    }

    @Test(
        "Reduce Motion takes the travel away and leaves the arrival",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    func reduceMotionRemovesTheTravel() async throws {
        // Pointed at the space switch rather than at the command bar, and
        // deliberately: this is the one moment whose travel this harness has
        // been shown to see. Asserting "no travel" on something it cannot see
        // travel in either way would be a test that passes for the wrong
        // reason, which is worse than no test.
        let seen = switchSpaces(reduceMotion: true)
        print("space switch under Reduce Motion, leftmost column: \(seen.map { Int($0) })")

        #expect(!seen.isEmpty, "the list still has to arrive")
        #expect(
            seen.count == 1,
            "Reduce Motion is on and the list still travelled through \(seen.map { Int($0) })"
        )
    }
}
