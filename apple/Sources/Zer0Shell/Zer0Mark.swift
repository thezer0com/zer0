import SwiftUI

/// The zer0 mark, as geometry.
///
/// Ported from `design/logo/zer0.svg`, which stays the source of truth: a
/// purple zero cut on the diagonal, its two halves slipped along the cut like
/// a geological fault, with a white "zer" inlaid on the band at the upper
/// right — one lockup that reads *zer0*, not a mark with a wordmark beside it.
/// It is geometry rather than a bundled asset for the same reasons the SVG
/// carries no `<text>` and no `stroke` — a path stays sharp at any size, and
/// there is no resource that can fail to load.
///
/// This `Shape` is the **ring** — the purple path, which is also the whole
/// mark wherever one ink is wanted: an inlay in a single-colour band is
/// invisible by construction, so the quiet renderings (empty states, anything
/// `foregroundStyle` drives) draw this and are done. The two-colour lockup is
/// ``Zer0MarkGlyph``'s to compose, because a `Shape` paints one colour and
/// the artwork is two.
///
/// **There are two drawings, not one.** Below 32 rendered pixels the canonical
/// cut closes under antialiasing and the inlay is five pixels of mush, so
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
    ///
    /// The adopted artwork is taller than it is wide, and its ink runs edge
    /// to edge of the frame — the supplied curves' control hull even grazes
    /// ~2u past it — so a square frame letterboxes the mark on the width.
    static let viewBox = CGSize(width: 170, height: 199)

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

    /// Whether the canonical drawing's white inlay is drawn at this size.
    ///
    /// The inlay is 28 units wide on a 170-unit mark: three glyphs in five
    /// pixels at 32px, two and a half at 16. There is no hinting that rescues
    /// that, so where the hint takes over the inlay is dropped — which means
    /// one threshold decides both, and that is the point: two thresholds here
    /// would be two places for the mark to disagree with itself.
    static func detailDrawn(atSide side: CGFloat, scale: CGFloat) -> Bool {
        !hinted(atSide: side, scale: scale)
    }

    func path(in rect: CGRect) -> Path {
        (hinted ? Self.smallPath : Self.markPath).applying(Self.fit(into: rect))
    }

    /// The canonical ring, in viewBox units, exactly as the `d` attribute
    /// writes it: two halves, each a run of cubic Béziers along the inner
    /// boundary, a line out across the band, and a run back along the outer
    /// one. Built once: the geometry never changes, only where it is drawn.
    ///
    /// The SVG asks for `fill-rule="evenodd"`; the default non-zero rule
    /// paints these identically, because neither half overlaps the other and
    /// each is a simple closed loop.
    static let markPath: Path = {
        var path = Path()

        // The lower-right half.
        path.move(to: CGPoint(x: 30.9405, y: 164.396))
        path.addLine(to: CGPoint(x: 53.8005, y: 141.546))
        path.addCurve(to: CGPoint(x: 83.6042, y: 165.488), control1: CGPoint(x: 61.4706, y: 154.684), control2: CGPoint(x: 72.0627, y: 163.193))
        path.addCurve(to: CGPoint(x: 116.537, y: 154.019), control1: CGPoint(x: 95.1457, y: 167.782), control2: CGPoint(x: 106.85, y: 163.707))
        path.addCurve(to: CGPoint(x: 136.261, y: 112.831), control1: CGPoint(x: 126.224, y: 144.332), control2: CGPoint(x: 133.234, y: 129.694))
        path.addCurve(to: CGPoint(x: 132.99, y: 62.3561), control1: CGPoint(x: 139.288, y: 95.968), control2: CGPoint(x: 138.125, y: 78.0294))
        path.addLine(to: CGPoint(x: 157.29, y: 38.0461))
        path.addCurve(to: CGPoint(x: 168.73, y: 112.009), control1: CGPoint(x: 168.09, y: 59.9701), control2: CGPoint(x: 172.172, y: 86.3625))
        path.addCurve(to: CGPoint(x: 138.698, y: 176.565), control1: CGPoint(x: 165.287, y: 137.656), control2: CGPoint(x: 154.571, y: 160.691))
        path.addCurve(to: CGPoint(x: 82.9974, y: 197.742), control1: CGPoint(x: 122.824, y: 192.438), control2: CGPoint(x: 102.949, y: 199.995))
        path.addCurve(to: CGPoint(x: 30.9405, y: 164.396), control1: CGPoint(x: 63.0462, y: 195.489), control2: CGPoint(x: 44.4706, y: 183.59))
        path.closeSubpath()

        // The upper-left half, slipped the other way along the same cut.
        path.move(to: CGPoint(x: 12.6305, y: 160.086))
        path.addLine(to: CGPoint(x: 36.9305, y: 135.776))
        path.addCurve(to: CGPoint(x: 33.6603, y: 85.3011), control1: CGPoint(x: 31.7956, y: 120.103), control2: CGPoint(x: 30.6333, y: 102.164))
        path.addCurve(to: CGPoint(x: 53.384, y: 44.1127), control1: CGPoint(x: 36.6872, y: 68.4379), control2: CGPoint(x: 43.6969, y: 53.7998))
        path.addCurve(to: CGPoint(x: 86.3167, y: 32.6446), control1: CGPoint(x: 63.0711, y: 34.4256), control2: CGPoint(x: 74.7752, y: 30.3499))
        path.addCurve(to: CGPoint(x: 116.12, y: 56.5861), control1: CGPoint(x: 97.8582, y: 34.9393), control2: CGPoint(x: 108.45, y: 43.448))
        path.addLine(to: CGPoint(x: 138.98, y: 33.7361))
        path.addCurve(to: CGPoint(x: 86.9236, y: 0.390393), control1: CGPoint(x: 125.45, y: 14.5423), control2: CGPoint(x: 106.875, y: 2.64343))
        path.addCurve(to: CGPoint(x: 31.2234, y: 21.5673), control1: CGPoint(x: 66.9724, y: -1.86265), control2: CGPoint(x: 47.0967, y: 5.69397))
        path.addCurve(to: CGPoint(x: 1.19105, y: 86.1229), control1: CGPoint(x: 15.35, y: 37.4407), control2: CGPoint(x: 4.63352, y: 60.4762))
        path.addCurve(to: CGPoint(x: 12.6305, y: 160.086), control1: CGPoint(x: -2.25142, y: 111.77), control2: CGPoint(x: 1.83054, y: 138.162))
        path.closeSubpath()

        return path
    }()

    /// The same idea, redrawn for the sizes the canonical drawing cannot carry.
    ///
    /// Ported from `design/logo/zer0-small.svg`, whose header carries the
    /// measurements: the ring goes 34u→46.75u (the ×1.375 the previous hinted
    /// master used), the gap 16u→23u, the slip 8u→11u, and the whole drawing
    /// is shortened (outer radii 85×99.5→72.25×84.55) because the adopted
    /// canonical mark fills its viewBox edge to edge and the hinted halves
    /// must fit their own translations inside the same frame. The inlay is
    /// absent on purpose — see ``detailDrawn(atSide:scale:)``.
    ///
    /// **Not a cleaned-up version of `markPath`.** It is a second drawing of one
    /// idea, and the two have to stay in agreement by hand; a change to the mark
    /// carried across only one of them is how an icon set rots (ADR-0040).
    ///
    /// The `d` attribute writes each half as arc–line–arc and lets `Z` draw the
    /// fourth side, which is why there is one line here where `markPath` has two.
    static let smallPath: Path = {
        var path = Path()

        // The lower-right half, pried toward the bottom of the cut.
        path.move(to: CGPoint(x: 151.95, y: 48.82))
        path.addSVGArc(
            to: CGPoint(x: 42.09, y: 158.67), radii: smallOuter, largeArc: false, sweep: true
        )
        path.addLine(to: CGPoint(x: 75.88, y: 124.88))
        path.addSVGArc(
            to: CGPoint(x: 118.16, y: 82.6), radii: smallInner, largeArc: false, sweep: false
        )
        path.closeSubpath()

        // The upper-left half, slipped the other way along the same cut.
        path.move(to: CGPoint(x: 18.05, y: 150.18))
        path.addSVGArc(
            to: CGPoint(x: 127.91, y: 40.33), radii: smallOuter, largeArc: false, sweep: true
        )
        path.addLine(to: CGPoint(x: 94.12, y: 74.12))
        path.addSVGArc(
            to: CGPoint(x: 51.84, y: 116.4), radii: smallInner, largeArc: false, sweep: false
        )
        path.closeSubpath()

        return path
    }()

    /// The white "zer" inlaid on the canonical ring's band, upper right —
    /// five subpaths once the `e`'s counter is counted, ported verbatim from
    /// the second `path` of `design/logo/zer0.svg`.
    ///
    /// Canonical drawing only: the hinted master carries no inlay, so this is
    /// drawn exactly where ``detailDrawn(atSide:scale:)`` says so, in white,
    /// over ``artworkInk`` — the two colours are the artwork's, not a view's.
    static let detailPath: Path = {
        var path = Path()

        // The z.
        path.move(to: CGPoint(x: 140.998, y: 67.7467))
        path.addLine(to: CGPoint(x: 145.141, y: 63.603))
        path.addLine(to: CGPoint(x: 145.997, y: 64.7698))
        path.addLine(to: CGPoint(x: 140.552, y: 70.2145))
        path.addLine(to: CGPoint(x: 139.654, y: 69.3165))
        path.addLine(to: CGPoint(x: 138.268, y: 59.6715))
        path.addLine(to: CGPoint(x: 134.464, y: 63.4758))
        path.addLine(to: CGPoint(x: 133.432, y: 62.4434))
        path.addLine(to: CGPoint(x: 138.664, y: 57.2108))
        path.addLine(to: CGPoint(x: 139.583, y: 58.13))
        path.closeSubpath()

        // The e, bowl first…
        path.move(to: CGPoint(x: 146.635, y: 57.5274))
        path.addCurve(to: CGPoint(x: 148.381, y: 58.6093), control1: CGPoint(x: 147.234, y: 58.079), control2: CGPoint(x: 147.816, y: 58.4396))
        path.addCurve(to: CGPoint(x: 149.972, y: 58.6305), control1: CGPoint(x: 148.942, y: 58.7743), control2: CGPoint(x: 149.473, y: 58.7814))
        path.addCurve(to: CGPoint(x: 151.288, y: 57.8244), control1: CGPoint(x: 150.467, y: 58.475), control2: CGPoint(x: 150.906, y: 58.2063))
        path.addCurve(to: CGPoint(x: 152.15, y: 56.6223), control1: CGPoint(x: 151.669, y: 57.4426), control2: CGPoint(x: 151.957, y: 57.0419))
        path.addCurve(to: CGPoint(x: 152.603, y: 55.1657), control1: CGPoint(x: 152.348, y: 56.1981), control2: CGPoint(x: 152.499, y: 55.7125))
        path.addLine(to: CGPoint(x: 153.946, y: 55.392))
        path.addCurve(to: CGPoint(x: 153.395, y: 57.2305), control1: CGPoint(x: 153.871, y: 56.0142), control2: CGPoint(x: 153.687, y: 56.6271))
        path.addCurve(to: CGPoint(x: 152.263, y: 58.8285), control1: CGPoint(x: 153.107, y: 57.8291), control2: CGPoint(x: 152.73, y: 58.3618))
        path.addCurve(to: CGPoint(x: 149.93, y: 60.1862), control1: CGPoint(x: 151.542, y: 59.5498), control2: CGPoint(x: 150.764, y: 60.0023))
        path.addCurve(to: CGPoint(x: 147.406, y: 59.9952), control1: CGPoint(x: 149.096, y: 60.37), control2: CGPoint(x: 148.254, y: 60.3064))
        path.addCurve(to: CGPoint(x: 144.98, y: 58.3618), control1: CGPoint(x: 146.557, y: 59.6747), control2: CGPoint(x: 145.749, y: 59.1302))
        path.addCurve(to: CGPoint(x: 143.375, y: 55.9506), control1: CGPoint(x: 144.226, y: 57.6076), control2: CGPoint(x: 143.691, y: 56.8038))
        path.addCurve(to: CGPoint(x: 143.128, y: 53.4404), control1: CGPoint(x: 143.059, y: 55.0973), control2: CGPoint(x: 142.977, y: 54.2606))
        path.addCurve(to: CGPoint(x: 144.344, y: 51.22), control1: CGPoint(x: 143.278, y: 52.6201), control2: CGPoint(x: 143.684, y: 51.88))
        path.addCurve(to: CGPoint(x: 146.409, y: 50.0462), control1: CGPoint(x: 144.971, y: 50.5931), control2: CGPoint(x: 145.659, y: 50.2018))
        path.addCurve(to: CGPoint(x: 148.707, y: 50.2654), control1: CGPoint(x: 147.153, y: 49.886), control2: CGPoint(x: 147.919, y: 49.959))
        path.addCurve(to: CGPoint(x: 151.019, y: 51.8423), control1: CGPoint(x: 149.494, y: 50.5624), control2: CGPoint(x: 150.265, y: 51.088))
        path.addCurve(to: CGPoint(x: 151.372, y: 52.21), control1: CGPoint(x: 151.146, y: 51.9696), control2: CGPoint(x: 151.264, y: 52.0921))
        path.addCurve(to: CGPoint(x: 151.641, y: 52.5211), control1: CGPoint(x: 151.476, y: 52.3231), control2: CGPoint(x: 151.566, y: 52.4268))
        path.addLine(to: CGPoint(x: 146.635, y: 57.5274))
        path.closeSubpath()

        // …and its counter, wound the other way.
        path.move(to: CGPoint(x: 145.334, y: 52.1817))
        path.addCurve(to: CGPoint(x: 144.535, y: 54.1545), control1: CGPoint(x: 144.782, y: 52.7333), control2: CGPoint(x: 144.516, y: 53.3909))
        path.addCurve(to: CGPoint(x: 145.723, y: 56.6011), control1: CGPoint(x: 144.558, y: 54.9135), control2: CGPoint(x: 144.954, y: 55.729))
        path.addLine(to: CGPoint(x: 149.605, y: 52.7191))
        path.addCurve(to: CGPoint(x: 147.285, y: 51.4463), control1: CGPoint(x: 148.794, y: 51.9366), control2: CGPoint(x: 148.021, y: 51.5123))
        path.addCurve(to: CGPoint(x: 145.334, y: 52.1817), control1: CGPoint(x: 146.545, y: 51.3756), control2: CGPoint(x: 145.895, y: 51.6207))
        path.closeSubpath()

        // The r, stem and arm…
        path.move(to: CGPoint(x: 157.554, y: 53.2125))
        path.addLine(to: CGPoint(x: 156.642, y: 52.3004))
        path.addLine(to: CGPoint(x: 157.802, y: 51.1407))
        path.addLine(to: CGPoint(x: 152.18, y: 45.5192))
        path.addLine(to: CGPoint(x: 151.02, y: 46.6789))
        path.addLine(to: CGPoint(x: 150.108, y: 45.7667))
        path.addLine(to: CGPoint(x: 152.173, y: 43.702))
        path.addLine(to: CGPoint(x: 154.153, y: 45.2434))
        path.addCurve(to: CGPoint(x: 153.778, y: 42.7756), control1: CGPoint(x: 153.828, y: 44.3431), control2: CGPoint(x: 153.703, y: 43.5205))
        path.addCurve(to: CGPoint(x: 154.903, y: 40.6472), control1: CGPoint(x: 153.854, y: 42.0308), control2: CGPoint(x: 154.228, y: 41.3214))
        path.addCurve(to: CGPoint(x: 155.504, y: 40.1452), control1: CGPoint(x: 155.11, y: 40.4398), control2: CGPoint(x: 155.31, y: 40.2725))
        path.addCurve(to: CGPoint(x: 156.119, y: 39.7563), control1: CGPoint(x: 155.697, y: 40.0085), control2: CGPoint(x: 155.902, y: 39.8789))
        path.addLine(to: CGPoint(x: 156.833, y: 41.1634))
        path.addCurve(to: CGPoint(x: 156.317, y: 41.4958), control1: CGPoint(x: 156.635, y: 41.2766), control2: CGPoint(x: 156.463, y: 41.3874))
        path.addCurve(to: CGPoint(x: 155.843, y: 41.8988), control1: CGPoint(x: 156.166, y: 41.5995), control2: CGPoint(x: 156.008, y: 41.7338))
        path.addCurve(to: CGPoint(x: 154.98, y: 43.9777), control1: CGPoint(x: 155.273, y: 42.4692), control2: CGPoint(x: 154.985, y: 43.1622))
        path.addCurve(to: CGPoint(x: 155.836, y: 46.7991), control1: CGPoint(x: 154.976, y: 44.7933), control2: CGPoint(x: 155.261, y: 45.7337))
        path.addLine(to: CGPoint(x: 158.99, y: 49.9528))
        path.addLine(to: CGPoint(x: 160.503, y: 48.4396))
        path.addLine(to: CGPoint(x: 161.415, y: 49.3517))
        path.closeSubpath()

        // …and the tail of its diagonal stroke.
        path.move(to: CGPoint(x: 157.491, y: 43.4191))
        path.addLine(to: CGPoint(x: 155.871, y: 41.7998))
        path.addLine(to: CGPoint(x: 155.093, y: 40.7816))
        path.addLine(to: CGPoint(x: 156.119, y: 39.7563))
        path.addLine(to: CGPoint(x: 158.466, y: 42.4433))
        path.closeSubpath()

        return path
    }()

    /// The hinted drawing's two ellipses, as radii, the way the `A` commands
    /// write them: a thicker ring around a counter kept large on purpose,
    /// because a zero that loses its counter is a dot.
    private static let smallOuter = CGSize(width: 72.25, height: 84.55)
    private static let smallInner = CGSize(width: 25.5, height: 37.8)

    /// The artwork's purple — `#635BC9`, as written in `design/logo/zer0.svg`.
    ///
    /// Kept as a tuple beside the `Color` so the number in the file and the
    /// ink in the shell cannot drift apart unwatched. This is brand artwork,
    /// not a UI state colour: it is reached for through the mark, and a view
    /// painting with it directly has usually stopped drawing the logo and
    /// started decorating.
    static let artworkInkRGB = (r: 0x63, g: 0x5B, b: 0xC9)

    /// The `Color` form of ``artworkInkRGB``, and the only spelling of the
    /// artwork's purple the shell carries.
    static let artworkInk = Color(
        red: Double(artworkInkRGB.r) / 255,
        green: Double(artworkInkRGB.g) / 255,
        blue: Double(artworkInkRGB.b) / 255
    )

    /// The ink the canonical drawing covers: `markPath` unioned with
    /// `detailPath`, whose bounds the supplied curves' control hull sets.
    ///
    /// The adopted mark fills its viewBox edge to edge and its hull grazes
    /// ~2u past the frame the file declares, so — like `make-icon.sh`, which
    /// faced the same question for the icon grid — the fit measures what is
    /// actually drawn rather than trusting the viewBox. Both paths of the
    /// lockup go through this one transform, which is what keeps the inlay
    /// registered on the band.
    private static let inkBounds = markPath.boundingRect.union(detailPath.boundingRect)

    /// Centres the drawn ink in `rect` at the largest scale that fits.
    static func fit(into rect: CGRect) -> CGAffineTransform {
        let scale = min(rect.width / inkBounds.width, rect.height / inkBounds.height)
        return CGAffineTransform(
            translationX: rect.midX - inkBounds.midX * scale,
            y: rect.midY - inkBounds.midY * scale
        ).scaledBy(x: scale, y: scale)
    }
}

/// The white half of the lockup: ``Zer0Mark.detailPath`` drawn as a `Shape`,
/// fitted by the same transform the ring is.
private struct Zer0MarkDetail: Shape {
    func path(in rect: CGRect) -> Path {
        Zer0Mark.detailPath.applying(Zer0Mark.fit(into: rect))
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
///
/// **Ink.** `.quiet` — the default — draws the ring bare, in whatever
/// `foregroundStyle` says: an empty state wants the mark present and quiet,
/// and one grey ring says that better than brand purple ever could. `.brand`
/// draws the artwork as the artwork: the purple ring with its white inlay
/// where the size can carry the lockup, the hinted purple ring where it
/// cannot. The colours come from ``Zer0Mark/artworkInk``; they are the logo's,
/// not the surrounding view's.
struct Zer0MarkGlyph: View {
    /// How the mark is inked.
    enum Ink: Equatable {
        /// The artwork's own two colours — or one, at sizes where the inlay
        /// cannot survive and the hinted ring stands in for the lockup.
        case brand
        /// One ink, whatever `foregroundStyle` provides: the mark as a quiet
        /// glyph, inlay omitted because a single-colour band hides it anyway.
        case quiet
    }

    /// The side of the square the mark is drawn in, in points.
    let side: CGFloat

    /// See ``Ink``. Quiet by default: the mark's day job is an empty state,
    /// and brand ink is the decision a call site makes on purpose.
    var ink: Ink = .quiet

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let hinted = Zer0Mark.hinted(atSide: side, scale: displayScale)

        return Group {
            if ink == .brand {
                if Zer0Mark.detailDrawn(atSide: side, scale: displayScale) {
                    ZStack {
                        Zer0Mark().fill(Zer0Mark.artworkInk)
                        Zer0MarkDetail().fill(.white)
                    }
                } else {
                    Zer0Mark(hinted: hinted).fill(Zer0Mark.artworkInk)
                }
            } else {
                Zer0Mark(hinted: hinted)
            }
        }
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
