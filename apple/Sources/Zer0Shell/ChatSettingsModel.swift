import Foundation
import Observation
import Zer0Core

/// What the Chat and Connections panes are looking at.
///
/// One object for both, because they are one configuration: a connection with
/// no provider behind it has nothing to talk to, and each pane's empty state
/// has to know about the other.
///
/// **It holds no rules of its own.** Which provider a chat opens on, whether a
/// credential name is really a name, what counts as ready, when the file has to
/// be re-read, where a secret lives — every one of those belongs to `Zer0Config`
/// or to `ConfigHost`, and is asked for rather than reimplemented. What is left
/// is the one thing neither of them does: **finding out whether a key works**,
/// which is a request nobody else was making.
///
/// So what is tested on this object is **the crossings**: that a switch reaches
/// the layer underneath instead of repainting a row, and that a key the
/// provider refused is never written down.
@MainActor
@Observable
final class ChatSettingsModel {
    private let host: ConfigHost

    /// The one `ConfigHost` in the process, shared with `BrowserModel`.
    ///
    /// Two of them over one file would be two answers to "which provider
    /// answers this question", and they diverge the moment a setting changes:
    /// the pane would go green while the browser kept using the old provider.
    var configHost: ConfigHost { host }
    private let probe: ChatProviderProbe
    /// How a tool decision leaves the pane. `Action.setToolConsent` is the
    /// core's own door for exactly this — *"change a remembered answer from
    /// Settings, without a call in flight"* — so the pane does not get a
    /// private one.
    private var dispatch: (Action) -> Void
    /// Where the tool ledger is read from. A closure rather than a `Zer0`
    /// handle, because a settings model owning one would be a second thing
    /// holding the browser open, and because the tests have no browser at all.
    private var readLedger: () -> ([ToolDescriptor], [ToolGrant]) = { ([], []) }

    /// What the last key check said, for the provider in hand.
    ///
    /// Not in the file: it is about this moment rather than about what is
    /// configured, and a spinner that survived a restart would be a lie.
    private(set) var keyState: ChatKeyState = .absent

    /// What went wrong writing to the file, if anything did. Cleared on the
    /// next attempt rather than on a timer: somebody reading an error is not on
    /// a clock.
    var failure: String?

    /// The connection being added, so the screen can say so while it happens.
    private(set) var adding: String?

    /// Every tool the connected servers have published, and what was decided
    /// about each. Both come from the core — `Zer0.knownTools` and
    /// `Zer0.toolGrants` — and stay empty until a server has connected and said.
    private(set) var tools: [ToolDescriptor] = []
    private(set) var grants: [ToolGrant] = []

    /// Where each connection has actually got to.
    ///
    /// Separate from `Readiness`, which answers a different question and used
    /// to be asked this one. `Readiness` is about the *file* — is it switched
    /// on, does its key exist — and a file can be flawless while the server it
    /// describes is not running. Reading one as the other is how a connection
    /// that could not be reached showed a tick and the sentence "Ready".
    private(set) var connections: [String: McpServerState] = [:]

    /// Where connection state is read from. A closure for the same reason
    /// `readLedger` is one: the tests have no browser at all.
    private var readServerState: (String) -> McpServerState = { _ in .idle }

    /// Bumped whenever the file underneath changes.
    ///
    /// `ConfigHost` is `@Observable` and this object reads through it, but a
    /// SwiftUI view observing *this* one does not automatically observe *that*
    /// one through a computed property. This is the one piece of state that
    /// makes a reload redraw the pane, which is what an external editor's save
    /// has to do.
    private(set) var revision = 0

    /// Live, for the app. Tests and the harness build their own.
    static let shared = ChatSettingsModel()

    init(
        host: ConfigHost = ConfigHost(),
        probe: ChatProviderProbe = NetworkChatProviderProbe(),
        dispatch: @escaping (Action) -> Void = { _ in }
    ) {
        self.host = host
        self.probe = probe
        self.dispatch = dispatch
        keyState = storedKeyState()

        // An edit made in somebody's editor has to reach this pane and not only
        // the browser. `ConfigHost` already watches the file and the directory
        // it sits in; this is the pane joining that, rather than a second
        // watcher with its own idea of when to read.
        host.onChange = { [weak self] in self?.refresh() }
    }

    /// Attach to the running browser.
    ///
    /// Called by each pane as it appears rather than at construction, because
    /// the settings model outlives any one window and the browser is what holds
    /// the core handle. Idempotent: appearing twice attaches to the same thing
    /// twice.
    func bind(to browser: BrowserModel) {
        dispatch = { [weak browser] action in browser?.send(action) }
        readLedger = { [weak browser] in
            guard let browser else { return ([], []) }
            return (browser.knownTools, browser.toolGrants)
        }
        readServerState = { [weak browser] id in
            browser?.mcpServerState(id) ?? .idle
        }
        // Pushed, so a proxy quit in another window changes this pane while
        // somebody is looking at it rather than the next time they open it.
        browser.connectionsChanged = { [weak self] server, state in
            self?.noteConnection(server, state)
        }
        refresh()
    }

    // MARK: - Keeping in step

    /// Re-read everything the panes draw from.
    ///
    /// The file is the truth: somebody's editor may have changed it since, and
    /// `ConfigHost` is what notices.
    /// Record where one connection has got to.
    ///
    /// The one way this changes outside a full `refresh`, so the pushed update
    /// and the re-read cannot come to different conclusions about what the row
    /// says.
    func noteConnection(_ server: String, _ state: McpServerState) {
        connections[server] = state
    }

    func refresh() {
        host.reloadNow()
        (tools, grants) = readLedger()
        connections = Dictionary(
            uniqueKeysWithValues: host.config.mcpServers.map { ($0.id, readServerState($0.id)) }
        )
        revision += 1
    }

    // MARK: - Reading

    var file: Config { host.config }
    var providers: [ProviderConfig] { host.config.providers }
    var servers: [McpServerConfig] { host.config.mcpServers }
    var configPath: String { host.path }
    var exists: Bool { host.exists }
    var isReadable: Bool { host.isReadable }
    var diagnostics: [ConfigDiagnostic] { host.diagnostics }

    /// The provider a new chat would open on, decided by the core.
    var effectiveProvider: ProviderConfig? { host.effectiveProvider() }

    /// The one being configured. The default when there is one, otherwise the
    /// first entry, otherwise nothing — which is the empty state.
    var current: ProviderConfig? {
        host.config.defaultProvider.flatMap { id in providers.first { $0.id == id } }
            ?? providers.first
    }

    func readiness(of provider: ProviderConfig) -> Readiness {
        host.readiness(ofProvider: provider.id)
    }

    func readiness(of server: McpServerConfig) -> Readiness {
        host.readiness(ofServer: server.id)
    }

    /// Whether anything at all has been set up.
    ///
    /// A named property rather than an inline condition, for the same reason
    /// `showsSessionWarning` is one: a screen nobody can reach from a test is a
    /// screen that quietly stops appearing.
    var isConfigured: Bool { !providers.isEmpty }

    /// Whether the key this provider names is on this machine.
    ///
    /// `availableCredentials` is names only. Nothing on this side of the
    /// Keychain has ever held the characters, which is why the pane can say a
    /// key is saved without being able to print it even if somebody asked it to.
    func hasKey(_ provider: ProviderConfig) -> Bool {
        guard let name = provider.credential else { return true }
        return host.availableCredentials.contains(name)
    }

    /// Set when the Keychain itself would not answer, which is a different
    /// thing from it having no key. A locked keychain reported as "no keys"
    /// would invite somebody to paste all of theirs in again.
    var credentialStoreError: String? { host.credentialStoreError }

    /// Something the file said that a person should see.
    ///
    /// Errors first: an error means something was dropped, so the pane is
    /// showing less than the file says and has to admit it.
    var worstDiagnostic: ConfigDiagnostic? {
        host.errors.first ?? host.diagnostics.first
    }

    func revealConfigInFinder() { host.revealInFinder() }

    // MARK: - Choosing a provider

    /// Add this kind if it is not there, and make it the one a chat opens on.
    @discardableResult
    func choose(_ style: ChatProviderStyle) -> ProviderConfig? {
        failure = nil
        let provider = providers.first { $0.kind == style.kind }
            ?? ChatProviderStyles.newProvider(style)
        do {
            if !providers.contains(where: { $0.id == provider.id }) {
                try host.upsertProvider(provider)
            }
            try host.setDefaultProvider(id: provider.id)
        } catch {
            failure = describe(error)
            return nil
        }
        revision += 1
        keyState = storedKeyState()
        return current
    }

    func setBaseUrl(_ url: String, on provider: ProviderConfig) {
        var next = provider
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        next.baseUrl = trimmed.isEmpty ? nil : trimmed
        write(next)
    }

    func select(model: String, on provider: ProviderConfig) {
        var next = provider
        next.defaultModel = model
        write(next)
    }

    private func write(_ provider: ProviderConfig) {
        failure = nil
        do {
            try host.upsertProvider(provider)
        } catch {
            failure = describe(error)
            return
        }
        revision += 1
    }

    // MARK: - The key

    /// Whether this looks like a key for the provider that is selected.
    ///
    /// Checked before the network, and it catches the commonest paste mistake:
    /// an OpenAI key under Claude. A hint and never a refusal — a provider is
    /// free to change its prefix, and a settings screen that rejects a working
    /// key because it looks unusual is worse than one that lets the provider
    /// answer.
    func prefixWarning(for entry: String, provider: ProviderConfig) -> String? {
        let style = ChatProviderStyles.style(for: provider.kind)
        guard let prefix = style.keyPrefix else { return nil }
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 6, !trimmed.hasPrefix(prefix) else { return nil }

        if let other = ChatProviderStyles.all.first(where: {
            $0.kind != style.kind && $0.keyPrefix.map(trimmed.hasPrefix) == true
        }) {
            return "That looks like a \(other.name) key, and you have \(style.name) selected."
        }
        return "A \(style.name) key usually starts with \(prefix). This one does not, "
            + "so it may not work."
    }

    /// Hand over a key and find out whether it works, in one step.
    ///
    /// **Storing and checking are deliberately not separable from outside.** A
    /// key stored without being checked is a key somebody finds out about in
    /// the middle of a conversation three days later, and pasting one is the
    /// most likely place in the whole product to fail. The check comes back
    /// with the model catalogue, so the menu underneath fills as a consequence
    /// of the key going green rather than as a second thing to press.
    func submit(key entry: String, for provider: ProviderConfig) async {
        let secret = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty, let name = provider.credential else { return }

        keyState = .checking
        let result = await probe.check(provider: provider, key: secret)

        switch result {
        case let .working(models):
            do {
                // Written only now. A key the provider refused is not stored:
                // otherwise the pane reopens showing a saved key beside a red
                // line, and "saved" starts meaning nothing.
                try host.storeSecret(secret, named: name)
            } catch {
                keyState = .refused(describe(error))
                return
            }
            remember(models, on: provider)
            keyState = .working(models: models.count)
        case let .refused(why):
            keyState = .refused(why)
        case let .unreachable(why):
            keyState = .unreachable(why)
        }
    }

    /// Check a provider that needs no key, which is also how the local one gets
    /// a model list.
    func probeWithoutKey(_ provider: ProviderConfig) async {
        keyState = .checking
        switch await probe.check(provider: provider, key: nil) {
        case let .working(models):
            remember(models, on: provider)
            keyState = .working(models: models.count)
        case let .refused(why):
            keyState = .refused(why)
        case let .unreachable(why):
            keyState = .unreachable(why)
        }
    }

    /// Write what the provider said it can run into the file, so the menu
    /// survives a restart and so somebody reading the file can see it.
    private func remember(_ models: [String], on provider: ProviderConfig) {
        guard !models.isEmpty else { return }
        var next = provider
        next.models = models
        if next.defaultModel == nil || !models.contains(next.defaultModel ?? "") {
            next.defaultModel = models.first
        }
        write(next)
    }

    func forgetKey(of provider: ProviderConfig) {
        failure = nil
        guard let name = provider.credential else { return }
        do {
            try host.removeSecret(named: name)
        } catch {
            failure = describe(error)
            return
        }
        revision += 1
        keyState = .absent
    }

    /// What the pane opens saying, before anything has been checked this run.
    private func storedKeyState() -> ChatKeyState {
        guard let provider = current else { return .absent }
        guard provider.credential != nil else { return .stored }
        return hasKey(provider) ? .stored : .absent
    }

    // MARK: - Connections

    /// Add a connection, with the screen saying so while it happens.
    ///
    /// `secrets` are values that must not reach the file: they go into the
    /// Keychain under the names the server config points at, and the file
    /// records only those names.
    @discardableResult
    func add(_ server: McpServerConfig, secrets: [String: String] = [:]) async -> Bool {
        failure = nil
        adding = server.name
        defer { adding = nil }

        for (name, value) in secrets where !value.isEmpty {
            do {
                try host.storeSecret(value, named: name)
            } catch {
                failure = "\(server.name) was not added: \(describe(error))"
                return false
            }
        }
        do {
            try host.upsertServer(server)
        } catch {
            failure = describe(error)
            return false
        }
        revision += 1
        return true
    }

    func remove(_ server: McpServerConfig) {
        failure = nil
        do {
            try host.removeServer(id: server.id)
        } catch {
            failure = describe(error)
            return
        }
        // The credentials it named go with it. A key left behind under a name
        // nothing points at is a secret nobody can find in order to delete it.
        for secret in server.secretEnv { try? host.removeSecret(named: secret.credential) }
        if let credential = server.credential { try? host.removeSecret(named: credential) }
        revision += 1
    }

    func setEnabled(_ server: McpServerConfig, _ enabled: Bool) {
        failure = nil
        do {
            try host.setServer(id: server.id, enabled: enabled)
        } catch {
            failure = describe(error)
            return
        }
        revision += 1
    }

    // MARK: - What a connection may do

    /// The tools this server has published, if it has connected.
    func tools(of server: McpServerConfig) -> [ToolDescriptor] {
        tools.filter { $0.server == server.id }
    }

    /// `nil` means nobody was ever asked, which is not the same as no.
    func decision(server: String, tool: String) -> Bool? {
        grants.first { $0.server == server && $0.tool == tool }?.allowed
    }

    /// Change a remembered answer. Through the core's own door for this, so a
    /// decision made here is the same decision a running tool call reads.
    func setConsent(server: String, tool: String, allowed: Bool) {
        dispatch(.setToolConsent(server: server, tool: tool, allowed: allowed))
        rereadLedger()
    }

    /// Take an answer back, so the next call asks again.
    func forgetConsent(server: String, tool: String) {
        dispatch(.forgetToolConsent(server: server, tool: tool))
        rereadLedger()
    }

    /// The ledger, handed in directly. For tests and for the shot harness,
    /// which have no browser to read one from.
    func ingest(tools: [ToolDescriptor], grants: [ToolGrant]) {
        self.tools = tools
        self.grants = grants
    }

    /// Re-read the ledger after a decision, so a row redraws having actually
    /// asked rather than having assumed the dispatch worked.
    private func rereadLedger() {
        (tools, grants) = readLedger()
    }

    // MARK: - The file itself

    /// Write the commented example, for a machine with no file yet.
    func writeExample() {
        failure = nil
        do {
            try host.writeExample()
        } catch {
            failure = describe(error)
            return
        }
        revision += 1
    }

    /// An error said as a sentence.
    ///
    /// `ConfigError` and `SecretStoreError` both already name what happened and
    /// what to do about it, so this mostly gets out of the way. It exists so a
    /// refusal never surfaces as a Swift enum case name.
    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: - Status, in one sentence

    /// What a connection is doing, and what it is waiting on.
    ///
    /// The interesting case is `missingCredential`, which is the normal state
    /// five minutes after cloning a dotfiles repository onto a new Mac: the
    /// file describes everything perfectly and none of the keys are here yet.
    /// That is a to-do list, not a failure, and it says which key.
    func status(of server: McpServerConfig) -> (summary: String, symbol: String, healthy: Bool) {
        switch readiness(of: server) {
        case .disabled:
            return ("Switched off. Still set up, not running.", "pause.circle", false)
        case let .missingCredential(credential):
            return (
                "Waiting on a key. The file calls it “\(credential)”, and this Mac does "
                    + "not have one yet.",
                "key", false
            )
        case .unknown:
            return ("Not in the settings file.", "questionmark.circle", false)
        case .ready:
            // The file is in order. What the connection is doing is a different
            // question, and it is the one somebody staring at this row wants
            // answered.
            switch connections[server.id] ?? .idle {
            case .idle:
                return (
                    "Set up, not connected yet. zer0 connects when the assistant first "
                        + "needs it.",
                    "clock", true
                )
            case .starting:
                return ("Connecting…", "clock", true)
            case .stopped:
                return ("Disconnected.", "pause.circle", false)
            case let .failed(failure, message):
                // The server's situation, in the core's words, never "zer0
                // failed". A local proxy that is not running is the normal
                // state of a local proxy, not a defect in this browser — and it
                // is the state it will be in most of the time somebody looks.
                return (
                    message.isEmpty ? failure.reasonText : message,
                    failure == .unreachable ? "bolt.horizontal.circle" : "exclamationmark.triangle",
                    false
                )
            case .ready:
                break
            }

            let published = tools(of: server)
            if published.isEmpty {
                return (
                    "Connected. It has not said what it can do yet.",
                    "clock", true
                )
            }
            let allowed = published.filter { decision(server: server.id, tool: $0.tool) == true }
            if allowed.isEmpty {
                return (
                    "Connected, and allowed to do nothing yet. It will ask the first time.",
                    "hand.raised", true
                )
            }
            return (
                allowed.count < published.count
                    ? "Allowed to do \(allowed.count) of the \(published.count) things it offers."
                    : "Allowed to do all \(published.count) things it offers.",
                "checkmark.seal", true
            )
        }
    }
}
