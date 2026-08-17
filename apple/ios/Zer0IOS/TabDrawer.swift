import SwiftUI
import Zer0Core

/// The tab list both widths show: the same groups — favorites, pinned, today
/// — in the same order the macOS sidebar draws them, over the same space bar
/// (D1). One view for both, because two lists of the same tabs are two lists
/// that drift; what differs is only where it is put, which is the split
/// view's business and not this file's.
struct TabDrawer: View {
    @Environment(BrowserModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass

    let newTab: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if isEmpty {
                emptySpace
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        group(model.favoriteTabs(), kind: .favorite)
                        group(model.pinnedTabs(), kind: .pinned)
                        group(model.todayTabs(), kind: .today)
                        newTabButton
                    }
                    .padding(.horizontal, Design.Space.tight)
                    .padding(.bottom, Design.Space.snug)
                }
            }

            // Spaces at the bottom, near the thumb — the same placement the
            // macOS sidebar gives them, for the same reason: they are a set
            // of places, not a list of settings. The rule above them is the
            // one the Mac wears between its list and its chips, quiet at
            // half strength so it reads as a seam and not a border.
            Divider().hairline().opacity(0.5)
            spaceBar
        }
        .chromeSurface()
    }

    /// Favorites follow you between spaces, so "empty" means all three groups
    /// are, not just the ones this space owns. The same rule, in the model's
    /// own words.
    private var isEmpty: Bool {
        model.favoriteTabs().isEmpty
            && model.pinnedTabs().isEmpty
            && model.todayTabs().isEmpty
    }

    @ViewBuilder
    private func group(_ tabs: [BrowserTab], kind: TabKind) -> some View {
        if !tabs.isEmpty {
            Text(sectionTitle(kind))
                .font(Design.Text.micro.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
                .padding(.horizontal, Design.Space.tight)
                .padding(.top, Design.Space.snug)
                .padding(.bottom, Design.Space.hair)

            VStack(alignment: .leading, spacing: 1) {
                ForEach(tabs, id: \.id) { row($0) }
            }
        }
    }

    /// The three groups, named as the macOS sidebar names them, so the two
    /// hosts say the same words about the same rows.
    private func sectionTitle(_ kind: TabKind) -> String {
        switch kind {
        case .favorite: "Favorites"
        case .pinned: "Pinned"
        case .today: "Today"
        }
    }

    private func row(_ tab: BrowserTab) -> some View {
        let isActive = model.snapshot.activeTab == tab.id

        // A button rather than a tap gesture so the touch is answered the
        // moment it lands — the press dip is the answer to "did it hear me",
        // and feedback delivered after the click has already happened is too
        // late to be feedback.
        return Button {
            select(tab)
        } label: {
            HStack(spacing: Design.Space.tight) {
                // A child tab indented under its parent, so the tree reads at
                // a glance — the same cue the macOS row carries.
                if tab.parent != nil {
                    Color.clear.frame(width: Design.Space.snug)
                }

                // What a row stands for is the model's answer, not this file's:
                // a conversation wears the favicon of the page it is about, and a
                // second copy of that rule here is where the two hosts would
                // start to disagree.
                SiteBadge(subject: model.badge(for: tab))
                    .opacity(tab.loadingComplete ? 1 : 0.4)

                Text(tab.displayTitle)
                    .font(Design.Text.rowTitle)
                    .lineLimit(1)
                    .foregroundStyle(isActive ? .primary : .secondary)

                Spacer(minLength: Design.Space.hair)

                if !tab.loadingComplete {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.6)
                        .accessibilityLabel("Loading")
                }
            }
            .padding(.horizontal, Design.Space.tight)
            .padding(.vertical, Design.Space.hair)
            .background {
                if isActive {
                    RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous)
                        .fill(Design.Palette.selectedRow)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(tab.displayTitle)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    private func select(_ tab: BrowserTab) {
        model.activate(tab.id)
        // Choose-and-close is the drawer's whole gesture; the regular-width
        // column has nothing to close (D1).
        if sizeClass == .compact { close() }
    }

    /// The drawer's main action, and the one control in it allowed to look
    /// like one. Where it sends you is the field, seeded blank: opening a tab
    /// and asking where to are the same gesture on a phone.
    private var newTabButton: some View {
        Button(action: newTab) {
            HStack(spacing: Design.Space.tight) {
                Text("New Tab").font(Design.Text.rowTitle)
                Spacer()
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, Design.Space.tight)
            .padding(.vertical, Design.Space.hair)
            .background {
                RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous)
                    .fill(.primary.opacity(0.05))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .padding(.top, Design.Space.tight)
    }

    private var emptySpace: some View {
        EmptyState(
            glyph: {
                Zer0MarkGlyph(side: Design.Glyph.icon)
                    .foregroundStyle(.tertiary)
            },
            title: "Nothing open here",
            message: "Tabs you open in \(model.activeSpace?.name ?? "this space") stay in it, "
                + "with their own history and their own logins."
        ) {
            Button("New Tab", action: newTab)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Spaces

    private var spaceBar: some View {
        HStack(spacing: Design.Space.hair) {
            // The chips scroll and the + does not, so six spaces cannot push
            // the only control that makes a seventh off the edge.
            ScrollView(.horizontal) {
                HStack(spacing: Design.Space.hair) {
                    ForEach(model.snapshot.spaces, id: \.id) { space in
                        spaceChip(space)
                    }
                }
            }
            .scrollIndicators(.hidden)
            // Without this the scroll view claims the height it is offered
            // and the space bar eats the tab list.
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
            // Typography, not an icon: "+" as set text, because the licensed
            // set carries no plus yet and an SF Symbol here would be the one
            // keystroke ADR-0116 budgets against.
            Text("+")
                .font(Design.Text.label.weight(.semibold))
                .frame(width: Design.Space.loose, height: Design.Space.loose)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .foregroundStyle(.secondary)
        .accessibilityLabel("New Space")
    }

    private func spaceChip(_ space: Space) -> some View {
        let isActive = space.id == model.snapshot.activeSpace

        return Button {
            model.activate(space: space.id)
        } label: {
            HStack(spacing: Design.Space.hair) {
                Text(space.name)
                    .font(Design.Text.label.weight(isActive ? .semibold : .regular))
                    .lineLimit(1)
            }
            // The same two states as a tab row: selected takes the palette's
            // selected fill, everything else is legible secondary text.
            .foregroundStyle(isActive ? .primary : .secondary)
            .padding(.horizontal, Design.Space.tight)
            .padding(.vertical, Design.Space.hair)
            .background {
                if isActive {
                    Capsule().fill(Design.Palette.selectedRow)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.pressable)
        // A space that keeps nothing says so before you log into something in
        // it — out loud, where the macOS chip says it with an icon this
        // licensed set does not carry yet.
        .accessibilityLabel(
            space.profile.ephemeral ? "\(space.name), keeps nothing" : space.name
        )
    }
}
