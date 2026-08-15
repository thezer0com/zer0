import SwiftUI

// MARK: - Three candidates, and the one that shipped

/// Three candidate palettes for zer0, offered so the decision DESIGN.md §7 and
/// ADR-0040 both leave open could be made by looking rather than by reading
/// adjectives.
///
/// **B · Fault was adopted (ADR-0043).** `Design.Palette` in `Palette.swift` is
/// what the shell actually draws with; this file stays as the record of what
/// was on the table, because the value of a decision record is the
/// disagreement between the options, and deleting the two that lost deletes it.
/// A and C are still live code — `PaletteContrastTests` measures all three, so
/// a proposal that could not ship cannot sit here pretending it could.
///
/// Every value is a `Swatch` rather than a `Color` so the numbers stay
/// checkable: `PaletteContrastTests` recomputes every ratio quoted here from
/// these same bytes, so a hex nudged by a shade cannot quietly drop a pair
/// under WCAG AA.
///
/// ## What the root swap reaches
///
/// Three modifiers, applied once (`View.zer0Palette(_:)`):
///
/// - `.tint(accent)` — every accent in the shell is spelled `.tint`, on
///   purpose (DESIGN.md §7), so one modifier re-points selection, the drop
///   target, prominent buttons, the running-extension dot and the mark.
/// - `.foregroundStyle(ink, inkSecondary, inkTertiary)` — the `.primary` →
///   `.secondary` → `.tertiary` ladder, all three levels at once.
/// - `.backgroundStyle(background)` — every `.background(.background)`.
///
/// ## What the root swap could not reach, and what adopting therefore cost
///
/// All three were real, all three were paid, and ADR-0043 argues each one.
///
/// 1. **`.orange`, `.red` and `.green` were written as concrete colours** at
///    about a dozen sites (`BrowserView`, `DownloadsView`, `FindBar`,
///    `InstallBanner`, `ExtensionsView`, `ExtensionConsentSheet`). They are now
///    `Design.Palette.warning` / `.danger` / `.success`, and a test scans the
///    shell for a view spelling one for itself.
/// 2. **`.quaternary` has no slot.** `foregroundStyle` takes three levels, and
///    `Design.Surface.recessed` is built on the fourth. `recessed` and
///    `recessedInner` are stated here so `DesignSystem.swift` can point at them
///    — two lines.
/// 3. **Materials do not take a palette.** The sidebar was `.thinMaterial` and
///    sampled the *desktop*: the largest chrome surface in the product took its
///    colour from the person's wallpaper, in both themes. It is now
///    `ChromeMaterial` — the same system material with its blending stated as
///    `.withinWindow`, over `Palette.chrome`. The panels that float over the
///    page keep `.regularMaterial`, because blurring page content is what a
///    panel over a page is for.
///
/// A fourth turned up that none of the three had a slot for: **`.selection` is
/// not `.tint`**. The selected sidebar row followed the *system* accent, which
/// is why board `04-sidebar-light.png` shows all three palettes identical
/// there. `Palette.selectedRow` is the answer, and its strength is derived
/// rather than picked.
struct Zer0Palette {
    /// What this palette is called when someone points at it.
    let name: String
    /// The bet, in one sentence.
    let thesis: String

    // MARK: Surfaces

    /// The window's own background: what `.background(.background)` becomes.
    let background: Swatch
    /// A group of rows set back into the window: what `Design.Surface.recessed`
    /// becomes.
    let recessed: Swatch
    /// The second step of recess, for a group inside a group.
    let recessedInner: Swatch

    // MARK: Text

    /// `.primary`: the thing being read.
    let ink: Swatch
    /// `.secondary`: the line that qualifies the thing being read. Held to the
    /// same 4.5:1 floor as primary, because it is prose and people read it.
    let inkSecondary: Swatch
    /// `.tertiary`: timestamps, keyboard hints, the mark on an empty screen.
    /// Held to 3:1, not 4.5:1 — this level exists to be quiet, and anything
    /// that must be read is not spelled at this level.
    let inkTertiary: Swatch

    // MARK: Accent

    /// `.tint`: selection, focus, the drop target, prominent buttons.
    let accent: Swatch
    /// The accent under a pointer.
    let accentHover: Swatch
    /// The accent under a press. Darker in light, lighter in dark: a press
    /// moves *toward* the surface it is on, which is what makes it read as the
    /// control going down rather than lighting up.
    let accentPressed: Swatch
    /// What is legible on top of a filled accent.
    let onAccent: Swatch

    // MARK: Status

    /// Something is off but nothing is lost: the session could not be read, an
    /// extension is not running, a download failed.
    let warning: Swatch
    /// A hard negative: `notFound` in the find bar, a `critical` permission.
    let danger: Swatch
    /// A confirmed success. The rarest of the three, and deliberately so.
    let success: Swatch
}

// MARK: - A: Paper

extension Zer0Palette {
    /// **The browser has no colour so the page can.**
    ///
    /// Warm neutrals throughout and one low-chroma ink-blue that appears only
    /// where something is selected or focused. Nothing in the chrome competes
    /// with a rendered page, which is the strictest reading of "no chrome that
    /// does not pay for itself" — a colour is chrome too.
    ///
    /// The accent is deliberately weak in chroma and strong in value: it earns
    /// its "this one" through darkness against a near-white field, not through
    /// hue. That is what lets it sit next to a page of any colour without
    /// arguing with it.
    static func paper(dark: Bool) -> Zer0Palette {
        let name = "Paper"
        let thesis = "The browser has no colour so the page can."

        if dark {
            return Zer0Palette(
                name: name, thesis: thesis,
                background: 0x141516, recessed: 0x1E1F21, recessedInner: 0x25262A,
                ink: 0xEDEEEF, inkSecondary: 0xA5A9AD, inkTertiary: 0x767A7F,
                accent: 0x93B6D8, accentHover: 0xA9C6E2, accentPressed: 0x7CA1C6,
                onAccent: 0x0E1A24,
                warning: 0xE2A64A, danger: 0xEF7268, success: 0x71C494
            )
        }
        return Zer0Palette(
            name: name, thesis: thesis,
            background: 0xFBFBFA, recessed: 0xF0F0EE, recessedInner: 0xE7E7E4,
            ink: 0x16171A, inkSecondary: 0x55585C, inkTertiary: 0x83878C,
            accent: 0x31506E, accentHover: 0x3C6086, accentPressed: 0x243D55,
            onAccent: 0xFFFFFF,
            warning: 0x8A5A0B, danger: 0xA62B22, success: 0x276B44
        )
    }
}

// MARK: - B: Fault

extension Zer0Palette {
    /// **The mark is a cut zero — cold, geometric, unapologetic — and the
    /// colour says the same thing.**
    ///
    /// One saturated ultramarine, the blue of a plotter pen rather than the
    /// blue of a system default, on neutrals tinted to the same temperature so
    /// the whole window reads as one material. It is the only proposal that
    /// gives zer0 a colour someone could describe over the phone.
    ///
    /// The hue is chosen to sit clear of the browser blues it would be shelved
    /// beside — it runs violet where Safari and Chrome run cyan — and clear of
    /// `danger` and `warning`, which is what keeps a prominent button from
    /// reading as an alarm.
    static func fault(dark: Bool) -> Zer0Palette {
        let name = "Fault"
        let thesis = "The mark is a cut zero: cold, geometric, and the colour commits to that."

        if dark {
            return Zer0Palette(
                name: name, thesis: thesis,
                background: 0x0E0F17, recessed: 0x1A1B27, recessedInner: 0x222432,
                ink: 0xECEDF5, inkSecondary: 0x9EA1B5, inkTertiary: 0x6E7186,
                accent: 0x8E86FF, accentHover: 0xA49DFF, accentPressed: 0x7A70F2,
                onAccent: 0x101033,
                warning: 0xE5A94D, danger: 0xF0726A, success: 0x63C08D
            )
        }
        return Zer0Palette(
            name: name, thesis: thesis,
            background: 0xFAFAFC, recessed: 0xECECF3, recessedInner: 0xE2E2EC,
            ink: 0x121327, inkSecondary: 0x53556B, inkTertiary: 0x83859A,
            accent: 0x3B2FE0, accentHover: 0x4F45EC, accentPressed: 0x2C22B4,
            onAccent: 0xFFFFFF,
            warning: 0x8F5600, danger: 0xB92019, success: 0x1C7549
        )
    }
}

// MARK: - C: Spaces

extension Zer0Palette {
    /// **The colour is not the product's, it is the Space's: which identity you
    /// are in is legible without reading a label.**
    ///
    /// A Space is already a cookie jar and an identity (ADR-0007). This
    /// proposal makes it a colour as well: the accent, the selected row, the
    /// focus ring and the mark all take the active Space's hue, and the
    /// sidebar's own surface carries a few percent of it. Switching from Work
    /// to Personal changes the temperature of the window, which is the fastest
    /// possible answer to "am I about to send this from the wrong account".
    ///
    /// The neutrals are strictly achromatic on purpose — the Space's hue has to
    /// be the only colour in the chrome or it stops being a signal.
    ///
    /// The identity set is fixed rather than free, and that is a feature: six
    /// hues, each one checked, none of them in the orange or red the status
    /// colours already own.
    static func spaces(_ identity: SpaceIdentity, dark: Bool) -> Zer0Palette {
        let name = "Spaces · \(identity.name)"
        let thesis = "Each Space carries its own colour, so which identity you are in is visible."

        if dark {
            return Zer0Palette(
                name: name, thesis: thesis,
                background: identity.dark.tinted(over: 0x131313, by: 0.06),
                recessed: identity.dark.tinted(over: 0x1E1E1E, by: 0.08),
                recessedInner: identity.dark.tinted(over: 0x262626, by: 0.08),
                ink: 0xEDEDED, inkSecondary: 0xA6A6A6, inkTertiary: 0x777777,
                accent: identity.dark,
                accentHover: identity.dark.lightened(0.14),
                accentPressed: identity.dark.darkened(0.10),
                onAccent: 0x101018,
                warning: 0xE2A64A, danger: 0xEF7268, success: 0x71C494
            )
        }
        return Zer0Palette(
            name: name, thesis: thesis,
            background: identity.light.tinted(over: 0xFBFBFB, by: 0.035),
            recessed: identity.light.tinted(over: 0xEFEFEF, by: 0.05),
            recessedInner: identity.light.tinted(over: 0xE6E6E6, by: 0.05),
            ink: 0x161616, inkSecondary: 0x565656, inkTertiary: 0x858585,
            accent: identity.light,
            accentHover: identity.light.lightened(0.10),
            accentPressed: identity.light.darkened(0.14),
            onAccent: 0xFFFFFF,
            warning: 0x8A5A0B, danger: 0xA62B22, success: 0x276B44
        )
    }

    /// The hue a Space is allowed to take.
    ///
    /// A closed set, not a colour well. Two reasons, and the second is the one
    /// that matters: a free picker lets someone choose a hue that fails
    /// contrast or collides with `warning`, and a Space's colour is a safety
    /// signal — the whole point is knowing which account you are about to post
    /// from. A signal you can misconfigure into invisibility is not one.
    ///
    /// Orange and red are absent by construction: they belong to `warning` and
    /// `danger`, and a Space painted in either would make every window look
    /// like it had a problem.
    struct SpaceIdentity {
        let name: String
        let light: Swatch
        let dark: Swatch

        static let indigo = SpaceIdentity(name: "Indigo", light: 0x4B57C8, dark: 0x9AA2F5)
        static let teal = SpaceIdentity(name: "Teal", light: 0x0C6E6C, dark: 0x5FC9C4)
        static let violet = SpaceIdentity(name: "Violet", light: 0x7A34D8, dark: 0xC0A0F8)
        static let magenta = SpaceIdentity(name: "Magenta", light: 0xB01A57, dark: 0xF191B4)
        static let green = SpaceIdentity(name: "Green", light: 0x2A6A2E, dark: 0x7FC98A)
        static let slate = SpaceIdentity(name: "Slate", light: 0x4A5464, dark: 0xA3B0C2)

        /// Every hue a Space can take, in the order they would be handed out.
        static let all: [SpaceIdentity] = [indigo, teal, violet, magenta, green, slate]
    }
}

// MARK: - Swatch

/// One colour, stored as bytes so it can be both drawn and measured.
///
/// A palette that cannot be measured is a palette that fails contrast six
/// months later without anyone noticing, so the source of truth is the number
/// and the `Color` is derived from it — never the other way round.
struct Swatch: ExpressibleByIntegerLiteral, Equatable {
    let red: Double
    let green: Double
    let blue: Double

    init(integerLiteral value: Int) { self.init(hex: UInt32(value)) }

    init(hex: UInt32) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
    }

    init(red: Double, green: Double, blue: Double) {
        self.red = min(1, max(0, red))
        self.green = min(1, max(0, green))
        self.blue = min(1, max(0, blue))
    }

    /// Drawn in sRGB explicitly. The default `Color(red:green:blue:)` is
    /// already sRGB, but saying so is what makes the measured luminance below
    /// and the pixel on screen the same claim.
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }

    var hex: String {
        String(format: "#%02X%02X%02X",
               Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }

    /// WCAG relative luminance.
    var luminance: Double {
        0.2126 * Self.linear(red) + 0.7152 * Self.linear(green) + 0.0722 * Self.linear(blue)
    }

    /// WCAG contrast ratio against another swatch.
    func contrast(against other: Swatch) -> Double {
        let lighter = max(luminance, other.luminance)
        let darker = min(luminance, other.luminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// This colour laid over `base` at `amount` opacity, composited.
    ///
    /// Kept as a real composite rather than an `.opacity()` at the call site so
    /// the result has a measurable luminance: a tinted background whose
    /// contrast cannot be computed is a tinted background nobody checked.
    func tinted(over base: Swatch, by amount: Double) -> Swatch {
        Swatch(
            red: base.red * (1 - amount) + red * amount,
            green: base.green * (1 - amount) + green * amount,
            blue: base.blue * (1 - amount) + blue * amount
        )
    }

    func lightened(_ amount: Double) -> Swatch {
        Swatch(red: red + (1 - red) * amount,
               green: green + (1 - green) * amount,
               blue: blue + (1 - blue) * amount)
    }

    func darkened(_ amount: Double) -> Swatch {
        Swatch(red: red * (1 - amount), green: green * (1 - amount), blue: blue * (1 - amount))
    }

    private static func linear(_ channel: Double) -> Double {
        channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }
}

// MARK: - Wearing one

extension View {
    /// Wear a palette.
    ///
    /// The whole adoption, in one place. Everything the shell paints is either
    /// `.tint`, a level of the foreground ladder, or `.background` — so three
    /// modifiers cover it, and the three that are left over are named in the
    /// type's own documentation rather than discovered later.
    func zer0Palette(_ palette: Zer0Palette) -> some View {
        tint(palette.accent.color)
            .foregroundStyle(
                palette.ink.color,
                palette.inkSecondary.color,
                palette.inkTertiary.color
            )
            .backgroundStyle(palette.background.color)
    }
}
