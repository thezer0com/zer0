import AppKit
import SwiftUI
import Zer0Core

/// The strip that appears at the top of the page when the sidebar is hidden.
///
/// Without it the window's traffic lights sit directly on the page: on Gmail
/// they land on the logo. A window with no title bar still needs somewhere for
/// its own controls to live, and somewhere to grab when you want to move it.
///
/// It only exists when the sidebar is away. With the sidebar open, the sidebar
/// is that place.
///
/// **It takes its colour from the page** (ADR-0047). A strip painted in the
/// app's own grey above a near-black page is two surfaces that know nothing
/// about each other, with a seam welded between them; painted in the page's
/// colour it reads as the top of the page rather than as a bar bolted over it.
/// The colour is a fact the core works out and puts on the tab — this file only
/// decides what to do with it, which is what keeps the same rule true on a
/// platform with no `WKWebView` in it.
struct WindowChrome: View {
    @Environment(BrowserModel.self) private var model

    enum Metrics {
        /// Enough for the traffic lights plus breathing room. They are
        /// positioned by the system, so this is reserved rather than laid out.
        static let trafficLightWidth: CGFloat = 78
        /// The title is centred, so it is capped rather than laid out: a long
        /// one truncates instead of pushing the traffic-light reservations
        /// apart.
        static let titleWidth: CGFloat = 340
        /// The toggle's hit area. Bigger than the glyph it holds, because a
        /// 13pt symbol is a 13pt target and a target that small is a target you
        /// miss. Off the 4pt rhythm in neither direction: 28 × 24 is `loose +
        /// hair` by `snug × 2`, and it centres optically in a 38pt strip.
        static let toggle = CGSize(width: 28, height: 24)
        /// How much of the strip the extension buttons may take before they
        /// start scrolling instead of growing.
        ///
        /// Six buttons. Past that the title — the one thing this strip says —
        /// would start losing room to them, and a strip whose contents can push
        /// out its own reason for existing is the toolbar this is not
        /// (ADR-0068). It is deliberately close to `trafficLightWidth`, the
        /// balancing reservation it stands in for, so an ordinary number of
        /// extensions leaves the title where it already sat.
        static let actionsWidth: CGFloat = 164
    }

    static let height: CGFloat = 38

    /// What the page said its colour is, or nothing.
    private var tint: PageTint? { model.activeTab?.tint }

    /// What is legible on this strip.
    ///
    /// **One level, deliberately.** Everywhere else in the shell text ranks by
    /// colour first (DESIGN.md §5), and it can, because it sits on a surface we
    /// chose. This surface is chosen by the page, and a second, quieter ink
    /// cannot be guaranteed readable on a colour someone else picked — at the
    /// edge of the band ADR-0047 allows, a level even 25% down from the ink
    /// falls under AA. Two items do not need a colour to rank them: the control
    /// is a control, and the title is a caption. Size and weight already say it.
    private var ink: Color {
        guard let tint else { return Design.Palette.ink }
        // The palette's own ink, from whichever half of it is legible here. The
        // core decides *which side*, because that is a property of the colour;
        // which ink is on that side is the palette's business.
        return tint.prefersDarkInk
            ? Design.Palette.light.ink.color
            : Design.Palette.dark.ink.color
    }

    var body: some View {
        HStack(spacing: Design.Space.tight) {
            Color.clear.frame(width: Metrics.trafficLightWidth)

            SidebarToggle(ink: ink, tip: toggleTip) {
                model.perform(.toggleSidebar)
            }

            Spacer()

            if let tab = model.activeTab {
                // The one thing worth saying up here, in the quietest way that
                // still reads: which page you are on.
                Text(tab.displayTitle)
                    .font(Design.Text.label)
                    .foregroundStyle(ink)
                    .lineLimit(1)
                    .frame(maxWidth: Metrics.titleWidth)
            }

            Spacer()

            // Where the balancing reservation was.
            //
            // This strip exists *because* the sidebar is away, and it already
            // carries the two things the sidebar was carrying that the window
            // still needs: somewhere for the traffic lights, and the way back
            // to the sidebar. A pinned extension button is a third, and it
            // travels here for exactly the same reason and under the rule
            // ADR-0068 sets: **this strip may hold a control only if the
            // sidebar holds it too.** That is what keeps it from becoming the
            // junk drawer ADR-0010 refuses — a favicon, a blocking badge and a
            // padlock are all in no sidebar, so none of them can arrive here.
            //
            // It costs the page nothing: the strip is already 38pt, and this
            // sits in the space that was reserved and empty.
            if model.pinnedExtensions.isEmpty {
                Color.clear.frame(width: Metrics.trafficLightWidth)
            } else {
                ExtensionActionBar(ink: ink, popoverEdge: .maxY)
                    .frame(maxWidth: Metrics.actionsWidth, alignment: .trailing)
            }
        }
        .padding(.horizontal, Design.Space.snug)
        .frame(height: Self.height)
        .background(surface)
        .overlay(alignment: .bottom) { seam }
        // A colour that hard-cuts on every navigation is worse than no colour
        // at all. `subtle` rather than `entrance`: nothing arrived, a surface
        // that was already there changed — and this is the one curve Reduce
        // Motion leaves alone, correctly, because a cross-fade is feedback and
        // not travel (ADR-0046).
        .motion(.subtle, value: tint)
        // The whole strip drags the window, which is what the title bar used
        // to be for.
        .gesture(WindowDragGesture())
    }

    @ViewBuilder
    private var surface: some View {
        if let tint {
            Swatch(hex: tint.rgb).color
        } else {
            // Nothing to borrow, so the strip is chrome and says so: the same
            // surface the sidebar wears, which is the other place the window's
            // own controls live.
            Color.clear.chromeSurface()
        }
    }

    /// The line under the strip, and the argument for when it is drawn.
    ///
    /// **Tinted, there is none.** The seam is the whole defect: a rule under a
    /// strip that is already the page's colour draws a border around nothing
    /// and puts back exactly the "bar bolted on" reading the colour removes.
    ///
    /// Untinted, it stays. That strip is not continuous with anything — it is
    /// the app's own surface over a page of unknown colour — and a boundary
    /// that exists should be visible rather than left for the page to
    /// accidentally reveal.
    @ViewBuilder
    private var seam: some View {
        if tint == nil {
            Divider().hairline()
        }
    }

    /// Read from the keymap rather than printed. ⌃S is a default, not a fact
    /// (ADR-0012, ADR-0018).
    private var toggleTip: String {
        guard let chord = model.chord(for: .toggleSidebar) else { return "Show Sidebar" }
        return "Show Sidebar (\(chord.displayString))"
    }
}

/// The way back to the sidebar, drawn as part of the strip rather than floating
/// on it.
///
/// It used to be a bare borderless button: a glyph with no target around it, no
/// answer to the pointer, and a fixed `.secondary` that had no relationship to
/// whatever was behind it. It read as pasted on, because it was.
///
/// Everything it wears is derived from the strip's own ink, so it belongs to
/// whatever colour the page turned out to be — including a page that declared
/// near-white and one that declared near-black.
private struct SidebarToggle: View {
    let ink: Color
    let tip: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "sidebar.left")
                .font(.system(size: Design.Glyph.control, weight: .medium))
                .foregroundStyle(ink)
                .frame(
                    width: WindowChrome.Metrics.toggle.width,
                    height: WindowChrome.Metrics.toggle.height
                )
                .background(
                    RoundedRectangle(cornerRadius: Design.Radius.small)
                        // A wash of the ink rather than a stated grey: on a
                        // page that declared near-black this has to lighten,
                        // and on one that declared near-white it has to darken.
                        // The ink already knows which way that is.
                        .fill(ink.opacity(hovering ? 0.14 : 0))
                )
                .contentShape(RoundedRectangle(cornerRadius: Design.Radius.small))
        }
        .buttonStyle(.pressable)
        .onHover { hovering = $0 }
        .motion(.subtle, value: hovering)
        .help(tip)
    }
}
