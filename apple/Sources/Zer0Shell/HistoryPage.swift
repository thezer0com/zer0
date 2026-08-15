import SwiftUI
import Zer0Core

/// Everywhere you have been, as a page.
///
/// A page rather than the Settings pane it used to be, and the argument is what
/// the thing *is*: history is a long list you search, scroll and walk with the
/// keyboard, and a window you open to change a setting is none of those. As a
/// page it gets an address, a tab, ⌘W, a place in the sidebar and a way back
/// after a restart, none of which had to be built (ADR-0063).
///
/// **The ranking is the core's and there is not a second one here.** What is
/// typed goes to `search_history`, which is the ranking the command bar uses —
/// the same fuzzy score, the same capped frecency bonus, the same tie-breaks.
/// A list that ordered itself would be this shell disagreeing with the bar
/// about which page answers "gh", and nobody notices an ordering that is
/// slightly wrong (ADR-0015).
///
/// What is decided here is a look: how a day is named, where the cursor lands,
/// and what an empty screen says.
struct HistoryPage: View {
    @Environment(BrowserModel.self) private var model

    /// What is typed. Local, because a half-typed search is not state any other
    /// window has an opinion about.
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    /// The row the keyboard is on. `nil` is "the cursor is in the field and
    /// nothing is picked out", which is where this opens.
    @State private var highlighted: String?
    /// How much a Clear would take. The narrowest span by default: a
    /// destructive control that opens pre-aimed at everything is one mis-click
    /// from a history nobody can get back.
    @State private var span: HistoryRange = .lastHour

    /// Sizes that belong to this one page rather than to the whole UI, so they
    /// are named here instead of pretending to be design tokens.
    private enum Metrics {
        /// A column of rows, not the width of a maximised window. A URL set
        /// across 2000 points is a line with its title stranded at one end.
        static let column: CGFloat = 720
        /// The search field. Wide enough for a phrase, and the widest thing in
        /// the strip so it reads as what the page is for.
        static let field: CGFloat = 280
        /// The span pop-up beside Clear. Sized to "The Last 24 Hours".
        static let span: CGFloat = 150
    }

    var body: some View {
        VStack(spacing: 0) {
            // Nothing to search and nothing to clear, so no strip and no rule
            // under it. On day one the empty state is the whole screen rather
            // than a screen with a disabled search bar over it.
            if !model.recentHistory(limit: 1).isEmpty {
                strip
                Divider().hairline()
            }
            content
        }
        .background(.background)
        // The cursor is in the field on arrival. This page is a search with a
        // list under it; opening it and asking for a click first would be the
        // browser making you say twice that you want to search your history.
        .onAppear { searchFocused = true }
        // ⌘F on this page means this field. There is no document for WebKit's
        // find to run over, and this is the only search the page has.
        .onChange(of: model.pageSearchRequests) { _, _ in searchFocused = true }
        .onChange(of: query) { _, _ in highlighted = nil }
    }

    // MARK: - The strip

    /// The search, and the one destructive act. No title: the tab, the sidebar
    /// row and the address all already say "History", and a fourth would be
    /// chrome that does not pay for itself.
    private var strip: some View {
        HStack(spacing: Design.Space.snug) {
            HStack(spacing: Design.Space.tight) {
                Image(systemName: "magnifyingglass")
                    .font(Design.Text.detail)
                    .foregroundStyle(.secondary)

                TextField("Search history", text: $query)
                    .textFieldStyle(.plain)
                    .font(Design.Text.detail)
                    .focused($searchFocused)
                    .onKeyPress(.downArrow) { move(by: 1) }
                    .onKeyPress(.upArrow) { move(by: -1) }
                    .onKeyPress(.return) { openHighlighted() }
                    .onKeyPress(.escape) { clearQuery() }
                    // Deliberately no ⌫ binding. The cursor lives in this
                    // field, and a backspace that sometimes edits the search and
                    // sometimes destroys a row depending on where the highlight
                    // happens to be is the worst kind of overload — the two
                    // outcomes are a keystroke apart and only one is
                    // recoverable. Forgetting is the ✕ on the row.

                if !query.isEmpty {
                    Button {
                        query = ""
                        searchFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tertiary)
                    .help("Clear the search")
                }
            }
            .padding(.horizontal, Design.Space.tight)
            .padding(.vertical, Design.Space.hair)
            .frame(width: Metrics.field)
            .background(
                Design.Surface.recessed,
                in: RoundedRectangle(cornerRadius: Design.Radius.small)
            )

            Spacer(minLength: Design.Space.regular)

            clearControl
        }
        // On the same column the rows are on, not on the window's edges. The
        // field filters the list directly under it, and a control whose left
        // edge is 180 points away from the first thing it acts on reads as
        // belonging to the window rather than to the list.
        // Inside the column, matching a row's own inset — and applied *before*
        // the column frame, which is the part that is easy to get wrong. After
        // the centring frame, padding only makes the outer box narrower and the
        // same column re-centres inside it, so the field does not move at all
        // relative to the icons under it. Measured, not reasoned: the first
        // attempt put it after and rendered pixel-identical.
        .padding(.horizontal, Design.Space.snug)
        .frame(maxWidth: Metrics.column)
        .frame(maxWidth: .infinity)
        .padding(.vertical, Design.Space.snug)
    }

    /// How much, then the act. Two controls because they answer two questions,
    /// and the span is restated in the confirmation so nothing is discarded
    /// without it being said out loud one more time.
    ///
    /// `DestructiveButton` rather than a dialog of this page's own: the pairing
    /// of a red label with an asking is what that component exists to make
    /// unforgettable, and a second copy of the pairing is how one of them ends
    /// up without the asking.
    private var clearControl: some View {
        HStack(spacing: Design.Space.tight) {
            Picker("", selection: $span) {
                Text("The Last Hour").tag(HistoryRange.lastHour)
                Text("The Last 24 Hours").tag(HistoryRange.lastDay)
                Text("Everything").tag(HistoryRange.everything)
            }
            .labelsHidden()
            .frame(width: Metrics.span, alignment: .trailing)
            .accessibilityLabel("How much history to clear")

            DestructiveButton(
                title: "Clear",
                question: "Clear \(spanQuestion)?",
                consequence: "\(spanConsequence) This cannot be undone.",
                confirm: "Clear"
            ) {
                model.clearHistory(span)
                highlighted = nil
            }
        }
    }

    private var spanQuestion: String {
        switch span {
        case .lastHour: "the last hour of history"
        case .lastDay: "the last 24 hours of history"
        case .everything: "all history"
        }
    }

    private var spanConsequence: String {
        switch span {
        case .lastHour: "Every page you visited in the last hour will be forgotten."
        case .lastDay: "Every page you visited in the last 24 hours will be forgotten."
        case .everything: "Every page you have visited will be forgotten."
        }
    }

    // MARK: - The list

    private var entries: [HistoryEntry] {
        model.searchHistory(query)
    }

    @ViewBuilder
    private var content: some View {
        // Read once per pass. `entries` crosses the FFI, and a body that asked
        // three times would rank the whole history three times per keystroke.
        let shown = entries

        if shown.isEmpty {
            empty
        } else {
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                        if query.isEmpty {
                            ForEach(days(of: shown)) { day in
                                Section {
                                    rows(day.entries)
                                } header: {
                                    dayHeader(day.title)
                                }
                            }
                        } else {
                            // No day headers over ranked results. The order is
                            // how well each row answers what was typed, and a
                            // header claiming a second ordering on top of it
                            // would say the list is sorted by day when it is
                            // not.
                            rows(shown)
                        }
                    }
                    .frame(maxWidth: Metrics.column)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, Design.Space.regular)
                    .padding(.vertical, Design.Space.snug)
                }
                .onChange(of: highlighted) { _, row in
                    guard let row else { return }
                    withAnimation(nil) { scroll.scrollTo(row, anchor: .center) }
                }
            }
        }
    }

    private func rows(_ entries: [HistoryEntry]) -> some View {
        ForEach(Array(entries.enumerated()), id: \.element.url) { index, entry in
            HistoryRow(
                entry: entry,
                stamp: stamp(entry),
                isHighlighted: entry.url == highlighted,
                open: { open(entry) },
                forget: { forget(entry) }
            )
            .id(entry.url)

            if index < entries.count - 1 {
                Divider().hairline().padding(.leading, Design.Space.section)
            }
        }
    }

    private func dayHeader(_ title: String) -> some View {
        Text(title)
            .sectionHeading()
            .foregroundStyle(.secondary)
            .padding(.horizontal, Design.Space.snug)
            .padding(.vertical, Design.Space.tight)
            .frame(maxWidth: .infinity, alignment: .leading)
            // A material and not a fill: this header sits over rows as they
            // scroll under it, and an opaque bar there reads as a seam.
            .background(.bar)
    }

    /// The first thing anybody sees, because nobody has a history on their
    /// first day. It says what will fill this screen and what the screen will
    /// then be good for.
    private var empty: some View {
        EmptyState(
            icon: query.isEmpty ? "clock" : "magnifyingglass",
            title: query.isEmpty ? "Nothing here yet" : "No matches",
            message: query.isEmpty
                ? "Every page you open lands here, newest first. Search it to find "
                    + "your way back to something you cannot name the address of."
                : "Nothing in your history matches “\(query)”."
        ) {
            if !query.isEmpty {
                Button("Clear the Search") {
                    query = ""
                    searchFocused = true
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Days

    /// A run of entries that share a calendar day.
    private struct Day: Identifiable {
        let id: Date
        let title: String
        let entries: [HistoryEntry]
    }

    /// Group the list into days, in the order the core already put it in.
    ///
    /// Grouped rather than flat because with no query the order *is* time, and
    /// a header every so often is what turns 400 rows into "yesterday
    /// afternoon" — the question people actually bring to a history. It is a
    /// run of consecutive entries and never a re-sort: the ordering stays the
    /// core's, and this only says where one day ends.
    ///
    /// The calendar is `Calendar.current` and so this is the shell's: which day
    /// a moment falls in is a question about somebody's timezone, and the core
    /// has no timezone to answer it with.
    private func days(of entries: [HistoryEntry]) -> [Day] {
        let calendar = Calendar.current
        var out: [Day] = []

        for entry in entries {
            let start = calendar.startOfDay(for: moment(of: entry))
            if let last = out.last, last.id == start {
                out[out.count - 1] = Day(
                    id: start,
                    title: last.title,
                    entries: last.entries + [entry]
                )
            } else {
                out.append(Day(id: start, title: Self.dayName.string(from: start), entries: [entry]))
            }
        }
        return out
    }

    /// "Today", "Yesterday", then the date written out. Relative naming is on,
    /// because the two days anybody is actually looking for have names.
    private static let dayName: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    private func moment(of entry: HistoryEntry) -> Date {
        Date(timeIntervalSince1970: Double(entry.lastVisitMs) / 1000)
    }

    /// The time under a row, and how much of it is said.
    ///
    /// Under a day header the date is already on screen, so the row says the
    /// time and nothing more. In a ranked list there is no header and the rows
    /// are not in date order, so each one carries its own date — otherwise
    /// "09:14" is a time on a day nobody named.
    private func stamp(_ entry: HistoryEntry) -> String {
        let at = moment(of: entry)
        return query.isEmpty
            ? at.formatted(date: .omitted, time: .shortened)
            : at.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: - Keyboard

    /// Every row on screen, in the order they are drawn, which is what the
    /// arrow keys walk.
    private var walkable: [HistoryEntry] { entries }

    private func move(by delta: Int) -> SwiftUI.KeyPress.Result {
        let rows = walkable
        guard !rows.isEmpty else { return .ignored }

        let current = highlighted.flatMap { url in rows.firstIndex { $0.url == url } }
        let next = switch current {
        case let .some(index): min(max(index + delta, 0), rows.count - 1)
        // The first press down picks the top row rather than the second one,
        // and the first press up picks the bottom.
        case .none: delta > 0 ? 0 : rows.count - 1
        }
        highlighted = rows[next].url
        return .handled
    }

    private func openHighlighted() -> SwiftUI.KeyPress.Result {
        guard let entry = walkable.first(where: { $0.url == highlighted }) else { return .ignored }
        open(entry)
        return .handled
    }

    /// Esc empties the field before it does anything else, and only gives the
    /// press up once there is nothing left to clear.
    private func clearQuery() -> SwiftUI.KeyPress.Result {
        guard !query.isEmpty else { return .ignored }
        query = ""
        return .handled
    }

    // MARK: - Acting on a row

    private func open(_ entry: HistoryEntry) {
        model.send(.openTab(space: nil, url: entry.url, parent: nil))
    }

    /// Forgetting a row moves the highlight to whatever takes its place, so a
    /// run of deletes is one key held down rather than a hunt for the list
    /// after every press.
    private func forget(_ entry: HistoryEntry) {
        let rows = walkable
        let index = rows.firstIndex { $0.url == entry.url }
        model.forgetHistory(url: entry.url)

        // The row below, or the row above when there is nothing below. Landing
        // back on the one just forgotten is the bug this arithmetic exists to
        // avoid, and it only shows up on the last row of the list.
        guard let index, rows.count > 1 else {
            highlighted = nil
            return
        }
        highlighted = index + 1 < rows.count ? rows[index + 1].url : rows[index - 1].url
    }
}

/// One page you have been to: what it was called, where it lives, and the two
/// things to do with it.
private struct HistoryRow: View {
    @Environment(BrowserModel.self) private var model
    let entry: HistoryEntry
    let stamp: String
    let isHighlighted: Bool
    let open: () -> Void
    let forget: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: Design.Space.snug) {
            // The icon of the space you are in, because opening the row opens
            // the page in the space you are in. History is one list across every
            // space; the icon cache behind it is not, and this row is honest
            // about which one it is showing.
            SiteBadge(subject: model.badge(forHost: host))

            VStack(alignment: .leading, spacing: Design.Space.line) {
                Text(entry.title ?? entry.url)
                    .font(Design.Text.rowTitle)
                    .lineLimit(1)
                // The one place in this list where the exact string matters —
                // which host, which path — so it is set as a value rather than
                // as prose.
                Text(entry.url)
                    .font(Design.Text.mono)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: Design.Space.regular)

            if entry.visitCount > 1 {
                Text("\(entry.visitCount)×")
                    .font(Design.Text.micro)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }

            Text(stamp)
                .font(Design.Text.micro)
                .foregroundStyle(.tertiary)
                .monospacedDigit()

            // The forget button appears on the row you are pointing at or the
            // row the keyboard is on, rather than on all four hundred at once.
            // A column of crosses down a list reads as a list of things to
            // delete.
            Button(action: forget) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Forget this page")
            .opacity(hovering || isHighlighted ? 1 : 0)
        }
        .padding(.horizontal, Design.Space.snug)
        .padding(.vertical, Design.Space.tight)
        // The row is the width of the column, not the width of what is in it.
        // Without this the trailing time and ✕ end wherever the title happens
        // to stop, so no two rows put them on the same vertical.
        .frame(maxWidth: .infinity)
        // The keyboard's row, marked with a fill rather than with
        // `Palette.selectedRow`: that purple is a *selection* and carries its
        // own ink with it, which would leave a title and a monospaced URL
        // unreadable on top of it. Here the highlight only has to say "this one
        // answers Return", so it stays under the type instead of replacing it.
        .background(
            isHighlighted ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: Design.Radius.small)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
    }

    private var host: String? { URL(string: entry.url)?.host() }
}
