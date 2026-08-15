import SwiftUI
import Testing
import Zer0Core

@testable import Zer0Shell

/// What Reduce Motion does to the two curves, and which way the sidebar
/// travels when a space changes.
///
/// These run on every `check.sh`. What they cannot see is whether anything
/// actually moves on screen — that needs frames, and the frames live in
/// `ZZMotionShots.swift` behind `ZER0_SHOT=1`. What they *can* see is the rule
/// itself, which is the part someone would undo by accident: a future curve
/// added without asking the environment, or an `entrance` left springing for a
/// person who asked for less movement.
@MainActor
struct MotionTests {
    private let full = Design.Motion(reduced: false)
    private let reduced = Design.Motion(reduced: true)

    @Test("Reduce Motion declines the overshoot")
    func reduceMotionFlattensEntrance() {
        // The spring is the whole difference between the two curves. With the
        // setting on, an arrival still takes time — it just stops bouncing,
        // which means it is the same curve as an adjustment.
        #expect(full.entrance != full.subtle, "two curves, or there is only one")
        #expect(reduced.entrance == reduced.subtle)
        #expect(reduced.entrance != full.entrance)
    }

    @Test("Reduce Motion does not slow feedback down or take it away")
    func reduceMotionKeepsFeedback() {
        // `subtle` is what a row lighting under the pointer and a panel
        // resizing use. Someone who asked for less movement did not ask for a
        // less responsive interface, so this is deliberately untouched.
        #expect(reduced.subtle == full.subtle)
    }

    @Test("every curve in the shell is one of the two")
    func thereAreOnlyTwoCurves() {
        // Read off the enum, not written out here. This line used to be
        // `let all: [Design.Curve] = [.entrance, .subtle]`, which counted the
        // array it had just built: a third case in `DesignSystem` left it
        // green, which is the one thing it exists to catch.
        let all = Design.Curve.allCases
        #expect(all.count == 2, "the shell has two curves and the choice means something")
        #expect(all.contains(.entrance) && all.contains(.subtle))

        // And both resolve, in both modes, without a nil that would silently
        // switch an animation off rather than reduce it.
        for curve in all {
            _ = full(curve)
            _ = reduced(curve)
        }
    }

    // MARK: - Which way a space change went

    private let a: SpaceId = 1
    private let b: SpaceId = 2
    private let c: SpaceId = 3

    @Test("moving right through the chips is travel to the right")
    func travelForward() {
        #expect(BrowserModel.travel(from: a, to: b, through: [a, b, c]) == 1)
        #expect(BrowserModel.travel(from: a, to: c, through: [a, b, c]) == 1)
    }

    @Test("moving left through the chips is travel to the left")
    func travelBackward() {
        #expect(BrowserModel.travel(from: c, to: a, through: [a, b, c]) == -1)
        #expect(BrowserModel.travel(from: b, to: a, through: [a, b, c]) == -1)
    }

    @Test("a space that stopped existing is not somewhere you travelled from")
    func closedSpaceIsNotTravel() {
        // Closing the space you are in moves you somewhere without you going
        // anywhere. A list that slid in from the left would be claiming a
        // gesture nobody made.
        #expect(BrowserModel.travel(from: b, to: a, through: [a, c]) == 0)
        #expect(BrowserModel.travel(from: nil, to: a, through: [a]) == 0)
        #expect(BrowserModel.travel(from: a, to: a, through: [a]) == 0)
    }

    @Test("the model reports the direction whatever asked for the change")
    func directionSurvivesEveryPath() async throws {
        let model = BrowserModel(storagePath: nil)
        model.createSpace(named: "Work")
        let spaces = model.snapshot.spaces.map(\.id)
        try #require(spaces.count == 2)

        model.activate(space: spaces[0])
        #expect(model.spaceTravel == -1, "back to the first chip is travel left")

        // The keyboard path goes through the core, not through the chip that
        // was clicked, which is exactly why the direction is read off the
        // snapshot rather than off the button.
        model.perform(.nextSpace)
        #expect(model.snapshot.activeSpace == spaces[1])
        #expect(model.spaceTravel == 1)
    }
}
