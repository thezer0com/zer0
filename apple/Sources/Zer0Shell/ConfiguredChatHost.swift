import Foundation
import Zer0Core

/// Which model a provider will answer with, or `nil` when it names none.
///
/// **The one door.** The composer prints this and the request is built from it,
/// and those must be the same sentence: a footer naming a model the request
/// would not use is a claim nothing backs (ADR-0018), and it goes wrong in the
/// direction that is hardest to notice — the name looks right and the answer
/// comes from somewhere else. Written once here, next to the resolution it is
/// half of, so the second caller cannot pick a different rule.
///
/// `nil` for a provider with no model named is not a gap to fill in. A guess
/// would be refused by the provider a second later, with a message from an API
/// instead of one from zer0.
func modelThatWillAnswer(_ provider: ProviderConfig?) -> String? {
    guard let provider else { return nil }
    return provider.defaultModel ?? provider.models.first
}

/// A server described in a way that cannot be connected to.
///
/// One type for every shape of it, carrying the core's sentence when there is
/// one, because the person reading it does not care which `guard` it came out
/// of — they care what to change in the file.
struct MisconfiguredServer: LocalizedError {
    let detail: String
    var errorDescription: String? { detail }
}

/// Turn a configured server into something to talk to.
///
/// **The one door.** Every transport is decided here and nowhere else, which is
/// what makes the address rule a rule: `HttpLink` takes a `URL` and cannot be
/// handed the raw text out of the file, so the only way to build one is through
/// the `mcpEndpointVerdict` below it. A second place that made links would be a
/// second place entitled to skip the check.
///
/// A free function rather than a closure inside `ConfiguredChatHost.init` so a
/// test can ask it directly what it does with an address, without a browser, a
/// Keychain or a network.
@MainActor
func makeMcpLink(
    _ server: McpServerConfig,
    environment: [String: String],
    secret: (String) -> String?
) throws -> McpLink {
    // No `default:`. A transport added to the configuration has to break the
    // build here until it has a way to be reached (ADR-0031).
    switch server.transport {
    case .stdio:
        guard let command = server.command, !command.isEmpty else {
            throw MisconfiguredServer(
                detail: "\(server.id) runs a program on this Mac, and names no command."
            )
        }
        return try StdioLink(command: command, args: server.args, environment: environment)

    case .http:
        guard let address = server.url, !address.isEmpty else {
            throw MisconfiguredServer(detail: "\(server.id) is reached at a URL, and names none.")
        }
        // Which addresses may be reached is a decision, so it is the core's
        // (ADR-0099). Refused rather than repaired: no upgrade to https and
        // retry, no stripping a path that did not work.
        switch mcpEndpointVerdict(url: address) {
        case let .refused(reason):
            throw MisconfiguredServer(detail: reason)
        case let .allowed(checked, _):
            guard let url = URL(string: checked) else {
                throw MisconfiguredServer(
                    detail: "\(server.id) names an address zer0 could not open."
                )
            }
            return HttpLink(
                url: url,
                // Resolved at the moment it is used and never held. A server
                // whose `credential` names nothing in the Keychain connects
                // without one rather than being stopped: an endpoint that wants
                // a token says so with a 401, in its own words, and refusing on
                // its behalf would be zer0 asserting something it cannot know.
                token: server.credential.flatMap(secret)
            )
        }
    }
}

/// The `ChatHost` the browser actually runs on: a provider on one side, tool
/// servers on the other, and configuration resolving both.
///
/// This exists because the two halves were each complete and neither was
/// plugged in. `ChatProviderHost` speaks four wires and was built only by
/// tests; `McpHost` speaks MCP over stdio and was built nowhere at all. What was
/// missing was the piece that reads `ConfigHost`, turns a `ProviderConfig` into
/// the endpoint and model a request needs, and reads the key out of the
/// Keychain at the moment it is used.
///
/// It decides as little as it can get away with. **Every mapping that two
/// platforms could not reasonably disagree about is asked of the core**, down to
/// which wire a provider kind speaks — a Swift `switch` from `ProviderKind` to
/// `WireFormat` would be a second opinion about a question `chatWireFormat`
/// already answers, and the half that is wrong is always the one in the shell.
@MainActor
final class ConfiguredChatHost: ChatHost {
    private let provider = ChatProviderHost()
    private let mcp: McpHost
    private let config: ConfigHost
    private let emit: @MainActor (Action) -> Void
    /// What the core says the configured servers can do. A closure rather than
    /// a stored list, because the register changes when a server connects and a
    /// copy here would be a second answer to a question the core already
    /// answers.
    var knownTools: (@MainActor () -> [ToolDescriptor])?

    init(
        config: ConfigHost,
        appVersion: String = "0.1.0",
        emit: @escaping @MainActor (Action) -> Void
    ) {
        self.config = config
        self.emit = emit
        mcp = McpHost(appVersion: appVersion)

        provider.emit = emit
        provider.resolve = { [weak self] _ in self?.resolved() }
        // The one route to a secret this host has, and it is a closure so the
        // host holds no service name, no file handle and no key of its own.
        provider.token = { [config] name in
            try await MainActor.run { try config.secret(named: name) }
        }

        mcp.emit = emit
        mcp.secret = { [config] name in try? config.secret(named: name) }
        mcp.setServerState = { [weak self] server, state in
            self?.serverStateChanged?(server, state)
        }
        mcp.makeLink = { [config] server, environment in
            try makeMcpLink(server, environment: environment) { credential in
                try? config.secret(named: credential)
            }
        }
    }

    /// Where a connection has got to, on its way to the register in the core.
    ///
    /// A closure for the same reason `knownTools` is one: this object does not
    /// hold the core handle, and a copy of the state kept here would be a
    /// second answer to a question the register already answers.
    var serverStateChanged: (@MainActor (String, McpServerState) -> Void)?

    // MARK: - ChatHost

    func startReply(
        conversation: ConversationId,
        message: MessageId,
        transcript: [Message],
        tools: [ToolDescriptor]
    ) {
        provider.perform([
            .startChatReply(
                conversation: conversation,
                message: message,
                transcript: transcript,
                tools: tools
            )
        ])
    }

    func cancelReply(message: MessageId) {
        provider.perform([.cancelChatReply(message: message)])
    }

    func runToolCall(conversation _: ConversationId, invocation: ToolInvocation) {
        mcp.run(
            call: invocation.id.description,
            server: invocation.server,
            tool: invocation.tool,
            arguments: invocation.arguments
        )
    }

    func cancelToolCall(call: ToolCallId) {
        mcp.cancel(call: call.description)
    }

    /// Connect to what is configured, then ask it what it can do.
    ///
    /// Starting is idempotent per server and the answer always arrives: a
    /// server that says nothing is reported as an empty list, and that is what
    /// stops its tools being callable. A server nobody enabled is never started,
    /// so switching one off in Settings is the thing that takes it away rather
    /// than a second list somewhere agreeing to forget it.
    ///
    /// **A server that went away is started again here.** There used to be a
    /// set of ids that had been started once, and it never had anything removed
    /// from it — so a connection that failed stayed failed for the life of the
    /// launch. That is wrong for a program on this Mac and much worse for a
    /// local proxy over HTTP, which somebody quits and restarts all day and
    /// which is *expected* to be missing half the time. `McpHost.start` already
    /// refuses to start a server it is holding, and drops one that failed, so
    /// asking it every time is both idempotent and the retry.
    func listTools(server: String?) {
        let wanted = config.config.mcpServers.filter { candidate in
            candidate.enabled && (server == nil || candidate.id == server)
        }
        for candidate in wanted {
            mcp.start(candidate)
        }
        mcp.listTools(server: server)
    }

    // MARK: - Resolving a provider

    /// Everything a reply needs, or `nil` when nothing is set up.
    ///
    /// `nil` is not a failure to report here — `ChatProviderHost` turns it into
    /// `NoProviderConfigured`, which is the one error whose useful action is a
    /// settings screen rather than "try again".
    private func resolved() -> ChatProviderHost.Resolved? {
        guard let chosen = config.effectiveProvider() else { return nil }
        guard let wire = chatWireFormat(name: providerKindWire(kind: chosen.kind)) else {
            return nil
        }

        var endpoint = chatProviderPreset(wire: wire, id: chosen.id)
        // Only when the file says so. An empty string in `base_url` is somebody
        // clearing a field, not somebody asking to talk to nothing.
        if let base = chosen.baseUrl?.trimmingCharacters(in: .whitespaces), !base.isEmpty {
            endpoint = ProviderEndpoint(
                id: endpoint.id,
                wire: endpoint.wire,
                baseUrl: base,
                auth: endpoint.auth
            )
        }

        guard let model = modelThatWillAnswer(chosen) else {
            // A provider with no model named is not ready to answer, and
            // guessing one would fail later with a message from an API.
            return nil
        }

        return ChatProviderHost.Resolved(
            endpoint: endpoint,
            model: model,
            tools: offerable,
            system: chatDefaultSystemPrompt()
        )
    }

    /// The tools a request may carry.
    ///
    /// Built from what the core published and filtered again inside
    /// `ChatProviderHost` against what `StartChatReply` actually allowed. Two
    /// filters for one rule is deliberate: this one keeps the request small,
    /// and that one is the guarantee.
    private var offerable: [ToolSpec] {
        (knownTools?() ?? []).map { descriptor in
            ToolSpec(
                server: descriptor.server,
                tool: descriptor.tool,
                summary: descriptor.summary,
                inputSchemaJson: descriptor.inputSchemaJson
            )
        }
    }
}
