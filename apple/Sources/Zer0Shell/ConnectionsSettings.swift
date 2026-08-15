import AppKit
import SwiftUI
import Zer0Core

/// What the assistant can reach beyond the conversation, and how to take any of
/// it back.
///
/// The vocabulary is the consent sheet's, on purpose. A connection that reads
/// every file in a folder and an extension that reads every page in the browser
/// are the same size of decision, and giving them two scales would be inventing
/// a second grammar for one idea. So the risk tiers are `PermissionRisk`, the
/// colours are the palette's three status hues, and every row says what
/// something costs you rather than what it is called.
struct ConnectionsSettings: View {
    @Environment(BrowserModel.self) private var browser: BrowserModel?
    @State private var chat: ChatSettingsModel
    @State private var adding = false
    /// Which connections have their permissions open.
    @State private var expanded: Set<String> = []

    private enum Metrics {
        /// The connection's symbol, in a column so every name starts on the
        /// same vertical whatever its glyph renders at.
        static let iconColumn: CGFloat = 22
        /// The three-way answer menu. Sized to "Ask each time", which is the
        /// longest of the three and the one it opens on.
        static let consentMenu: CGFloat = 140
    }

    init(_ chat: ChatSettingsModel = .shared) {
        _chat = State(initialValue: chat)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.loose) {
            header

            if chat.servers.isEmpty {
                empty
            } else {
                composer
                list
            }

            if let failure = chat.failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(Design.Text.label)
                    .foregroundStyle(Design.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .motion(.subtle, value: chat.servers.count)
        .onAppear { if let browser { chat.bind(to: browser) } }
        .sheet(isPresented: $adding) {
            McpAddSheet(chat: chat)
        }
    }

    /// No title: the sidebar row already says "Connections", and a pane that
    /// repeats its own name is chrome that does not pay for itself. What it
    /// opens with is the part the sidebar cannot say — and what it says is a
    /// consequence, because everything below is a decision about access.
    private var header: some View {
        Text("A connection lets the assistant reach something outside the conversation — a "
            + "folder, an account, a site. Nothing is connected until you add it, and "
            + "everything one can do is listed and switchable here.")
            .font(Design.Text.detail)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// §9: an empty state teaches the feature and hands over the first step.
    private var empty: some View {
        EmptyState(
            icon: "point.3.connected.trianglepath.dotted",
            title: "Nothing connected",
            message: "The assistant can only see what you type. Connect a folder or an "
                + "account and it can work with what is actually there."
        ) {
            Button {
                adding = true
            } label: {
                Label("Add a Connection", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .frame(minHeight: Design.Pane.emptyStateMinHeight)
    }

    private var composer: some View {
        HStack(spacing: Design.Space.tight) {
            Text("Connected to \(chat.servers.count) "
                + "\(chat.servers.count == 1 ? "thing" : "things").")
                .font(Design.Text.label)
                .foregroundStyle(.secondary)

            Spacer(minLength: Design.Space.regular)

            if let name = chat.adding {
                HStack(spacing: Design.Space.tight) {
                    ProgressView().controlSize(.small)
                    Text("Adding \(name)…")
                        .font(Design.Text.label)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    adding = true
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(Design.Space.regular)
        .background(
            Design.Surface.recessed,
            in: RoundedRectangle(cornerRadius: Design.Radius.medium)
        )
    }

    private var list: some View {
        VStack(spacing: 0) {
            ForEach(Array(chat.servers.enumerated()), id: \.element.id) { index, server in
                row(server)

                if index < chat.servers.count - 1 {
                    Divider().hairline().padding(.leading, Design.Space.regular)
                }
            }
        }
        .background(
            Design.Surface.recessed,
            in: RoundedRectangle(cornerRadius: Design.Radius.medium)
        )
    }

    private func row(_ server: McpServerConfig) -> some View {
        let status = chat.status(of: server)

        return VStack(alignment: .leading, spacing: Design.Space.snug) {
            HStack(alignment: .top, spacing: Design.Space.snug) {
                Image(systemName: McpCatalogue.entry(server.id)?.symbol ?? "shippingbox")
                    .font(.title3)
                    .foregroundStyle(status.healthy
                        ? AnyShapeStyle(.tint)
                        : AnyShapeStyle(.tertiary))
                    .frame(width: Metrics.iconColumn)

                VStack(alignment: .leading, spacing: Design.Space.line) {
                    Text(server.name).font(Design.Text.rowTitle)

                    Text(reach(server))
                        .font(Design.Text.label)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Label(status.summary, systemImage: status.symbol)
                        .font(Design.Text.label)
                        .foregroundStyle(status.healthy
                            ? AnyShapeStyle(.secondary)
                            : AnyShapeStyle(Design.Palette.warning))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: Design.Space.regular)

                controls(server)
            }

            if expanded.contains(server.id) {
                permissions(server)
            }
        }
        .padding(Design.Space.regular)
        .motion(.subtle, value: expanded)
    }

    /// Where this connection actually goes: a program on this Mac, or a server
    /// somewhere else. Those are different sizes of trust, and the row says
    /// which without being asked.
    private func reach(_ server: McpServerConfig) -> String {
        switch server.transport {
        case .stdio:
            "Runs a program on this Mac."
        case .http:
            httpReach(server.url ?? "")
        }
    }

    /// A URL on this machine is not "over the internet", and saying so of a
    /// proxy on `127.0.0.1` would be the row inventing a risk that is not there
    /// — which costs exactly as much trust as hiding one that is (ADR-0018).
    /// The core decides which is which, because it is the same question it
    /// answers when it decides whether the address may be reached at all.
    private func httpReach(_ address: String) -> String {
        let name = URL(string: address)?.host() ?? address
        switch mcpEndpointVerdict(url: address) {
        case let .allowed(_, loopback):
            return loopback
                ? "Reaches \(name) on this Mac. Nothing leaves the machine."
                : "Reaches \(name) over the internet."
        case let .refused(reason):
            return reason
        }
    }

    @ViewBuilder
    private func controls(_ server: McpServerConfig) -> some View {
        HStack(spacing: Design.Space.snug) {
            // Bordered, not borderless. Rendered beside `DestructiveButton`,
            // which macOS draws with a border, a borderless button reads as a
            // label somebody forgot to style — and this one is the only way to
            // reach what a connection is allowed to do.
            Button(expanded.contains(server.id) ? "Hide" : "What It Can Do") {
                if expanded.contains(server.id) {
                    expanded.remove(server.id)
                } else {
                    expanded.insert(server.id)
                }
            }
            .buttonStyle(.bordered)

            DestructiveButton(
                title: "Remove",
                question: "Remove \(server.name)?",
                consequence: removalConsequence(server),
                confirm: "Remove"
            ) {
                chat.remove(server)
                expanded.remove(server.id)
            }

            // Trailing, where every other switch in this window sits. Between
            // the two buttons it read as though the button beside it were its
            // label, which on a control that decides whether something runs is
            // not a small ambiguity.
            //
            // Off keeps the entry and takes it out of use: deleting to switch
            // something off and retyping it to switch it back on is not a
            // toggle. That is the core's own reasoning on `enabled`, and this
            // is the control it exists for.
            SettingSwitch(
                label: "\(server.name) is on",
                isOn: Binding(
                    get: { server.enabled },
                    set: { chat.setEnabled(server, $0) }
                )
            )
            .controlSize(.mini)
        }
    }

    /// What removing actually costs, named rather than gestured at.
    ///
    /// The key is the part somebody would not think of: a connection that named
    /// one takes it out of the Keychain with it, and a person who re-adds the
    /// same server tomorrow will be asked for it again. Saying so beforehand is
    /// the difference between a decision and a surprise.
    private func removalConsequence(_ server: McpServerConfig) -> String {
        let base = "The assistant loses access to it immediately. Nothing it already did is "
            + "undone, and nothing on your Mac is deleted."
        let credentials = server.secretEnv.map(\.credential)
            + (server.credential.map { [$0] } ?? [])
        guard !credentials.isEmpty else { return base }
        return base + " The key it was using — “\(credentials.joined(separator: "”, “"))” — "
            + "is taken out of your Keychain too."
    }

    /// What this connection is allowed to do, with a way to take each one back.
    ///
    /// Switching a row goes through `Action.setToolConsent`, which is the same
    /// ledger a tool call in flight reads. It is not a repaint, and it is not a
    /// second copy of the decision: a tool approved here does not ask again,
    /// and one taken back here asks the next time the model wants it.
    @ViewBuilder
    private func permissions(_ server: McpServerConfig) -> some View {
        let published = chat.tools(of: server)

        VStack(alignment: .leading, spacing: 0) {
            whatRuns(server)
            Divider().hairline()

            if published.isEmpty {
                notYetKnown(server)
            } else {
                ForEach(Array(published.enumerated()), id: \.offset) { index, tool in
                    toolRow(tool, on: server)

                    if index < published.count - 1 {
                        Divider().hairline()
                    }
                }
            }
        }
        .background(
            Design.Surface.recessedInner,
            in: RoundedRectangle(cornerRadius: Design.Radius.small)
        )
        .padding(.leading, Design.Space.section)
    }

    /// The program, whole, after the fact.
    ///
    /// The review sheet showed this before anything started; somebody looking a
    /// month later has as much right to it, and more reason — this is the row
    /// they reach for when they are trying to remember what they agreed to.
    private func whatRuns(_ server: McpServerConfig) -> some View {
        HStack(alignment: .top, spacing: Design.Space.snug) {
            Image(systemName: server.transport == .stdio ? "terminal" : "globe")
                .foregroundStyle(.secondary)
                .font(Design.Text.detail)

            Text(server.transport == .stdio
                ? mcpExactCommand(command: server.command ?? "", args: server.args)
                : server.url ?? "")
                .font(Design.Text.mono)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: Design.Space.snug)
        }
        .padding(Design.Space.snug)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A connection that has not published anything yet.
    ///
    /// Deliberately not filled with a plausible list from the catalogue.
    /// ADR-0018: the interface asserts only what the layer beneath it can back
    /// up, and until the server has connected and said what it has, this row
    /// knows nothing. What it can honestly promise is the thing that matters —
    /// that the first time anything runs, it asks.
    private func notYetKnown(_ server: McpServerConfig) -> some View {
        HStack(alignment: .top, spacing: Design.Space.snug) {
            Image(systemName: McpRisk.symbol(.unknown))
                .foregroundStyle(.secondary)
                .font(Design.Text.detail)

            VStack(alignment: .leading, spacing: Design.Space.line) {
                Text("\(server.name) has not said what it can do yet.")
                    .font(Design.Text.detail)
                    .fixedSize(horizontal: false, vertical: true)
                Text("The list fills in once it has connected. Until then nothing is "
                    + "allowed in advance: the first time the assistant wants to use "
                    + "anything here, it asks.")
                    .font(Design.Text.label)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Design.Space.snug)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toolRow(_ tool: ToolDescriptor, on server: McpServerConfig) -> some View {
        let decided = chat.decision(server: server.id, tool: tool.tool)

        return HStack(alignment: .top, spacing: Design.Space.snug) {
            // Grey, and hollow. zer0 did not write this sentence — the server
            // did, about itself — so there is no risk tier to paint. Colouring
            // it would be the browser ranking a claim it did not make and
            // cannot check (ADR-0018).
            Image(systemName: McpRisk.symbol(.unknown))
                .foregroundStyle(.secondary)
                .font(Design.Text.detail)

            VStack(alignment: .leading, spacing: Design.Space.line) {
                Text(tool.tool)
                    .font(Design.Text.detail)
                    .fixedSize(horizontal: false, vertical: true)
                // Said as the server's own words, because that is what it is.
                Text(tool.summary.isEmpty
                    ? "\(server.name) gave no description of this."
                    : "\(server.name) describes this as: \(tool.summary)")
                    .font(Design.Text.label)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: Design.Space.snug)

            // Three states, not two. "Nobody was asked" is not "no", and
            // collapsing them would turn every un-asked tool into a refusal
            // nobody made — the exact confusion ADR-0028 keeps out of extension
            // permissions.
            Picker("", selection: Binding(
                get: { decided.map { $0 ? Answer.allow : .refuse } ?? .ask },
                set: { answer in
                    switch answer {
                    case .ask: chat.forgetConsent(server: server.id, tool: tool.tool)
                    case .allow: chat.setConsent(server: server.id, tool: tool.tool, allowed: true)
                    case .refuse: chat.setConsent(server: server.id, tool: tool.tool, allowed: false)
                    }
                }
            )) {
                Text("Ask each time").tag(Answer.ask)
                Text("Always allow").tag(Answer.allow)
                Text("Never").tag(Answer.refuse)
            }
            .labelsHidden()
            .frame(width: Metrics.consentMenu, alignment: .trailing)
            .accessibilityLabel(tool.tool)
        }
        .padding(.vertical, Design.Space.tight)
        .padding(.horizontal, Design.Space.snug)
    }

    /// The three answers a remembered decision can be in.
    private enum Answer: Hashable {
        case ask, allow, refuse
    }
}

// MARK: - How a tier looks

/// The risk grammar, for what a connection can do.
///
/// **Merge me.** `ExtensionConsentSheet` carries the same five-way mapping over
/// the same `PermissionRisk`, written as private methods on the sheet. Two
/// copies of one ranking is exactly the drift that turns a scale into a
/// decoration, and the next time either changes they have to change together.
/// Whichever lands second takes the other's copy out. The argument for each
/// choice is written where it was first made, on the sheet.
enum McpRisk {
    static func symbol(_ risk: PermissionRisk) -> String {
        switch risk {
        case .critical: "exclamationmark.triangle.fill"
        case .high: "exclamationmark.circle.fill"
        case .unknown: "questionmark.circle"
        case .moderate: "info.circle.fill"
        case .low: "checkmark.circle.fill"
        }
    }

    static func tint(_ risk: PermissionRisk) -> Color {
        switch risk {
        case .critical: Design.Palette.danger
        case .high: Design.Palette.warning
        case .unknown, .moderate, .low: .secondary
        }
    }

    static func titleFont(_ risk: PermissionRisk) -> Font {
        switch risk {
        case .critical: Design.Text.detail.weight(.semibold)
        case .high: Design.Text.detail.weight(.medium)
        case .unknown, .moderate, .low: Design.Text.detail
        }
    }

    static func heading(_ risk: PermissionRisk) -> String {
        switch risk {
        case .critical: "Changes things"
        case .high: "Reads things you would not paste into a chat"
        case .unknown: "zer0 cannot explain these"
        case .moderate: "Real access, and only this much"
        case .low: "Housekeeping"
        }
    }
}
