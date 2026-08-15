import AppKit
import SwiftUI
import Zer0Core

extension BrowserTab {
    /// Presentation only, which is why it lives on this side. Anything that
    /// changes behaviour belongs in the reducer.
    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let url, !url.isEmpty { return url }
        return "New Tab"
    }

    var host: String? {
        guard let url, let parsed = URL(string: url) else { return nil }
        return parsed.host()
    }
}

/// Vertical tabs, grouped the way Arc groups them: favorites that follow you
/// everywhere, pinned tabs that belong to the space, and today's tabs that
/// expire on their own.
///
/// Rows are hand-built rather than a `List`, because the selected row needs to
/// read as *selected* at a glance and the system list style does not go far
/// enough at sidebar size.
struct Sidebar: View {
    /// How wide this column is allowed to be. Read by `BrowserView`, which is
    /// the one place that builds the split, and by the lock that measures what
    /// the column actually got.
    ///
    /// Sizes that belong to this one panel rather than to the whole UI, so they
    /// are named here instead of pretending to be design tokens (DESIGN.md,
    /// "Local metrics"). They were three bare literals at the call site, which
    /// is the one thing that section says is not acceptable — and the number
    /// that matters, the floor, had nothing anywhere saying what it was a floor
    /// *for*.
    enum Metrics {
        /// The narrowest this column may be, and the whole of ADR-0014's
        /// argument stated as a number: a vertical list is worth having because
        /// **the title fits**.
        ///
        /// **Measured, not picked.** A row spends 84pt before the title gets
        /// anything — the badge, the two gaps around it, the spacer, the
        /// trailing control's column, and the row's own padding inside the
        /// list's. SwiftUI's own default for a sidebar column is 140, which
        /// leaves about ten characters: rendered side by side, "Hacker N…",
        /// "Bauhaus…" and "WKWebVi…" are three rows nobody can tell apart, which
        /// is the horizontal tab strip's defect in the other dimension. At 200
        /// it is about twenty-two characters, and the same three rows read.
        static let minWidth: CGFloat = 200
        /// What it opens at: about thirty characters, which is a page title
        /// rather than the start of one.
        static let idealWidth: CGFloat = 260
        /// Past this the sidebar stops being navigation beside a page and
        /// starts being half the window.
        static let maxWidth: CGFloat = 380
    }

    @Environment(BrowserModel.self) private var model
    /// Which window this sidebar belongs to. `nil` until the scene has claimed
    /// an identity, which reads as "the one in front" — the same answer this
    /// list gave before there could be two (ADR-0065).
    @Environment(\.browserWindowId) private var windowId
    @Curves private var motion

    /// Where the two markers live: the fill under the current tab, and the one
    /// under the current space.
    ///
    /// A marker that is one view moving is the difference between "you are here
    /// now" and "you were there, and something else is lit now". Only ever one
    /// of each is on screen, so the pair of `matchedGeometryEffect` ids never
    /// has two sources.
    @Namespace private var markers

    private enum Marker {
        static let tab = "zer0.marker.tab"
        static let space = "zer0.marker.space"
    }

    @State private var renamingSpace: SpaceId?
    @State private var draftName: String = ""
    @State private var hovered: TabId?
    @State private var hoveredSpace: SpaceId?
    @State private var hoveredBookmark: BookmarkId?
    /// How tall the shelf's rows actually are. Zero until the first layout.
    @State private var measuredShelf: CGFloat = 0
    @State private var newTabHovered = false
    /// Set by "Close Space…", cleared when the dialog goes away.
    @State private var closingSpace: SpaceId?

    // MARK: Drag state
    //
    // All of it is preview: what the list looks like mid-gesture. The order
    // after the drop is whatever the core returns, never what these decided.

    /// What the drag looks like right now. Injectable so the same view can be
    /// drawn mid-gesture without one.
    @State private var drag: TabDragState

    @State private var rowFrames: [TabId: TabRowFrame] = [:]
    @State private var sectionFrames: [TabKind: TabSectionFrame] = [:]
    @State private var spaceChipFrames: [SpaceId: CGRect] = [:]
    @State private var listFrame: CGRect = .zero
    @State private var scroll = ScrollPosition(edge: .top)
    @State private var scrollOffset: CGFloat = 0
    @State private var autoscroll: CGFloat = 0
    @State private var autoscrollTask: Task<Void, Never>?
    @State private var escapeMonitor: Any?

    init(drag: TabDragState = TabDragState()) {
        _drag = State(wrappedValue: drag)
    }

    /// Frames are read in this space, so a row measured inside the scroll view
    /// and a chip measured in the space bar can be compared to one another.
    ///
    /// `nonisolated` because geometry is measured off the main actor.
    nonisolated private static let coordinateSpace = "zer0.sidebar"
    /// Only used to read how far the list is scrolled.
    nonisolated private static let scrollSpace = "zer0.sidebar.scroll"

    var body: some View {
        VStack(spacing: 0) {
            // The window has no title bar, so the traffic lights land here.
            // Same height as WindowChrome, so the page top does not jump when
            // the sidebar comes and goes.
            Color.clear.frame(height: WindowChrome.height)

            // A space is a place, not a filter. Switching one used to swap the
            // list in a single frame, which says "the list refreshed"; keyed on
            // the space and given an edge to come from, it says "you moved, and
            // that way". The edge is the direction through the chip row, so the
            // list and the marker under the chips travel the same way at the
            // same time — two signals for one event rather than one signal and
            // one jump.
            //
            // Only the sidebar moves. The page swaps outright, because the
            // thing on the other side of it is a live `WKWebView` and animating
            // one's geometry is how a window switch turns into a stutter.
            //
            // A `ZStack` rather than the list sitting directly in the column:
            // mid-transition two lists exist, and stacked vertically they would
            // ask for twice the height and shove the space bar off the bottom
            // of the window for the length of the animation. Here they overlap,
            // which is also what makes the slide read as one list replacing
            // another rather than two lists queueing. `clipped` keeps the
            // travelling list inside the sidebar instead of over the page.
            ZStack {
                tabs
                    .id(model.snapshot.activeSpace)
                    .transition(spaceArrival)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            bookmarkShelf

            extensionBar

            Divider().hairline().opacity(0.5)
            spaceBar
        }
        .motion(.entrance, value: model.snapshot.activeSpace)
        // Still a system material, over a surface we own. `.thinMaterial` here
        // sampled the desktop — the sidebar came out the colour of whatever
        // photograph was behind the window, in both themes (ADR-0043).
        .chromeSurface()
        .coordinateSpace(.named(Self.coordinateSpace))
        // The line goes over the lifted row, not under it. They land on top of
        // each other constantly — the tab is dropped where the pointer is, and
        // the pointer is carrying the row — and of the two, the line is the one
        // that answers the question.
        .overlay { liftedRow }
        .overlay { insertionLine }
        // A drag that outlives its view would leave the Esc monitor swallowing
        // keystrokes for the rest of the session.
        .onDisappear { endDrag() }
        // Closing a space takes every tab in it and there is no undo, so it
        // asks. Hung on the sidebar rather than on a chip: one dialog, not one
        // per space.
        .confirmationDialog(
            closingSpace.map { "Close “\(model.spaceName($0))”?" } ?? "Close this space?",
            isPresented: Binding(
                get: { closingSpace != nil },
                set: { if !$0 { closingSpace = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Close Space", role: .destructive) {
                if let space = closingSpace { model.closeSpace(space) }
                closingSpace = nil
            }
            Button("Cancel", role: .cancel) { closingSpace = nil }
        } message: {
            Text(closeSpaceWarning)
        }
    }

    /// Tooltips read the keymap instead of hard-coding a chord, so rebinding a
    /// shortcut changes what the sidebar says the way it already changes the
    /// menus.
    private func tip(_ label: String, _ command: UiCommand) -> String {
        guard let chord = model.chord(for: command) else { return label }
        return "\(label) (\(chord.displayString))"
    }

    /// Says what is actually about to be lost. "Are you sure?" is not a
    /// warning, it is a speed bump.
    private var closeSpaceWarning: String {
        guard let space = closingSpace else { return "" }

        return switch model.snapshot.tabs.count(where: { $0.space == space }) {
        case 0: "Nothing is open in it, so nothing else goes with it."
        case 1: "The tab open in it closes too. This cannot be undone."
        case let count: "All \(count) tabs open in it close too. This cannot be undone."
        }
    }

    /// Which way the list travels when the space changes.
    ///
    /// The direction is the core's snapshot, not this view's guess: `spaceTravel`
    /// is read off the two consecutive snapshots, so a space reached by keyboard
    /// arrives from the same side as one reached by clicking its chip.
    ///
    /// `0` — a space closing under you, or the first draw — is a fade. Nothing
    /// travelled, so nothing should look like it did.
    private var spaceArrival: AnyTransition {
        guard model.spaceTravel != 0 else { return .opacity }
        let forward = model.spaceTravel > 0
        return .asymmetric(
            insertion: motion.arrival(from: forward ? .trailing : .leading),
            removal: motion.arrival(from: forward ? .leading : .trailing)
        )
    }

    // MARK: - Tabs

    @ViewBuilder
    private var tabs: some View {
        if isEmpty {
            emptySpace
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    group(model.favoriteTabs(in: windowId), kind: .favorite)
                    group(model.pinnedTabs(in: windowId), kind: .pinned)
                    group(model.todayTabs(in: windowId), kind: .today)

                    // Nothing to drop onto, and it would sit under the pointer
                    // at the exact moment the list needs to read as a list.
                    if !drag.isActive {
                        newTabButton
                    }
                }
                .padding(.horizontal, Design.Space.tight)
                .padding(.bottom, Design.Space.snug)
                .onGeometryChange(for: CGFloat.self) {
                    -$0.frame(in: .named(Self.scrollSpace)).minY
                } action: { scrollOffset = $0 }
            }
            .coordinateSpace(.named(Self.scrollSpace))
            .scrollPosition($scroll)
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named(Self.coordinateSpace))
            } action: { listFrame = $0 }
        }
    }

    /// Favorites follow you between spaces, so "empty" means all three groups
    /// are, not just the ones this space owns.
    private var isEmpty: Bool {
        model.favoriteTabs(in: windowId).isEmpty
            && model.pinnedTabs(in: windowId).isEmpty
            && model.todayTabs(in: windowId).isEmpty
    }

    /// A new space opens on this. Without it the sidebar is a blank panel with
    /// one small button in the corner, which is the worst possible first
    /// impression of the feature the whole browser is built around.
    private var emptySpace: some View {
        EmptyState(
            icon: "rectangle.stack",
            title: "Nothing open here",
            message: "Tabs you open in \(model.activeSpace?.name ?? "this space") stay in it, "
                + "with their own history and their own logins."
        ) {
            Button {
                model.openTab()
            } label: {
                Label("New Tab", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .help(tip("New Tab", .newTab))
        }
    }

    /// The three groups, named in one place so the list and the copy that
    /// floats above a drag can never drift apart.
    private func sectionTitle(_ kind: TabKind) -> String {
        switch kind {
        case .favorite: "Favorites"
        case .pinned: "Pinned"
        case .today: "Today"
        }
    }

    private func sectionHeader(_ kind: TabKind) -> some View {
        Text(sectionTitle(kind))
            .font(Design.Text.micro.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.5)
            .padding(.horizontal, Design.Space.tight)
    }

    @ViewBuilder
    private func group(_ tabs: [BrowserTab], kind: TabKind) -> some View {
        // Mid-drag every section is on screen, empty or not. Dropping a tab
        // under "Pinned" is how anyone would expect to pin one, and a heading
        // that is not there cannot be aimed at.
        if !tabs.isEmpty || drag.isActive {
            sectionHeader(kind)
                .padding(.top, Design.Space.snug)
                .padding(.bottom, Design.Space.hair)

            VStack(alignment: .leading, spacing: 1) {
                if tabs.isEmpty {
                    TabDropWell().padding(.horizontal, Design.Space.tight)
                } else {
                    // A tab is opened and closed dozens of times a day, and
                    // until now the list simply had one more row or one fewer
                    // between two frames. The row grows out of the gap the list
                    // opens for it and collapses back into the gap it leaves,
                    // which is the whole of what has to be said: the list made
                    // room, and then it closed up.
                    ForEach(tabs, id: \.id) { row($0).arrivesInList() }
                }
            }
            .motion(.entrance, value: GroupState(
                ids: tabs.map(\.id),
                active: model.snapshot.activeTab
            ))
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named(Self.coordinateSpace))
            } action: { rect in
                sectionFrames[kind] = TabSectionFrame(
                    kind: kind,
                    minY: rect.minY,
                    maxY: rect.maxY
                )
            }
        }
    }

    /// What a group animates on: which rows it holds, and which one is current.
    ///
    /// Both in one value, and that is not tidiness. `.animation(_:value:)` on an
    /// inner container **replaces** the outer one for everything below it, so
    /// keying the list on its ids here and the marker on the active tab one
    /// level up meant the marker's animation was discarded before it could run:
    /// the fill under the current row would have travelled only on the updates
    /// where the list *also* changed, which is to say almost never. Written
    /// down because the code looked right and the frames are the only reason
    /// anyone would know.
    private struct GroupState: Equatable {
        let ids: [TabId]
        let active: TabId?
    }

    /// What a row shows. Shared with the copy that follows the pointer during a
    /// drag, so the thing being dragged is unmistakably the thing you grabbed.
    private func rowLabel(
        _ tab: BrowserTab,
        isActive: Bool,
        isHovered: Bool,
        isCompanion: Bool = false
    ) -> some View {
        HStack(spacing: Design.Space.tight) {
            // A child tab is indented under its parent, so the tree reads at a
            // glance instead of having to be worked out.
            if tab.parent != nil {
                Color.clear.frame(width: Design.Space.snug)
            }

            // What a row stands for is the model's answer, not this file's. A
            // conversation's row wears the favicon of the page it is about, and
            // a sidebar that worked that out for itself would be the second
            // place that rule lives.
            SiteBadge(subject: model.badge(for: tab))
                .opacity(tab.loadingComplete ? 1 : 0.4)

            Text(tab.displayTitle)
                .font(Design.Text.rowTitle)
                .lineLimit(1)
                .foregroundStyle(isActive || isCompanion ? .primary : .secondary)

            Spacer(minLength: Design.Space.hair)
            trailing(tab, isHovered: isHovered, isCompanion: isCompanion)
        }
        .padding(.horizontal, Design.Space.tight)
        .padding(.vertical, Design.Space.hair)
    }

    private func row(_ tab: BrowserTab) -> some View {
        let isActive = model.snapshot.activeTab == tab.id
        // Hover chrome during a drag is noise: the pointer is somewhere else
        // entirely, and a close button under it is a target nobody wants.
        let isHovered = hovered == tab.id && !drag.isActive
        let isDragging = drag.tab?.id == tab.id
        // On screen beside the focused tab. Without this the sidebar marks one
        // row and the window shows two pages, and the browser is holding two
        // disagreeing pictures of itself.
        let isCompanion = model.isInSplit(tab.id) && !isActive

        return rowLabel(tab, isActive: isActive, isHovered: isHovered, isCompanion: isCompanion)
            .background(background(
                isActive: isActive,
                isHovered: isHovered,
                isCompanion: isCompanion
            ))
            // Hover is an answer to the pointer, so it fades in rather than
            // switching on: a row that lights the instant the pointer crosses
            // its edge reads as a hit test, and one that takes 180ms to do it
            // reads as a surface responding. Bound to the flag and nothing
            // else, so a list mid-reorder is not fighting a second curve.
            .motion(.subtle, value: isHovered)
            .contentShape(Rectangle())
            // The row it came from stays put and fades, so the list still says
            // where the tab was before you picked it up.
            .opacity(isDragging ? 0.3 : 1)
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named(Self.coordinateSpace))
            } action: { rect in
                rowFrames[tab.id] = TabRowFrame(
                    tab: tab.id,
                    kind: tab.kind,
                    space: tab.space,
                    minY: rect.minY,
                    maxY: rect.maxY
                )
            }
            .onTapGesture { model.activate(tab.id) }
            .gesture(dragGesture(tab))
            .onHover { hovered = $0 ? tab.id : (hovered == tab.id ? nil : hovered) }
            .contextMenu { menu(tab) }
            // A tap gesture is invisible to both the keyboard and VoiceOver, so
            // the row has to say on its own that it is a button, whether it is
            // the current one, and how to fire it. `.contain` keeps the close
            // and mute buttons reachable as children instead of flattening them
            // away.
            .focusable()
            .onKeyPress(.return) {
                model.activate(tab.id)
                return .handled
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(tab.displayTitle)
            .accessibilityValue(isCompanion ? "Shown beside the current tab" : "")
            .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { model.activate(tab.id) }
    }

    @ViewBuilder
    private func trailing(_ tab: BrowserTab, isHovered: Bool, isCompanion: Bool) -> some View {
        if !tab.loadingComplete {
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.6)
                .frame(width: Design.Space.regular)
                .accessibilityLabel("Loading")
        } else if tab.playingAudio || tab.muted {
            Button {
                model.toggleMute(tab)
            } label: {
                Image(systemName: tab.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(Design.Text.micro)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .frame(width: Design.Space.regular)
            .help(tab.muted ? "Unmute Tab" : "Mute Tab")
            .accessibilityLabel(tab.muted ? "Unmute Tab" : "Mute Tab")
        } else if isHovered {
            // Close only shows on hover: a permanent × on every row is visual
            // noise you look past anyway.
            Button {
                model.close(tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(Design.Text.micro.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .frame(width: Design.Space.regular)
            .help(tip("Close Tab", .closeTab))
            .accessibilityLabel("Close Tab")
        } else if isCompanion {
            // Quiet, and only on the row that is not the focused one: the
            // marked row already says "this is where you are", and this says
            // "and this one is beside it".
            Image(systemName: "rectangle.split.2x1")
                .font(Design.Text.micro)
                .foregroundStyle(.secondary)
                .frame(width: Design.Space.regular)
                .help("Shown beside the current tab")
                .accessibilityHidden(true)
        }
    }

    /// What is drawn behind a row: at most one mark of rank, and the pointer's
    /// answer under it.
    ///
    /// The selected fill is one view that moves rather than one that is painted
    /// out here and painted in over there. Arrowing through a list of tabs is
    /// the most repeated gesture in the sidebar, and a marker that travels says
    /// "this is the same cursor, one row down"; a marker that blinks says "two
    /// unrelated rows changed colour and you work out which one you are on".
    /// Exactly one row can be active, so the shared id never has two sources.
    @ViewBuilder
    private func background(isActive: Bool, isHovered: Bool, isCompanion: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous)

        ZStack {
            if isHovered, !isActive, !isCompanion {
                shape.fill(.primary.opacity(0.06))
            }
            if isCompanion {
                // The same colour as the selected row and plainly less of it:
                // both pages are on screen, one of them has the keyboard.
                shape.fill(Design.Palette.companionRow)
            }
            if isActive {
                // Ours, not the system's. `.selection` resolves to whatever
                // accent macOS is set to, which left the most-looked-at surface
                // in the product outside the palette entirely (ADR-0043).
                shape.fill(Design.Palette.selectedRow)
                    .matchedGeometryEffect(id: Marker.tab, in: markers)
            }
        }
    }

    @ViewBuilder
    private func menu(_ tab: BrowserTab) -> some View {
        if tab.kind != .favorite {
            Button("Add to Favorites") { model.setKind(tab.id, .favorite) }
        }
        if tab.kind != .pinned {
            Button("Pin to Space") { model.setKind(tab.id, .pinned) }
        }
        if tab.kind != .today {
            Button("Unpin") { model.setKind(tab.id, .today) }
        }

        Divider()
        splitItem(tab)

        if model.snapshot.spaces.count > 1 {
            Divider()
            Menu("Move to Space") {
                ForEach(model.snapshot.spaces.filter { $0.id != tab.space }, id: \.id) { space in
                    Button(space.name) { model.move(tab.id, to: space.id, index: 0) }
                }
            }
        }

        Divider()
        Button("Copy Address") { model.copyURL(of: tab.id) }
        Button("Close Tab", role: .destructive) { model.close(tab.id) }
    }

    /// Bringing a tab in beside the current one, or putting the pair away.
    ///
    /// Absent rather than disabled for a tab in another space: a favorite
    /// follows you everywhere but still belongs to one cookie jar, and two
    /// panes drawing from two jars would be one window claiming to be two.
    @ViewBuilder
    private func splitItem(_ tab: BrowserTab) -> some View {
        if model.isInSplit(tab.id) {
            Button("Close Split") { model.toggleSplit() }
        } else if let active = model.snapshot.activeTab,
                  active != tab.id,
                  tab.space == model.snapshot.activeSpace
        {
            Button("Open in Split") { model.splitWith(tab.id) }
        }
    }

    /// The sidebar's main action, so it is allowed to look like one. It used to
    /// be tertiary grey: the thing you are most likely to want was the faintest
    /// thing on screen.
    private var newTabButton: some View {
        Button {
            model.openTab()
        } label: {
            HStack(spacing: Design.Space.tight) {
                Image(systemName: "plus")
                    .font(Design.Text.label.weight(.semibold))
                    // Same width as a SiteBadge, so the label lines up with the
                    // titles above it rather than nearly lining up.
                    .frame(width: Design.Space.regular)
                Text("New Tab").font(Design.Text.rowTitle)
                Spacer()
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, Design.Space.tight)
            .padding(.vertical, Design.Space.hair)
            .background {
                RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous)
                    .fill(.primary.opacity(newTabHovered ? 0.1 : 0.05))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .padding(.top, Design.Space.tight)
        .onHover { newTabHovered = $0 }
        .help(tip("New Tab", .newTab))
        .motion(.subtle, value: newTabHovered)
    }

    // MARK: - Dragging

    /// Picking a row up.
    ///
    /// A plain drag gesture rather than the system's drag-and-drop: on macOS a
    /// list is scrolled with the wheel, not by dragging, so nothing here is
    /// competing with the scroll view — and owning the gesture is what makes an
    /// insertion line, an Esc, and an edge that scrolls possible at all.
    private func dragGesture(_ tab: BrowserTab) -> some Gesture {
        DragGesture(
            minimumDistance: Design.Space.hair,
            coordinateSpace: .named(Self.coordinateSpace)
        )
        .onChanged { value in
            // Esc already ended this one. The button is still down, so without
            // this the next pixel of movement would start it over.
            guard !drag.cancelled else { return }
            if !drag.isActive { beginDrag(tab) }
            drag.pointer = value.location
            updateTarget()
        }
        .onEnded { _ in
            if !drag.cancelled { commitDrag() }
            endDrag()
            // Here and nowhere else: this is the mouse coming up, which is the
            // only moment a cancelled drag is really over. Clearing it any
            // earlier lets the next pixel of movement start it again.
            drag.cancelled = false
        }
    }

    private func beginDrag(_ tab: BrowserTab) {
        drag.tab = tab
        hovered = nil
        startAutoscroll()
        watchForEscape()
    }

    /// Work out where the drop would land, given where the pointer is.
    private func updateTarget() {
        guard let tab = drag.tab else { return }

        // The space bar wins whenever the pointer is over it. Dropping on a
        // space is a different intent from dropping in the list, and the two
        // targets must never both be lit.
        if let chip = spaceChipFrames.first(where: { $0.value.contains(drag.pointer) })?.key {
            // The tab's own space is not a destination, so nothing lights up —
            // rather than the list quietly keeping a slot the pointer left
            // behind and dropping the tab somewhere it was never aimed.
            let target = chip == tab.space ? nil : chip
            if drag.space != target || drag.slot != nil {
                withAnimation(motion.subtle) {
                    drag.space = target
                    drag.slot = nil
                }
            }
            autoscroll = 0
            return
        }

        // Only what is on screen counts. A lazy list keeps frames for rows that
        // have scrolled away, and aiming at one of those would put the line
        // somewhere the person cannot see.
        let visible = rowFrames.values.filter {
            listFrame.isEmpty || ($0.midY >= listFrame.minY && $0.midY <= listFrame.maxY)
        }
        let next = TabDrop.slot(
            at: drag.pointer.y,
            dragging: tab,
            rows: Array(visible),
            sections: Array(sectionFrames.values),
            activeSpace: model.snapshot.activeSpace
        )
        if next != drag.slot || drag.space != nil {
            withAnimation(motion.subtle) {
                drag.slot = next
                drag.space = nil
            }
        }
        autoscroll = autoscrollDirection()
    }

    /// Which way to scroll, when the pointer is dragged against an edge of the
    /// list. Without this a long list can only be reordered as far as the
    /// window is tall.
    private func autoscrollDirection() -> CGFloat {
        guard !listFrame.isEmpty else { return 0 }

        if drag.pointer.y < listFrame.minY + Design.Space.section { return -1 }
        if drag.pointer.y > listFrame.maxY - Design.Space.section { return 1 }
        return 0
    }

    private func startAutoscroll() {
        autoscrollTask?.cancel()
        autoscrollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                guard autoscroll != 0 else { continue }
                scroll.scrollTo(y: max(0, scrollOffset + autoscroll * Design.Space.tight))
            }
        }
    }

    /// Esc closes. Always — including a drag that is still under the pointer.
    ///
    /// A monitor rather than `.onKeyPress`, because a key press only reaches a
    /// view that has focus, and during a drag focus is wherever it was before
    /// the mouse went down.
    private func watchForEscape() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 53 is Escape. There is no symbolic constant for a hardware key
            // code, and matching on the character fails once a modifier is held.
            guard event.keyCode == 53 else { return event }
            cancelDrag()
            return nil
        }
    }

    private func cancelDrag() {
        guard drag.isActive else { return }
        drag.cancelled = true
        endDrag()
    }

    private func commitDrag() {
        guard let tab = drag.tab else { return }

        // Dropped on a space chip: the tab arrives at the end of that space's
        // Today list, which is where a tab that has just turned up belongs.
        if let space = drag.space, space != tab.space {
            withAnimation(motion.entrance) {
                model.drop(tab.id, into: TabDropSlot(
                    kind: .today,
                    space: space,
                    before: nil,
                    y: 0,
                    crossesSpace: true
                ))
            }
            return
        }
        guard let slot = drag.slot else { return }
        // Animated here rather than on the list, so the rows settle into the
        // order the core just handed back instead of appearing in it.
        withAnimation(motion.entrance) { model.drop(tab.id, into: slot) }
    }

    private func endDrag() {
        withAnimation(motion.subtle) { drag.clear() }
        autoscroll = 0
        autoscrollTask?.cancel()
        autoscrollTask = nil

        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
    }

    @ViewBuilder
    private var insertionLine: some View {
        if drag.isActive, drag.space == nil, let slot = drag.slot {
            TabInsertionLine(
                destination: slot.crossesSpace ? model.spaceName(slot.space) : nil
            )
            .padding(.horizontal, Design.Space.regular)
            .offset(y: slot.y - Design.Stroke.insertion / 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    /// The row itself, under the pointer.
    ///
    /// A floating layer, and it behaves like one: it is opaque, it carries a
    /// shadow, and it covers whatever it happens to be over — a heading
    /// included. That is what every list with a drag does, and nobody is
    /// confused by it, because the shadow says "this is on top of the list, not
    /// part of it". Covering something for a moment is legible. Two strings
    /// blended into each other is not, which is what a translucent card or a
    /// heading redrawn over it produces.
    ///
    /// Solid fill rather than a material for exactly that reason: if the
    /// heading can be read through the card, the problem is back in another
    /// form.
    @ViewBuilder
    private var liftedRow: some View {
        if let tab = drag.tab {
            GeometryReader { geometry in
                rowLabel(tab, isActive: false, isHovered: false)
                    .background {
                        RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    }
                    // Neutral, not tinted. The card's top edge and the
                    // insertion line sit on top of each other for most of a
                    // drag, and two blue horizontals there are one blue
                    // horizontal too many: the accent has to mean exactly one
                    // thing, and that thing is where the tab lands.
                    .overlay {
                        RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous)
                            .strokeBorder(.primary.opacity(0.12), lineWidth: Design.Stroke.hairline)
                    }
                    // The step for a thing that has left the surface and only
                    // just: the card is lifted out of the list it came from,
                    // not floating over a page. It was written out by hand at
                    // this exact radius and offset with a darker cast, which is
                    // a fourth depth by opacity alone — and a scale with a
                    // fourth step nobody named is not a scale.
                    .elevation(Design.Elevation.resting)
                    .scaleEffect(1.03)
                    .frame(width: geometry.size.width - Design.Space.regular)
                    .position(x: geometry.size.width / 2, y: liftedRowY)
            }
            .allowsHitTesting(false)
            .transition(.opacity)
            .motion(.subtle, value: drag.space)
        }
    }

    /// Where the lifted row floats.
    ///
    /// Under the pointer, where the person picked it up. It used to be held a
    /// row below to keep off the insertion line; that is what the z-order is
    /// for. A fixed offset makes the card swim against the cursor, which is a
    /// worse thing to feel than a heading being covered is to look at.
    ///
    /// The one exception is the space bar: there the card parks above it, so
    /// the chip it is about to fall into stays visible. The chip is the drop
    /// indicator in that mode, and the drop indicator is the one thing the card
    /// never gets to cover.
    private var liftedRowY: CGFloat {
        if drag.space != nil, !listFrame.isEmpty {
            return listFrame.maxY - Design.Space.loose
        }
        return drag.pointer.y
    }

    // MARK: - Kept pages

    /// Sizes that belong to this shelf rather than to the whole UI.
    private enum Shelf {
        /// How much of the sidebar the shelf may take when it is unrolled.
        ///
        /// A ceiling rather than a share, because the list above it is the
        /// primary navigation (ADR-0014) and a shelf that grew with its own
        /// contents would eventually be the sidebar. Past this it scrolls,
        /// which is what a ceiling is for.
        static let maxHeight: CGFloat = 220
        /// The glyph column, matching a row's `SiteBadge` so titles line up
        /// with the tab titles above rather than nearly lining up.
        static let markColumn: CGFloat = Design.Space.regular
        /// What a row is assumed to be tall before anything has been measured:
        /// a title, sometimes a line of labels, and `hair` above and below.
        static let estimatedRow: CGFloat = 36
    }

    /// Kept pages, on a shelf that is rolled up until it is asked for.
    ///
    /// **Not a fourth tab group**, and that is the decision rather than the
    /// layout. ADR-0014 says the sidebar's three groups become "a list of lists
    /// that needs collapsing" at four, and it is right — but the deeper reason
    /// is that those three groups are lists of *tabs*, things with a web view
    /// behind them, and the whole point of a bookmark is that it has none. A
    /// kept page in that list would be a row that looks like a tab, sorts like
    /// a tab, and does not behave like one.
    ///
    /// So it sits below the list, above the spaces, and costs one row when it
    /// is shut (ADR-0059). Which is the promise: keeping a page does not cost you room in
    /// the thing you look at all day.
    @ViewBuilder
    private var bookmarkShelf: some View {
        Divider().hairline().opacity(0.5)

        VStack(alignment: .leading, spacing: 0) {
            shelfHeader

            if model.bookmarksVisible {
                if model.bookmarks.isEmpty {
                    emptyShelf
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(model.bookmarks, id: \.id) { bookmark in
                                shelfRow(bookmark)
                            }
                        }
                        .padding(.horizontal, Design.Space.tight)
                        .padding(.bottom, Design.Space.tight)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                            measuredShelf = $0
                        }
                    }
                    // Not `maxHeight`. A `ScrollView` takes every point it is
                    // offered, so a ceiling alone gave four rows the same band
                    // of sidebar as twelve — ninety points of empty material
                    // under the last one, which was visible the first time
                    // anybody rendered it. As tall as its rows, up to the
                    // ceiling; past that it scrolls, which is what the ceiling
                    // was always for.
                    .frame(height: shelfHeight)
                    .scrollBounceBehavior(.basedOnSize)
                }
            }
        }
        // Rolling up and down is the shelf moving, not two shelves swapping.
        .motion(.entrance, value: model.bookmarksVisible)
        .motion(.subtle, value: model.bookmarks.count)
    }

    /// How tall the open shelf is allowed to be right now.
    ///
    /// The estimate is used for exactly one layout pass, before anything has
    /// been measured, so the first frame is roughly right rather than either
    /// zero-height or full-height.
    private var shelfHeight: CGFloat {
        let content = measuredShelf > 0
            ? measuredShelf
            : CGFloat(model.bookmarks.count) * Shelf.estimatedRow
        return min(content, Shelf.maxHeight)
    }

    private var shelfHeader: some View {
        Button {
            model.bookmarksVisible.toggle()
        } label: {
            HStack(spacing: Design.Space.tight) {
                Image(systemName: "chevron.right")
                    .font(Design.Text.micro.weight(.semibold))
                    .rotationEffect(.degrees(model.bookmarksVisible ? 90 : 0))
                    .frame(width: Design.Space.snug)
                Text("Kept")
                    .font(Design.Text.micro.weight(.semibold))
                    .textCase(.uppercase)
                    .tracking(0.5)
                Spacer()
                // Said only when there is something to say. "0" is a number
                // nobody needs and a label that draws the eye to an absence.
                if !model.bookmarks.isEmpty {
                    Text("\(model.bookmarks.count)")
                        .font(Design.Text.micro)
                        .monospacedDigit()
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, Design.Space.snug)
            .padding(.vertical, Design.Space.tight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .help(tip("Kept Pages", .toggleBookmarks))
        .accessibilityLabel("Kept pages, \(model.bookmarks.count)")
    }

    /// The shelf with nothing on it, which is what everyone sees on day one.
    ///
    /// It says what the shelf is *for* and which key fills it, because an
    /// empty list that only says it is empty has taught nobody anything. The
    /// sentence is the distinction the whole feature rests on: this keeps the
    /// page without keeping the tab.
    private var emptyShelf: some View {
        VStack(alignment: .leading, spacing: Design.Space.hair) {
            Text("Nothing kept yet")
                .font(Design.Text.label.weight(.medium))
            Text("\(shelfChord) keeps the page you are on. It stays here after the tab is gone.")
                .font(Design.Text.micro)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Design.Space.snug)
        .padding(.bottom, Design.Space.snug)
    }

    /// Read off the keymap rather than written as "⌘D", so rebinding it changes
    /// what the empty state teaches.
    private var shelfChord: String {
        model.chord(for: .addBookmark)?.displayString ?? "Keep This Page"
    }

    private func shelfRow(_ bookmark: Bookmark) -> some View {
        let isHovered = hoveredBookmark == bookmark.id

        return Button {
            // A kept page opens somewhere new by default: you went looking for
            // it, you did not ask to lose the page you were on.
            model.openBookmark(bookmark, inNewTab: !NSEvent.modifierFlags.contains(.option))
        } label: {
            HStack(spacing: Design.Space.tight) {
                SiteBadge(subject: model.badge(forHost: bookmark.host))
                    .frame(width: Shelf.markColumn)

                VStack(alignment: .leading, spacing: Design.Space.line) {
                    Text(bookmark.displayTitle)
                        .font(Design.Text.row)
                        .lineLimit(1)
                    // Labels only when there are any. A row that reserves space
                    // for a second line it usually has nothing to put on is a
                    // list with a hole down the middle of it.
                    if !bookmark.tags.isEmpty {
                        Text(bookmark.tags.joined(separator: " · "))
                            .font(Design.Text.micro)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, Design.Space.tight)
            .padding(.vertical, Design.Space.hair)
            .background {
                RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous)
                    .fill(.primary.opacity(isHovered ? 0.08 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .onHover { hoveredBookmark = $0 ? bookmark.id : nil }
        .motion(.subtle, value: isHovered)
        .help(bookmark.url)
        .contextMenu {
            Button("Open in New Tab") { model.openBookmark(bookmark) }
            Button("Open Here") { model.openBookmark(bookmark, inNewTab: false) }
            Divider()
            Button("Rename…") { model.beginRenaming(bookmark) }
            Button("Copy Link") { model.copy(bookmark.url) }
            Divider()
            // Destructive, and marked as such: this is the only thing in the
            // browser that throws away something somebody deliberately kept.
            Button("Remove", role: .destructive) { model.forget(bookmark) }
        }
        .accessibilityLabel(bookmark.displayTitle)
    }

    // MARK: - Extension buttons

    /// The extensions somebody keeps to hand, above the spaces.
    ///
    /// Here rather than over the page, and the argument is ADR-0068's: the
    /// sidebar's width is already spent, so a row inside it costs the page
    /// nothing, and it lands beside the space chips because those are the other
    /// row of small always-available controls — two rows of furniture at the
    /// bottom, under the list of places, which is the shape this panel already
    /// had.
    ///
    /// Above the divider the space bar already draws, so nothing is added when
    /// the row is empty: with no extensions pinned this is not a thinner strip,
    /// it is no strip.
    @ViewBuilder
    private var extensionBar: some View {
        if !model.pinnedExtensions.isEmpty {
            Divider().hairline().opacity(0.5)

            ExtensionActionBar(ink: .primary, popoverEdge: .maxX)
                .padding(.horizontal, Design.Space.snug)
                .padding(.vertical, Design.Space.tight)
        }
    }

    // MARK: - Spaces

    /// Spaces live at the bottom, near the thumb, and read as a set of places
    /// rather than a list of settings.
    private var spaceBar: some View {
        HStack(spacing: Design.Space.hair) {
            // The chips scroll and the + does not. In one row, six spaces
            // squeezed every name down to "S…" and pushed the only control that
            // makes a seventh off the edge of the sidebar.
            ScrollView(.horizontal) {
                HStack(spacing: Design.Space.hair) {
                    ForEach(model.snapshot.spaces, id: \.id) { space in
                        spaceChip(space)
                    }
                }
            }
            .scrollIndicators(.hidden)
            // Without this the scroll view claims the height it is offered and
            // the space bar eats the tab list.
            .fixedSize(horizontal: false, vertical: true)

            newSpaceButton
        }
        .padding(.horizontal, Design.Space.snug)
        .padding(.vertical, Design.Space.tight)
    }

    private var newSpaceButton: some View {
        Button {
            model.createSpace(named: "Space \(model.snapshot.spaces.count + 1)")
        } label: {
            Image(systemName: "plus")
                .font(Design.Text.label.weight(.semibold))
                .frame(width: Design.Space.loose, height: Design.Space.loose)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .foregroundStyle(.secondary)
        .help(tip("New Space", .newSpace))
        .accessibilityLabel("New Space")
    }

    /// What the chip says about itself, including the chord that reaches it.
    ///
    /// The chip is where somebody finds out ⌃3 exists at all: there is no menu
    /// item for a numbered space any more than there is for ⌘1, and the
    /// Shortcuts pane is a place you go only if you already suspect. Read off
    /// the keymap rather than written as "⌃3", so rebinding does not leave a lie
    /// behind — the same arrangement an extension button's tooltip has
    /// (ADR-0068), down to what happens past the ninth: nothing is printed,
    /// because there is no chord to print rather than one that does nothing.
    private func spaceTip(_ space: Space) -> String {
        let name = space.profile.ephemeral ? "\(space.name) — keeps nothing" : space.name
        guard let position = model.snapshot.spaces.firstIndex(where: { $0.id == space.id }),
              // `exactly:` rather than a cast: somebody with 300 spaces would
              // otherwise trap here, and a tooltip is not worth a crash.
              let index = UInt8(exactly: position + 1),
              let chord = model.chord(for: .selectSpace(index: index))
        else { return name }
        return "\(name) (\(chord.displayString))"
    }

    private func spaceChip(_ space: Space) -> some View {
        let isActive = space.id == model.snapshot.activeSpace
        let isHovered = hoveredSpace == space.id && !drag.isActive
        let isTarget = drag.space == space.id
        // Every space but the one the tab already lives in is somewhere it
        // could go, and saying so mid-drag is what makes the space bar a target
        // rather than a row of buttons that happen to be down there.
        let isOffered = drag.tab.map { $0.space != space.id } ?? false

        return Button {
            model.activate(space: space.id)
        } label: {
            HStack(spacing: Design.Space.hair) {
                if space.profile.ephemeral {
                    // A space that keeps nothing should say so before you log
                    // into something in it.
                    Image(systemName: "eye.slash.fill")
                        .font(Design.Text.micro)
                }
                Text(space.name)
                    .font(Design.Text.label.weight(isActive ? .semibold : .regular))
                    .lineLimit(1)
            }
            // The same two states as a tab row, for the same reason: selected
            // takes the palette's selected fill, everything else is legible
            // secondary text. Switching space is the largest move in the
            // sidebar, so it cannot be the faintest thing in it.
            .foregroundStyle(isActive ? .primary : .secondary)
            .padding(.horizontal, Design.Space.tight)
            .padding(.vertical, Design.Space.hair)
            .background {
                if isTarget {
                    Capsule().fill(.tint.opacity(0.3))
                } else if isActive {
                    // The other half of what makes switching a space read as
                    // moving: this fill is one capsule that travels along the
                    // row to the chip you picked, in the same direction and on
                    // the same curve as the list behind it. Two things saying
                    // one thing.
                    Capsule().fill(Design.Palette.selectedRow)
                        .matchedGeometryEffect(id: Marker.space, in: markers)
                } else if isHovered {
                    Capsule().fill(.primary.opacity(0.06))
                }
            }
            .overlay {
                if isTarget {
                    Capsule().strokeBorder(.tint, lineWidth: Design.Stroke.insertion)
                } else if isOffered {
                    Capsule().strokeBorder(
                        .tint.opacity(0.3),
                        style: StrokeStyle(
                            lineWidth: Design.Stroke.hairline,
                            dash: [Design.Space.hair, Design.Space.hair]
                        )
                    )
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.pressable)
        // A space is a bigger destination than a row, so it answers bigger.
        .scaleEffect(isTarget ? 1.08 : 1)
        .motion(.entrance, value: isTarget)
        .motion(.subtle, value: isHovered)
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .named(Self.coordinateSpace))
        } action: { spaceChipFrames[space.id] = $0 }
        .onHover {
            hoveredSpace = $0 ? space.id : (hoveredSpace == space.id ? nil : hoveredSpace)
        }
        .help(spaceTip(space))
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .contextMenu { spaceMenu(space) }
        .popover(isPresented: Binding(
            get: { renamingSpace == space.id },
            set: { if !$0 { renamingSpace = nil } }
        )) {
            renamePopover(space)
        }
    }

    @ViewBuilder
    private func spaceMenu(_ space: Space) -> some View {
        Button("Rename…") {
            draftName = space.name
            renamingSpace = space.id
        }
        Toggle("Ephemeral", isOn: Binding(
            get: { space.profile.ephemeral },
            set: { on in
                model.setProfile(space.id, SpaceProfile(
                    userAgent: space.profile.userAgent,
                    ephemeral: on
                ))
            }
        ))
        Divider()
        // The ellipsis is a promise: something else happens before anything is
        // destroyed.
        Button("Close Space…", role: .destructive) {
            closingSpace = space.id
        }
        // Refusing here rather than letting the core silently ignore it keeps
        // the menu honest.
        .disabled(model.snapshot.spaces.count <= 1)
    }

    private func renamePopover(_ space: Space) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.snug) {
            Text("Rename Space")
                .font(Design.Text.sectionTitle)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.6)

            // A rename that needs a click into the field and a ⌘A before you
            // can type is not a rename, it is paperwork. `@FocusState` does not
            // win this against the web view underneath; `CommandBarField` takes
            // first responder and selects what is there.
            CommandBarField(
                text: $draftName,
                // Sized and worded for a rename field: the command bar's 20pt
                // "Search or enter address" was leaking in here.
                fontSize: 13,
                placeholder: "Space name",
                onSubmit: { commitRename(space) },
                onCancel: { renamingSpace = nil },
                onMove: { _ in }
            )
            .frame(width: 220, height: 28)

            HStack(spacing: Design.Space.tight) {
                Spacer()
                Button("Cancel") { renamingSpace = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { commitRename(space) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedDraft.isEmpty)
            }
        }
        .padding(Design.Space.regular)
    }

    private var trimmedDraft: String {
        draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commitRename(_ space: Space) {
        // A blank name leaves a chip you can neither read nor aim at, so it is
        // not a rename worth performing.
        guard !trimmedDraft.isEmpty else { return }
        model.rename(space: space.id, to: trimmedDraft)
        renamingSpace = nil
    }
}
