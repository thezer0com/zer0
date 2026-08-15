import AppKit
import SwiftUI
import Zer0Core

extension Bookmark {
    /// Presentation only, which is why it lives on this side. What a bookmark
    /// *is* stays in the core.
    var displayTitle: String {
        title.isEmpty ? url : title
    }

    var host: String? {
        URL(string: url)?.host()
    }

    /// The labels as they are typed back into the field: comma separated, in
    /// the order they were given.
    var typedTags: String {
        tags.joined(separator: ", ")
    }
}

/// What ⌘D says back.
///
/// A key that changes nothing you can see is the worst failure a shortcut has
/// (ADR-0011): no error, no feedback, and the person presses it three more
/// times. So the press answers, and the answer is also the place you rename
/// what you just kept — because the moment you know what to call a page is the
/// moment you decide to keep it, and a rename that costs a trip to a manager
/// screen is a rename nobody does.
///
/// Everything here is reachable from the keyboard and nothing needs the mouse:
/// the title arrives focused and selected so typing replaces it, Tab reaches
/// the labels, Return closes, Esc closes. The panel opens over the page rather
/// than in the sidebar so it appears where the eye already is, and so it does
/// not depend on the sidebar being open.
struct BookmarkPanel: View {
    @Environment(BrowserModel.self) private var model

    let kept: BrowserModel.KeptPage

    @State private var title: String = ""
    @State private var tags: String = ""
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case title
        case tags
    }

    private enum Metrics {
        /// Narrower than the command bar: this is a note about one page, not a
        /// list to read.
        static let width: CGFloat = 360
        /// How far below the top of the window it hangs, matching the command
        /// bar so the two floating panels in this shell share a horizon.
        static let dropFromTop: CGFloat = 100
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Design.Radius.large, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.snug) {
            header

            VStack(alignment: .leading, spacing: Design.Space.tight) {
                field("Name", text: $title, focused: .title, prompt: kept.bookmark.url)
                field("Labels", text: $tags, focused: .tags, prompt: "rust, read later")
            }

            // Only where it is true, and before the fact rather than after.
            // Somebody in a throwaway space is entitled to know that this one
            // thing is going to outlive it.
            if kept.fromEphemeralSpace {
                Label(
                    "This space records nothing else. What you keep here still outlives it.",
                    systemImage: "eye.slash"
                )
                .font(Design.Text.micro)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            footer
        }
        .padding(Design.Space.regular)
        .frame(width: Metrics.width)
        .background { VisualEffect(material: .hudWindow, radius: Design.Radius.large) }
        .overlay { shape.strokeBorder(.quaternary, lineWidth: Design.Stroke.hairline) }
        .clipShape(shape)
        .elevation(Design.Elevation.floating)
        .onAppear {
            title = kept.bookmark.title
            tags = kept.bookmark.typedTags
            focus = .title
        }
        // A page opened for editing arrives selected, so typing replaces it
        // rather than appending to a title nobody wanted to keep.
        .onChange(of: focus) { _, now in
            guard now == .title else { return }
            DispatchQueue.main.async { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
        }
        .onExitCommand { close() }
        // Every way out commits, including the ones this view does not control
        // — the command bar taking over, the window changing. Anything else
        // means a rename that vanishes depending on which key put the panel
        // away, which is the kind of loss nobody reports and everybody stops
        // trusting. Renaming a bookmark that has just been removed is a no-op
        // in the core, so Remove is safe through the same door.
        .onDisappear { commit() }
    }

    private var header: some View {
        HStack(spacing: Design.Space.tight) {
            SiteBadge(subject: model.badge(forHost: kept.bookmark.host))
                .frame(width: Design.Space.regular)
            VStack(alignment: .leading, spacing: Design.Space.line) {
                // Says what happened, and says only what is true: a second ⌘D
                // on a page you already kept did not keep it again.
                Text(kept.isNew ? "Kept" : "Already kept")
                    .font(Design.Text.rowTitle)
                Text(kept.bookmark.url)
                    .font(Design.Text.micro)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
    }

    private func field(
        _ label: String,
        text: Binding<String>,
        focused: Field,
        prompt: String
    ) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.line) {
            Text(label)
                .font(Design.Text.micro.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
            TextField("", text: text, prompt: Text(prompt))
                .textFieldStyle(.plain)
                .font(Design.Text.row)
                .focused($focus, equals: focused)
                .onSubmit { close() }
                .padding(.horizontal, Design.Space.tight)
                .padding(.vertical, Design.Space.hair)
                .background {
                    RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous)
                        .fill(.primary.opacity(0.06))
                }
        }
    }

    private var footer: some View {
        HStack(spacing: Design.Space.tight) {
            // Destructive, on the far side from the button a finger lands on.
            Button("Remove", role: .destructive) { model.forget(kept.bookmark) }
                .buttonStyle(.borderless)
                // `.destructive` alone renders as plain grey text here, which
                // is what a *disabled* control looks like — the one reading a
                // destructive button must never invite. The rank comes from the
                // palette rather than from a hue spelled in a view (ADR-0043).
                .foregroundStyle(Design.Palette.danger)
            Spacer()
            Button("Done") { close() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .font(Design.Text.label)
    }

    /// Put the panel away. What was typed is written down by `onDisappear`,
    /// which is the one door every dismissal goes through.
    private func close() {
        model.stopKeeping()
    }

    private func commit() {
        model.rename(kept.bookmark, to: title, tags: tags)
    }
}
