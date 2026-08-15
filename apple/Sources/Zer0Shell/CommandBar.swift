import AppKit
import SwiftUI
import Zer0Core

/// One input for navigating, searching and switching tabs.
///
/// The ranking is not decided here. The core returns an ordered list and this
/// draws it, so every platform ends up with the same behaviour.
struct CommandBar: View {
    @Environment(BrowserModel.self) private var model
    @Curves private var motion
    @State private var highlighted: Int = 0
    /// Counts moves the keyboard asked for. Only those scroll the list: doing
    /// it for the pointer would drag a row out from under the pointer, which
    /// hovers the next row, which scrolls again.
    @State private var keyboardMoves: Int = 0
    /// How tall the rows actually are, so the panel can be as tall as them and
    /// no taller. Zero until the first layout has been through.
    @State private var measuredList: CGFloat = 0
    /// Where the highlight lives. One rectangle that moves down the list, not
    /// one that is painted out here and in over there.
    @Namespace private var highlightSpace

    /// Sizes that belong to this one panel rather than to the whole UI, so
    /// they are named here instead of pretending to be design tokens.
    enum Metrics {
        /// Wide enough for a real URL to fit on one line.
        static let width: CGFloat = 620
        static let fieldHeight: CGFloat = 28
        /// The list stops before the palette covers the page it floats over.
        static let listMaxHeight: CGFloat = 320
        /// Icons share a column so every title starts on the same vertical.
        static let iconColumn: CGFloat = 18
        /// How far below the top of the window the panel hangs.
        ///
        /// Not centred, and not against the top edge: a palette pinned to the
        /// top reads as part of the window's chrome, and one in the middle of
        /// the screen has nowhere to have come from. This is roughly the upper
        /// third, which is where the eye already is.
        static let dropFromTop: CGFloat = 100
        /// How far in from the panel's edge the highlight is drawn.
        ///
        /// The highlight is a shape inside the panel rather than a bar across
        /// it. A full-bleed fill in the accent colour is what a system list
        /// does, and this is not a system list — it is the surface the person
        /// looks at most in the product, and it should not be borrowed.
        static let highlightInset: CGFloat = Design.Space.tight
        /// What a row is assumed to be tall before anything has been measured.
        ///
        /// Used for exactly one layout pass, and then replaced by the real
        /// number. It exists so the panel's first frame is roughly right rather
        /// than either zero-height or full-height; a title, a subtitle and
        /// `Space.tight` above and below come to about this.
        static let estimatedRow: CGFloat = 44
    }

    /// The shape of the panel, in one place: the fill, the border and the
    /// clip have to be the same rounded rectangle or the border sits a
    /// half-pixel off the fill it is supposed to edge.
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Design.Radius.large, style: .continuous)
    }

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            CommandBarField(
                text: $model.commandBarQuery,
                onSubmit: { acceptHighlighted() },
                onCancel: { model.commandBarOpen = false },
                onMove: { move(by: $0) }
            )
            .frame(height: Metrics.fieldHeight)
            .padding(Design.Space.regular)
            .onChange(of: model.commandBarQuery) { _, _ in
                model.updateSuggestions()
                // Any new result set invalidates where the cursor was, and the
                // list has to come back to the top with it.
                highlighted = 0
                keyboardMoves += 1
            }

            Divider().hairline()

            if model.suggestions.isEmpty {
                emptyState
            } else {
                results
            }
        }
        .frame(width: Metrics.width)
        // The one panel in the shell that floats over a `WKWebView` rather than
        // over SwiftUI, and so the one that needs a real `NSVisualEffectView`
        // to have anything to blur. `.hudWindow` is the material this platform
        // gives a floating palette; `.regularMaterial` here was a flat tint
        // pretending to be glass.
        .background {
            VisualEffect(material: .hudWindow, radius: Design.Radius.large)
        }
        // What turns a translucent fill into glass. Without an edge, a material
        // over a page that happens to be light is a slab with nothing to say
        // where it stops; the hairline is the same one every other floating
        // panel in this shell wears, for the same reason.
        .overlay { shape.strokeBorder(.quaternary, lineWidth: Design.Stroke.hairline) }
        .clipShape(shape)
        // The deepest step on the scale, and the only thing that takes it: this
        // is the one panel that dims the window behind it, so it has to look
        // like the reason the window stepped back.
        .elevation(Design.Elevation.overlay)
        .onAppear { highlighted = 0 }
        // The panel grows and shrinks with the result count; gliding shows it
        // is the same panel rather than a new one being swapped in.
        //
        // Until the list stopped claiming a fixed 320 points this animation had
        // nothing to animate: two results and eight results produced the same
        // panel, so most of it was empty. The sentence in DESIGN.md §3 about it
        // gliding was true of the code and false of the screen.
        .motion(.subtle, value: model.suggestions.count)
        .background { openInNewTabKey }
    }

    /// ⌘↩: open the highlighted row over there instead of here.
    ///
    /// It is a button rather than another case in the field's key handling
    /// because a key equivalent is matched before the text field ever sees the
    /// key press, and AppKit has no binding for ⌘↩ inside a field editor. It
    /// takes no space and no clicks: the shortcut is the whole point of it.
    private var openInNewTabKey: some View {
        Button("") { acceptHighlighted(inNewTab: true) }
            .keyboardShortcut(.return, modifiers: .command)
            .frame(width: 0, height: 0)
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// How tall the list is allowed to be right now.
    ///
    /// A `ScrollView` takes every point it is offered, which is why this panel
    /// used to be 320 points of list whether it held two rows or eight: below
    /// the second result there was a slab of empty material with nothing in it,
    /// and no rendered check had ever caught it because nobody had rendered the
    /// short list. The panel is now as tall as its rows, up to the ceiling that
    /// keeps it off the page it floats over — and past that it scrolls, which
    /// is what the ceiling was always for.
    private var listHeight: CGFloat {
        let content = measuredList > 0
            ? measuredList
            : CGFloat(model.suggestions.count) * Metrics.estimatedRow
        return min(content, Metrics.listMaxHeight)
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(model.suggestions.enumerated()), id: \.offset) { index, suggestion in
                        row(suggestion, isHighlighted: index == highlighted)
                            .contentShape(Rectangle())
                            // ⌘-click is the pointer's half of ⌘↩: same row,
                            // deliberately somewhere else.
                            .onTapGesture {
                                model.accept(
                                    suggestion,
                                    inNewTab: NSEvent.modifierFlags.contains(.command)
                                )
                            }
                            // The pointer owns the highlight while it is over
                            // the list, so mouse and keyboard never disagree
                            // about what Enter would do.
                            .onHover { inside in
                                if inside { highlighted = index }
                            }
                    }
                }
                .padding(.vertical, Metrics.highlightInset)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measuredList = $0 }
            }
            .frame(height: listHeight)
            // Nothing to scroll is nothing to scroll: a list that fits should
            // sit still rather than rubber-band under the wheel.
            .scrollBounceBehavior(.basedOnSize)
            // The highlight travels between rows, so arrowing down reads as one
            // cursor moving rather than two rows independently changing colour.
            .motion(.subtle, value: highlighted)
            // Eight results do not fit, so arrowing down has to carry the view
            // with it. Otherwise the selection walks off the bottom edge.
            .onChange(of: keyboardMoves) { _, _ in
                withAnimation(motion.subtle) { proxy.scrollTo(highlighted) }
            }
        }
    }

    /// One result.
    ///
    /// Three steps of hierarchy rather than one, because a result has three
    /// jobs and they are not equal: the title is what is read, the address is
    /// what confirms it, and the verb is what Return is about to do. They used
    /// to be `row` over `label` in the same colour — eleven points over ten,
    /// which on a 620-point panel is not a hierarchy, it is a rounding error.
    /// `rowTitle` over `label` is thirteen over ten with weight and colour
    /// pulling the same way, so the eye lands on the title before anyone has
    /// read a word.
    ///
    /// The icon column is left as a column deliberately. Real favicons are
    /// being brought in separately, and a row that is already the right shape
    /// takes one without being rebuilt.
    private func row(_ suggestion: Suggestion, isHighlighted: Bool) -> some View {
        HStack(spacing: Design.Space.snug) {
            leadingMark(for: suggestion, isHighlighted: isHighlighted)
                .frame(width: Metrics.iconColumn)

            VStack(alignment: .leading, spacing: Design.Space.line) {
                Text(primaryText(for: suggestion))
                    .font(Design.Text.rowTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let secondary = secondaryText(for: suggestion) {
                    Text(secondary)
                        .font(Design.Text.label)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: Design.Space.snug)

            // Tell the user before they commit that this will land somewhere
            // else, rather than surprising them after the fact.
            if let space = destinationSpace(for: suggestion) {
                Text(model.spaceName(space))
                    .font(Design.Text.label)
                    .padding(.horizontal, Design.Space.tight)
                    .padding(.vertical, Design.Space.line)
                    .background(.tint.opacity(0.2))
                    .clipShape(Capsule())
            }
            if isHighlighted {
                returnHint(for: suggestion)
            }
        }
        .padding(.horizontal, Design.Space.regular)
        .padding(.vertical, Design.Space.tight)
        .background(highlight(isHighlighted))
    }

    /// What is drawn under the row the keyboard is on.
    ///
    /// A shape inside the panel rather than a bar across it, and the accent as
    /// a tint and an edge rather than as a solid fill: a full-bleed block of
    /// system blue is what an `NSTableView` does, and this panel is the product
    /// rather than a list borrowed from the platform. Everything here is
    /// `.tint` and geometry, so whatever the palette turns out to be (§7,
    /// ADR-0040) re-points all of it without another decision.
    @ViewBuilder
    private func highlight(_ isHighlighted: Bool) -> some View {
        if isHighlighted {
            let shape = RoundedRectangle(cornerRadius: Design.Radius.medium, style: .continuous)
            shape
                .fill(.tint.opacity(0.16))
                .overlay(shape.strokeBorder(.tint.opacity(0.35), lineWidth: Design.Stroke.hairline))
                .padding(.horizontal, Metrics.highlightInset)
                .matchedGeometryEffect(id: "zer0.commandBar.highlight", in: highlightSpace)
        }
    }

    /// What Return does to this row, said out loud on the row it would do it to.
    ///
    /// It used to be the word "Switch" in tertiary grey on every open-tab row,
    /// which is the wrong information in the wrong place at the wrong volume:
    /// first-order — what the key under your finger is about to do — whispered,
    /// and repeated on rows the key would not touch. One row can be committed
    /// to at a time, so one row says it, and it says it at a weight worth
    /// reading.
    private func returnHint(for suggestion: Suggestion) -> some View {
        HStack(spacing: Design.Space.hair) {
            Text("↩")
                .font(Design.Text.micro)
                .padding(.horizontal, Design.Space.hair)
                .padding(.vertical, Design.Space.line)
                .background(.tint.opacity(0.18), in: RoundedRectangle(cornerRadius: Design.Radius.small))
            Text(verb(for: suggestion))
                .font(Design.Text.label.weight(.medium))
        }
        .foregroundStyle(.tint)
        // The chord is already bound to the row; hearing it again after the
        // title is repetition, and the row's own label is what VoiceOver reads.
        .accessibilityHidden(true)
    }

    /// The verb, derived from the gesture the bar was opened with.
    ///
    /// ADR-0019: Return means what the gesture that opened the bar meant. That
    /// is the sentence this reads, so the word on screen cannot drift from what
    /// the core will dispatch without the ADR being wrong first.
    private func verb(for suggestion: Suggestion) -> String {
        switch suggestion {
        case .switchToTab: "Switch"
        case .search: "Search"
        // Not "Go here" and not "Open": this row does not take you anywhere,
        // and a verb that promised it would is the row lying about itself.
        case .askChat: "Ask"
        case .navigate, .openHistory, .openBookmark:
            switch model.commandBarIntent {
            case .navigateCurrentTab: "Go here"
            case .openNewTab: "Open"
            }
        }
    }

    // MARK: - Nothing to show

    /// An empty list is still a screen. With no query it teaches what the bar
    /// takes; with a query it says plainly that the search came back empty,
    /// instead of leaving a field floating on its own.
    private var emptyState: some View {
        let query = model.commandBarQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        return VStack(spacing: Design.Space.snug) {
            // The same glyph treatment every other empty state gets. Hand-drawn
            // here it had picked up its own size and weight, which is how two
            // near-identical screens start looking like two different products.
            EmptyStateSymbol(name: query.isEmpty ? "command" : "magnifyingglass")

            VStack(spacing: Design.Space.hair) {
                // Same scale as the input above it: the empty state belongs to
                // the palette rather than looking pasted into it.
                Text(query.isEmpty ? "Where to?" : "No results for “\(query)”")
                    .font(Design.Text.commandInput.weight(.medium))
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(query.isEmpty
                    ? "Type an address, search the web, or jump to a tab you already have open."
                    : "Nothing in your open tabs, kept pages or history matched.")
                    .font(Design.Text.row)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if query.isEmpty {
                shortcutHints
            }
        }
        .frame(maxWidth: .infinity)
        .padding(Design.Space.loose)
    }

    private var shortcutHints: some View {
        HStack(spacing: Design.Space.snug) {
            hint("↑↓", "move")
            switch model.commandBarIntent {
            // Opened as an address bar, so ↩ replaces this page and the way to
            // keep it is worth saying out loud.
            case .navigateCurrentTab:
                hint("↩", "go here")
                hint("⌘↩", "new tab")
            case .openNewTab:
                hint("↩", "open")
            }
            hint("⎋", "close")
        }
        .padding(.top, Design.Space.hair)
    }

    private func hint(_ key: String, _ meaning: String) -> some View {
        HStack(spacing: Design.Space.hair) {
            Text(key)
                .font(Design.Text.micro)
                .padding(.horizontal, Design.Space.hair)
                .padding(.vertical, Design.Space.line)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: Design.Radius.small))
            Text(meaning)
                .font(Design.Text.micro)
        }
        .foregroundStyle(.tertiary)
    }

    // MARK: - Rendering a suggestion

    /// What stands at the head of a row.
    ///
    /// A row that names a site wears that site's mark, the same one the sidebar
    /// and the history pane use. This is a switcher as much as a search box:
    /// three rows all wearing `arrow.right.square` say "these are tabs", which
    /// is the one thing you already knew, and say nothing at all about *which*
    /// tab. A row that has no site — a web search — keeps its glyph, because
    /// there is no site for it to be.
    @ViewBuilder
    private func leadingMark(for suggestion: Suggestion, isHighlighted: Bool) -> some View {
        if let host = host(of: suggestion) {
            SiteBadge(subject: model.badge(forHost: host))
        } else {
            Image(systemName: icon(for: suggestion))
                // Sized against the title it sits beside rather than left at
                // whatever the inherited body size was, and given weight so a
                // thin glyph on a translucent panel is a symbol rather than a
                // smudge. It brightens with the row: the icon is part of what
                // is selected, not a decoration that happens to be near it.
                .font(Design.Text.rowTitle)
                .foregroundStyle(isHighlighted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
    }

    /// The site a row is about, if it is about one.
    private func host(of suggestion: Suggestion) -> String? {
        let url: String? = switch suggestion {
        case let .switchToTab(_, _, url): url
        case let .openBookmark(url, _): url
        case let .openHistory(url, _): url
        case let .navigate(url): url
        case .search, .askChat: nil
        }
        guard let url, let host = URL(string: url)?.host(), !host.isEmpty else { return nil }
        return host
    }

    private func icon(for suggestion: Suggestion) -> String {
        switch suggestion {
        case .switchToTab: "arrow.right.square"
        // The same glyph the shelf and the page action wear. A kept page is
        // recognised by its mark before anybody reads the row.
        case .openBookmark: "bookmark.fill"
        case .openHistory: "clock"
        case .navigate: "globe"
        case .search: "magnifyingglass"
        case .askChat: "sparkles"
        }
    }

    private func primaryText(for suggestion: Suggestion) -> String {
        switch suggestion {
        case let .switchToTab(_, title, _): title
        case let .openBookmark(_, title): title
        case let .openHistory(url, title): title ?? url
        case let .navigate(url): url
        case let .search(query, _): query
        case let .askChat(question): question
        }
    }

    private func secondaryText(for suggestion: Suggestion) -> String? {
        switch suggestion {
        case let .switchToTab(_, _, url): url
        case let .openBookmark(url, _): url
        case let .openHistory(url, title): title == nil ? nil : url
        case .navigate: nil
        case .search: "Search"
        case .askChat: "Ask"
        }
    }

    /// Only meaningful for suggestions that would open something new: an
    /// already-open tab is wherever it already is.
    private func destinationSpace(for suggestion: Suggestion) -> SpaceId? {
        let url: String? = switch suggestion {
        case let .openBookmark(url, _): url
        case let .openHistory(url, _): url
        case let .navigate(url): url
        case .search, .switchToTab, .askChat: nil
        }
        guard let url, let target = model.routeDestination(for: url) else { return nil }
        return target == model.snapshot.activeSpace ? nil : target
    }

    // MARK: - Keyboard

    private func move(by delta: Int) {
        guard !model.suggestions.isEmpty else { return }
        let count = model.suggestions.count
        // Wraps, so holding down arrow at the bottom returns to the top rather
        // than sticking.
        highlighted = (highlighted + delta + count) % count
        keyboardMoves += 1
    }

    private func acceptHighlighted(inNewTab: Bool = false) {
        guard model.suggestions.indices.contains(highlighted) else { return }
        model.accept(model.suggestions[highlighted], inNewTab: inNewTab)
    }
}
