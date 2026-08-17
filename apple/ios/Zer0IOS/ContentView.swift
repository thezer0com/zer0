import SwiftUI
import Zer0Core

/// The browser: one field at the top, the page under it, the tab list beside
/// the page — a column on a regular width, a drawer over it on a compact one
/// (ADR-0123's spelling of the same sidebar).
///
/// The split view this used to be built on owned the drawer's presentation,
/// which meant the system owned how it arrived — and a drawer that arrives
/// like a navigation controller is a drawer that never says it was called
/// up. The two arrangements are laid out by hand instead, so the drawer can
/// wear the same `summoned` arrival the Mac's palette does and the column
/// can simply be there.
struct ContentView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(BrowserModel.self) private var model

    /// Counts New Tab requests — the drawer's row, the empty screen's button.
    /// A counter and not a flag because two presses in a row are two requests,
    /// the same rule `pageSearchRequests` holds on the model.
    @State private var newTabRequests = 0
    /// Whether D1's drawer is open. Read only on compact widths, where the
    /// tab list is presented over the page rather than beside it.
    @State private var drawerOpen = false
    @FocusState private var fieldFocused: Bool

    /// Sizes that belong to this one screen rather than to the whole UI, so
    /// they are named here instead of pretending to be design tokens.
    private enum Metrics {
        /// The regular-width tab column: the width the split view used to
        /// open at, kept because the row titles were measured against it —
        /// about thirty characters, a page title rather than the start of
        /// one (`Sidebar.Metrics.idealWidth` makes the same argument at 260
        /// beside a 1400-point window; a phone-shaped column keeps the
        /// extra room).
        static let columnWidth: CGFloat = 300
        /// The page left showing beside the compact drawer, so the drawer
        /// reads as a panel over the page rather than as a replacement for
        /// it. The widest gap the system names, spent on making the layer
        /// under the drawer visible.
        static let drawerPeek: CGFloat = Design.Space.section
    }

    var body: some View {
        VStack(spacing: 0) {
            AddressBar(
                focused: $fieldFocused,
                newTabRequests: newTabRequests,
                openDrawer: {
                    // The keyboard and the drawer each take the bottom half
                    // of a phone; opening one lets go of the other.
                    fieldFocused = false
                    drawerOpen = true
                }
            )

            content
                .overlay { dimmingScrim }
                .overlay(alignment: .top) { commandPanel }
                // The panel is summoned, so it is summoned *by something*:
                // the scrim and the panel move on the same curve, which is
                // what ties "the page stepped back" to "and this is the
                // reason why" — the Mac's palette says the same sentence
                // with the same two shapes.
                .motion(.entrance, value: panelUp)
        }
        .onAppear { armShotHarness() }
    }

    /// The page, and the tab list beside or over it — D1's two answers to
    /// where the same list goes.
    @ViewBuilder
    private var content: some View {
        if sizeClass == .compact {
            compactContent
        } else {
            regularContent
        }
    }

    /// The macOS arrangement, visible because it can be: the list as layout
    /// beside the page, not over it. What separates the two is colour and an
    /// edge — chrome against background — the same way the Mac's sidebar and
    /// page divide, which is all the split view was drawing for us.
    private var regularContent: some View {
        HStack(spacing: 0) {
            TabDrawer(newTab: startNewTab, close: {})
                .frame(width: Metrics.columnWidth)

            PageArea(startNewTab: startNewTab)
        }
    }

    /// The compact arrangement: the same list over the page, because 393
    /// points have no room beside anything.
    ///
    /// The drawer comes forward rather than sliding in from an edge — a
    /// panel called up over the page, the way the Mac's palette is called
    /// up over the window — and the page it covers steps back on the same
    /// curve, so the two read as one event rather than a panel and a
    /// coincidentally darker page.
    private var compactContent: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                PageArea(startNewTab: startNewTab)

                if drawerOpen {
                    // Tapping the page the drawer stands on closes it: the
                    // dimmed page is the rest of the browser, still live,
                    // and "anywhere but the drawer" is how everyone reads
                    // it. The dimming fades rather than travels — a curtain
                    // sliding in would be a thing in the room.
                    Color.black.opacity(0.15)
                        .onTapGesture { drawerOpen = false }
                        .transition(.opacity)

                    TabDrawer(
                        newTab: {
                            drawerOpen = false
                            startNewTab()
                        },
                        close: { drawerOpen = false }
                    )
                    .frame(width: geometry.size.width - Metrics.drawerPeek)
                    .summoned()
                    // A panel over the page takes the depth a panel over
                    // the page has earned — the same step the download
                    // shelf wears on the Mac.
                    .elevation(Design.Elevation.floating)
                }
            }
        }
        .motion(.entrance, value: drawerOpen)
    }

    /// Whether the field is holding suggestions over the page. An empty
    /// answer gets no panel and no dimming: there is nothing to answer with,
    /// and a dimmed page under a bare field would be the interface holding
    /// its breath.
    private var panelUp: Bool {
        fieldFocused && !model.suggestions.isEmpty
    }

    /// The page stepping back for the panel above it, in the palette's own
    /// gesture — the same 0.15 the Mac's scrim dims by. Tapping the dimmed
    /// page lets the keyboard go: the panel is the field's answer, not a
    /// modal, and leaving focus is how it is dismissed.
    @ViewBuilder
    private var dimmingScrim: some View {
        if panelUp {
            Color.black.opacity(0.15)
                .onTapGesture { fieldFocused = false }
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var commandPanel: some View {
        if panelUp {
            CommandPanel { suggestion in
                model.accept(suggestion)
                fieldFocused = false
            }
            .padding(.horizontal, Design.Space.regular)
            .summoned()
        }
    }

    private func startNewTab() {
        newTabRequests += 1
    }

    // MARK: - The shot harness

    /// The phone's spelling of the Mac's `ZER0_SHOT=1` harnesses. `simctl`
    /// can launch, screenshot and set appearance, but it cannot type and it
    /// cannot tap — and "interface is verified by looking" needs the
    /// interface in the states worth looking at. These arguments drive the
    /// same model calls a person's gestures drive; nothing here renders a
    /// state the app could not reach on its own, and nothing runs without
    /// the flag.
    private func armShotHarness() {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-zer0-shot") else { return }
        if args.contains("-zer0-drawer") { drawerOpen = true }
        // The restored session's tabs closed, so the screen the first day
        // opens on can be photographed. The same close a row's context menu
        // performs, nothing more.
        if args.contains("-zer0-empty") {
            for tab in model.snapshot.tabs { model.close(tab.id) }
        }
    }
}

/// The address field, always on screen (D2): tap and the cursor is in it,
/// type and the core ranks what was typed, Enter and the first row goes.
///
/// macOS summons a field with ⌘L because a bar costs reading room; a phone
/// has no chord to summon anything with, so this field is permanent and
/// carries both jobs — ⌘L's when edited directly, ⌘T's when a New Tab button
/// sent the focus. The ranking, and what Enter does with it, are the core's
/// through the same `suggest`/`accept` pair the macOS bar uses; nothing here
/// has an opinion about either.
struct AddressBar: View {
    @Environment(BrowserModel.self) private var model

    /// The field's focus, owned by the screen so buttons elsewhere can put
    /// the cursor in it. A field that opens has the cursor in it.
    let focused: FocusState<Bool>.Binding
    let newTabRequests: Int
    let openDrawer: () -> Void

    /// Whether this editing session began at a New Tab button. Enter has to
    /// mean different things — `openCommandBar`'s two intents — and where the
    /// session began is the only honest difference between them.
    @State private var draftingNewTab = false

    var body: some View {
        field
            .chromeSurface()
            // The bar's one edge, against the page: everything above it is one
            // surface, and the hairline is where the chrome stops.
            .overlay(alignment: .bottom) { Divider().hairline() }
            .onAppear { armShotHarness() }
    }

    private var field: some View {
        @Bindable var model = model

        return HStack(spacing: Design.Space.tight) {
            Button(action: openDrawer) {
                Text("Tabs")
                    .font(Design.Text.label.weight(.semibold))
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("Show tabs")

            TextField("Search or enter address", text: $model.commandBarQuery)
                .font(Design.Text.rowTitle)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .focused(focused)
                .onSubmit { submit() }
                .padding(.horizontal, Design.Space.tight)
                .padding(.vertical, Design.Space.hair)
                .background { fieldSurface }
                // Focus, said by colour before weight: the capsule takes a
                // hairline in the accent while the cursor is in it and hands
                // it back when the cursor leaves. `subtle` rather than
                // nothing — the ring answering the tap is feedback, and
                // Reduce Motion keeps feedback.
                .motion(.subtle, value: focused.wrappedValue)
        }
        .padding(.horizontal, Design.Space.regular)
        .padding(.vertical, Design.Space.tight)
        .onChange(of: newTabRequests) { _, _ in
            // ⌘T, spelled the way a phone spells it. `openCommandBar` is the
            // one door every editing session enters by; the macOS palette
            // state it also raises is simply unread on this host, where the
            // bar is the field and never a separate panel.
            model.openCommandBar(intent: .openNewTab)
            draftingNewTab = true
            focused.wrappedValue = true
        }
        .onChange(of: focused.wrappedValue) { _, editing in
            guard editing else { return }
            // A tap in the field is ⌘L: seeded from where you are, and Enter
            // moves this tab. The New Tab path seeded itself a moment ago,
            // and re-running this half would clobber the blank it left.
            if !draftingNewTab {
                model.openCommandBar(intent: .navigateCurrentTab)
            }
            draftingNewTab = false
            model.updateSuggestions()
        }
        .onChange(of: model.activeTab) { _, tab in
            // A real address bar shows where you are. Re-seeded only while
            // nobody is editing — a field that overwrote what somebody was
            // typing because a page committed would be a bug wearing a
            // feature's clothes.
            guard !focused.wrappedValue else { return }
            model.commandBarQuery = tab.map { model.addressBarText(of: $0) } ?? ""
            model.updateSuggestions()
        }
        .onAppear {
            // The first frame says where the restored session is.
            model.commandBarQuery = model.activeTab.map { model.addressBarText(of: $0) } ?? ""
            model.updateSuggestions()
        }
    }

    /// The field's capsule: a recess the page is not in, and — while the
    /// cursor is here — an edge in the accent. A focus ring drawn by the
    /// platform would carry the system's colour and the system's weight;
    /// this one carries the palette's.
    @ViewBuilder
    private var fieldSurface: some View {
        let shape = RoundedRectangle(cornerRadius: Design.Radius.medium, style: .continuous)
        ZStack {
            shape.fill(Design.Surface.recessed)
            if focused.wrappedValue {
                shape.strokeBorder(.tint, lineWidth: Design.Stroke.hairline)
            }
        }
    }

    /// Enter takes the first row, which is the row the highlight sits on
    /// when the macOS palette opens. An empty answer is no destination at
    /// all, and the keyboard simply goes — no invented row, no
    /// half-dispatch.
    private func submit() {
        if let first = model.suggestions.first {
            model.accept(first)
        }
        focused.wrappedValue = false
    }

    /// The shot harness's half of this bar: the focused-with-suggestions
    /// state, reached the way a person reaches it. The query is typed into
    /// the same field through the same model calls, and the session is
    /// flagged as already-seeded so the focus does not re-seed it — the
    /// same flag a New Tab press sets, for the same reason.
    private func armShotHarness() {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-zer0-shot"), args.contains("-zer0-suggest") else { return }
        model.openCommandBar(intent: .navigateCurrentTab)
        model.commandBarQuery = "zer0.io"
        model.updateSuggestions()
        draftingNewTab = true
        focused.wrappedValue = true
    }
}
