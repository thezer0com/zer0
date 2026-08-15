import AppKit
import SwiftUI
import Zer0Core

/// Sizes that belong to this one window rather than to the whole UI, so they
/// are named here instead of pretending to be design tokens.
///
/// File scope rather than nested, because every pane below is part of the same
/// window and they have to agree about how wide a control column is.
private enum Metrics {
    /// Big enough that the longest pane does not open already scrolled, small
    /// enough that it still reads as a settings window and not a second
    /// browser.
    static let windowWidth: CGFloat = 880
    static let windowHeight: CGFloat = 580
    /// The list of sections. Sized to the longest section name plus its icon.
    static let sectionListWidth: CGFloat = 200
    /// A ceiling on the content column: prose set the full width of the window
    /// is prose nobody finishes a line of.
    static let contentWidth: CGFloat = 640

    /// A pop-up menu's width, and a segmented control's. Both are given
    /// `alignment: .trailing`, and that pairing is the whole point: a control
    /// centred in a fixed frame sits *inside* the column rather than on it, so
    /// four consecutive rows ended their controls on four different verticals
    /// — 26pt of wobble between the search pop-up and the Choose… button
    /// directly under it. The width bounds the control; the alignment is what
    /// puts its edge on the column.
    static let menu: CGFloat = 180
    /// A segmented control, which needs room for every segment at once rather
    /// than for the widest one.
    static let segmented: CGFloat = 220
    /// A text field holding a value that is long by nature, like a user agent.
    static let field: CGFloat = 260
    /// A stepper's number, right-aligned so it does not shuffle at two digits.
    static let counter: CGFloat = 30
    /// The two ends of the Air Traffic composer. Narrower than `menu` because
    /// the pattern field between them is what the row is actually for.
    static let ruleKind: CGFloat = 150
    static let ruleTarget: CGFloat = 130
}

/// Everything the browser lets you change, in one window.
///
/// Shaped like macOS settings on purpose: a sidebar of sections, one screen
/// each, controls on the right of their labels. A browser's settings is not
/// the place to be inventive.
public struct SettingsView: View {
    @Environment(BrowserModel.self) private var model
    @State private var section: SettingsSection = .general

    public init() {}

    public var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $section) { item in
                Label(item.title, systemImage: item.icon).tag(item)
            }
            .navigationSplitViewColumnWidth(Metrics.sectionListWidth)
        } detail: {
            ScrollView {
                content
                    .padding(Design.Space.loose)
                    .frame(maxWidth: Metrics.contentWidth, alignment: .leading)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(width: Metrics.windowWidth, height: Metrics.windowHeight)
        // A command that opens Settings says which pane it means: ⇧⌘, is
        // Extensions, not "wherever you were last time".
        .onAppear { section = model.settingsSection }
        .onChange(of: model.settingsSection) { _, requested in section = requested }
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .general: GeneralSettings()
        case .tabs: TabSettings()
        case .spaces: SpaceSettings()
        case .airTraffic: AirTrafficSettings()
        case .shortcuts: ShortcutSettings()
        case .extensions: ExtensionsView()
        case .chat: ChatSettings()
        case .connections: ConnectionsSettings()
        case .privacy: PrivacySettings()
        case .updates: UpdatesSettings()
        }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(BrowserModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.section) {
            SettingSection(title: "Search") {
                SettingRow(
                    title: "Search engine",
                    description: "Used when what you type is not an address."
                ) {
                    Picker("", selection: Binding(
                        get: { model.searchTemplate },
                        set: { model.setSearchTemplate($0) }
                    )) {
                        ForEach(model.searchEngines, id: \.template) { engine in
                            Text(engine.name).tag(engine.template)
                        }
                        if model.currentSearchEngineName == nil {
                            Text("Custom").tag(model.searchTemplate)
                        }
                    }
                    .labelsHidden()
                    .frame(width: Metrics.menu, alignment: .trailing)
                }
            }

            SettingSection(
                title: "Startup",
                footnote: "Ephemeral spaces never restore: that is what makes them ephemeral."
            ) {
                Picker("", selection: startupBinding) {
                    Text("Pick up where I left off").tag(0)
                    Text("Open one new tab").tag(1)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            SettingSection(title: "Appearance") {
                SettingRow(title: "Theme") {
                    Picker("", selection: Binding(
                        get: { model.preferences.theme },
                        set: { theme in model.updatePreferences { $0.theme = theme } }
                    )) {
                        Text("System").tag(ThemePreference.system)
                        Text("Light").tag(ThemePreference.light)
                        Text("Dark").tag(ThemePreference.dark)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: Metrics.segmented, alignment: .trailing)
                }
            }

            SettingSection(
                title: "Downloads",
                footnote: "A file never replaces one already there. A second copy of "
                    + "report.pdf is saved as report-2.pdf."
            ) {
                SettingRow(
                    title: "Save files to",
                    description: "⇧⌘J lists what has come down."
                ) {
                    HStack(spacing: Design.Space.tight) {
                        Text(downloadFolderName)
                            .font(Design.Text.label)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Button("Choose…", action: chooseDownloadFolder)
                    }
                }

                Divider().hairline()

                SettingRow(
                    title: "Ask where to save",
                    description: "Otherwise files go straight to the folder above."
                ) {
                    SettingSwitch(label: "Ask where to save", isOn: Binding(
                        get: { model.preferences.askWhereToSave },
                        set: { on in model.updatePreferences { $0.askWhereToSave = on } }
                    ))
                }
            }
        }
    }

    /// The folder as a person names it, not as a path. The full path is a
    /// tooltip's worth of detail, and it destroys the row's hierarchy.
    private var downloadFolderName: String {
        let path = model.preferences.downloadDirectory ?? DownloadHost.systemDownloadDirectory()
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private func chooseDownloadFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = URL(
            fileURLWithPath: model.preferences.downloadDirectory
                ?? DownloadHost.systemDownloadDirectory(),
            isDirectory: true
        )

        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.updatePreferences { $0.downloadDirectory = url.path }
    }

    private var startupBinding: Binding<Int> {
        Binding(
            get: { () -> Int in
                if case .restoreSession = model.preferences.startup { 0 } else { 1 }
            },
            set: { choice in
                model.updatePreferences {
                    $0.startup = choice == 0 ? .restoreSession : .newTab
                }
            }
        )
    }
}

// MARK: - Tabs

private struct TabSettings: View {
    @Environment(BrowserModel.self) private var model

    private static let options: [(String, UInt64)] = [
        ("After 1 hour", 60 * 60 * 1000),
        ("After 12 hours", 12 * 60 * 60 * 1000),
        ("After 24 hours", 24 * 60 * 60 * 1000),
        ("After 7 days", 7 * 24 * 60 * 60 * 1000),
        ("Never", 0),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.section) {
            SettingSection(
                title: "Archiving",
                footnote: "Only today's tabs expire. Favorites and pinned tabs stay until you "
                    + "close them, and the tab you are looking at is never archived."
            ) {
                SettingRow(
                    title: "Archive tabs",
                    description: "Counted from the last time you looked at the tab."
                ) {
                    Picker("", selection: Binding(
                        get: { model.archiveAfterMs },
                        set: { model.setArchiveAfter($0) }
                    )) {
                        ForEach(Self.options, id: \.1) { label, value in
                            Text(label).tag(value)
                        }
                    }
                    .labelsHidden()
                    .frame(width: Metrics.menu, alignment: .trailing)
                }
            }

            SettingSection(title: "Closing") {
                SettingRow(
                    title: "Warn when closing many tabs",
                    description: "Zero turns the warning off."
                ) {
                    Stepper(
                        value: Binding(
                            get: { Int(model.preferences.confirmCloseOver) },
                            set: { n in
                                model.updatePreferences { $0.confirmCloseOver = UInt32(max(0, n)) }
                            }
                        ),
                        in: 0 ... 50
                    ) {
                        Text("\(model.preferences.confirmCloseOver)")
                            .monospacedDigit()
                            .frame(width: Metrics.counter, alignment: .trailing)
                    }
                }
            }
        }
    }
}

// MARK: - Spaces

private struct SpaceSettings: View {
    @Environment(BrowserModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.loose) {
            ForEach(model.snapshot.spaces, id: \.id) { space in
                SettingSection(title: space.name) {
                    SettingRow(
                        title: "Ephemeral",
                        description: "Keeps nothing on disk: no cookies, no history, no tabs "
                            + "after you quit."
                    ) {
                        SettingSwitch(label: "Ephemeral", isOn: Binding(
                            get: { space.profile.ephemeral },
                            set: { on in
                                model.setProfile(space.id, SpaceProfile(
                                    userAgent: space.profile.userAgent,
                                    ephemeral: on
                                ))
                            }
                        ))
                    }

                    SettingRow(
                        title: "User agent",
                        description: "Leave empty to look like Safari."
                    ) {
                        TextField("Default", text: Binding(
                            get: { space.profile.userAgent ?? "" },
                            set: { agent in
                                model.setProfile(space.id, SpaceProfile(
                                    userAgent: agent.isEmpty ? nil : agent,
                                    ephemeral: space.profile.ephemeral
                                ))
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: Metrics.field)
                    }
                }
            }
        }
    }
}

// MARK: - Air traffic

private struct AirTrafficSettings: View {
    @Environment(BrowserModel.self) private var model
    @State private var pattern: String = ""
    @State private var kind: Kind = .domain
    @State private var target: SpaceId?

    private enum Kind: String, CaseIterable, Identifiable {
        case domain, domainContains, urlContains, regex
        var id: String { rawValue }

        var label: String {
            switch self {
            case .domain: "Domain is"
            case .domainContains: "Domain contains"
            case .urlContains: "URL contains"
            case .regex: "URL matches"
            }
        }

        var placeholder: String {
            switch self {
            case .domain: "github.com"
            case .domainContains: "github"
            case .urlContains: "/buserbrasil/"
            case .regex: #"^https://\w+\.corp\.example\.com/"#
            }
        }

        func pattern(_ value: String) -> RoutePattern {
            switch self {
            case .domain: .domain(host: value)
            case .domainContains: .domainContains(fragment: value)
            case .urlContains: .urlContains(fragment: value)
            case .regex: .regex(pattern: value)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.loose) {
            header
            composer

            if model.snapshot.routes.isEmpty {
                EmptyState(
                    icon: "arrow.triangle.branch",
                    title: "No rules yet",
                    message: "Send a site to the space it belongs to, and stop moving tabs by hand."
                ) {
                    // Somebody with no rules does not know the shape of one, so
                    // the empty state writes the first one for them.
                    Button {
                        kind = .domain
                        pattern = "github.com"
                        target = target ?? model.snapshot.spaces.last?.id
                    } label: {
                        Label("Start with an example", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(minHeight: Design.Pane.emptyStateMinHeight)
            } else {
                rules
            }
        }
    }

    /// No title: the sidebar row already says "Air Traffic", and a pane that
    /// repeats its own name is chrome that does not pay for itself. What the
    /// pane opens with is the part the sidebar cannot say.
    private var header: some View {
        Text("Rules send a URL to the space that owns it. First match wins, so put the "
            + "specific ones above the general ones.")
            .font(Design.Text.detail)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var composer: some View {
        HStack(spacing: Design.Space.tight) {
            Picker("", selection: $kind) {
                ForEach(Kind.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .frame(width: Metrics.ruleKind)

            TextField(kind.placeholder, text: $pattern)
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)

            Text("→").foregroundStyle(.secondary)

            Picker("", selection: $target) {
                ForEach(model.snapshot.spaces, id: \.id) { space in
                    Text(space.name).tag(Optional(space.id))
                }
            }
            .labelsHidden()
            .frame(width: Metrics.ruleTarget)

            // Prominent, like the Extensions composer's: it is the one action
            // this bar exists for, and Return already does it.
            Button("Add", action: add)
                .buttonStyle(.borderedProminent)
                .disabled(pattern.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(Design.Space.regular)
        .background(Design.Surface.recessed, in: RoundedRectangle(cornerRadius: Design.Radius.medium))
        .onAppear { target = target ?? model.snapshot.activeSpace }
    }

    private var rules: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.snapshot.routes.enumerated()), id: \.offset) { index, route in
                HStack(spacing: Design.Space.snug) {
                    Toggle("", isOn: Binding(
                        get: { route.enabled },
                        set: { model.setRoute(at: index, enabled: $0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)

                    VStack(alignment: .leading, spacing: Design.Space.line) {
                        // A routing pattern is a value someone typed and
                        // will compare against another one, not a sentence.
                        Text(describe(route.pattern)).font(Design.Text.mono)
                        Text(model.spaceName(route.space))
                            .font(Design.Text.label)
                            .foregroundStyle(.secondary)
                    }
                    .opacity(route.enabled ? 1 : 0.5)

                    Spacer()

                    Button {
                        model.removeRoute(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, Design.Space.tight)
                .padding(.horizontal, Design.Space.regular)

                if index < model.snapshot.routes.count - 1 {
                    Divider().hairline().padding(.leading, Design.Space.regular)
                }
            }
        }
        .background(Design.Surface.recessed, in: RoundedRectangle(cornerRadius: Design.Radius.medium))
    }

    private func describe(_ pattern: RoutePattern) -> String {
        switch pattern {
        case let .domain(host): host
        case let .domainContains(fragment): "domain contains \(fragment)"
        case let .urlContains(fragment): "URL contains \(fragment)"
        case let .regex(pattern): pattern
        }
    }

    private func add() {
        let value = pattern.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, let space = target ?? model.snapshot.spaces.first?.id else { return }

        model.addRoute(kind.pattern(value), to: space)
        pattern = ""
    }
}

// MARK: - Shortcuts

private struct ShortcutSettings: View {
    @Environment(BrowserModel.self) private var model

    var body: some View {
        let rows = bindings
        return VStack(alignment: .leading, spacing: Design.Space.loose) {
            HStack(alignment: .firstTextBaseline) {
                Text("The same bindings on every platform: ⌘ here, Ctrl elsewhere.")
                    .font(Design.Text.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: Design.Space.regular)

                DestructiveButton(
                    title: "Reset to Defaults",
                    question: "Reset every shortcut?",
                    consequence: "Every binding you have changed goes back to the one zer0 "
                        + "ships with. This cannot be undone.",
                    confirm: "Reset to Defaults"
                ) { model.resetKeymap() }
            }

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, entry in
                    HStack(spacing: Design.Space.regular) {
                        Text(entry.command.title).font(Design.Text.rowTitle)
                        Spacer(minLength: Design.Space.regular)

                        // Every chord bound to this command, side by side.
                        HStack(spacing: Design.Space.tight) {
                            ForEach(Array(entry.chords.enumerated()), id: \.offset) { _, chord in
                                keyCap(chord.displayString)
                            }
                        }
                    }
                    .padding(.vertical, Design.Space.tight)
                    .padding(.horizontal, Design.Space.regular)

                    if index < rows.count - 1 {
                        Divider().hairline().padding(.leading, Design.Space.regular)
                    }
                }
            }
            .background(Design.Surface.recessed, in: RoundedRectangle(cornerRadius: Design.Radius.medium))
        }
    }

    /// One row per command, carrying every chord bound to it.
    ///
    /// The core's keymap is a flat list of bindings and a command is allowed to
    /// hold more than one (ADR-0012: ⌘B exists because ⌃S collides with Save
    /// off Apple). Rendered flat, "Next Tab" appeared twice with two different
    /// chords and nothing on the screen said a command could have two — which
    /// reads as the browser having lost track of its own shortcuts. The order
    /// is the core's, taken from where each command is first bound; the
    /// grouping is presentation and stays here.
    private var bindings: [(command: UiCommand, chords: [Chord])] {
        var order: [UiCommand] = []
        var chords: [UiCommand: [Chord]] = [:]

        for binding in model.keymap {
            if chords[binding.command] == nil { order.append(binding.command) }
            chords[binding.command, default: []].append(binding.chord)
        }
        return order.map { (command: $0, chords: chords[$0] ?? []) }
    }

    private func keyCap(_ chord: String) -> some View {
        Text(chord)
            .font(.system(.body, design: .rounded).weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, Design.Space.tight)
            .padding(.vertical, Design.Space.hair)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: Design.Radius.small))
    }
}

/// A button for something that cannot be got back.
///
/// One component rather than a rule nobody reads, because the pairing *is* the
/// rule: an action that discards what someone accumulated asks first, the
/// question names what is lost, and the button carries the ellipsis that
/// promises the asking. "Reset to Defaults" wiped every rebinding on one click
/// while "Clear History…" two panes away asked — that difference was an
/// omission, not a decision.
///
/// The colour is not decoration either. On a *bordered* button macOS paints
/// `role: .destructive` nothing at all, so "Clear History…" arrived looking
/// exactly like the benign "Choose…" beside it. Rendered side by side, `role`
/// alone and `role` + a red tint are both indistinguishable from a plain
/// button; only a foreground style paints — a red label over a pale red fill,
/// in both themes. The role stays, because it is what VoiceOver and a second
/// platform read; the colour is what makes it visible on this one.
///
/// The red is `Design.Palette.danger` and not the system's, so that discarding
/// someone's history and a `critical` permission on the consent sheet are the
/// same red rather than two that happen to look alike (ADR-0043).
///
/// Internal rather than file-private since the Chat and Connections panes
/// landed: removing a key and removing a connection are the same kind of act as
/// clearing history, and the whole point of this type is that a caller cannot
/// have the red without the asking. A second copy in another file would be the
/// omission this component exists to make impossible.
struct DestructiveButton: View {
    let title: String
    /// The dialog's headline. A question, and never "Are you sure?".
    let question: String
    /// What is actually lost, in a sentence.
    let consequence: String
    /// The verb on the button that goes through with it.
    let confirm: String
    let action: () -> Void

    @State private var asking = false

    var body: some View {
        // The ellipsis is appended rather than written at the call site: it is
        // a promise that something happens before anything is destroyed, and a
        // promise the component keeps cannot be forgotten by the next caller.
        Button("\(title)…", role: .destructive) { asking = true }
            .foregroundStyle(Design.Palette.danger)
            .confirmationDialog(question, isPresented: $asking, titleVisibility: .visible) {
                Button(confirm, role: .destructive, action: action)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(consequence)
            }
    }
}

// MARK: - Privacy

/// Internal rather than file-private, the way `ChatSettings` and
/// `ConnectionsSettings` already are: this pane carries a long honesty
/// paragraph and a warning state, and whether either is readable is a question
/// only a rendered frame answers (`ZZBlockingShots`).
struct PrivacySettings: View {
    @Environment(BrowserModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.section) {
            SettingSection(
                title: "Content blocking",
                // What this list is, said where the switch is rather than in a
                // document nobody opens. A browser that says "blocks trackers
                // and ads" over a starter list is telling somebody they are
                // covered when they are not (ADR-0018).
                //
                // Two sentences, and it was six. The count lives on the row
                // above, so nothing here repeats a number — the earlier version
                // put "77 rules" and "76 hosts" on one screen, which reads as a
                // contradiction rather than as two true things.
                footnote: "Compiled into WebKit itself, so it runs ahead of the page and needs no "
                    + "extension. It is a starter list, not EasyList — so it stops the common "
                    + "advertising and analytics infrastructure and it will miss things. WebKit's "
                    + "own tracking prevention runs underneath it on every page, list or no list."
            ) {
                SettingRow(
                    title: "Block trackers and ads",
                    description: model.blocking.state.summary
                ) {
                    SettingSwitch(label: "Block trackers and ads", isOn: Binding(
                        get: { model.preferences.blockContent },
                        set: { on in model.updatePreferences { $0.blockContent = on } }
                    ))
                }

                // A compile that failed leaves the switch on and nothing
                // filtered. Silence there would be the worst state this pane
                // can be in: the control says protected and the browser is not.
                if model.blocking.state.isFailure {
                    Divider().hairline()
                    Label(model.blocking.state.summary, systemImage: "exclamationmark.triangle.fill")
                        .font(Design.Text.detail)
                        .foregroundStyle(Design.Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !model.preferences.blockingExceptions.isEmpty {
                    Divider().hairline()
                    VStack(alignment: .leading, spacing: Design.Space.tight) {
                        Text("Turned off for")
                            .font(Design.Text.detail)
                            .foregroundStyle(.secondary)
                        ForEach(model.preferences.blockingExceptions, id: \.self) { host in
                            HStack {
                                Text(host).font(Design.Text.mono)
                                Spacer()
                                Button {
                                    model.setBlocking(host: host, blocking: true)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                                .help("Block trackers on \(host) again")
                            }
                        }
                        // Where these came from, so the list does not read as
                        // something only editable here. Printed once, under the
                        // rows it explains, and read from the live keymap so
                        // rebinding cannot leave a lie behind (ADR-0018).
                        if let chord = model.chord(for: .toggleBlockingHere) {
                            Text("\(chord.displayString) does this from the page itself.")
                                .font(Design.Text.label)
                                .foregroundStyle(.tertiary)
                                .padding(.top, Design.Space.hair)
                        }
                    }
                }
            }

            SitePermissionsSection()

            SavedLoginsSection()

            // Shipped on, because WebKit's own default here is an embedded web
            // view's and would let any page start making noise (ADR-0074). The
            // description says where a change lands rather than implying it is
            // immediate: this one lives on a configuration `WKWebView` copies
            // at birth, so an open tab cannot be told about it at all.
            SettingSection(title: "Pages") {
                SettingRow(
                    title: "Block sound that starts on its own",
                    description: "Muted video still plays. Reaches pages you open from now on."
                ) {
                    SettingSwitch(label: "Block sound that starts on its own", isOn: Binding(
                        get: { model.preferences.blockAudibleAutoplay },
                        set: { on in model.updatePreferences { $0.blockAudibleAutoplay = on } }
                    ))
                }

                // The row ADR-0074 said it would not write until windows could
                // open, and ADR-0075 is the day they can. Its description says
                // something different from the one above it because the engine
                // gives it a different reach, not for variety: this setting
                // lives on `WKPreferences`, which an open page still shares, so
                // it lands the next time that page loads.
                SettingRow(
                    title: "Block windows that open on their own",
                    description: "A window you asked for still opens. Takes effect the next time a page loads."
                ) {
                    SettingSwitch(label: "Block windows that open on their own", isOn: Binding(
                        get: { model.preferences.blockUnpromptedWindows },
                        set: { on in model.updatePreferences { $0.blockUnpromptedWindows = on } }
                    ))
                }
            }

            SettingSection(title: "Tracking") {
                SettingRow(
                    title: "Send Do Not Track",
                    description: "Sites can ignore it, and most do."
                ) {
                    SettingSwitch(label: "Send Do Not Track", isOn: Binding(
                        get: { model.preferences.sendDoNotTrack },
                        set: { on in model.updatePreferences { $0.sendDoNotTrack = on } }
                    ))
                }
            }

            SettingSection(title: "Data") {
                SettingRow(
                    title: "Clear everything on quit",
                    description: "Every space's cookies and storage, wiped when you close zer0."
                ) {
                    SettingSwitch(label: "Clear everything on quit", isOn: Binding(
                        get: { model.preferences.clearDataOnQuit },
                        set: { on in model.updatePreferences { $0.clearDataOnQuit = on } }
                    ))
                }

                // No "Clear History…" here any more. History is a page at an
                // address of its own, the clearing lives beside the list it
                // clears, and a second button two panes away would be a second
                // path to a destructive act — with the copy on one of them
                // going stale the first time the other gained a span
                // (ADR-0063).
            }
        }
    }
}

// MARK: - Updates

/// The Sparkle pane. Two states, and the difference is what ADR-0109's split
/// means for the person reading the screen.
///
/// A canary binary is *on* the canary feed by construction; there is nothing
/// to switch to and no second feed to choose. The pane says so plainly and
/// offers the one verb that always applies: check now.
///
/// A stable binary is on the stable feed, full stop. There is no "peek at
/// canary" toggle here, and ADR-0110 is why: an appcast enclosure is a whole
/// `.app`, so a stable binary that read the canary feed would have its bundle
/// id mutate to `com.thezer0.canary` on the first canary update — orphaning
/// the stable profile. Someone who wants canary installs `Zer0 Canary.app`,
/// the second bundle ADR-0109 already ships.
private struct UpdatesSettings: View {
    @State private var host = UpdateHost.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.section) {
            SettingSection(
                title: "Automatic updates",
                footnote: "Checked once a day and when zer0 opens. zer0 downloads the update in "
                    + "the background and asks before relaunching."
            ) {
                SettingRow(
                    title: "Check for updates automatically",
                    description: "Turn off to check only when you press Check Now."
                ) {
                    SettingSwitch(label: "Check for updates automatically", isOn: Binding(
                        get: { host.automaticallyChecksForUpdates },
                        set: { on in host.setAutomaticallyChecksForUpdates(on) }
                    ))
                }

                Divider().hairline()

                SettingRow(
                    title: "Check now",
                    description: "Asks the feed for the latest version this binary can install."
                ) {
                    Button("Check Now") { host.checkForUpdatesManually() }
                }
            }

            // A canary binary carries its channel in the bundle id; the pane
            // names it so the person reading the screen knows which feed
            // "Check Now" will read. Stable has no equivalent readout: a
            // stable binary reading stable is the unremarkable default, and a
            // "you are on stable" line would be chrome that does not pay for
            // itself.
            if host.channel == .canary {
                SettingSection(
                    title: "Channel",
                    footnote: "This is the canary build. Updates come from the canary feed; there "
                        + "is no stable feed to switch back to from here. Install Zer0 (stable) "
                        + "for the stable channel."
                ) {
                    SettingRow(title: "Channel") {
                        Text("Canary")
                            .font(Design.Text.label)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

