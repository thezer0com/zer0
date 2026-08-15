import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Zer0Shell

/// A palette that fails contrast is not a candidate.
///
/// Every ratio quoted in the proposal write-up is recomputed here from the
/// same bytes the palette draws with, so "checked" means checked rather than
/// eyeballed — and so a hex nudged one shade during review cannot silently
/// drop a pair under the floor.
///
/// The floors are WCAG 2.1 AA: 4.5:1 for anything anyone reads, 3:1 for a
/// level that exists to be quiet and for the boundary of a control.
@Suite("palette contrast")
struct PaletteContrastTests {
    /// Text people actually read.
    private let readable = 4.5
    /// Incidental text, and the edge of a control.
    private let incidental = 3.0

    private var candidates: [Zer0Palette] {
        var all = [
            Zer0Palette.paper(dark: false), Zer0Palette.paper(dark: true),
            Zer0Palette.fault(dark: false), Zer0Palette.fault(dark: true),
        ]
        for identity in Zer0Palette.SpaceIdentity.all {
            all.append(Zer0Palette.spaces(identity, dark: false))
            all.append(Zer0Palette.spaces(identity, dark: true))
        }
        return all
    }

    @Test("body text clears AA on every surface it lands on")
    func bodyTextIsReadable() {
        for palette in candidates {
            for surface in [palette.background, palette.recessed, palette.recessedInner] {
                #expect(
                    palette.ink.contrast(against: surface) >= readable,
                    "\(palette.name): primary text \(palette.ink.hex) on \(surface.hex)"
                )
                // Secondary is prose — the line that explains what a setting
                // does — so it takes the reading floor, not the quiet one.
                #expect(
                    palette.inkSecondary.contrast(against: surface) >= readable,
                    "\(palette.name): secondary text \(palette.inkSecondary.hex) on \(surface.hex)"
                )
            }
        }
    }

    @Test("the quiet level is quiet, not invisible")
    func tertiaryClearsTheIncidentalFloor() {
        for palette in candidates {
            #expect(
                palette.inkTertiary.contrast(against: palette.background) >= incidental,
                "\(palette.name): tertiary \(palette.inkTertiary.hex)"
            )
        }
    }

    @Test("the accent reads as a control against every surface")
    func accentIsVisible() {
        for palette in candidates {
            for surface in [palette.background, palette.recessed] {
                for accent in [palette.accent, palette.accentHover, palette.accentPressed] {
                    #expect(
                        accent.contrast(against: surface) >= incidental,
                        "\(palette.name): accent \(accent.hex) on \(surface.hex)"
                    )
                }
            }
        }
    }

    @Test("a label on a filled accent survives the press state")
    func labelsOnAccentAreReadable() {
        for palette in candidates {
            for fill in [palette.accent, palette.accentHover, palette.accentPressed] {
                #expect(
                    palette.onAccent.contrast(against: fill) >= readable,
                    "\(palette.name): \(palette.onAccent.hex) on \(fill.hex)"
                )
            }
        }
    }

    @Test("a warning, a failure and a success are all readable where they are said")
    func statusColoursAreReadable() {
        for palette in candidates {
            for surface in [palette.background, palette.recessed] {
                for status in [palette.warning, palette.danger, palette.success] {
                    #expect(
                        status.contrast(against: surface) >= readable,
                        "\(palette.name): status \(status.hex) on \(surface.hex)"
                    )
                }
            }
        }
    }

    /// A Space's colour is a safety signal — it answers "which account am I
    /// about to post from". Two Spaces that look alike answer it wrongly, and
    /// a Space that looks like a warning answers a different question.
    @Test("no two Space hues, and no Space and a status colour, can be confused")
    func spaceIdentitiesStayDistinct() {
        for dark in [false, true] {
            let palettes = Zer0Palette.SpaceIdentity.all.map { Zer0Palette.spaces($0, dark: dark) }

            for (index, one) in palettes.enumerated() {
                for other in palettes[(index + 1)...] {
                    #expect(
                        distance(one.accent, other.accent) > 0.12,
                        "\(one.name) and \(other.name) are too close to tell apart"
                    )
                }
                // Nothing in the Space set may sit in the region the status
                // colours already own.
                for status in [one.warning, one.danger] {
                    #expect(
                        distance(one.accent, status) > 0.12,
                        "\(one.name) is too close to a status colour"
                    )
                }
            }
        }
    }

    /// Straight-line distance in sRGB. Crude next to a perceptual space, and
    /// deliberately so: it is a floor nobody has to trust a colour-science
    /// library to reproduce, and a pair that clears it is not a pair anyone
    /// mistakes.
    private func distance(_ a: Swatch, _ b: Swatch) -> Double {
        let dr = a.red - b.red, dg = a.green - b.green, db = a.blue - b.blue
        return (dr * dr + dg * dg + db * db).squareRoot()
    }
}

// MARK: - The one that shipped

/// The suite above asks whether a palette *could* ship. This one asks whether
/// the palette that *did* is still the one, and whether the three surfaces a
/// root `.tint()` cannot reach — the sidebar, the selected row and the status
/// colours — actually took it.
///
/// Every ratio here is recomputed from the same bytes `Design.Palette` draws
/// with. Nothing is measured off a resolved `NSColor`: a dynamic colour asked
/// for its components in a test process answers for whatever appearance that
/// process happens to be in, which is a check of nothing.
@Suite("adopted palette")
struct AdoptedPaletteTests {
    /// Text people actually read.
    private let readable = 4.5
    /// Incidental text, and the edge or state of a control (WCAG 1.4.11).
    private let incidental = 3.0

    /// Light and dark, so every claim below is made twice and neither half can
    /// pass on the other's account.
    private var halves: [(name: String, palette: Zer0Palette, chrome: Swatch,
                          selected: Swatch, companion: Swatch)] {
        [
            ("light", Design.Palette.light, Design.Palette.chromeSwatch(dark: false),
             Design.Palette.selectedRowSwatch(dark: false),
             Design.Palette.companionRowSwatch(dark: false)),
            ("dark", Design.Palette.dark, Design.Palette.chromeSwatch(dark: true),
             Design.Palette.selectedRowSwatch(dark: true),
             Design.Palette.companionRowSwatch(dark: true)),
        ]
    }

    /// ADR-0043 decided B, and a decision that can be swapped by editing one
    /// factory call is a decision worth naming here.
    @Test("the shell wears Fault")
    func theShellWearsFault() {
        #expect(Design.Palette.light.name == "Fault")
        #expect(Design.Palette.dark.name == "Fault")
        #expect(Design.Palette.light.accent == Zer0Palette.fault(dark: false).accent)
        #expect(Design.Palette.dark.accent == Zer0Palette.fault(dark: true).accent)
    }

    /// The sidebar carries all three levels of the ladder — a row title, a
    /// group heading, a hint — so its own surface has to hold all three.
    @Test("the sidebar's surface carries every level of text")
    func theSidebarSurfaceCarriesEveryLevelOfText() {
        for half in halves {
            #expect(
                half.palette.ink.contrast(against: half.chrome) >= readable,
                "\(half.name): primary on chrome \(half.chrome.hex)"
            )
            #expect(
                half.palette.inkSecondary.contrast(against: half.chrome) >= readable,
                "\(half.name): secondary on chrome \(half.chrome.hex)"
            )
            #expect(
                half.palette.inkTertiary.contrast(against: half.chrome) >= incidental,
                "\(half.name): tertiary on chrome \(half.chrome.hex)"
            )
            // The drag's insertion line and the offered-space outline are the
            // accent, drawn on this surface and nowhere else.
            #expect(
                half.palette.accent.contrast(against: half.chrome) >= incidental,
                "\(half.name): accent on chrome \(half.chrome.hex)"
            )
        }
    }

    /// Both halves of the selected row's criterion, which is the whole reason
    /// it is a stated colour rather than an opacity someone liked.
    @Test("the selected row is seen, and its label is read")
    func theSelectedRowIsSeenAndItsLabelIsRead() {
        for half in halves {
            #expect(
                half.selected.contrast(against: half.chrome) >= incidental,
                "\(half.name): selected row \(half.selected.hex) on chrome \(half.chrome.hex)"
            )
            #expect(
                half.palette.ink.contrast(against: half.selected) >= readable,
                "\(half.name): row title on selected row \(half.selected.hex)"
            )
        }
    }

    /// *"The same colour and plainly less of it."* Halfway, within a quarter of
    /// the span — loose enough that a shade may be nudged, tight enough that
    /// the companion cannot creep up on the focused row or fade into the
    /// sidebar.
    @Test("the companion row sits halfway between the sidebar and the selected row")
    func theCompanionRowSitsHalfway() {
        for half in halves {
            let span = half.chrome.luminance - half.selected.luminance
            let midpoint = half.selected.luminance + span / 2
            let drift = "\(half.name): companion \(half.companion.hex) at "
                + "\(half.companion.luminance), against a midpoint of \(midpoint)"
            #expect(abs(half.companion.luminance - midpoint) <= abs(span) / 4, "\(drift)")
            #expect(
                half.palette.ink.contrast(against: half.companion) >= readable,
                "\(half.name): row title on companion \(half.companion.hex)"
            )
        }
    }

    /// *"A border that should be seen and not noticed"* as a number.
    ///
    /// The rule exists because `Divider` takes its colour from the foreground
    /// ladder, and the palette sets that ladder at the root: measured on the
    /// same surface, a divider went from 1.15:1 to 2.7:1 the day the ink
    /// landed, and every list in the product turned into stacked bars. Nobody
    /// chose that, which is exactly why it needs a floor and a ceiling.
    @Test("a rule is a hairline, not a border")
    func aRuleIsAHairlineNotABorder() {
        for half in halves {
            let rule = Design.Palette.ruleSwatch(dark: half.name == "dark")
            for surface in [half.palette.recessed, half.chrome, half.palette.background] {
                let ratio = rule.contrast(against: surface)
                let seen = "\(half.name): rule \(rule.hex) on \(surface.hex) at \(ratio)"
                // Below 1.15 it is not there. Above 1.6 it is a border, and a
                // list of rows does not have internal borders.
                #expect(ratio >= 1.15, "\(seen)")
                #expect(ratio <= 1.6, "\(seen)")
            }
        }
    }

    /// The sidebar renders the palette's colour, and nothing outside the
    /// palette gets a say in it.
    ///
    /// **Measured, not asserted, and that is the point.** This decision has
    /// been got wrong twice by reading APIs instead of pixels. `.thinMaterial`
    /// silently sampled the desktop, so the sidebar was the colour of somebody's
    /// wallpaper. Replacing it with an `NSVisualEffectView` at `.withinWindow`
    /// over a chrome fill *looked* correct in the source and rendered `#F3F3F3`
    /// / `#353535` — the system's grey, painted straight over the fill. Only a
    /// render catches either one, so this test does a render.
    ///
    /// Cheap on purpose: 40×40, no run loop pumped, which is why it can sit
    /// with the ordinary tests instead of behind `ZER0_SHOT`.
    @Test("the sidebar draws the palette's surface and nothing else")
    @MainActor
    func theSidebarDrawsThePalettesSurface() throws {
        for half in halves {
            let dark = half.name == "dark"
            let size = CGSize(width: 40, height: 40)

            let view = Color.clear
                .chromeSurface()
                .frame(width: size.width, height: size.height)
                .preferredColorScheme(dark ? .dark : .light)

            let host = NSHostingView(rootView: AnyView(view))
            host.frame = CGRect(origin: .zero, size: size)
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

            // In a window, because that is where the old material found the
            // desktop to blur. A surface that is only correct outside one is
            // not correct.
            let window = testWindow(host.frame, styleMask: [.borderless])
            window.appearance = host.appearance
            window.contentView = host
            window.displayIfNeeded()

            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let drawn = try #require(rep.colorAt(x: 20, y: 20)?.usingColorSpace(.sRGB))

            // Compared against the palette colour put through the *same*
            // pipeline rather than against the hex, because an offscreen
            // render lands in the display's colour space and reading it back
            // as sRGB shifts every channel by a point or two. Comparing two
            // renders cancels that; comparing a render to a number would only
            // measure it.
            let reference = try draw(Design.Palette.chrome, dark: dark, size: size)
            let off = max(
                abs(Double(drawn.redComponent) - Double(reference.redComponent)),
                abs(Double(drawn.greenComponent) - Double(reference.greenComponent)),
                abs(Double(drawn.blueComponent) - Double(reference.blueComponent))
            )
            // One part in 255. The effect view this replaced missed by 4 in
            // light and by 30 in dark, so the floor is nowhere near tight.
            let diff = "\(half.name): sidebar drew \(hex(drawn)), "
                + "palette draws \(hex(reference)) (\(half.chrome.hex))"
            #expect(off <= 1.0 / 255, "\(diff)")
        }
    }

    /// A status colour is a rank, and a rank drifts the moment one of its tiers
    /// is a system hue that moves on its own.
    ///
    /// Source-scanning rather than pixel-checking because that is what the
    /// decision actually is: `Color.orange` anywhere in the shell is a tier
    /// outside the palette, whatever it renders as today.
    @Test("no view spells a status colour for itself")
    func noViewSpellsAStatusColourForItself() throws {
        // Two files are exempt, and both say why in their own headers:
        // `PaletteProposals` is the record of what was on the table, and
        // `SiteBadge` is a derived function of a hostname rather than a palette
        // (DESIGN.md §7).
        let exempt: Set<String> = ["PaletteProposals.swift", "SiteBadge.swift", "Palette.swift"]
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Zer0ShellTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // apple
            .deletingLastPathComponent()  // the repo root
            .appending(path: "apple/Sources/Zer0Shell")

        let files = try FileManager.default
            .contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && !exempt.contains($0.lastPathComponent) }
        #expect(!files.isEmpty, "found no shell sources under \(sources.path)")

        for file in files {
            let code = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")

            for hue in ["orange", "red", "green", "yellow"] {
                let spelled = "\(file.lastPathComponent) spells .\(hue) itself. "
                    + "A status colour comes from Design.Palette (ADR-0043)."
                #expect(!code.spells(hue), "\(spelled)")
            }
        }
    }

    // MARK: Machinery

    /// Draw a flat colour through the same offscreen path the surface takes, so
    /// the two can be compared without either of them going through a colour
    /// space the other did not.
    @MainActor
    private func draw(_ colour: Color, dark: Bool, size: CGSize) throws -> NSColor {
        let host = NSHostingView(
            rootView: AnyView(
                colour
                    .frame(width: size.width, height: size.height)
                    .preferredColorScheme(dark ? .dark : .light)
            )
        )
        host.frame = CGRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

        let window = testWindow(host.frame, styleMask: [.borderless])
        window.appearance = host.appearance
        window.contentView = host
        window.displayIfNeeded()

        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return try #require(
            rep.colorAt(x: Int(size.width) / 2, y: Int(size.height) / 2)?.usingColorSpace(.sRGB)
        )
    }

    private func hex(_ colour: NSColor) -> String {
        String(
            format: "#%02X%02X%02X",
            Int((Double(colour.redComponent) * 255).rounded()),
            Int((Double(colour.greenComponent) * 255).rounded()),
            Int((Double(colour.blueComponent) * 255).rounded())
        )
    }
}

extension String {
    /// Whether this source spells `.orange` — the colour — rather than merely
    /// containing those letters.
    ///
    /// A plain substring search reports `\.reduceMotionOverride` as `.red`,
    /// which is how a scan like this earns a reputation for crying wolf and
    /// then gets deleted. The identifier has to *end* where the hue ends.
    func spells(_ hue: String) -> Bool {
        var searched = startIndex
        while let found = range(of: ".\(hue)", range: searched..<endIndex) {
            if found.upperBound == endIndex { return true }
            let next = self[found.upperBound]
            if !next.isLetter, !next.isNumber, next != "_" { return true }
            searched = found.upperBound
        }
        return false
    }
}
