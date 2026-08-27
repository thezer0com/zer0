import SwiftUI
import Zer0Core

/// Every size remembered for a site, and a way to take one back.
///
/// The revocation screen ADR-0129 named as debt: ⌘0 on the page forgets the
/// site you are on, and somebody who forgot which sites they zoomed had no
/// way to find out. This is `SitePermissionsSection`'s shape for the other
/// half of the problem — the rows are per space, so the same site can appear
/// twice at two sizes, and a row that did not name its space would read as a
/// duplicate.
struct SiteZoomsSection: View {
    @Environment(BrowserModel.self) private var model

    var body: some View {
        SettingSection(title: "Zoom", footnote: footnote) {
            if model.siteZooms.isEmpty {
                empty
            } else {
                list
            }
        }
    }

    /// The footnote names the other door — the page — and reads its chord
    /// from the live keymap rather than writing ⌘0 down, so a rebinding
    /// cannot leave this pane lying (ADR-0018, the same rule the blocking
    /// exceptions list follows).
    private var footnote: String {
        let base = "Every tab on a site opens at the size you chose for it, in the "
            + "space you chose it in. A space is a separate signed-in identity, so "
            + "the same site can sit at two sizes."
        guard let chord = model.chord(for: .zoomReset) else {
            return base + " Resetting a page's zoom forgets it too."
        }
        return base + " \(chord.displayString) on the page forgets it too."
    }

    /// The state almost everybody is in: no site was ever zoomed, or every
    /// zoom was undone. It explains how a row appears rather than apologising
    /// for the lack of one.
    private var empty: some View {
        HStack(alignment: .top, spacing: Design.Space.snug) {
            LucideGlyph(icon: .zoomIn, side: Metrics.emptyGlyph)
                .foregroundStyle(.tertiary)

            Text("No site has a remembered size. Zoom a page and every tab on "
                + "that site opens there, in the space you zoomed it in — and "
                + "shows up here.")
                .font(Design.Text.detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var list: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.siteZooms.enumerated()), id: \.element) { index, zoom in
                row(zoom)
                if index < model.siteZooms.count - 1 {
                    Divider().hairline()
                }
            }
        }
    }

    private func row(_ zoom: StoredZoom) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Space.snug) {
            VStack(alignment: .leading, spacing: Design.Space.line) {
                // The origin, not a prettified host: it is what the row is
                // keyed by and what tells a lookalike apart from the real
                // thing (ADR-0018).
                Text(zoom.origin)
                    .font(Design.Text.rowTitle)
                    .textSelection(.enabled)

                Text("\(Self.percent(zoom.factor)) · \(model.spaceName(zoom.space))")
                    .font(Design.Text.label)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: Design.Space.regular)

            Button {
                model.forgetSiteZoom(zoom)
            } label: {
                LucideGlyph(icon: .minusCircle, side: Metrics.forgetGlyph)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Forget this size, so the site opens at the ordinary one")
            .accessibilityLabel("Forget the size for \(zoom.origin) in \(model.spaceName(zoom.space))")
        }
        .padding(.vertical, Design.Space.hair)
    }

    /// The factor the core holds as a readable whole: 1.5 rather than 150%.
    /// Rounded to a whole percent because no keystroke produces a finer step,
    /// and a decimal nobody set would be a lie about what is remembered.
    private static func percent(_ factor: Double) -> String {
        "\(Int((factor * 100).rounded()))%"
    }

    private enum Metrics {
        /// Beside a `detail` line, the way the permissions pane's glyph is —
        /// sized to read with the sentence, not at the empty-state glyph's
        /// display size.
        static let emptyGlyph: CGFloat = 13
        /// A control whose whole label is a glyph, beside a `rowTitle` line.
        static let forgetGlyph: CGFloat = 13
    }
}
