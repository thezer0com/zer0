import AppKit
import CryptoKit
import Foundation
import SwiftUI

/// The mark that stands for a row's subject in a list.
///
/// The site's own icon when there is one, and a coloured letter when there is
/// not. Nobody recognises a tab by a letter; they recognise it by its icon, and
/// how fast a hand finds the right row depends on that. So the icon is the
/// point and the letter is what holds its place.
///
/// A row for one of the browser's own pages is not a site and draws the
/// browser's own mark instead (ADR-0083). What a row stands for is
/// `BrowserModel.badge(for:)`'s answer; this view only draws it.
///
/// The letter is not a consolation prize. It is what shows for the second or
/// two before the bytes arrive, for a site that has no icon at all, for one
/// whose server was down, and for a page that is not on the web — and it is
/// stable, because the colour comes from a hash of the hostname rather than
/// from a rotating palette. A row that went blank while waiting would be worse
/// than the placeholder it replaced.
struct SiteBadge: View {
    /// What one badge stands for.
    ///
    /// One closed value rather than a host beside an optional icon beside a
    /// flag, because two of those three combinations are nonsense: the
    /// browser's own pages have no host to hash a colour from and no favicon to
    /// fetch. A shape that cannot express the nonsense is a guarantee; a rule
    /// saying "do not pass both" is a wish.
    enum Subject: Equatable {
        /// A site on the web, and its own icon once the core has one.
        ///
        /// `host` is `nil` for a page that has none — a tab with nothing
        /// committed, a `data:` URL — and that draws the neutral placeholder
        /// rather than a letter, because there is no name to take one from.
        ///
        /// The icon is passed in rather than looked up so this view stays
        /// drawable on its own, which is what lets it be rendered offscreen and
        /// looked at.
        case site(host: String?, icon: NSImage?)
        /// One of the browser's own pages, which wears the browser's own mark.
        ///
        /// `zer0://history` is not a site: there is nobody to ask for an icon
        /// and no host worth a letter. The mark is also the more useful answer,
        /// because it says at a glance that the row is the browser talking
        /// about itself rather than somewhere you went.
        case zer0
    }

    let subject: Subject
    var size: CGFloat = 16

    var body: some View {
        ZStack {
            ground.opacity(icon == nil ? 1 : 0)

            if let icon {
                // Bare, with no container and no shadow. A favicon is already
                // a designed mark on its own ground; wrapping one in a
                // gradient tile is a sticker glued over a logo. `.fit` because
                // a handful of sites serve something that is not square, and
                // squashing a wordmark to fill a box is worse than leaving air
                // beside it.
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        // It arrives, it does not appear. The letter is already in that exact
        // spot at that exact size, so a crossfade reads as the row resolving
        // rather than as something being swapped in.
        .motion(.subtle, value: icon == nil)
        // Decoration: the row next to it already says which site this is, and
        // hearing "G" before every title is noise.
        .accessibilityHidden(true)
    }

    /// The host this badge stands for, when it stands for a site at all.
    private var host: String? {
        switch subject {
        case let .site(host, _): host
        case .zer0: nil
        }
    }

    private var icon: NSImage? {
        switch subject {
        case let .site(_, icon): icon
        case .zer0: nil
        }
    }

    /// What is drawn when there is no favicon: a letter for a site, our own
    /// mark for one of our own pages.
    ///
    /// The mark goes through `Zer0MarkGlyph` and not through the `Shape`,
    /// because at this size the canonical drawing is a plain O (ADR-0040).
    @ViewBuilder
    private var ground: some View {
        switch subject {
        case .site: letter
        case .zer0: Zer0MarkGlyph(side: size)
        }
    }

    /// The stand-in: a hue owned by the hostname, with its initial on top.
    private var letter: some View {
        let palette = Self.palette(for: host)

        return ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(LinearGradient(
                    colors: [palette.highlight, palette.base],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))

            Text(initial)
                .font(.system(size: size * 0.58, weight: .semibold, design: .rounded))
                .foregroundStyle(palette.ink)
        }
        .frame(width: size, height: size)
        // Deliberately not on `Design.Elevation`. That scale is black shadows
        // for panels that left a surface; this is the badge's own hue bled a
        // point or two past its edge, which is what stops a saturated 16pt
        // square looking like a sticker cut out and dropped on the row. A
        // black cast at any of the three steps would swamp something this
        // small.
        .shadow(color: palette.base.opacity(0.35), radius: 2, y: 1)
    }

    private var initial: String {
        guard let letter = Self.significantPart(of: host)?.first else { return "•" }
        return String(letter).uppercased()
    }

    /// The part of a host worth reading: `mail.google.com` is Google, not Mail.
    static func significantPart(of host: String?) -> String? {
        guard let host, !host.isEmpty else { return nil }

        let parts = host
            .replacingOccurrences(of: "www.", with: "")
            .split(separator: ".")
        guard parts.count > 1 else { return parts.first.map(String.init) }

        // Second to last: the registrable name, before the suffix.
        return String(parts[parts.count - 2])
    }

    // MARK: - Colour

    /// What one badge is painted with: a fill, a lighter top corner, and the
    /// letter colour that reads against both.
    struct Palette {
        let base: Color
        let highlight: Color
        let ink: Color
    }

    /// A stable colour per site, and a letter that survives it.
    ///
    /// Hashed rather than picked from a rotating palette so the same site gets
    /// the same colour in every window, every session, forever.
    ///
    /// Hue alone says nothing about legibility. At one fixed brightness the
    /// wheel spans a relative luminance of roughly 0.06 (blue) to 0.60
    /// (yellow), so a fixed white letter measured 1.8:1 on the bright half —
    /// well under the 4.5:1 floor. Each hue therefore lands on whichever of two
    /// levels it can actually carry: vivid with a black letter, or deep with a
    /// white one. Worst case across all 256 hues is about 6:1, gradient
    /// included.
    static func palette(for host: String?) -> Palette {
        guard let name = significantPart(of: host) else {
            return Palette(base: .gray, highlight: Color(white: 0.62), ink: .white)
        }

        let digest = SHA256.hash(data: Data(name.utf8))
        let hue = Double(Array(digest).first ?? 0) / 255.0

        let vivid = luminance(hue: hue, saturation: saturation, brightness: vividLevel)
            >= inkCrossover
        let level = vivid ? vividLevel : deepLevel

        return Palette(
            base: Color(hue: hue, saturation: saturation, brightness: level * 0.92),
            highlight: Color(hue: hue, saturation: saturation, brightness: min(1, level * 1.05)),
            ink: vivid ? .black : .white
        )
    }

    private static let saturation = 0.62
    /// The only two brightnesses a badge is allowed to take.
    private static let vividLevel = 0.95
    private static let deepLevel = 0.60
    /// Black beats white above a luminance of 0.179. The gap to 0.30 is
    /// deliberate: the gradient's bright corner must not cross back over it.
    private static let inkCrossover = 0.30

    /// The worst contrast a hue produces, both gradient stops considered.
    ///
    /// Exists so a test can sweep all 256 reachable hues and hold the floor:
    /// the badge picks its colour from a hash, so "most hues are fine" is not
    /// good enough when one unlucky site gets an unreadable one.
    static func contrastAtWorst(hue: Double) -> Double {
        let vivid = luminance(hue: hue, saturation: saturation, brightness: vividLevel)
            >= inkCrossover
        let level = vivid ? vividLevel : deepLevel
        let ink = vivid ? 0.0 : 1.0

        // Both stops: the gradient's bright corner is where white ink is most
        // at risk, and its dark corner is where black ink is.
        return [level * 0.92, min(1, level * 1.05)]
            .map { contrast(luminance(hue: hue, saturation: saturation, brightness: $0), ink) }
            .min() ?? 0
    }

    /// WCAG contrast ratio between two relative luminances.
    static func contrast(_ a: Double, _ b: Double) -> Double {
        let lighter = max(a, b)
        let darker = min(a, b)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// WCAG relative luminance of an HSB colour, treating it as sRGB.
    static func luminance(hue: Double, saturation: Double, brightness: Double) -> Double {
        let (red, green, blue) = rgb(hue: hue, saturation: saturation, brightness: brightness)
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// sRGB transfer function: luminance is not the channel value, and
    /// averaging the raw channels would put the crossover in the wrong place.
    private static func linear(_ channel: Double) -> Double {
        channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }

    private static func rgb(
        hue: Double,
        saturation: Double,
        brightness: Double
    ) -> (Double, Double, Double) {
        let sector = (hue * 6).rounded(.down)
        let offset = hue * 6 - sector
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - offset * saturation)
        let t = brightness * (1 - (1 - offset) * saturation)

        switch Int(sector) % 6 {
        case 0: return (brightness, t, p)
        case 1: return (q, brightness, p)
        case 2: return (p, brightness, t)
        case 3: return (p, q, brightness)
        case 4: return (t, p, brightness)
        default: return (brightness, p, q)
        }
    }
}
