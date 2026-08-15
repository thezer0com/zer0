import SwiftUI
import Testing

@testable import Zer0Shell

/// A `Path` that comes out wrong renders as nothing at all — no crash, no
/// warning, just a screen that quietly lost its logo. Nobody notices until
/// someone opens the app, which is exactly the kind of failure a test is for.
///
/// These check the port against the geometry `design/logo/zer0.svg` and
/// `design/logo/zer0-small.svg` document in their headers, not against a pixel.
///
/// **Both masters, every time.** ADR-0040 ships two drawings of one idea, and
/// they have to stay in agreement by hand; a suite that only ever asked about
/// the canonical one would let the hinted drawing rot silently, which is the
/// exact failure the ADR names as the cost of having two.
struct Zer0MarkTests {
    /// A square is the shape the mark is actually drawn in; the others are
    /// here because a `Shape` is handed whatever rect the layout gives it.
    private let boxes = [
        CGRect(x: 0, y: 0, width: 256, height: 256),
        CGRect(x: 0, y: 0, width: Design.Glyph.mark, height: Design.Glyph.mark),
        CGRect(x: 10, y: 20, width: 200, height: 100),
        CGRect(x: -40, y: 7, width: 30, height: 180),
        CGRect(x: 0, y: 0, width: 1, height: 1),
    ]

    /// The canonical drawing and the hinted one, by the flag that picks them.
    private let masters = [false, true]

    private func path(hinted: Bool) -> Path {
        hinted ? Zer0Mark.smallPath : Zer0Mark.markPath
    }

    @Test("the mark is a drawing, not an empty path")
    func theMarkHasGeometry() throws {
        for hinted in masters {
            let path = path(hinted: hinted)

            #expect(!path.isEmpty, "hinted: \(hinted)")
            #expect(
                !path.boundingRect.isEmpty,
                "an empty box means nothing would be painted (hinted: \(hinted))"
            )

            // Both halves, and the four arcs that make them. A port that dropped
            // one subpath still draws something, so counting is what catches it.
            var subpaths = 0
            var curves = 0
            path.forEach { element in
                switch element {
                case .move: subpaths += 1
                case .curve: curves += 1
                case .line, .quadCurve, .closeSubpath: break
                }
            }
            #expect(
                subpaths == 2,
                "the mark is two halves slipped along a cut, not one shape (hinted: \(hinted))"
            )
            #expect(curves >= 4, "four elliptical arcs, each at least one cubic")
        }
    }

    @Test("the mark stays inside the box it is given")
    func theMarkStaysInBounds() throws {
        // The viewBox the SVGs declare. Nothing may leak outside it, or the
        // mark would clip against whatever sits next to it.
        let declared = CGRect(origin: .zero, size: Zer0Mark.viewBox)

        for hinted in masters {
            #expect(declared.contains(path(hinted: hinted).boundingRect), "hinted: \(hinted)")

            for box in boxes {
                let drawn = Zer0Mark(hinted: hinted).path(in: box).boundingRect
                #expect(
                    box.insetBy(dx: -0.01, dy: -0.01).contains(drawn),
                    "drawn at \(drawn), which escapes \(box) (hinted: \(hinted))"
                )
            }
        }
    }

    @Test("the mark fills the box rather than hiding in a corner of it")
    func theMarkFillsItsBox() throws {
        // The canonical ink is 170x198 of a 256 viewBox and the hinted one is
        // shorter and narrower, so a square box is filled to roughly three
        // quarters on the short axis and four fifths on the long one. Far looser
        // than the real numbers on purpose: this is here to catch a path that
        // collapsed to a sliver, not to freeze a curve.
        for hinted in masters {
            for box in boxes {
                let drawn = Zer0Mark(hinted: hinted).path(in: box).boundingRect
                let fit = min(box.width, box.height)
                #expect(drawn.height > fit * 0.6, "only \(drawn.height) tall in \(box)")
                #expect(drawn.width > fit * 0.5, "only \(drawn.width) wide in \(box)")

                // Centred, the way an `<svg>` centres its viewBox by default.
                #expect(abs(drawn.midX - box.midX) < fit * 0.05, "hinted: \(hinted)")
                #expect(abs(drawn.midY - box.midY) < fit * 0.05, "hinted: \(hinted)")
            }
        }
    }

    @Test("it is a zero: there is a hole in the middle and a ring around it")
    func theMarkIsARing() throws {
        let centre = CGPoint(x: Zer0Mark.viewBox.width / 2, y: Zer0Mark.viewBox.height / 2)

        for hinted in masters {
            let path = path(hinted: hinted)
            #expect(
                !path.contains(centre, eoFill: true),
                "the counter filled in, so this is a blob (hinted: \(hinted))"
            )

            // Left and right of the counter, between the two ellipses. The
            // hinted ring is thicker and its counter smaller, so a point that
            // sits in the canonical ring sits in that one too.
            #expect(path.contains(CGPoint(x: 60, y: centre.y), eoFill: true), "hinted: \(hinted)")
            #expect(path.contains(CGPoint(x: 196, y: centre.y), eoFill: true), "hinted: \(hinted)")
        }
    }

    /// The routing ADR-0040 asks for, in the units it asks for it in.
    ///
    /// **This is the ADR's first named regression**, word for word: somebody
    /// needs the mark somewhere new, reaches for the canonical drawing, scales it
    /// to sixteen pixels and ships a plain O. Nothing errors when that happens,
    /// so this is the only thing that would say so.
    ///
    /// Points would be the wrong unit and the wrong test: a 16pt badge is 32
    /// pixels on a Retina display and 16 on anything else, and both are the
    /// hinted drawing, while a 32pt mark at 2x is 64 pixels and is not.
    @Test("the sizes the cut cannot survive get the drawing that was made for them")
    func theSmallSizesGetTheirOwnDrawing() throws {
        // The sidebar badge, which is what this rule exists for.
        #expect(Zer0Mark.hinted(atSide: 16, scale: 2))
        #expect(Zer0Mark.hinted(atSide: 16, scale: 1))
        // 32pt at 1x is 32 pixels: the same case wearing different numbers.
        #expect(Zer0Mark.hinted(atSide: 32, scale: 1))

        // And where the canonical drawing starts winning.
        #expect(!Zer0Mark.hinted(atSide: 32, scale: 2))
        #expect(!Zer0Mark.hinted(atSide: Design.Glyph.mark, scale: 1))
        #expect(!Zer0Mark.hinted(atSide: Design.Glyph.mark, scale: 2))
    }
}

/// The About window says which build you are looking at. Running out of
/// SwiftPM there is no bundle to read, and inventing a version there would be
/// worse than admitting it.
@MainActor
struct AboutVersionTests {
    @Test("a bundled build names its version and its build number")
    func bundledBuild() {
        let line = AboutView.versionLine(from: [
            "CFBundleShortVersionString": "0.1.0",
            "CFBundleVersion": "1",
        ])
        #expect(line == "Version 0.1.0 (1)")
    }

    @Test("without a build number the version stands alone")
    func noBuildNumber() {
        #expect(AboutView.versionLine(from: ["CFBundleShortVersionString": "0.2.0"])
            == "Version 0.2.0")
        #expect(AboutView.versionLine(from: [
            "CFBundleShortVersionString": "0.2.0",
            "CFBundleVersion": "",
        ]) == "Version 0.2.0")
    }

    @Test("with no bundle at all it says so rather than making a number up")
    func noBundle() {
        #expect(AboutView.versionLine(from: nil) == "Development build")
        #expect(AboutView.versionLine(from: [:]) == "Development build")
        #expect(AboutView.versionLine(from: ["CFBundleShortVersionString": ""])
            == "Development build")
    }
}
