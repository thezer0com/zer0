import AppKit
import SwiftUI
import Zer0Core

/// Adding a connection without knowing what a command line is.
///
/// **The problem, stated honestly.** An MCP server over stdio is a program,
/// some arguments and some environment variables. That is a developer's object,
/// and no amount of styling turns a text field holding
/// `npx -y @scope/pkg /Users/me` into something a person who has never opened
/// Terminal can fill in. So this sheet does not try to make *composing* one
/// clickable. It offers three doors, in the order of how likely somebody is to
/// get through them, and it is candid about the last:
///
/// 1. **Ready to add.** zer0 ships the recipe. Click a name, answer the one or
///    two things it genuinely needs — and every one of those is a real control,
///    a folder picker or a secure field, never a string to type — then read
///    what it will be able to do before anything runs. This path is fully
///    clickable, which is why it is first and largest.
/// 2. **Paste what the instructions gave you.** Every MCP server on the web is
///    distributed as a `mcpServers` block to copy. Copying a block of text out
///    of a page is something almost anybody can do; composing the same block is
///    not. So a paste is read, any literal key in it is lifted out into the
///    Keychain, and it lands on the *same* review screen the catalogue produces.
/// 3. **By hand.** Program and arguments, behind a disclosure, labelled for
///    what it is. **This is the part that genuinely cannot be made clickable**,
///    and a wizard walking somebody through inventing a command line for a
///    program they have never heard of would be a longer road to the same dead
///    end.
///
/// What all three share is the last screen: nothing is added until it has said
/// what will run and what that lets the assistant do.
struct McpAddSheet: View {
    let chat: ChatSettingsModel
    @Environment(\.dismiss) private var dismiss

    @State private var step: Step = .choose
    @State private var answers: [String: String] = [:]
    @State private var pasted: String = ""
    @State private var pasteFailure: String?
    @State private var byHand = false
    @State private var command: String = ""
    @State private var argumentLine: String = ""
    @State private var handName: String = ""
    @FocusState private var pasteFocused: Bool

    /// Internal rather than private so the shot harness can open the sheet on
    /// a step other than the first. There is no other door: the steps are
    /// reached by clicking, and a machine with no screen cannot click.
    enum Step: Equatable {
        case choose
        /// Door two and door three, on a screen of their own.
        ///
        /// They were folded under the catalogue on the first screen, and
        /// rendered they were *below the fold*: the paste box was cut by the
        /// footer and the button that reads it could not be seen at all. A
        /// primary path a person cannot see is not a path. Four rows fit; four
        /// rows and a text area do not, and the honest fix is a step rather
        /// than a smaller box.
        case paste
        /// Answering what a catalogue entry needs.
        case fill(String)
        /// The last screen before anything runs: what will be added, the
        /// catalogue entry it came from when it came from one, and any secret
        /// lifted out of a paste on its way to the Keychain.
        case review(servers: [McpServerConfig], catalogue: String?, secrets: [String: String])
    }

    init(chat: ChatSettingsModel, startingAt step: Step = .choose) {
        self.chat = chat
        _step = State(initialValue: step)
    }

    private enum Metrics {
        /// Wide enough for a title and its sentence of consequence without the
        /// sentence wrapping to four lines. The width the consent sheet settled
        /// on, for the same reason.
        static let width: CGFloat = 520
        static let maxHeight: CGFloat = 640
        static let markColumn: CGFloat = 28
        /// The paste area. Deep enough for a common `mcpServers` block without
        /// scrolling, which is what makes a paste feel like it landed.
        static let pasteHeight: CGFloat = 150
        static let field: CGFloat = 280
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch step {
            case .choose:
                chooseStep
            case .paste:
                pasteStep
            case let .fill(id):
                if let entry = McpCatalogue.entry(id) { fillStep(entry) }
            case let .review(servers, catalogue, secrets):
                reviewStep(servers, McpCatalogue.entry(catalogue), secrets)
            }
        }
        .frame(width: Metrics.width)
        .frame(maxHeight: Metrics.maxHeight)
        .background(.regularMaterial)
        .motion(.subtle, value: step)
    }

    // MARK: - The three doors

    private var chooseStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading(
                "Add a connection",
                "Pick something zer0 already knows how to set up, or paste the instructions "
                    + "you were given."
            )

            Divider().hairline()

            ScrollView {
                catalogue.padding(Design.Space.loose)
            }
            .scrollBounceBehavior(.basedOnSize)

            Divider().hairline()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(Design.Space.loose)
        }
    }

    private var catalogue: some View {
        VStack(alignment: .leading, spacing: Design.Space.snug) {
            Text("Ready to add")
                .sectionHeading()
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                ForEach(Array(McpCatalogue.entries.enumerated()), id: \.element.id) { index, entry in
                    catalogueRow(entry)

                    if index < McpCatalogue.entries.count - 1 {
                        Divider().hairline().padding(.leading, Design.Space.section)
                    }
                }
            }
            .background(
                Design.Surface.recessed,
                in: RoundedRectangle(cornerRadius: Design.Radius.medium)
            )

            Text("Anything else")
                .sectionHeading()
                .foregroundStyle(.secondary)
                .padding(.top, Design.Space.tight)

            // The same shape as a catalogue row, on purpose: the three doors
            // are three ways to do one thing, and drawing this one as a
            // different species would make it read as a fallback rather than as
            // the ordinary route it is for every server we did not ship.
            row(
                symbol: "doc.on.clipboard",
                name: "Paste what the instructions gave you",
                summary: "Most connections come as a block of settings to copy. zer0 reads "
                    + "one and shows you what it would do before adding anything."
            ) { step = .paste }
            .background(
                Design.Surface.recessed,
                in: RoundedRectangle(cornerRadius: Design.Radius.medium)
            )
        }
    }

    /// The shape every row on this screen takes.
    private func row(
        symbol: String,
        name: String,
        summary: String,
        @ViewBuilder trailing: () -> some View = { Image(systemName: "chevron.right")
            .font(Design.Text.label)
            .foregroundStyle(.tertiary) },
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Design.Space.snug) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: Metrics.markColumn)

                VStack(alignment: .leading, spacing: Design.Space.line) {
                    Text(name).font(Design.Text.rowTitle)
                    Text(summary)
                        .font(Design.Text.label)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: Design.Space.regular)

                trailing()
            }
            .padding(Design.Space.snug)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
    }

    private func catalogueRow(_ entry: McpCatalogueEntry) -> some View {
        let already = chat.servers.contains { $0.id == entry.id }

        return Button {
            answers = [:]
            // An entry that needs nothing goes straight to the consequence: a
            // step that asks nothing is a click spent on ceremony.
            step = entry.inputs.isEmpty
                ? .review(servers: [entry.server(from: [:])], catalogue: entry.id, secrets: [:])
                : .fill(entry.id)
        } label: {
            HStack(alignment: .top, spacing: Design.Space.snug) {
                Image(systemName: entry.symbol)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: Metrics.markColumn)

                VStack(alignment: .leading, spacing: Design.Space.line) {
                    Text(entry.name).font(Design.Text.rowTitle)
                    Text(entry.summary)
                        .font(Design.Text.label)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: Design.Space.regular)

                if already {
                    // Not disabled: adding it again is how somebody changes the
                    // folder they chose, and a greyed row with no explanation is
                    // a dead end (§9).
                    Text("Added")
                        .font(Design.Text.label)
                        .foregroundStyle(.tertiary)
                } else {
                    Image(systemName: "chevron.right")
                        .font(Design.Text.label)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(Design.Space.snug)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
    }

    /// Door two, with door three folded inside it.
    private var pasteStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading(
                "Paste the settings you were given",
                "The block starting with mcpServers. Copy the whole thing, braces included."
            )

            Divider().hairline()

            ScrollView {
                fromInstructions.padding(Design.Space.loose)
            }
            .scrollBounceBehavior(.basedOnSize)

            Divider().hairline()

            HStack {
                Button("Back") { step = .choose }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Read This") { readPaste() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(Design.Space.loose)
        }
        // The box this screen exists for is the box the next keystroke goes in.
        .onAppear { pasteFocused = true }
    }

    private var fromInstructions: some View {
        VStack(alignment: .leading, spacing: Design.Space.snug) {
            VStack(alignment: .leading, spacing: Design.Space.snug) {
                TextEditor(text: $pasted)
                    .font(Design.Text.mono)
                    .scrollContentBackground(.hidden)
                    .frame(height: Metrics.pasteHeight)
                    .padding(Design.Space.tight)
                    .background(
                        Design.Surface.recessedInner,
                        in: RoundedRectangle(cornerRadius: Design.Radius.small)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Design.Radius.small)
                            .strokeBorder(.separator, lineWidth: Design.Stroke.hairline)
                    )
                    .focused($pasteFocused)
                    .accessibilityLabel("Settings to paste")

                if let pasteFailure {
                    Label(pasteFailure, systemImage: "exclamationmark.triangle")
                        .font(Design.Text.label)
                        .foregroundStyle(Design.Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Spacer()
                    Button(byHand ? "Hide" : "No block? Set it up by hand") { byHand.toggle() }
                        .buttonStyle(.borderless)
                        .font(Design.Text.label)
                }

                if byHand { handEntry }
            }
            .padding(Design.Space.regular)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Design.Surface.recessed,
                in: RoundedRectangle(cornerRadius: Design.Radius.medium)
            )
        }
        .motion(.subtle, value: byHand)
    }

    /// Door three, said plainly.
    ///
    /// The sentence above it is the honest part of this whole sheet: there is
    /// no clicking your way to "run this program with these flags", and a form
    /// pretending otherwise would be a lie in a nicer font.
    ///
    /// Environment variables are deliberately absent. Almost every one is a
    /// token, and a plain grid of them here would be a worse answer than the
    /// paste box above — which at least takes what it finds and puts it in the
    /// Keychain instead of the file.
    private var handEntry: some View {
        VStack(alignment: .leading, spacing: Design.Space.snug) {
            Divider().hairline()

            Text("This is for somebody following instructions that name a program to run. "
                + "There is no way around knowing what it is — a command is a command. "
                + "If your instructions came as a block of settings, the box above is the "
                + "easier road, and it also keeps any key out of the settings file.")
                .font(Design.Text.label)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SettingRow(title: "Name", description: "What you will see it called.") {
                TextField("Notes", text: $handName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: Metrics.field)
            }

            SettingRow(title: "Program", description: "Usually npx, uvx or a full path.") {
                TextField("npx", text: $command)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: Metrics.field)
            }

            SettingRow(title: "Arguments", description: "Separated by spaces, as written.") {
                TextField("-y @scope/package", text: $argumentLine)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: Metrics.field)
                    .onSubmit(readByHand)
            }

            HStack {
                Spacer()
                Button("Continue", action: readByHand)
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        command.trimmingCharacters(in: .whitespaces).isEmpty
                            || handName.trimmingCharacters(in: .whitespaces).isEmpty
                    )
            }
        }
    }

    // MARK: - What it needs

    private func fillStep(_ entry: McpCatalogueEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            heading(entry.name, entry.summary)

            Divider().hairline()

            ScrollView {
                VStack(alignment: .leading, spacing: Design.Space.regular) {
                    ForEach(entry.inputs) { input in
                        control(input)
                    }
                }
                .padding(Design.Space.loose)
            }
            .scrollBounceBehavior(.basedOnSize)

            Divider().hairline()

            HStack {
                Button("Back") { step = .choose }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Continue") {
                    step = .review(
                        servers: [entry.server(from: answers)],
                        catalogue: entry.id,
                        secrets: secrets(of: entry)
                    )
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!complete(entry))
            }
            .padding(Design.Space.loose)
        }
    }

    /// One control per thing that has to be answered, and each is the control
    /// the answer actually is.
    ///
    /// This is where "everything is clickable" is either true or it is not. A
    /// folder is a folder picker, so nobody types a path or learns what `~`
    /// means. A key is a secure field with one button to the page that issues
    /// one, so nobody is left hunting. Only the third case is typing, and it
    /// exists for the few things that genuinely are a typed value.
    @ViewBuilder
    private func control(_ input: McpInput) -> some View {
        switch input {
        case let .folder(id, label, help):
            field(label, help) {
                HStack(spacing: Design.Space.tight) {
                    Text(answers[id].map(shortPath) ?? "None chosen")
                        .font(Design.Text.detail)
                        .foregroundStyle(answers[id] == nil
                            ? AnyShapeStyle(.tertiary)
                            : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button("Choose…") { chooseFolder(into: id) }
                        .buttonStyle(answers[id] == nil
                            ? AnyButtonStyle(.borderedProminent)
                            : AnyButtonStyle(.bordered))
                }
            } beneath: {
                EmptyView()
            }

        case let .secret(id, label, help, _, _, from, fromName):
            field(label, help) {
                SecureField("", text: Binding(
                    get: { answers[id] ?? "" },
                    set: { answers[id] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(label)
            } beneath: {
                if let from, let fromName {
                    Button {
                        NSWorkspace.shared.open(from)
                    } label: {
                        Label("Get one from \(fromName)", systemImage: "arrow.up.forward")
                            .font(Design.Text.label)
                    }
                    .buttonStyle(.borderless)
                }
            }

        case let .text(id, label, help, example):
            field(label, help) {
                TextField(example, text: Binding(
                    get: { answers[id] ?? "" },
                    set: { answers[id] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(label)
            } beneath: {
                EmptyView()
            }
        }
    }

    /// A labelled control, stacked rather than side by side.
    ///
    /// `SettingRow` puts the label opposite the control, which is right on a
    /// 640pt settings column and wrong here: in a 520pt sheet the same layout
    /// squeezed "A personal access token. Give it only the repositories you
    /// want the assistant to see" into a third of the width and wrapped it over
    /// six lines beside an empty field. The sentence explaining what to paste
    /// is the most important thing on this screen, so it gets the full width
    /// and the field does too.
    private func field(
        _ label: String,
        _ help: String,
        @ViewBuilder control: () -> some View,
        @ViewBuilder beneath: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.tight) {
            Text(label).font(Design.Text.rowTitle)

            control()

            Text(help)
                .font(Design.Text.label)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                beneath()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func complete(_ entry: McpCatalogueEntry) -> Bool {
        entry.inputs.allSatisfy { input in
            !(answers[input.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    /// The answers that must go to the Keychain rather than into the file,
    /// keyed by the credential name the server config points at.
    private func secrets(of entry: McpCatalogueEntry) -> [String: String] {
        var found: [String: String] = [:]
        for input in entry.inputs {
            if case let .secret(id, _, _, _, credential, _, _) = input {
                found[credential] = answers[id] ?? ""
            }
        }
        return found
    }

    private func chooseFolder(into id: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Everything in this folder becomes readable by the assistant."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        answers[id] = url.path
    }

    // MARK: - The last screen before anything runs

    private func reviewStep(
        _ servers: [McpServerConfig],
        _ entry: McpCatalogueEntry?,
        _ secrets: [String: String]
    ) -> some View {
        let missing = entry.map { !McpRuntimeCheck.isAvailable($0.runtime) } ?? false

        return VStack(alignment: .leading, spacing: 0) {
            heading(
                servers.count == 1 ? servers[0].name : "\(servers.count) connections",
                "Nothing has started yet. This is what will."
            )

            Divider().hairline()

            ScrollView {
                VStack(alignment: .leading, spacing: Design.Space.loose) {
                    if let entry {
                        abilities(entry)
                    } else {
                        unexplained
                    }

                    ForEach(Array(servers.enumerated()), id: \.offset) { _, server in
                        whatRuns(server, secrets: secrets)
                    }

                    if missing, let entry {
                        runtimeMissing(entry)
                    }
                }
                .padding(Design.Space.loose)
            }
            .scrollBounceBehavior(.basedOnSize)

            Divider().hairline()

            HStack {
                Button("Back") { step = .choose }
                Spacer()
                Button("Don't Add", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(servers.count == 1 ? "Add Connection" : "Add \(servers.count)") {
                    Task {
                        for server in servers {
                            await chat.add(server, secrets: secrets)
                        }
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(missing)
            }
            .padding(Design.Space.loose)
        }
    }

    /// What it will be able to do, from the recipe zer0 shipped, before it runs.
    ///
    /// A server only names its tools once it has started, which is after the
    /// moment consent is worth asking for — and its own description of its own
    /// tools is the thing being trusted describing itself, which ADR-0028
    /// refuses as evidence. So the sentences here are ours, and they are shown
    /// first.
    private func abilities(_ entry: McpCatalogueEntry) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.snug) {
            Text("What this lets the assistant do")
                .sectionHeading()
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                ForEach(Array(entry.expects.enumerated()), id: \.element.id) { index, tool in
                    HStack(alignment: .top, spacing: Design.Space.snug) {
                        Image(systemName: McpRisk.symbol(tool.risk))
                            .foregroundStyle(McpRisk.tint(tool.risk))
                            .font(.body)

                        VStack(alignment: .leading, spacing: Design.Space.line) {
                            Text(tool.title)
                                .font(McpRisk.titleFont(tool.risk))
                                .fixedSize(horizontal: false, vertical: true)
                            Text(tool.detail)
                                .font(Design.Text.label)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: Design.Space.snug)
                    }
                    .padding(Design.Space.snug)

                    if index < entry.expects.count - 1 {
                        Divider().hairline().padding(.leading, Design.Space.loose)
                    }
                }
            }
            .background(
                Design.Surface.recessed,
                in: RoundedRectangle(cornerRadius: Design.Radius.medium)
            )

            // No switches on this screen, and that is deliberate rather than
            // unfinished. Nothing here has been agreed to yet in the sense a
            // switch implies: the first time the assistant actually wants one
            // of these it asks, and the answer it gets then is what Connections
            // lists and lets you take back. Two sets of switches for one
            // decision would be a plan and a fact wearing the same control.
            Text("The first time the assistant wants to do any of these, it asks. "
                + "Whatever you answer can be changed in Connections afterwards.")
                .font(Design.Text.label)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A connection zer0 did not ship a recipe for.
    ///
    /// Dashed and uncoloured, which is the consent sheet's shape for *"we have
    /// nothing to assert"* — an outline around nothing, because that is what
    /// this is. Filling it with reassuring prose would be exactly the invented
    /// claim ADR-0018 forbids: we genuinely do not know what an arbitrary
    /// program does until it runs and says so.
    private var unexplained: some View {
        VStack(alignment: .leading, spacing: Design.Space.snug) {
            Text(McpRisk.heading(.unknown))
                .sectionHeading()
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: Design.Space.snug) {
                Image(systemName: McpRisk.symbol(.unknown))
                    .foregroundStyle(.secondary)
                    .font(.body)

                VStack(alignment: .leading, spacing: Design.Space.line) {
                    Text("zer0 did not write this recipe, so it cannot say what this will "
                        + "be able to do until it has started.")
                        .font(Design.Text.detail)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Once it connects, everything it offers is listed in Connections. "
                        + "Nothing is allowed in advance: the first time the assistant "
                        + "wants to use any of it, it asks.")
                        .font(Design.Text.label)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Design.Space.snug)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(
                RoundedRectangle(cornerRadius: Design.Radius.medium)
                    .strokeBorder(
                        .secondary,
                        style: StrokeStyle(
                            lineWidth: Design.Stroke.hairline,
                            dash: [Design.Space.hair, Design.Space.hair]
                        )
                    )
            )
        }
    }

    /// The program, named.
    ///
    /// Somebody is about to let code start on their Mac, and hiding which code
    /// is not a kindness — it is the part that would make a person right to
    /// distrust this sheet if they ever found out afterwards.
    private func whatRuns(_ server: McpServerConfig, secrets: [String: String]) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.snug) {
            Text("What runs")
                .sectionHeading()
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: Design.Space.tight) {
                // The sentence is the core's, not this file's. It is the one
                // line carrying the whole decision, and the core pins it with a
                // test for the same reason ADR-0028 pins the one about
                // `<all_urls>`: nothing goes red when a consequence quietly
                // softens back into a category name.
                Label(
                    server.transport == .stdio
                        ? mcpStdioConsequence()
                        : mcpHttpConsequence(),
                    systemImage: server.transport == .stdio
                        ? "exclamationmark.triangle.fill"
                        : "arrow.up.forward.app"
                )
                .font(Design.Text.detail)
                .foregroundStyle(server.transport == .stdio
                    ? AnyShapeStyle(Design.Palette.warning)
                    : AnyShapeStyle(.secondary))
                .fixedSize(horizontal: false, vertical: true)

                Divider().hairline()

                switch server.transport {
                case .stdio:
                    // Whole, never elided. The specification's words for a
                    // client offering one-click local setup are that it must
                    // show the exact command without truncation, and a view
                    // that ran out of room and put an ellipsis through the
                    // middle would be hiding the argument that matters. The
                    // sheet scrolls; the string does not shrink.
                    Text(mcpExactCommand(command: server.command ?? "", args: server.args))
                        .font(Design.Text.mono)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                case .http:
                    Text(server.url ?? "")
                        .font(Design.Text.mono)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !server.env.isEmpty {
                    Divider().hairline()
                    // Values, because these are the ones the core decided are
                    // *not* secrets. Anything that looked like one is not in
                    // this list — it is below, on its way to the Keychain.
                    Text("Settings passed to it: "
                        + server.env.map { "\($0.name)=\($0.value)" }.joined(separator: ", "))
                        .font(Design.Text.label)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !server.secretEnv.isEmpty {
                    Divider().hairline()
                    keptOut(server, secrets: secrets)
                }
            }
            .padding(Design.Space.snug)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Design.Surface.recessed,
                in: RoundedRectangle(cornerRadius: Design.Radius.medium)
            )
        }
    }

    /// The key, and where it is going instead.
    ///
    /// Worth its own paragraph because it is the one thing this sheet does that
    /// a person would not expect and would care about: a token pasted into the
    /// box above does **not** end up in the file they may be about to commit.
    /// Saying so is also the only way anybody learns the file is safe to
    /// commit.
    private func keptOut(_ server: McpServerConfig, secrets: [String: String]) -> some View {
        let names = server.secretEnv.map(\.name).joined(separator: ", ")
        let lifted = server.secretEnv.contains { secrets[$0.credential] != nil }

        return Label(
            lifted
                ? "\(names) looks like a key, so it goes into your Keychain. The settings "
                    + "file records only the name it is filed under, which is what makes "
                    + "that file safe to commit."
                : "\(names) is read from your Keychain when it starts. It is not in the "
                    + "settings file.",
            systemImage: "key.fill"
        )
        .font(Design.Text.label)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The dependency nobody warned them about.
    ///
    /// Checked here rather than discovered when the connection fails, because
    /// "command not found" two screens later is the single most likely way
    /// somebody who did everything right gets stuck — and it is not their
    /// mistake. Add is disabled, because a button that starts something certain
    /// to fail is the enabled control that does nothing (§9).
    private func runtimeMissing(_ entry: McpCatalogueEntry) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.tight) {
            Label(
                "\(entry.name) needs \(entry.runtime.productName ?? "another program") "
                    + "installed on this Mac, and it is not here yet.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(Design.Text.detail)
            .foregroundStyle(Design.Palette.warning)
            .fixedSize(horizontal: false, vertical: true)

            Text("zer0 cannot install it for you. It is a separate program from a separate "
                + "project, and installing software on your behalf is not something a "
                + "browser should do quietly.")
                .font(Design.Text.label)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let page = entry.runtime.installPage {
                Button {
                    NSWorkspace.shared.open(page)
                } label: {
                    Label(
                        "Get \(entry.runtime.productName ?? "it")",
                        systemImage: "arrow.up.forward"
                    )
                }
            }
        }
        .padding(Design.Space.snug)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Design.Palette.warning.opacity(0.07),
            in: RoundedRectangle(cornerRadius: Design.Radius.medium)
        )
    }

    // MARK: - Reading what was given

    private func readPaste() {
        pasteFailure = nil
        do {
            let reading = try McpConfigPaste.read(pasted)
            step = .review(servers: reading.servers, catalogue: nil, secrets: reading.secrets)
        } catch McpConfigPaste.Failure.notJson {
            pasteFailure = "That is not a settings block. Copy the whole thing, including "
                + "the outermost { and }."
        } catch McpConfigPaste.Failure.noServers {
            pasteFailure = "There are no connections in there. A settings block names at "
                + "least one."
        } catch let McpConfigPaste.Failure.unsupported(name) {
            pasteFailure = "zer0 does not understand how “\(name)” is meant to be reached. "
                + "It names neither a program to run nor an address to call."
        } catch {
            pasteFailure = "zer0 could not read that."
        }
    }

    private func readByHand() {
        let name = handName.trimmingCharacters(in: .whitespaces)
        let arguments = argumentLine
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }

        step = .review(
            servers: [McpServerConfig(
                id: McpConfigPaste.identifier(from: name),
                name: name,
                transport: .stdio,
                command: command.trimmingCharacters(in: .whitespaces),
                args: arguments,
                env: [],
                secretEnv: [],
                url: nil,
                credential: nil,
                enabled: true
            )],
            catalogue: nil,
            secrets: [:]
        )
    }

    // MARK: - Shared furniture

    private func heading(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.hair) {
            Text(title).font(.title3.weight(.semibold))
            Text(subtitle)
                .font(Design.Text.detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Design.Space.loose)
    }

    private func shortPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// A button style chosen at runtime.
///
/// Exists for two rows: the folder picker and the local-provider check, both of
/// which are prominent while nothing has been done and ordinary afterwards.
/// That is the row's whole job and then it is not, and SwiftUI's `buttonStyle`
/// takes a type rather than a value.
struct AnyButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView

    init(_ style: some PrimitiveButtonStyle) {
        make = { configuration in AnyView(Button(configuration).buttonStyle(style)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}
