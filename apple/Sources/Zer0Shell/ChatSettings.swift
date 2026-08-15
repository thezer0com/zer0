import AppKit
import SwiftUI
import Zer0Core

/// Choosing who answers, proving the key works, and picking a model.
///
/// The order is the order somebody does it in, and each step only appears once
/// the one above it is done: there is no model menu before there is a key,
/// because a menu that can only be empty teaches a person the screen is broken.
struct ChatSettings: View {
    @State private var chat: ChatSettingsModel
    /// The characters, only while they are being typed. They are handed to the
    /// model and this is cleared; nothing on screen holds a whole key after
    /// that, and there is no property anywhere on this side that could.
    @State private var entry: String = ""
    @State private var baseUrl: String = ""
    @FocusState private var keyFocused: Bool

    /// Sizes that belong to this one pane rather than to the whole UI, so they
    /// are named here instead of pretending to be design tokens.
    private enum Metrics {
        /// A provider card's symbol, in a column so four names start on the
        /// same vertical whatever their glyph renders at.
        static let markColumn: CGFloat = 28
        /// The key field. Long enough that a key does not scroll while it is
        /// being compared against what was copied, and short enough that the
        /// Check button beside it still fits the column — at 320 the button was
        /// clipped by the pane's right edge, which is a control you can see and
        /// cannot press.
        static let keyField: CGFloat = 280
        /// The model pop-up. Wider than a settings menu elsewhere because a
        /// model identifier is long by nature, and truncating the one thing
        /// being chosen is not a saving.
        static let modelMenu: CGFloat = 260
    }

    init(_ chat: ChatSettingsModel = .shared) {
        _chat = State(initialValue: chat)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.section) {
            if let provider = chat.current {
                configured(provider)
            } else {
                chooser
            }

            if let failure = chat.failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(Design.Text.label)
                    .foregroundStyle(Design.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .motion(.subtle, value: chat.current?.id)
        .onAppear { baseUrl = chat.current?.baseUrl ?? "" }
    }

    // MARK: - Nobody has chosen anything

    /// The empty state, and it *is* the chooser rather than a screen that leads
    /// to one.
    ///
    /// §9: an empty state teaches the feature and hands over the first step.
    /// The first step here is picking who answers, so a screen whose only
    /// action opened a menu somewhere else would be a click spent on ceremony.
    /// Four cards, one click — and the one that needs no account at all is on
    /// the list, which for somebody who has never held an API key is the most
    /// useful sentence on this pane.
    private var chooser: some View {
        VStack(alignment: .leading, spacing: Design.Space.loose) {
            VStack(alignment: .leading, spacing: Design.Space.tight) {
                Text("Who answers?")
                    .font(Design.Text.emptyTitle)
                Text("Chat needs somewhere to send what you ask. You can change this later, "
                    + "and nothing is sent anywhere until you do.")
                    .font(Design.Text.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                ForEach(Array(ChatProviderStyles.all.enumerated()), id: \.offset) { index, style in
                    providerCard(style)

                    if index < ChatProviderStyles.all.count - 1 {
                        Divider().hairline().padding(.leading, Design.Space.section)
                    }
                }
            }
            .background(
                Design.Surface.recessed,
                in: RoundedRectangle(cornerRadius: Design.Radius.medium)
            )

            fileNote
        }
    }

    private func providerCard(_ style: ChatProviderStyle) -> some View {
        Button {
            chat.choose(style)
            baseUrl = chat.current?.baseUrl ?? ""
            // The field this opens is the field the next character goes in.
            keyFocused = style.needsKey
        } label: {
            HStack(alignment: .top, spacing: Design.Space.snug) {
                Image(systemName: style.symbol)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: Metrics.markColumn)

                VStack(alignment: .leading, spacing: Design.Space.line) {
                    Text(style.name).font(Design.Text.rowTitle)
                    Text(style.summary)
                        .font(Design.Text.detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: Design.Space.regular)

                Image(systemName: "chevron.right")
                    .font(Design.Text.label)
                    .foregroundStyle(.tertiary)
            }
            .padding(Design.Space.regular)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
    }

    // MARK: - Somebody has

    @ViewBuilder
    private func configured(_ provider: ProviderConfig) -> some View {
        let style = ChatProviderStyles.style(for: provider.kind)

        SettingSection(title: "Provider") {
            // Not the provider's name: the picker opposite already says it, and
            // a row whose title and whose control are the same word is a row
            // that has spent its most legible line saying nothing.
            SettingRow(title: "Answered by", description: style.summary) {
                Picker("", selection: Binding(
                    get: { provider.kind },
                    set: { kind in
                        chat.choose(ChatProviderStyles.style(for: kind))
                        baseUrl = chat.current?.baseUrl ?? ""
                    }
                )) {
                    ForEach(Array(ChatProviderStyles.all.enumerated()), id: \.offset) { _, item in
                        Text(item.name).tag(item.kind)
                    }
                }
                .labelsHidden()
                .frame(width: Metrics.modelMenu, alignment: .trailing)
                .accessibilityLabel("Provider")
            }

            if style.needsBaseUrl {
                Divider().hairline()

                SettingRow(
                    title: "Address",
                    description: "Where the service lives. Whoever set it up will have "
                        + "given you this."
                ) {
                    TextField("https://gateway.example.com", text: $baseUrl)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: Metrics.keyField)
                        .onSubmit { chat.setBaseUrl(baseUrl, on: provider) }
                }
            }
        }

        if style.needsKey {
            key(provider, style)
        } else {
            localCheck(provider)
        }

        if !provider.models.isEmpty {
            model(provider)
        }

        fileSection
    }

    // MARK: - The key

    private func key(_ provider: ProviderConfig, _ style: ChatProviderStyle) -> some View {
        SettingSection(
            title: "Key",
            footnote: "The key goes into your macOS Keychain. The settings file records "
                + "only the name it is filed under — “\(provider.credential ?? provider.id)” — "
                + "which is what makes that file safe to keep in version control."
        ) {
            if chat.hasKey(provider) {
                stored(provider, style)
            } else {
                entryField(provider, style)
            }

            verdict(style)
        }
        .motion(.subtle, value: chat.hasKey(provider))
    }

    private func entryField(_ provider: ProviderConfig, _ style: ChatProviderStyle) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.snug) {
            SettingRow(
                title: "Paste your key",
                description: "A long string of letters and numbers. Press Return when it is in."
            ) {
                HStack(spacing: Design.Space.tight) {
                    // `maxWidth`, and the button `fixedSize`, in that pairing.
                    // With a fixed width on the field the row overflowed the
                    // column and macOS compressed the *button* instead — Check
                    // rendered as a ten-point sliver of accent at the pane's
                    // edge. A control you can see and cannot press is worse
                    // than one that is not there.
                    SecureField("", text: $entry)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: Metrics.keyField)
                        .focused($keyFocused)
                        .onSubmit { check(provider) }
                        .accessibilityLabel("\(style.name) key")

                    if case .checking = chat.keyState {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Check") { check(provider) }
                            .buttonStyle(.borderedProminent)
                            .fixedSize()
                            .disabled(entry.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }

            // There is no click in this app that produces a key, and pretending
            // otherwise would be the one dishonest control on the pane. What
            // there is, is one click to the page that issues one.
            if let page = style.keyPage, let name = style.keyPageName {
                Divider().hairline()

                SettingRow(
                    title: "Don't have one?",
                    description: "Keys are made on \(name). It takes a minute, and needs a "
                        + "card on file."
                ) {
                    Button {
                        NSWorkspace.shared.open(page)
                    } label: {
                        Label("Get a Key", systemImage: "arrow.up.forward")
                    }
                }
            }
        }
        // Focus lands where typing goes (ADR-0013): opening this pane with a
        // provider chosen and no key means the next keystroke is the key.
        .onAppear { keyFocused = true }
    }

    private func stored(_ provider: ProviderConfig, _ style: ChatProviderStyle) -> some View {
        SettingRow(
            title: "Key",
            description: "In your Keychain, under “\(provider.credential ?? provider.id)”."
        ) {
            HStack(spacing: Design.Space.snug) {
                // Not the key, and not a redaction of it either: nothing on
                // this side of the Keychain has ever held the characters, so
                // there is nothing here to redact. What is shown is that a key
                // is there.
                Label("Saved", systemImage: "key.fill")
                    .font(Design.Text.label)
                    .foregroundStyle(.secondary)

                Button("Replace") {
                    chat.forgetKey(of: provider)
                    entry = ""
                    keyFocused = true
                }

                DestructiveButton(
                    title: "Remove",
                    question: "Remove your \(style.name) key?",
                    consequence: "Chat stops working until you paste another one. The key "
                        + "itself is not cancelled — do that on "
                        + "\(style.keyPageName ?? "their site") if it has leaked.",
                    confirm: "Remove Key"
                ) {
                    chat.forgetKey(of: provider)
                    entry = ""
                    keyFocused = true
                }
            }
        }
    }

    /// A provider that needs no key still needs to be reachable, and the answer
    /// to "is Ollama actually running" is worth one button.
    private func localCheck(_ provider: ProviderConfig) -> some View {
        SettingSection(
            title: "Connection",
            footnote: "Nothing you type goes to a company. It is answered by a program on "
                + "this Mac."
        ) {
            SettingRow(
                title: "Is it running?",
                description: "zer0 asks it what models it has. That is also what fills the "
                    + "list below."
            ) {
                if case .checking = chat.keyState {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Check") {
                        Task { await chat.probeWithoutKey(provider) }
                    }
                    .buttonStyle(provider.models.isEmpty ? AnyButtonStyle(.borderedProminent)
                        : AnyButtonStyle(.bordered))
                }
            }

            verdict(ChatProviderStyles.style(for: provider.kind))
        }
    }

    /// What the last check said, in the voice the rest of the shell uses for a
    /// failure: what happened, and what it means for you.
    ///
    /// Refused and unreachable are two states rather than one, because they
    /// call for two different actions. Telling somebody to go and make a new
    /// key because their wifi dropped is how a settings screen loses trust for
    /// good.
    @ViewBuilder
    private func verdict(_ style: ChatProviderStyle) -> some View {
        switch chat.keyState {
        case .absent:
            if let provider = chat.current, let warning = chat.prefixWarning(
                for: entry, provider: provider
            ) {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(Design.Text.label)
                    .foregroundStyle(Design.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .stored:
            EmptyView()
        case .checking:
            Label("Asking \(style.name) whether it works…", systemImage: "clock")
                .font(Design.Text.label)
                .foregroundStyle(.secondary)
        case let .working(models):
            Label(
                models > 0 ? "Working. \(models) models available." : "Working.",
                systemImage: "checkmark.circle.fill"
            )
            .font(Design.Text.label)
            .foregroundStyle(Design.Palette.success)
        case let .refused(why):
            Label(why, systemImage: "xmark.circle.fill")
                .font(Design.Text.label)
                .foregroundStyle(Design.Palette.danger)
                .fixedSize(horizontal: false, vertical: true)
        case let .unreachable(why):
            Label(why, systemImage: "wifi.exclamationmark")
                .font(Design.Text.label)
                .foregroundStyle(Design.Palette.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func check(_ provider: ProviderConfig) {
        let secret = entry
        Task {
            await chat.submit(key: secret, for: provider)
            // Cleared whatever the answer, so a rejected key is not left on
            // screen for whoever walks past next.
            entry = ""
        }
    }

    // MARK: - The model

    /// A list, never a text field.
    ///
    /// Typing a model identifier from memory is a developer interface: it fails
    /// on a typo, with a message from an API, and the person who typed it has
    /// no way to find out what the right string was. This list came back with
    /// the request that verified the key, so it costs nothing extra and cannot
    /// be stale against a key that no longer works.
    private func model(_ provider: ProviderConfig) -> some View {
        SettingSection(
            title: "Model",
            footnote: "This list came from your provider, so it is what your key can "
                + "actually run. It is written into the settings file."
        ) {
            SettingRow(
                title: "Model",
                description: "Bigger models cost more per answer and think for longer."
            ) {
                Picker("", selection: Binding(
                    get: { provider.defaultModel ?? provider.models.first ?? "" },
                    set: { chat.select(model: $0, on: provider) }
                )) {
                    ForEach(provider.models, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .labelsHidden()
                .frame(width: Metrics.modelMenu, alignment: .trailing)
                .accessibilityLabel("Model")
            }
        }
    }

    // MARK: - The file

    /// Where the settings live, said out loud.
    ///
    /// The file is meant to be version-controlled, which means somebody will
    /// open it in an editor — and a GUI that pretends the file is not there
    /// makes that feel illicit. So the pane names it, gives one click to it,
    /// and says plainly that editing it by hand is a supported thing to do.
    ///
    /// What it deliberately does **not** do is offer to edit it here. A text
    /// view over a config file inside a settings window is a worse editor than
    /// the one they already have, and it would turn the GUI into a front end
    /// for a file rather than the way this is normally done.
    @ViewBuilder
    private var fileSection: some View {
        SettingSection(
            title: "Settings file",
            footnote: "Safe to keep in version control: no key is in it. Keys live in the "
                + "Keychain, and the file records only the name each one is filed under."
        ) {
            SettingRow(
                title: "Where this is saved",
                description: chat.exists
                    ? "Plain text. Editing it by hand is fine — zer0 reads it again when "
                        + "it changes."
                    : "Nothing has been written yet. It appears the moment you configure "
                        + "something here."
            ) {
                HStack(spacing: Design.Space.snug) {
                    Text(shortPath(chat.configPath))
                        .font(Design.Text.mono)
                        .foregroundStyle(chat.exists ? .secondary : .tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)

                    if chat.exists {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([
                                URL(fileURLWithPath: chat.configPath),
                            ])
                        }
                    } else {
                        Button("Create It") { chat.writeExample() }
                    }
                }
            }

            if let diagnostic = chat.worstDiagnostic {
                Divider().hairline()
                self.diagnostic(diagnostic)
            }
        }
    }

    /// What the file said that a person should see.
    ///
    /// An error means something was dropped, so the pane is showing less than
    /// the file does and has to admit it — with the line number, because the
    /// point of this row is to be actionable in the editor they are about to
    /// open.
    private func diagnostic(_ diagnostic: ConfigDiagnostic) -> some View {
        Label(
            "Line \(diagnostic.line): \(diagnostic.message)",
            systemImage: diagnostic.severity == .error
                ? "exclamationmark.triangle.fill"
                : "info.circle"
        )
        .font(Design.Text.label)
        .foregroundStyle(diagnostic.severity == .error
            ? AnyShapeStyle(Design.Palette.danger)
            : AnyShapeStyle(Design.Palette.warning))
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The file, mentioned on the one screen that has no section to put it in.
    ///
    /// Deliberately without the path. On day one nobody is going to open the
    /// file, and a full path set in the quietest type on the screen is three
    /// lines of noise under the one decision this screen is asking for. What
    /// belongs here is that the file exists and is yours; where it is belongs
    /// to the section that appears the moment there is one.
    private var fileNote: some View {
        Text("Whatever you pick is written to a plain-text settings file — yours to edit, "
            + "and safe to keep in version control. Keys never go in it.")
            .font(Design.Text.label)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The path as a person writes it, with the home directory as `~`. The full
    /// one destroys the row's hierarchy for a detail nobody reads twice.
    private func shortPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
