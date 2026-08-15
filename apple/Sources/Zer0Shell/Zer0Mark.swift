import SwiftUI

/// The zer0 mark, as geometry.
///
/// Ported from `design/logo/zer0.svg`, which stays the source of truth: a zero
/// cut on the diagonal, its two halves slipped along the cut like a geological
/// fault. It is a `Shape` rather than a bundled asset for the same reasons the
/// SVG carries no `<text>` and no `stroke` — a path takes the colour of
/// whatever draws it, stays sharp at any size, and there is no resource that
/// can fail to load.
///
/// **There are two drawings, not one.** Below 32 rendered pixels the canonical
/// cut closes under antialiasing and the mark ships as a plain O, so
/// `design/logo/zer0-small.svg` takes over — a redraw and not a scale (ADR-0040).
/// Which one to use is a question about pixels, so it is answered by
/// ``Zer0MarkGlyph`` and not here; reaching for this `Shape` directly at a small
/// size is the regression that ADR names first.
struct Zer0Mark: Shape {
    /// Draw the hinted master instead of the canonical one.
    ///
    /// Not a "small" flag with a threshold of its own: the threshold is
    /// ``hintMaxPixels`` and the decision is ``hinted(atSide:scale:)``.
    var hinted = false

    /// The SVG's `viewBox`. Every coordinate below is in these units so the
    /// port can be read side by side with the file it came from.
    static let viewBox = CGSize(width: 256, height: 256)

    /// At and below this many **rendered pixels**, the hinted drawing is used.
    ///
    /// Pixels rather than points, because the question is how many pixels the
    /// cut has to live in: 16pt@2x and 32pt@1x are both 32 pixels and both get
    /// the redraw, while 32pt@2x is 64 and gets the canonical mark. The same
    /// number `apple/scripts/make-icon.sh` routes the icon set by, and it is 32
    /// rather than 24 because at 32 the canonical cut survives only as a
    /// disturbance in the antialiasing — present, not legible, which is the
    /// worse failure because it looks deliberate.
    static let hintMaxPixels: CGFloat = 32

    /// Whether a mark this many points across, on a display of this scale, gets
    /// the hinted drawing.
    ///
    /// Separate from the view so it can be asked without one. A sidebar badge is
    /// 16pt, which is exactly the case ADR-0040 is about, and a routing rule
    /// that only exists inside a `body` is a rule no test can put a question to.
    static func hinted(atSide side: CGFloat, scale: CGFloat) -> Bool {
        side * scale <= hintMaxPixels
    }

    func path(in rect: CGRect) -> Path {
        (hinted ? Self.smallPath : Self.markPath).applying(Self.fit(into: rect))
    }

    /// The two halves, in viewBox units, exactly as the `d` attribute writes
    /// them. Built once: the geometry never changes, only where it is drawn.
    ///
    /// The SVG asks for `fill-rule="evenodd"`, and the default non-zero rule
    /// paints these identically: neither half overlaps the other, and each is
    /// a simple closed loop — outer arc one way round, inner arc back the
    /// other.
    static let markPath: Path = {
        var path = Path()

        // The lower-right half.
        path.move(to: CGPoint(x: 73.98, y: 190.33))
        path.addLine(to: CGPoint(x: 96.84, y: 167.48))
        path.addSVGArc(to: CGPoint(x: 176.03, y: 88.29), radii: inner, largeArc: false, sweep: false)
        path.addLine(to: CGPoint(x: 200.33, y: 63.98))
        path.addSVGArc(to: CGPoint(x: 73.98, y: 190.33), radii: outer, largeArc: false, sweep: true)
        path.closeSubpath()

        // The upper-left half, slipped the other way along the same cut.
        path.move(to: CGPoint(x: 55.67, y: 186.02))
        path.addLine(to: CGPoint(x: 79.97, y: 161.71))
        path.addSVGArc(to: CGPoint(x: 159.16, y: 82.52), radii: inner, largeArc: false, sweep: true)
        path.addLine(to: CGPoint(x: 182.02, y: 59.67))
        path.addSVGArc(to: CGPoint(x: 55.67, y: 186.02), radii: outer, largeArc: false, sweep: false)
        path.closeSubpath()

        return path
    }()

    /// The same idea, redrawn for the sizes the canonical drawing cannot carry.
    ///
    /// Ported from `design/logo/zer0-small.svg`, whose header carries the
    /// measurements: the ring goes 32u→44u, the gap 16u→22u and the slip
    /// 14u→20u — all three by the same ~1.375 — and the mark is *shortened*
    /// 80×104→72×94, because the grid scales by the tallest dimension and the
    /// height given up buys thickness everywhere else.
    ///
    /// **Not a cleaned-up version of `markPath`.** It is a second drawing of one
    /// idea, and the two have to stay in agreement by hand; a change to the mark
    /// carried across only one of them is how an icon set rots (ADR-0040).
    ///
    /// The `d` attribute writes each half as arc–line–arc and lets `Z` draw the
    /// fourth side, which is why there is one line here where `markPath` has two.
    static let smallPath: Path = {
        var path = Path()

        // The lower-left half.
        path.move(to: CGPoint(x: 200.01, y: 71.55))
        path.addSVGArc(
            to: CGPoint(x: 85.69, y: 185.87), radii: smallOuter, largeArc: false, sweep: true
        )
        path.addLine(to: CGPoint(x: 118.42, y: 153.14))
        path.addSVGArc(
            to: CGPoint(x: 167.28, y: 104.28), radii: smallInner, largeArc: false, sweep: false
        )
        path.closeSubpath()

        // The upper-right half, slipped the other way along the same cut.
        path.move(to: CGPoint(x: 55.99, y: 184.45))
        path.addSVGArc(
            to: CGPoint(x: 170.31, y: 70.13), radii: smallOuter, largeArc: false, sweep: true
        )
        path.addLine(to: CGPoint(x: 137.58, y: 102.86))
        path.addSVGArc(
            to: CGPoint(x: 88.72, y: 151.72), radii: smallInner, largeArc: false, sweep: false
        )
        path.closeSubpath()

        return path
    }()

    /// The ring's two ellipses, as radii, the way the `A` commands write them.
    private static let outer = CGSize(width: 80, height: 104)
    private static let inner = CGSize(width: 48, height: 72)
    /// And the hinted drawing's: a thicker ring around a counter kept large on
    /// purpose, because a zero that loses its counter is a dot.
    private static let smallOuter = CGSize(width: 72, height: 94)
    private static let smallInner = CGSize(width: 28, height: 50)

    /// Centres the viewBox in `rect` at the largest scale that fits, which is
    /// what an `<svg>` does when nobody tells it otherwise.
    private static func fit(into rect: CGRect) -> CGAffineTransform {
        let scale = min(rect.width / viewBox.width, rect.height / viewBox.height)
        return CGAffineTransform(
            translationX: rect.midX - viewBox.width * scale / 2,
            y: rect.midY - viewBox.height * scale / 2
        ).scaledBy(x: scale, y: scale)
    }
}

/// The mark at a size, drawn from whichever master that size can carry.
///
/// **The one door, and it exists because the alternative already has a name.**
/// ADR-0040's first named regression is somebody needing the mark somewhere new,
/// reaching for the canonical drawing, scaling it to 16 pixels and shipping a
/// plain O — "nothing errors, it just quietly stops being our logo in the one
/// place people see it most". A sidebar badge is 16pt, which is 32 rendered
/// pixels on a Retina display and 16 on anything else, so it is exactly that
/// case.
///
/// The threshold is in pixels, and the display scale is only knowable from the
/// environment, which is why this is a `View` and the `Shape` alone is not
/// enough to be safe with.
struct Zer0MarkGlyph: View {
    /// The side of the square the mark is drawn in, in points.
    let side: CGFloat

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Zer0Mark(hinted: Zer0Mark.hinted(atSide: side, scale: displayScale))
            .frame(width: side, height: side)
    }
}

extension Path {
    /// Appends `A rx ry 0 largeArc sweep x y` — one SVG elliptical arc.
    ///
    /// SVG names an arc by where it ends; a curve needs a centre and two
    /// angles. This is the endpoint-to-centre conversion from the SVG spec
    /// (F.6.5), with the x-axis rotation left out because the mark has none.
    ///
    /// The arc is then emitted as cubic Béziers instead of being handed to
    /// `addArc`, whose `clockwise` flag reads backwards between a y-up and a
    /// y-down space. Béziers carry their direction in the points themselves,
    /// so there is nothing left to get the wrong way round.
    mutating func addSVGArc(to end: CGPoint, radii: CGSize, largeArc: Bool, sweep: Bool) {
        guard let start = currentPoint, radii.width > 0, radii.height > 0 else {
            // A degenerate radius is a straight line, per the spec — not a
            // silently dropped segment that would leave the outline open.
            addLine(to: end)
            return
        }
        // An arc that ends where it starts draws nothing at all.
        guard start != end else { return }

        let half = CGPoint(x: (start.x - end.x) / 2, y: (start.y - end.y) / 2)

        // Radii too small to span the chord are grown until they just reach it.
        let span = half.x * half.x / (radii.width * radii.width)
            + half.y * half.y / (radii.height * radii.height)
        let correction = span > 1 ? span.squareRoot() : 1
        let rx = radii.width * correction
        let ry = radii.height * correction

        let denominator = rx * rx * half.y * half.y + ry * ry * half.x * half.x
        let numerator = max(0, rx * rx * ry * ry - denominator)
        let offset = (denominator > 0 ? (numerator / denominator).squareRoot() : 0)
            * (largeArc == sweep ? -1 : 1)

        let center = CGPoint(
            x: offset * rx * half.y / ry + (start.x + end.x) / 2,
            y: -offset * ry * half.x / rx + (start.y + end.y) / 2
        )

        func place(_ unit: CGPoint) -> CGPoint {
            CGPoint(x: center.x + unit.x * rx, y: center.y + unit.y * ry)
        }

        let startAngle = atan2((start.y - center.y) / ry, (start.x - center.x) / rx)
        let endAngle = atan2((end.y - center.y) / ry, (end.x - center.x) / rx)
        var swept = endAngle - startAngle
        if sweep, swept < 0 { swept += 2 * .pi }
        if !sweep, swept > 0 { swept -= 2 * .pi }

        // A cubic tracks a circular arc to within a rounding error up to a
        // quarter turn and visibly wanders past it, so the sweep is split.
        let segments = max(1, Int((abs(swept) / (.pi / 2)).rounded(.up)))
        let step = swept / Double(segments)
        // The control-point length that makes a cubic match a unit arc of
        // `step` radians.
        let handle = 4.0 / 3.0 * tan(step / 4)

        var angle = startAngle
        for _ in 0 ..< segments {
            let next = angle + step
            let from = CGPoint(x: cos(angle), y: sin(angle))
            let to = CGPoint(x: cos(next), y: sin(next))

            addCurve(
                to: place(to),
                // The tangent at each end, scaled by `handle`: rotating a unit
                // vector a quarter turn is (x, y) -> (-y, x).
                control1: place(CGPoint(x: from.x - handle * from.y, y: from.y + handle * from.x)),
                control2: place(CGPoint(x: to.x + handle * to.y, y: to.y - handle * to.x))
            )
            angle = next
        }
    }
}
