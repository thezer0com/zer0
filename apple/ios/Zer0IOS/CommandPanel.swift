import SwiftUI
import Zer0Core

/// The suggestions that hang under the address field while it holds focus:
/// the macOS palette's list, worn the way a phone wears it.
///
/// The field itself is permanent chrome (ADR-0123's D2), so what the palette
/// is on a Mac — field and list as one floating panel — splits here: the
/// field stays put, and the results float over the page below it rather than
/// pushing the page around every time the ranking changes. What it wears is
/// the palette's own dress: the same surface, edge, radius, elevation step
/// and first-row highlight, read from the same tokens.
struct CommandPanel: View {
    @Environment(BrowserModel.self) private var model

    /// What picking a row does. The caller owns the field's focus, so it
    /// owns what picking a row does to it.
    let pick: (Suggestion) -> Void

    /// Sizes that belong to this one panel rather than to the whole UI, so
    /// they are named here instead of pretending to be design tokens. Each
    /// is the macOS palette's own number doing the same job — the two are
    /// the same object on two hosts, and their geometry should not be able
    /// to drift apart silently.
    private enum Metrics {
        /// The list stops before the panel covers the page it floats over.
        static let listMaxHeight: CGFloat = 320
        /// What a row is assumed to be tall before anything has been
        /// measured: used for exactly one layout pass, then replaced by the
        /// real number.
        static let estimatedRow: CGFloat = 44
        /// How far inside the panel's edge the highlight is drawn. A shape
        /// inside the panel rather than a bar across it — the panel is the
        /// surface a person reads results in, and it is not a system list.
        static let highlightInset: CGFloat = Design.Space.tight
    }

    /// How tall the list is allowed to be right now.
    ///
    /// A `ScrollView` takes every point it is offered, which would hand two
    /// results the same height as eight — most of it empty material. As tall
    /// as its rows, up to the ceiling; past that it scrolls, which is what
    /// the ceiling was always for. The Mac panel measures the same way, for
    /// the same defect.
    @State private var measuredList: CGFloat = 0

    private var listHeight: CGFloat {
        let content = measuredList > 0
            ? measuredList
            : CGFloat(model.suggestions.count) * Metrics.estimatedRow
        return min(content, Metrics.listMaxHeight)
    }

    /// The panel's shape, in one place: the fill, the border and the clip
    /// have to be the same rounded rectangle or the border sits a half-pixel
    /// off the fill it is supposed to edge.
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Design.Radius.large, style: .continuous)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(model.suggestions.enumerated()), id: \.offset) { index, suggestion in
                    row(suggestion, isHighlighted: index == 0)
                }
            }
            .padding(.vertical, Metrics.highlightInset)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measuredList = $0 }
        }
        .frame(height: listHeight)
        .scrollBounceBehavior(.basedOnSize)
        // The deepest step on the scale, and the same one the macOS palette
        // takes: this panel dims the page behind it, and it has to look like
        // the reason the page stepped back. Painted rather than blurred
        // (ADR-0043) — the iOS half of `VisualEffect` is the same decision
        // wearing this platform's spelling.
        .background { VisualEffect(material: .hudWindow, radius: Design.Radius.large) }
        // What turns a fill into a panel: without an edge it is a slab with
        // nothing to say about where it stops.
        .overlay { shape.strokeBorder(.quaternary, lineWidth: Design.Stroke.hairline) }
        .clipShape(shape)
        .elevation(Design.Elevation.overlay)
        // The panel glides as the ranking changes its height: gliding shows
        // it is the same panel rather than a new one being swapped in.
        .motion(.subtle, value: model.suggestions.count)
    }

    /// One result: the title is what is read, the address is what confirms
    /// it — `rowTitle` over `label`, the macOS row's own two steps, so the
    /// eye lands on the title before anyone has read a word.
    ///
    /// No leading icon column yet: the licensed set carries no glyph for a
    /// tab, a history entry or a bookmark (ADR-0116), and half the rows
    /// wearing one while the rest do not is worse than none of them doing
    /// it. Titles align by default without the column.
    private func row(_ suggestion: Suggestion, isHighlighted: Bool) -> some View {
        Button {
            pick(suggestion)
        } label: {
            HStack(spacing: Design.Space.snug) {
                VStack(alignment: .leading, spacing: Design.Space.line) {
                    Text(title(of: suggestion))
                        .font(Design.Text.rowTitle)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(subtitle(of: suggestion))
                        .font(Design.Text.label)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: Design.Space.snug)
            }
            .padding(.horizontal, Design.Space.regular)
            .padding(.vertical, Design.Space.tight)
            .background { highlight(isHighlighted) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
    }

    /// What is drawn under the first row — the row Go is about to act on.
    ///
    /// On the Mac this is the row the arrows sit on; here there are no
    /// arrows, and the highlight is the whole answer to "what does that key
    /// do". The accent as a tint and an edge rather than a solid fill, the
    /// same shape the macOS palette paints under its highlighted row.
    @ViewBuilder
    private func highlight(_ isHighlighted: Bool) -> some View {
        if isHighlighted {
            let shape = RoundedRectangle(cornerRadius: Design.Radius.medium, style: .continuous)
            shape
                .fill(.tint.opacity(0.16))
                .overlay(shape.strokeBorder(.tint.opacity(0.35), lineWidth: Design.Stroke.hairline))
                .padding(.horizontal, Metrics.highlightInset)
        }
    }

    /// What a row is read by, and what confirms it — the two-line shape the
    /// macOS palette's rows have. The words come from the core's own
    /// categories; nothing here invents a destination the core did not offer.
    private func title(of suggestion: Suggestion) -> String {
        switch suggestion {
        case let .switchToTab(_, title, _): title
        case let .openBookmark(_, title): title
        case let .openHistory(_, title): title ?? ""
        case let .navigate(url): url
        case let .search(query, _): query
        case let .askChat(question): question
        }
    }

    private func subtitle(of suggestion: Suggestion) -> String {
        switch suggestion {
        case let .switchToTab(_, _, url):
            url ?? "Already open"
        case let .openBookmark(url, _):
            url
        case let .openHistory(url, _):
            url
        case .navigate:
            "Address"
        case .search:
            // The configured engine's own name, asked now rather than
            // remembered, so the row never names an engine somebody switched
            // away from a minute ago.
            model.currentSearchEngineName.map { "Search with \($0)" } ?? "Search"
        case .askChat:
            "Ask"
        }
    }
}
