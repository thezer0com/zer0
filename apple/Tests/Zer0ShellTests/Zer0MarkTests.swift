import Foundation
import SwiftUI
import Testing

@testable import Zer0Shell

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

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
///
/// **And the canonical master is now two colours.** The adopted artwork is a
/// purple cut zero with a white "zer" inlaid on the band — one lockup, not a
/// mark plus a wordmark — so the port carries a second path and the artwork's
/// own ink, and the tests hold those too: the inlay is geometry with a
/// placement (on the band, upper right), it is dropped exactly where the hint
/// takes over, and its colour belongs to the mark rather than to whichever
/// view drew it.
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

            // Both halves, and the arcs that make them. A port that dropped
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
            #expect(curves >= 4, "the ellipses, each at least one cubic per quarter")
        }
    }

    @Test("the port carries the supplied artwork's own frame")
    func thePortCarriesTheSuppliedFrame() throws {
        // The adopted artwork declares 170x199 — a zero taller than it is wide —
        // and its ink runs edge to edge in both directions, which the previous
        // mark's did not (170x198 centred in a 256 square). That difference is
        // the port's contract with the file: a viewBox copied wrong letterboxes
        // the mark in every frame it is ever drawn in, and nothing errors.
        #expect(Zer0Mark.viewBox == CGSize(width: 170, height: 199))

        let ink = Zer0Mark.markPath.boundingRect
        #expect(ink.width > Zer0Mark.viewBox.width * 0.9, "ink is \(ink.width) wide")
        #expect(ink.height > Zer0Mark.viewBox.height * 0.9, "ink is \(ink.height) tall")
    }

    @Test("the mark stays inside the box it is given")
    func theMarkStaysInBounds() throws {
        // The viewBox the SVGs declare. The canonical master's Bézier control
        // hull grazes about 2u past the frame the file itself declares — the
        // supplied geometry, kept verbatim — so the box they are held to has
        // that much slack. The hinted master sits well inside it.
        let declared = CGRect(origin: .zero, size: Zer0Mark.viewBox)
            .insetBy(dx: -3, dy: -3)

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
        // Both masters fill their viewBox to roughly nine tenths and beyond,
        // so a square box is filled to about that fraction on the narrow axis
        // and fully on the long one. Far looser than the real numbers on
        // purpose: this is here to catch a path that collapsed to a sliver,
        // not to freeze a curve.
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

            // Nine and three o'clock, midway through the band. Points chosen
            // to sit in the ring of both masters: the hinted ring is thicker
            // and its counter smaller, so the band they share is the overlap.
            #expect(path.contains(CGPoint(x: 23, y: centre.y), eoFill: true), "hinted: \(hinted)")
            #expect(path.contains(CGPoint(x: 146, y: centre.y), eoFill: true), "hinted: \(hinted)")
        }
    }

    /// The adopted artwork is a lockup: a purple cut zero with a white "zer"
    /// inlaid on the band at the upper right. The letters are geometry in the
    /// file — five subpaths once the `e`'s counter is counted — and the port
    /// has to carry them as a second path, because a `Shape` paints one colour
    /// and the inlay is the second one.
    @Test("the inlay is 'zer', carried on the ring's band at the upper right")
    func theInlayIsZerOnTheBand() throws {
        let detail = Zer0Mark.detailPath
        #expect(!detail.isEmpty)
        #expect(!detail.boundingRect.isEmpty)

        var subpaths = 0
        var curves = 0
        detail.forEach { element in
            switch element {
            case .move: subpaths += 1
            case .curve: curves += 1
            case .line, .quadCurve, .closeSubpath: break
            }
        }
        #expect(subpaths >= 5, "z, e and its counter, r and its tail: \(subpaths) subpaths")
        #expect(curves >= 20, "the letters are drawn, not approximated by lines")

        // Where the file puts it: the upper-right quadrant, inside the frame.
        let box = detail.boundingRect
        #expect(box.minX > Zer0Mark.viewBox.width * 0.7, "inlay starts at \(box.minX)")
        #expect(box.maxX < Zer0Mark.viewBox.width)
        #expect(box.maxY < Zer0Mark.viewBox.height * 0.45, "inlay reaches \(box.maxY)")

        // An inlay, not a companion: the middle of the lettering sits on the
        // canonical ring's band. If it drifts off the band it stops being
        // knockout detail and becomes floating text, which is a different
        // logo and not the one the file describes.
        let middle = CGPoint(x: box.midX, y: box.midY)
        #expect(Zer0Mark.markPath.contains(middle, eoFill: true))
    }

    /// The inlay cannot survive the sizes the hint exists for — three glyphs
    /// in 28 units of a 170-unit mark are five pixels of mush at 32px — so it
    /// is dropped exactly where the hinted drawing takes over. One threshold
    /// decides both, which is the point: two thresholds here would be two
    /// places for the mark to disagree with itself.
    @Test("the inlay never renders below the size that made the hint necessary")
    func theInlayDropsWhereTheHintTakesOver() throws {
        // The sidebar badge: hinted, and therefore plain.
        #expect(!Zer0Mark.detailDrawn(atSide: 16, scale: 2))
        #expect(!Zer0Mark.detailDrawn(atSide: 16, scale: 1))
        #expect(!Zer0Mark.detailDrawn(atSide: 32, scale: 1))

        // The About window: the one place the full lockup is drawn.
        #expect(Zer0Mark.detailDrawn(atSide: 32, scale: 2))
        #expect(Zer0Mark.detailDrawn(atSide: Design.Glyph.mark, scale: 1))
        #expect(Zer0Mark.detailDrawn(atSide: Design.Glyph.mark, scale: 2))
    }

    /// The artwork's purple is `#635BC9`, written in the SVG, and it lives on
    /// the mark: views reach for `Zer0Mark.artworkInk` or they have no business
    /// painting with it. A brand colour copied into a view is a brand colour
    /// the next view forgets.
    @Test("the artwork's purple is the one the SVG carries")
    func theArtworkInkIsTheSvgPurple() throws {
        #expect(Zer0Mark.artworkInkRGB == (r: 0x63, g: 0x5B, b: 0xC9))

        // And the Color built from it says the same thing when asked, so the
        // constant and the tuple cannot drift apart unnoticed.
        #if canImport(AppKit)
        let ink = try #require(NSColor(Zer0Mark.artworkInk).usingColorSpace(.sRGB))
        #expect(abs(ink.redComponent - 0x63 / 255.0) < 1 / 255.0)
        #expect(abs(ink.greenComponent - 0x5B / 255.0) < 1 / 255.0)
        #expect(abs(ink.blueComponent - 0xC9 / 255.0) < 1 / 255.0)
        #else
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(Zer0Mark.artworkInk).resolvedColor(with: UITraitCollection())
            .getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        #expect(abs(red - 0x63 / 255.0) < 1 / 255.0)
        #expect(abs(green - 0x5B / 255.0) < 1 / 255.0)
        #expect(abs(blue - 0xC9 / 255.0) < 1 / 255.0)
        #endif
    }

    /// The routing ADR-0040 asks for, in the units it asks for it in.
    ///
    /// **This is the ADR's first named regression**, word for word: somebody
    /// needs the mark somewhere new, reaches for the canonical drawing, scales
    /// it to sixteen pixels and ships a plain O. Nothing errors when that happens,
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

    @Test("the Apple port matches both SVG masters coordinate for coordinate")
    func theApplePortMatchesBothSvgMasters() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Zer0ShellTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // apple
            .deletingLastPathComponent()  // the repo root
        let logoRoot = repoRoot.appending(path: "design/logo")
        let canonical = try SVGMaster(file: logoRoot.appending(path: "zer0.svg"))
        let hinted = try SVGMaster(file: logoRoot.appending(path: "zer0-small.svg"))

        #expect(canonical.viewBox == Zer0Mark.viewBox)
        #expect(hinted.viewBox == Zer0Mark.viewBox)
        #expect(canonical.layers.count == 2)
        #expect(hinted.layers.count == 1)

        let artwork = SVGMaster.Ink(
            red: Zer0Mark.artworkInkRGB.r,
            green: Zer0Mark.artworkInkRGB.g,
            blue: Zer0Mark.artworkInkRGB.b
        )
        #expect(canonical.layers[0].ink == artwork)
        #expect(canonical.layers[1].ink == .white)
        #expect(hinted.layers[0].ink == artwork)

        #expect(canonical.layers[0].elements == SVGMaster.elements(of: Zer0Mark.markPath))
        #expect(canonical.layers[1].elements == SVGMaster.elements(of: Zer0Mark.detailPath))
        #expect(hinted.layers[0].elements == SVGMaster.elements(of: Zer0Mark.smallPath))
    }
}

private struct SVGMaster {
    struct Layer {
        let ink: Ink
        let elements: [Element]
    }

    struct Ink: Equatable {
        let red: Int
        let green: Int
        let blue: Int

        static let white = Ink(red: 255, green: 255, blue: 255)
    }

    enum Element: Equatable {
        case move(CGPoint)
        case line(CGPoint)
        case curve(end: CGPoint, control1: CGPoint, control2: CGPoint)
        case close
    }

    private enum Token {
        case command(Character)
        case number(CGFloat)
    }

    let viewBox: CGSize
    let layers: [Layer]

    init(file: URL) throws {
        let document = try XMLDocument(contentsOf: file)
        let root = try Self.require(document.rootElement(), "missing <svg> in \(file.path)")
        let viewBoxText = try Self.require(
            root.attribute(forName: "viewBox")?.stringValue,
            "missing viewBox in \(file.path)"
        )
        let viewBoxValues = try Self.numbers(in: viewBoxText)
        guard viewBoxValues.count == 4, viewBoxValues[0] == 0, viewBoxValues[1] == 0 else {
            throw Error.invalid("unsupported viewBox \(viewBoxText) in \(file.path)")
        }
        viewBox = CGSize(width: viewBoxValues[2], height: viewBoxValues[3])

        layers = try root.elements(forName: "path").map { element in
            let fill = try Self.require(
                element.attribute(forName: "fill")?.stringValue,
                "missing path fill in \(file.path)"
            )
            let data = try Self.require(
                element.attribute(forName: "d")?.stringValue,
                "missing path data in \(file.path)"
            )
            return Layer(ink: try Self.ink(fill), elements: try Self.pathElements(data))
        }
        guard !layers.isEmpty else {
            throw Error.invalid("no path layers in \(file.path)")
        }
    }

    static func elements(of path: Path) -> [Element] {
        var result: [Element] = []
        var subpathStart: CGPoint?
        var currentPoint: CGPoint?
        path.forEach { element in
            switch element {
            case .move(to: let point):
                result.append(.move(point))
                subpathStart = point
                currentPoint = point
            case .line(to: let point):
                result.append(.line(point))
                currentPoint = point
            case .curve(to: let end, control1: let control1, control2: let control2):
                result.append(.curve(end: end, control1: control1, control2: control2))
                currentPoint = end
            case .quadCurve:
                Issue.record("the SVG masters contain no quadratic curves")
            case .closeSubpath:
                if let subpathStart, currentPoint != subpathStart {
                    result.append(.line(subpathStart))
                }
                result.append(.close)
                currentPoint = subpathStart
            }
        }
        return result
    }

    private static func pathElements(_ data: String) throws -> [Element] {
        let tokens = try tokens(in: data)
        var index = 0
        var path = Path()

        while index < tokens.count {
            let command = try command(at: &index, in: tokens)
            switch command {
            case "M":
                path.move(to: try point(at: &index, in: tokens))
            case "L":
                path.addLine(to: try point(at: &index, in: tokens))
            case "C":
                let control1 = try point(at: &index, in: tokens)
                let control2 = try point(at: &index, in: tokens)
                let end = try point(at: &index, in: tokens)
                path.addCurve(to: end, control1: control1, control2: control2)
            case "A":
                let radii = try point(at: &index, in: tokens)
                let rotation = try number(at: &index, in: tokens)
                let largeArc = try flag(at: &index, in: tokens)
                let sweep = try flag(at: &index, in: tokens)
                let end = try point(at: &index, in: tokens)
                guard rotation == 0 else {
                    throw Error.invalid("rotated arcs are not part of the mark contract")
                }
                path.addSVGArc(
                    to: end,
                    radii: CGSize(width: radii.x, height: radii.y),
                    largeArc: largeArc,
                    sweep: sweep
                )
            case "Z":
                path.closeSubpath()
            default:
                throw Error.invalid("unsupported SVG path command \(command)")
            }
        }
        return elements(of: path)
    }

    private static func tokens(in data: String) throws -> [Token] {
        let pattern = #"[MLCAZ]|-?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(data.startIndex ..< data.endIndex, in: data)
        let matches = regex.matches(in: data, range: range)
        var tokens: [Token] = []
        var consumed = data

        for match in matches.reversed() {
            guard let tokenRange = Range(match.range, in: data) else { continue }
            let value = String(data[tokenRange])
            if value.count == 1, let command = value.first, command.isLetter {
                tokens.append(.command(command))
            } else if let number = Double(value) {
                tokens.append(.number(CGFloat(number)))
            } else {
                throw Error.invalid("invalid SVG path token \(value)")
            }
            if let consumedRange = Range(match.range, in: consumed) {
                consumed.replaceSubrange(consumedRange, with: "")
            }
        }
        guard consumed.allSatisfy({ $0.isWhitespace || $0 == "," }) else {
            throw Error.invalid("unsupported SVG path syntax \(consumed)")
        }
        return tokens.reversed()
    }

    private static func numbers(in value: String) throws -> [CGFloat] {
        try tokens(in: value).map { token in
            guard case .number(let number) = token else {
                throw Error.invalid("expected numbers in \(value)")
            }
            return number
        }
    }

    private static func command(at index: inout Int, in tokens: [Token]) throws -> Character {
        guard index < tokens.count, case .command(let value) = tokens[index] else {
            throw Error.invalid("expected SVG path command at token \(index)")
        }
        index += 1
        return value
    }

    private static func number(at index: inout Int, in tokens: [Token]) throws -> CGFloat {
        guard index < tokens.count, case .number(let value) = tokens[index] else {
            throw Error.invalid("expected SVG path number at token \(index)")
        }
        index += 1
        return value
    }

    private static func point(at index: inout Int, in tokens: [Token]) throws -> CGPoint {
        CGPoint(x: try number(at: &index, in: tokens), y: try number(at: &index, in: tokens))
    }

    private static func flag(at index: inout Int, in tokens: [Token]) throws -> Bool {
        let value = try number(at: &index, in: tokens)
        guard value == 0 || value == 1 else {
            throw Error.invalid("SVG arc flag must be 0 or 1, got \(value)")
        }
        return value == 1
    }

    private static func ink(_ value: String) throws -> Ink {
        if value.lowercased() == "white" { return .white }
        guard value.count == 7, value.first == "#",
              let red = Int(value.dropFirst().prefix(2), radix: 16),
              let green = Int(value.dropFirst(3).prefix(2), radix: 16),
              let blue = Int(value.dropFirst(5).prefix(2), radix: 16)
        else {
            throw Error.invalid("unsupported SVG fill \(value)")
        }
        return Ink(red: red, green: green, blue: blue)
    }

    private static func require<Value>(_ value: Value?, _ message: String) throws -> Value {
        guard let value else { throw Error.invalid(message) }
        return value
    }

    private enum Error: Swift.Error {
        case invalid(String)
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

    // The engine lines below run the same function the About window runs
    // (ADR-0124). Provenance is the decision under test: "embedded" and
    // "system" name different engines rendering the same pages, so a line
    // that swaps them is a bug report filed against the wrong engine.

    @Test("an embedded engine is named as the bundle's own")
    func embeddedEngineIsNamedAsTheBundlesOwn() {
        #expect(AboutView.engineLine(embedded: true, version: "7624.4.5.14.1")
            == "Engine: embedded WebKit 7624.4.5.14.1")
    }

    @Test("with nothing embedded the system engine is named as the system's")
    func systemEngineIsNamedAsTheSystems() {
        #expect(AboutView.engineLine(embedded: false, version: "21624.4.5.11.5")
            == "Engine: system WebKit 21624.4.5.11.5")
    }

    @Test("an engine version nobody can read is omitted, not invented")
    func unreadableEngineVersionIsOmittedNotInvented() {
        #expect(AboutView.engineLine(embedded: true, version: nil)
            == "Engine: embedded WebKit")
        #expect(AboutView.engineLine(embedded: false, version: nil)
            == "Engine: system WebKit")
        #expect(AboutView.engineLine(embedded: true, version: "")
            == "Engine: embedded WebKit")
    }
}
