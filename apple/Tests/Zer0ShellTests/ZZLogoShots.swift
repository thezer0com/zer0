import AppKit
import SwiftUI
import Testing

@testable import Zer0Shell

/// Looking at the adopted logo through the one door every consumer goes
/// through. `Zer0MarkGlyph` decides the master by size and the ink by intent,
/// and none of that can be settled by an assertion: whether the purple ring
/// carries the white "zer" inlay at About size, whether the badge at 16pt is
/// still the browser's mark rather than a purple blob, and whether the quiet
/// rendering really is quiet — those are judgements about pixels.
///
/// Opt-in behind `ZER0_SHOT=1`, like every `ZZ*` file.
@MainActor
@Suite("logo shots")
struct ZZLogoShots {
    /// The brand lockup where it is loudest: About's size, on both grounds it
    /// can be drawn against. The inlay is white on purple by construction, so
    /// both grounds have to show the same lockup — if the letters ever float
    /// free of the band, one of the two will say so immediately.
    @Test(
        "the brand lockup at About size, light and dark",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    func theBrandLockupAtAboutSize() {
        for (ground, name) in [(Color.white, "light"), (Color.black, "dark")] {
            Shot(size: CGSize(width: 120, height: 120)) {
                ZStack {
                    Rectangle().fill(ground)
                    Zer0MarkGlyph(side: Design.Glyph.mark, ink: .brand)
                }
            }
            .write("logo-brand-\(Design.Glyph.mark)-\(name)")
        }
    }

    /// The badge composition: brand ink at 16pt, the size ADR-0083's sidebar
    /// row is. What has to survive here is the cut — a solid purple blob at
    /// this size is "the logo is an O in the sidebar" wearing a new colour.
    @Test(
        "the brand mark at badge size, on both grounds",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    func theBrandMarkAtBadgeSize() {
        for (ground, name) in [(Color.white, "light"), (Color.black, "dark")] {
            let shot = Shot(size: CGSize(width: 40, height: 40)) {
                ZStack {
                    Rectangle().fill(ground)
                    Zer0MarkGlyph(side: 16, ink: .brand)
                }
            }
            // Magnified by the bitmap, not the renderer: what is inspected is
            // the pixels that were actually placed at 16pt.
            Shot.write(Self.magnified(shot.frame(), by: 16), "logo-brand-16-\(name)")
        }
    }

    @Test(
        "the browser badge stays distinct on a selected row",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    func theBrowserBadgeOnASelectedRow() {
        for (dark, name) in [(false, "light"), (true, "dark")] {
            let shot = Shot(size: CGSize(width: 40, height: 40)) {
                ZStack {
                    RoundedRectangle(cornerRadius: Design.Radius.small)
                        .fill(Design.Palette.selectedRow)
                    SiteBadge(subject: .zer0, onTintedSurface: true)
                }
                .padding(8)
                .environment(\.colorScheme, dark ? .dark : .light)
                .zer0Palette()
            }
            Shot.write(Self.magnified(shot.frame(), by: 16), "logo-selected-\(name)")
        }
    }

    /// The empty state's mark: default ink under a tertiary foreground, the
    /// way BrowserView and the iOS hosts draw it. It has to read as present
    /// and quiet — one grey ring, no inlay, no brand purple.
    @Test(
        "the quiet mark at empty-state size",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    func theQuietMarkAtEmptyStateSize() {
        Shot(size: CGSize(width: 120, height: 120)) {
            ZStack {
                Rectangle().fill(Color.white)
                Zer0MarkGlyph(side: Design.Glyph.mark)
                    .foregroundStyle(.tertiary)
            }
        }
        .write("logo-quiet-\(Int(Design.Glyph.mark))")
    }

    /// Nearest-neighbour magnification, so what is enlarged is the pixels and
    /// not a guess at what was between them.
    private static func magnified(_ rep: NSBitmapImageRep, by factor: Int) -> NSBitmapImageRep {
        let side = rep.pixelsWide * factor
        let out = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: side, pixelsHigh: rep.pixelsHigh * factor,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        for y in 0 ..< out.pixelsHigh {
            for x in 0 ..< side {
                out.setColor(
                    rep.colorAt(x: x / factor, y: y / factor) ?? .clear,
                    atX: x, y: y
                )
            }
        }
        return out
    }
}
