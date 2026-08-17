import SwiftUI
import Testing

@testable import Zer0Shell

/// The cost of a `Path` is that a wrong icon renders as confidently as a
/// right one — no crash, no warning, just a chevron pointing the wrong way on
/// a shipped find bar. These hold every vendored drawing against the numbers
/// its SVG declares, in the viewBox units the port is written in, the way
/// `Zer0MarkTests` holds the mark against `design/logo/zer0.svg`.
///
/// **Every case earns its row the day it lands.** The count below is what
/// makes that a rule rather than a hope: a new case with no vouched geometry
/// fails the suite instead of shipping on confidence.
struct LucideIconTests {
    /// The geometry each drawing is held to: how many subpaths, and the box
    /// its ink lands in (grid units — the numbers the SVG's own coordinates
    /// add up to).
    private let expected: [LucideIcon: (subpaths: Int, ink: CGRect)] = [
        // The lens: a circle at (11, 11), r 8 — so 3..19 — plus a handle
        // reaching to (21, 21).
        .search: (2, CGRect(x: 3, y: 3, width: 18, height: 18)),
        .chevronUp: (1, CGRect(x: 6, y: 9, width: 12, height: 6)),
        .chevronDown: (1, CGRect(x: 6, y: 9, width: 12, height: 6)),
        // (20, 6) → (9, 17) → (4, 12).
        .check: (1, CGRect(x: 4, y: 6, width: 16, height: 11)),
        // Two diagonals inside the 6..18 square.
        .x: (2, CGRect(x: 6, y: 6, width: 12, height: 12)),
    ]

    @Test("every icon carries vouched geometry")
    func everyCaseIsVouchedFor() {
        #expect(
            expected.count == LucideIcon.allCases.count,
            // A literal, not a `+`-joined String: swift-testing takes a
            // Comment, which only a literal converts to.
            "a case landed with no row in `expected`; vendored geometry nobody has vouched for is how a wrong icon ships"
        )
    }

    @Test("the ink is where the SVG says it is")
    func inkMatchesTheVendoredDrawings() {
        for icon in LucideIcon.allCases {
            let vouched = expected[icon]!
            let drawing = icon.drawing

            #expect(!drawing.isEmpty, "\(icon)")
            #expect(
                subpaths(of: drawing) == vouched.subpaths,
                "\(icon): a dropped or extra subpath still draws something"
            )
            #expect(
                matches(drawing.boundingRect, vouched.ink),
                "\(icon): ink at \(drawing.boundingRect), vouched \(vouched.ink)"
            )
        }
    }

    /// The stroke is centred on the ink, and round caps extend it by half a
    /// stroke — 1 at the grid's own size. Anything the set draws must fit the
    /// viewBox with that to spare, or the icon would clip against whatever
    /// sits beside it.
    @Test("the stroke stays inside the viewBox")
    func theStrokeStaysInsideTheGrid() {
        let grid = CGRect(origin: .zero, size: LucideIcon.viewBox)
        for icon in LucideIcon.allCases {
            #expect(
                grid.contains(icon.drawing.boundingRect.insetBy(dx: -1, dy: -1)),
                "\(icon) paints past its viewBox once the caps are paid for"
            )
        }
    }

    /// Bounds catch a broken path; these catch a *wrong* one. Same box, same
    /// subpath count, and a chevron that points down is still not a chevron
    /// that points up.
    @Test("the drawings are the icons they claim to be")
    func theDrawingsAreWhatTheyClaimToBe() {
        // A chevron is a three-point polyline whose middle vertex is the
        // apex: above the grid's centre for up, below it for down.
        #expect(apex(of: LucideIcon.chevronUp.drawing)!.y < 12)
        #expect(apex(of: LucideIcon.chevronDown.drawing)!.y > 12)

        // The check's deepest point is its middle vertex — the elbow, not an
        // endpoint. Deepest is the greatest y: the grid's y grows downward,
        // the way the SVG's does.
        #expect(deepest(of: LucideIcon.check.drawing)! == CGPoint(x: 9, y: 17))

        // Two straight subpaths, both through the centre of the grid, with
        // their endpoints in swapped corners: that is a cross, not a corner.
        let centre = CGPoint(x: 12, y: 12)
        let centres = lineCentres(of: LucideIcon.x.drawing)
        #expect(centres.count == 2)
        #expect(centres.allSatisfy { near($0, centre) })

        // The lens is a closed loop with its centre inside it, and the
        // handle is a second subpath leaving from the far corner.
        let search = LucideIcon.search.drawing
        #expect(inside(CGPoint(x: 11, y: 11), of: search))
        #expect(!inside(CGPoint(x: 11, y: 20), of: search))
        #expect(subpathStarts(of: search).last == CGPoint(x: 21, y: 21))
    }

    @Test("drawn in a box, the drawing fits the box")
    func theShapeRespectsItsBox() {
        // A square is the shape icons are actually drawn in; the others are
        // here because a `Shape` is handed whatever rect the layout gives it.
        let boxes = [
            CGRect(x: 0, y: 0, width: 256, height: 256),
            CGRect(x: 0, y: 0, width: 13, height: 13),
            CGRect(x: 10, y: 20, width: 200, height: 100),
            CGRect(x: -40, y: 7, width: 30, height: 180),
        ]

        for icon in LucideIcon.allCases {
            for box in boxes {
                let drawn = icon.path(in: box).boundingRect
                #expect(
                    box.insetBy(dx: -0.01, dy: -0.01).contains(drawn),
                    "\(icon) drawn at \(drawn), which escapes \(box)"
                )
            }
        }
    }

    /// The match with the design system is arithmetic, and arithmetic is
    /// what a test can hold: at the grid's own size the set's stroke is the
    /// system's heaviest named line, which is the match ADR-0116 licensed
    /// the set on.
    @Test("the set's stroke is the system's heaviest line at the grid's own size")
    func strokeLandsOnInsertion() {
        #expect(abs(24 * LucideIcon.strokeToGrid - Design.Stroke.insertion) < 0.0001)
    }

    // MARK: - Reading a Path as the shape it is

    /// How many times the pen was lifted: one per subpath.
    private func subpaths(of path: Path) -> Int {
        var count = 0
        path.forEach { element in
            if case .move = element { count += 1 }
        }
        return count
    }

    private func subpathStarts(of path: Path) -> [CGPoint] {
        var points: [CGPoint] = []
        path.forEach { element in
            if case .move(to: let point) = element { points.append(point) }
        }
        return points
    }

    /// The middle vertex of a polyline: a chevron's apex.
    private func apex(of path: Path) -> CGPoint? {
        let points = vertices(of: path)
        guard points.count == 3 else { return nil }
        return points[1]
    }

    private func deepest(of path: Path) -> CGPoint? {
        vertices(of: path).max { $0.y < $1.y }
    }

    /// Every `move` and `line` endpoint, ignoring curves — these five icons
    /// are straight-line drawings, and a curve appearing in one is itself a
    /// defect the other tests name.
    private func vertices(of path: Path) -> [CGPoint] {
        var points: [CGPoint] = []
        path.forEach { element in
            switch element {
            case .move(to: let point), .line(to: let point):
                points.append(point)
            case .quadCurve, .curve, .closeSubpath:
                break
            }
        }
        return points
    }

    /// The centre of each straight one-line subpath.
    private func lineCentres(of path: Path) -> [CGPoint] {
        var centres: [CGPoint] = []
        var start: CGPoint?
        var end: CGPoint?

        func close() {
            if let start, let end {
                centres.append(CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2))
            }
            start = nil
            end = nil
        }

        path.forEach { element in
            switch element {
            case .move(to: let point):
                close()
                start = point
                end = point
            case .line(to: let point):
                end = point
            case .quadCurve, .curve, .closeSubpath:
                break
            }
        }
        close()
        return centres
    }

    /// Whether the path's fill covers a point, computed here rather than
    /// asked of `Path.contains`: measured on the CI's macOS 15 runner, that
    /// API answers false for every point of the lens drawing — centre
    /// included — while macOS 26 answers the centre true. Rendering fills
    /// through a different door than that hit-test, so what moved between
    /// systems is the API's answer, not the ink. Each subpath is flattened
    /// (curves sampled sixteen times) and the point decided by even-odd
    /// crossings of a rightward ray: the same claim `eoFill:` was making,
    /// holding on every macOS the 15.4 floor admits.
    private func inside(_ point: CGPoint, of path: Path) -> Bool {
        var probe = EvenOddProbe(point: point)
        path.forEach { probe.add($0) }
        probe.closeRing()
        return probe.isInside
    }

    /// One small method per step, every signature explicit, because the
    /// first cut of this walked the path in a single closure — four cases
    /// of switch with the bezier arithmetic inline — and the CI's Swift
    /// 6.2 could not type-check that expression in reasonable time while
    /// the local 26.6 never complained. Behaviour is proven by the suite;
    /// this shape is what keeps slower solvers in the game.
    private struct EvenOddProbe {
        private let point: CGPoint
        private var crossings = 0
        private var ring: [CGPoint] = []
        private var pen = CGPoint.zero

        private static let samples = 16

        init(point: CGPoint) {
            self.point = point
        }

        var isInside: Bool {
            crossings % 2 == 1
        }

        mutating func add(_ element: Path.Element) {
            switch element {
            case .move(to: let p):
                startSubpath(at: p)
            case .line(to: let p):
                ring.append(p)
                pen = p
            case .quadCurve(to: let end, control: let c):
                flattenQuad(from: pen, through: c, to: end)
                pen = end
            case .curve(to: let end, control1: let c1, control2: let c2):
                flattenCubic(from: pen, via: c1, and: c2, to: end)
                pen = end
            case .closeSubpath:
                closeRing()
            }
        }

        mutating func closeRing() {
            if ring.count > 2 {
                countCrossings()
            }
            ring = []
        }

        private mutating func startSubpath(at p: CGPoint) {
            closeRing()
            ring = [p]
            pen = p
        }

        private mutating func countCrossings() {
            var index = 0
            while index < ring.count {
                let next = (index + 1) % ring.count
                countEdge(from: ring[index], to: ring[next])
                index += 1
            }
        }

        private mutating func countEdge(from a: CGPoint, to b: CGPoint) {
            let aAbove = a.y > point.y
            let bAbove = b.y > point.y
            if aAbove != bAbove {
                let slope = (b.x - a.x) / (b.y - a.y)
                let crossingX = a.x + (point.y - a.y) * slope
                if crossingX > point.x {
                    crossings += 1
                }
            }
        }

        private mutating func flattenQuad(
            from p0: CGPoint, through c: CGPoint, to p1: CGPoint
        ) {
            var step = 1
            while step <= Self.samples {
                let t = CGFloat(step) / CGFloat(Self.samples)
                ring.append(quadPoint(p0, c, p1, t: t))
                step += 1
            }
        }

        private mutating func flattenCubic(
            from p0: CGPoint, via c1: CGPoint, and c2: CGPoint, to p1: CGPoint
        ) {
            var step = 1
            while step <= Self.samples {
                let t = CGFloat(step) / CGFloat(Self.samples)
                ring.append(cubicPoint(p0, c1, c2, p1, t: t))
                step += 1
            }
        }

        private func quadPoint(
            _ p0: CGPoint, _ c: CGPoint, _ p1: CGPoint, t: CGFloat
        ) -> CGPoint {
            let u = 1 - t
            let x = u * u * p0.x + 2 * u * t * c.x + t * t * p1.x
            let y = u * u * p0.y + 2 * u * t * c.y + t * t * p1.y
            return CGPoint(x: x, y: y)
        }

        private func cubicPoint(
            _ p0: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ p1: CGPoint, t: CGFloat
        ) -> CGPoint {
            let u = 1 - t
            let uu = u * u
            let tt = t * t
            let x = u * uu * p0.x + 3 * uu * t * c1.x + 3 * u * tt * c2.x + tt * t * p1.x
            let y = u * uu * p0.y + 3 * uu * t * c1.y + 3 * u * tt * c2.y + tt * t * p1.y
            return CGPoint(x: x, y: y)
        }
    }

    private func matches(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.01 && abs(a.minY - b.minY) < 0.01
            && abs(a.width - b.width) < 0.01 && abs(a.height - b.height) < 0.01
    }

    private func near(_ a: CGPoint, _ b: CGPoint) -> Bool {
        abs(a.x - b.x) < 0.01 && abs(a.y - b.y) < 0.01
    }
}
