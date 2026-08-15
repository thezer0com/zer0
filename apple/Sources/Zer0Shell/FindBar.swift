import AppKit
import SwiftUI
import Zer0Core

/// Find in page, floating over the top right of the content.
///
/// Top right rather than a full-width bar: it covers less of what you are
/// reading, and what you are reading is the thing you are searching.
struct FindBar: View {
    @Environment(BrowserModel.self) private var model
    @State private var query: String = ""
    /// The text the last search actually ran with. Without it a stale "not
    /// found" from the previous term would sit next to freshly typed text.
    @State private var searchedFor: String?

    /// What the bar can honestly say. `WKFindConfiguration` reports a hit or a
    /// miss and nothing else, so there is no match count here and none is
    /// invented to fill the space.
    private enum Status: Equatable {
        case idle
        case pending
        case searching
        case found
        case notFound
    }

    /// Sizes that belong to this one strip rather than to the whole UI, so
    /// they are named here instead of pretending to be design tokens.
    private enum Metrics {
        /// Wide enough for a phrase, narrow enough that the bar stays a corner
        /// of the page rather than a band across it.
        static let fieldWidth: CGFloat = 200
        /// The field's own height, which is what makes this a strip and not a
        /// panel. `Design.Text.FieldSize.strip` is sized to fit inside it.
        static let fieldHeight: CGFloat = 20
        /// The rule between the status and the buttons, kept shorter than the
        /// bar so it separates rather than divides.
        static let dividerHeight: CGFloat = 16
        /// Half of `Design.Stroke.hairline`, and one device pixel at @2x.
        ///
        /// Deliberately lighter than a hairline: this border's job is to close
        /// the edge of a material against whatever page is behind it, not to
        /// be seen. A full point here reads as a frame drawn around the bar.
        /// The install banner's capsule is the same case at the same weight.
        static let edge: CGFloat = 0.5
    }

    private var status: Status {
        guard !query.isEmpty else { return .idle }
        if model.finder.isSearching { return .searching }
        guard searchedFor == query else { return .pending }
        return model.finder.lastSearchFound ? .found : .notFound
    }

    var body: some View {
        HStack(spacing: Design.Space.tight) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(Design.Text.detail)

            CommandBarField(
                text: Binding(get: { query }, set: { value in
                    query = value
                    model.setFindQuery(value)
                }),
                // Sized for this strip: the command bar's 20pt headline was
                // taller than the field it is drawn in here.
                fontSize: Design.Text.FieldSize.strip,
                placeholder: "Find in page",
                onSubmit: { find(forwards: true) },
                onCancel: { model.closeFind() },
                onMove: { find(forwards: $0 > 0) }
            )
            .frame(width: Metrics.fieldWidth, height: Metrics.fieldHeight)

            statusLabel
                .font(Design.Text.label)

            Divider().hairline().frame(height: Metrics.dividerHeight)

            Button { find(forwards: false) } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(query.isEmpty)
            .help(tooltip("Previous match", .findPrevious))
            .accessibilityLabel("Previous match")

            Button { find(forwards: true) } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(query.isEmpty)
            .help(tooltip("Next match", .findNext))
            .accessibilityLabel("Next match")

            Button { model.closeFind() } label: {
                Image(systemName: "xmark")
            }
            .help("Close find bar (⎋)")
            .accessibilityLabel("Close find bar")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Design.Space.snug)
        .padding(.vertical, Design.Space.tight)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Design.Radius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: Design.Radius.medium)
                .strokeBorder(.quaternary, lineWidth: Metrics.edge)
        )
        // Resting on the page: it has left the surface, but it is a strip in a
        // corner rather than a panel over the whole window.
        .elevation(Design.Elevation.resting)
        // The bar changes width as the status appears; gliding keeps it from
        // twitching on every keystroke.
        .motion(.subtle, value: status)
        .onAppear { query = model.finder.query }
    }

    /// Three states, all of them true: nothing searched yet, a hit, a miss.
    @ViewBuilder
    private var statusLabel: some View {
        switch status {
        case .idle:
            EmptyView()
        case .pending:
            Text("↩ to search")
                .foregroundStyle(.tertiary)
        case .searching:
            ProgressView().controlSize(.mini).scaleEffect(0.7)
        case .found:
            HStack(spacing: Design.Space.hair) {
                Image(systemName: "checkmark")
                Text("Found")
            }
            .foregroundStyle(.secondary)
        case .notFound:
            Text("No matches")
                .foregroundStyle(Design.Palette.danger)
        }
    }

    private func find(forwards: Bool) {
        searchedFor = query
        model.runFind(forwards: forwards)
    }

    /// Tooltips read the live keymap, so rebinding a shortcut does not leave a
    /// lie behind in the tooltip.
    private func tooltip(_ label: String, _ command: UiCommand) -> String {
        guard let chord = model.chord(for: command) else { return label }
        return "\(label) (\(chord.displayString))"
    }
}
