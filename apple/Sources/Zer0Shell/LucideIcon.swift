import SwiftUI

/// One icon from the licensed set.
///
/// Lucide is the shell's one icon set (ADR-0116): ISC-licensed — the license
/// is vendored at `design/lucide/LICENSE` — and stroke-drawn on a 24pt grid.
/// Like ``Zer0Mark``, the drawing is a `Path` ported from the SVG rather than
/// a bundled asset: a stroked path takes the colour of whatever draws it,
/// stays sharp at any size, and there is no resource that can fail to load.
///
/// **Drawn through ``LucideGlyph``, never directly.** The set's signature is
/// its stroke — 2 of the grid, round caps, round joins — and this `Shape`
/// used bare would render a filled silhouette that stopped reading as the
/// set. The glyph is the one door; the type is still a `Shape`, rather than
/// hiding one inside the view, so the suite can put its geometry to the
/// question the same way it does the mark's.
///
/// **A case lands with the consumer that needs it.** There is no stockpile:
/// an icon vendored ahead of a call site is geometry nobody has looked at,
/// and `LucideIconTests` refuses it until it carries vouched numbers.
enum LucideIcon: CaseIterable {
    /// The page's own search: a lens with a handle. `FindBar`'s leading glyph.
    case search
    case chevronUp
    case chevronDown
    case check
    case x

    /// The grid every icon in the set is drawn on. All coordinates in
    /// ``drawing`` are in these units, so each port reads side by side with
    /// the SVG file it came from.
    static let viewBox = CGSize(width: 24, height: 24)

    /// The set's stroke as a fraction of its grid: 2 of 24.
    ///
    /// Kept as a fraction so the weight the set was drawn with survives at
    /// every side, which is one rule instead of one number per size — and at
    /// a side of 24 it is exactly `Design.Stroke.insertion`, the match with
    /// the design system ADR-0116 licensed the set on.
    static let strokeToGrid: CGFloat = 2.0 / 24.0

    /// The drawing, in viewBox units, exactly as the SVG's shape elements
    /// write it (each is quoted beside the code it became). The circle the
    /// set names by centre and radius becomes the rect that circumscribes it.
    var drawing: Path {
        var path = Path()
        switch self {
        case .search:
            // <circle cx="11" cy="11" r="8"/>
            path.addEllipse(in: CGRect(x: 3, y: 3, width: 16, height: 16))
            // <path d="m21 21-4.3-4.3"/>
            path.move(to: CGPoint(x: 21, y: 21))
            path.addLine(to: CGPoint(x: 16.7, y: 16.7))

        case .chevronUp:
            // <path d="m18 15-6-6-6 6"/>
            path.move(to: CGPoint(x: 18, y: 15))
            path.addLine(to: CGPoint(x: 12, y: 9))
            path.addLine(to: CGPoint(x: 6, y: 15))

        case .chevronDown:
            // <path d="m6 9 6 6 6-6"/>
            path.move(to: CGPoint(x: 6, y: 9))
            path.addLine(to: CGPoint(x: 12, y: 15))
            path.addLine(to: CGPoint(x: 18, y: 9))

        case .check:
            // <path d="M20 6 9 17l-5-5"/>
            path.move(to: CGPoint(x: 20, y: 6))
            path.addLine(to: CGPoint(x: 9, y: 17))
            path.addLine(to: CGPoint(x: 4, y: 12))

        case .x:
            // <path d="M18 6 6 18"/>
            path.move(to: CGPoint(x: 18, y: 6))
            path.addLine(to: CGPoint(x: 6, y: 18))
            // <path d="m6 6 12 12"/>
            path.move(to: CGPoint(x: 6, y: 6))
            path.addLine(to: CGPoint(x: 18, y: 18))
        }
        return path
    }

    /// Centres the viewBox in `rect` at the largest scale that fits, which is
    /// what an `<svg>` does when nobody tells it otherwise.
    ///
    /// A twin of `Zer0Mark`'s `fit(into:)`, kept private rather than shared:
    /// the two viewboxes differ and each port stays readable against its own
    /// SVG, but a change to one is a change to how an `<svg>` scales and so
    /// to the other — this comment is the rope tying them.
    private static func fit(into rect: CGRect) -> CGAffineTransform {
        let scale = min(rect.width / viewBox.width, rect.height / viewBox.height)
        return CGAffineTransform(
            translationX: rect.midX - viewBox.width * scale / 2,
            y: rect.midY - viewBox.height * scale / 2
        ).scaledBy(x: scale, y: scale)
    }
}

extension LucideIcon: Shape {
    func path(in rect: CGRect) -> Path {
        drawing.applying(Self.fit(into: rect))
    }
}

/// A licensed icon, drawn at a side the way the set draws itself.
///
/// The one door the set's signature lives behind: stroke weight, round caps
/// and round joins are decided here and nowhere else, so no call site can
/// draw the geometry in a way that stops reading as Lucide. Colour is
/// deliberately not among them — `foregroundStyle` flows through a stroke
/// exactly as it does through text, so the icon takes the rank of whatever
/// wears it.
struct LucideGlyph: View {
    let icon: LucideIcon

    /// The side of the square the icon is drawn in, in points. A picture
    /// rather than prose: it does not follow the system text size, for the
    /// same reason `Design.Glyph` sits outside the type scale.
    let side: CGFloat

    var body: some View {
        icon
            .stroke(style: StrokeStyle(
                lineWidth: side * LucideIcon.strokeToGrid,
                lineCap: .round,
                lineJoin: .round
            ))
            .frame(width: side, height: side)
    }
}
