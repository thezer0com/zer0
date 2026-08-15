import AppKit
import SwiftUI

// MARK: - The palette, adopted

extension Design {
    /// **B · Fault, shipped** (ADR-0043).
    ///
    /// The three candidates and the argument for each are in
    /// `PaletteProposals.swift`, which stays as the record of what was on the
    /// table. This is the one that was taken, resolved into the colours the
    /// shell actually draws with.
    ///
    /// Every value is still a `Swatch` — bytes, not a `Color` — so the ratios
    /// stay computable and `PaletteContrastTests` can recompute them from the
    /// same numbers that reach the screen. A palette that cannot be measured is
    /// a palette that fails contrast six months later without anyone noticing.
    ///
    /// Each token is exposed as **one `Color` that resolves per appearance**,
    /// not as a pair the caller has to choose between. A view that had to read
    /// `@Environment(\.colorScheme)` to pick a hex is a view that can forget to,
    /// and the one that forgets is the one nobody opens in dark mode.
    enum Palette {
        /// The two halves of Fault, kept addressable so a test can measure the
        /// light pair and the dark pair independently — resolving a dynamic
        /// `NSColor` in a test process measures whatever appearance that process
        /// happens to be in, which is not a check of anything.
        static let light = Zer0Palette.fault(dark: false)
        static let dark = Zer0Palette.fault(dark: true)

        // MARK: Surfaces

        /// The window's own background.
        static let background = pair(\.background)

        /// **The sidebar's own surface**, and the one colour here that no
        /// proposal had a slot for.
        ///
        /// It exists because the sidebar was a material, and until ADR-0043 that
        /// material sampled the desktop: the largest chrome surface in the
        /// product took its colour from whatever photo the person had set as a
        /// wallpaper. A palette cannot reach a surface it does not own, so
        /// adoption had to give the sidebar a surface to own.
        ///
        /// One step off `background` in the direction of the recess — set back
        /// from the page beside it without becoming a `recessed` group, which
        /// is a different claim. The whole sidebar is not a card.
        static func chromeSwatch(dark: Bool) -> Swatch { dark ? 0x181925 : 0xF0F0F6 }

        static let chrome = Swatch.dynamic(light: chromeSwatch(dark: false),
                                           dark: chromeSwatch(dark: true))

        /// A group of rows set back into the window: a settings section, a
        /// list treated as one surface, the capsule around a failed address.
        static let recessed = pair(\.recessed)
        /// The second step of recess, for a group nested inside one that is
        /// already at full strength.
        static let recessedInner = pair(\.recessedInner)

        /// **The hairline between two rows**, and the one colour here that
        /// exists to undo a side effect rather than to say something.
        ///
        /// SwiftUI's `Divider` takes its colour from the foreground ladder, and
        /// the palette sets that ladder at the root of every window. Measured
        /// on the same surface: a divider was `#DDDDE1` before adoption and
        /// `#9597A8` after — 1.15:1 became 2.7:1, and every list in the product
        /// went from *rows on one surface* to *stacked bars*. Nobody chose
        /// that; it fell out of choosing an ink.
        ///
        /// So a rule is stated instead of derived. The criterion is the one
        /// `Design.Stroke.hairline` already gives in words — *"a border that
        /// should be seen and not noticed"* — as a number: between 1.15:1 and
        /// 1.6:1 against the surface it divides. Below that it is not there;
        /// above it, it is a border, and a list of rows does not have internal
        /// borders.
        static func ruleSwatch(dark: Bool) -> Swatch { dark ? 0x33354A : 0xD7D7E0 }

        static let rule = Swatch.dynamic(light: ruleSwatch(dark: false),
                                         dark: ruleSwatch(dark: true))

        // MARK: Text

        static let ink = pair(\.ink)
        static let inkSecondary = pair(\.inkSecondary)
        static let inkTertiary = pair(\.inkTertiary)

        // MARK: Accent

        static let accent = pair(\.accent)
        static let onAccent = pair(\.onAccent)

        /// **The selected sidebar row**, which is the accent surface this
        /// product is looked at more than any other.
        ///
        /// It was `.selection`, and `.selection` is not `.tint`: it resolves to
        /// the *system* accent, so the row a person stares at all day was
        /// painted whatever colour macOS was set to and no palette could move
        /// it. Rendered side by side, all three proposals produced an identical
        /// grey-blue row.
        ///
        /// A wash of the accent rather than the accent itself, and the strength
        /// is not taste — it is the only band where two requirements both hold:
        ///
        /// - **the state must be seen**: 3:1 against `chrome`, which is WCAG
        ///   1.4.11's floor for information carried by something other than
        ///   text, and being selected is exactly that;
        /// - **the label must still be read**: 4.5:1 for `ink` laid on it,
        ///   because the row keeps the `.primary` → `.secondary` ladder every
        ///   other row in the sidebar uses. A solid accent fill would need the
        ///   row's text to flip to `onAccent`, which is a change to the row and
        ///   not to the palette.
        ///
        /// In light that band is roughly 0.21–0.26 relative luminance and in
        /// dark 0.13–0.15. Both of these sit in the middle of it.
        static func selectedRowSwatch(dark: Bool) -> Swatch { dark ? 0x635BC9 : 0x837AE0 }

        static let selectedRow = Swatch.dynamic(light: selectedRowSwatch(dark: false),
                                                dark: selectedRowSwatch(dark: true))

        /// The other half of a split: on screen beside the focused tab, and not
        /// holding the keyboard.
        ///
        /// *"The same colour as the selected row and plainly less of it"* was
        /// already the rule; `.selection.opacity(0.3)` was a guess at it. This
        /// is the rule made measurable — **halfway between `chrome` and
        /// `selectedRow` in luminance**, so "less" is a number rather than an
        /// impression and the two states cannot converge.
        static func companionRowSwatch(dark: Bool) -> Swatch { dark ? 0x4A448F : 0xC6C0F2 }

        static let companionRow = Swatch.dynamic(light: companionRowSwatch(dark: false),
                                                 dark: companionRowSwatch(dark: true))

        // MARK: Status

        /// Something is off but nothing is lost: the session could not be read,
        /// an extension is not running, a download failed.
        ///
        /// Stated by the palette rather than borrowed from `.orange`, because
        /// `Color.orange` is a system hue that moves independently of every
        /// other colour on the screen. The consent sheet ranks risk in these
        /// three, and a tier that drifts is a rank that lies.
        static let warning = pair(\.warning)
        /// A hard negative: no matches in the find bar, a `critical`
        /// permission, an action that discards what someone accumulated.
        static let danger = pair(\.danger)
        /// A confirmed success. The rarest of the three, deliberately.
        static let success = pair(\.success)

        private static func pair(_ swatch: KeyPath<Zer0Palette, Swatch>) -> Color {
            Swatch.dynamic(light: light[keyPath: swatch], dark: dark[keyPath: swatch])
        }
    }
}

// MARK: - One colour, two appearances

extension Swatch {
    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    /// A colour that answers the appearance it is drawn in.
    ///
    /// `NSColor(name:dynamicProvider:)` rather than a `colorScheme` read at the
    /// call site: the Theme setting is applied as `.preferredColorScheme` on
    /// each window (`Zer0App`), which sets that window's `NSAppearance`, and a
    /// dynamic `NSColor` is resolved against the appearance of whatever is
    /// drawing it. So Theme keeps working, and no view has to remember to ask.
    static func dynamic(light: Swatch, dark: Swatch) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? dark.nsColor
                : light.nsColor
        })
    }
}

// MARK: - Wearing it

extension View {
    /// Wear the palette. Applied once, at the root of a window.
    ///
    /// Everything the shell paints is either `.tint`, a level of the foreground
    /// ladder, or the window's background — that was the point of spelling the
    /// accent `.tint` and never `Color.accentColor` (DESIGN.md §7) — so three
    /// modifiers cover it and the rest of the shell needs no edit.
    ///
    /// What this deliberately does **not** reach, because a root modifier
    /// cannot: the sidebar's material (`ChromeMaterial`), the selected row
    /// (`Palette.selectedRow`) and the status colours, which are named at their
    /// sites. All three are listed here rather than discovered later.
    public func zer0Palette() -> some View {
        tint(Design.Palette.accent)
            .foregroundStyle(
                Design.Palette.ink,
                Design.Palette.inkSecondary,
                Design.Palette.inkTertiary
            )
            .background(Design.Palette.background)
            .backgroundStyle(Design.Palette.background)
    }
}

// MARK: - The sidebar's surface

extension View {
    /// The sidebar's background: a colour the palette owns, and nothing else.
    ///
    /// **What this replaces, and why the material had to go.** The sidebar was
    /// `.thinMaterial`. SwiftUI's `Material` does not say what it samples, and
    /// at the window's edge with nothing opaque behind it what it samples is
    /// the *desktop*: checked against the wallpaper file, the sidebar rendered
    /// the same dark charcoal in the light board and the dark board, because
    /// the photograph behind the window was dark. Two defects follow, and both
    /// are the kind a person would report:
    ///
    /// - **the Theme setting does not hold.** Choose Light with a dark
    ///   wallpaper and the sidebar is dark. Nothing on the Appearance pane
    ///   explains that, and no reading of "Light" predicts it;
    /// - **no palette can reach the largest piece of chrome in the product**,
    ///   which makes *"neutrals tinted to the same temperature"* — the whole of
    ///   Fault's thesis — untrue of the surface with the most pixels in it.
    ///
    /// The first attempt kept the material and changed what it samples: an
    /// `NSVisualEffectView` with `.withinWindow` blending over a chrome fill.
    /// **Rendered and measured, that does not work.** The effect view paints
    /// its own backdrop over whatever is behind it, so the sidebar came out
    /// `#F3F3F3` in light and `#353535` in dark — the system's achromatic grey,
    /// against a palette asking for `#F0F0F6` and `#181925`. It is a system
    /// colour with extra steps, and it overwrites the exact surface the
    /// decision was about.
    ///
    /// So the sidebar is painted. Materials stay where they still earn their
    /// place — the command bar, the download shelf, the find bar, the install
    /// banner and the consent sheet keep `.regularMaterial`, because those
    /// float over a live page and blurring page content is what a panel over a
    /// page is *for*. Only the surface at the window's edge, which had nothing
    /// real to blur, gave one up.
    ///
    /// Honest about the cost: the sidebar is flat where it used to be
    /// translucent. What separates it from the page is now colour and an edge
    /// rather than depth. ADR-0043 argues that trade.
    func chromeSurface() -> some View {
        background(Design.Palette.chrome)
    }

    /// A `Divider` at the palette's weight.
    ///
    /// Spelled as an overlay rather than as a replacement view because
    /// `Divider` is the only thing in SwiftUI that knows whether it is in a
    /// row or a column, and a hand-rolled `Rectangle` would have to be told —
    /// at nine call sites, four of which are vertical.
    ///
    /// **Every `Divider()` in the shell wears this.** One that does not is a
    /// hairline at whatever weight the ink ladder happens to imply, which is
    /// how the shell got a 2.7:1 rule nobody asked for.
    func hairline() -> some View {
        overlay(Design.Palette.rule)
    }
}
