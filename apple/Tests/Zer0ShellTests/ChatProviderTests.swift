import Foundation
import Testing
import Zer0Core

@testable import Zer0Shell

/// What the host promises, through the real core, without a network.
///
/// The transport is injected, so every one of these runs the same way on a
/// machine with the wifi off — and the bytes are split where a test wants them
/// split, which is the only way to prove a chunk boundary is invisible.
@MainActor
struct ChatProviderTests {
    // MARK: - Fakes

    /// A scripted response. Yields exactly what it is told, in exactly the
    /// pieces it is told, and touches nothing.
    struct ScriptedTransport: ChatTransport {
        var status: UInt16 = 200
        var retryAfter: String?
        var chunks: [String] = []
        var failure: Error?
        /// Filled in when a request is performed, so a test can look at what
        /// actually went out.
        let seen = Box()

        final class Box: @unchecked Sendable {
            var request: HttpRequest?
        }

        func stream(_ request: HttpRequest) -> AsyncThrowingStream<ChatTransportEvent, Error> {
            let status = status
            let retryAfter = retryAfter
            let chunks = chunks
            let failure = failure
            seen.request = request

            return AsyncThrowingStream { continuation in
                if let failure {
                    continuation.finish(throwing: failure)
                    return
                }
                continuation.yield(.response(status: status, retryAfter: retryAfter))
                for chunk in chunks {
                    continuation.yield(.bytes(Data(chunk.utf8)))
                }
                continuation.finish()
            }
        }
    }

    /// A transport that never ends, so a test can stop something that is
    /// genuinely in flight rather than something that has already finished.
    struct StallingTransport: ChatTransport {
        let opened: Box

        final class Box: @unchecked Sendable {
            var started = false
            var cancelled = false
        }

        func stream(_: HttpRequest) -> AsyncThrowingStream<ChatTransportEvent, Error> {
            let opened = opened
            return AsyncThrowingStream { continuation in
                opened.started = true
                continuation.yield(.response(status: 200, retryAfter: nil))
                continuation.yield(.bytes(Data(
                    "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"model\":\"m\"}}\n\n"
                        .utf8
                )))
                continuation.onTermination = { _ in opened.cancelled = true }
            }
        }
    }

    // MARK: - Fixtures

    static let claude = chatProviderPreset(wire: .anthropicMessages, id: "claude")

    static func asked(_ text: String) -> Message {
        Message(
            id: 7,
            role: .user,
            text: text,
            page: nil,
            state: .complete,
            toolCalls: [],
            answers: nil,
            model: nil,
            createdAtMs: 0
        )
    }

    static let readPage = ToolSpec(
        server: "browser",
        tool: "read_page",
        summary: "Read the page",
        inputSchemaJson: #"{"type":"object","properties":{}}"#
    )

    /// A host wired to a script, with a fake Keychain and somewhere for the
    /// actions to land.
    static func host(
        transport: ChatTransport,
        token: String? = "sk-test",
        tools: [ToolSpec] = [],
        into actions: Actions
    ) -> ChatProviderHost {
        let host = ChatProviderHost()
        host.transport = transport
        host.token = { _ in token }
        host.resolve = { _ in
            ChatProviderHost.Resolved(
                endpoint: claude,
                model: "claude-sonnet-4-5",
                tools: tools,
                system: nil
            )
        }
        host.emit = { actions.append($0) }
        return host
    }

    final class Actions {
        private(set) var all: [Action] = []
        func append(_ action: Action) { all.append(action) }

        var text: String {
            all.reduce(into: "") { text, action in
                if case let .chatReplyDelta(_, delta) = action { text += delta }
            }
        }

        /// Whether the reply has ended, one way or the other. Exactly one of
        /// these arrives per reply, which is what makes it a thing to wait on
        /// rather than a duration to guess.
        var hasEnded: Bool {
            all.contains { action in
                switch action {
                case .chatReplyFinished, .chatFailed: true
                default: false
                }
            }
        }

        var failure: (kind: ChatErrorKind, detail: String)? {
            all.compactMap { action -> (ChatErrorKind, String)? in
                guard case let .chatFailed(_, _, kind, detail) = action else { return nil }
                return (kind, detail)
            }.first
        }
    }

    static func send(_ host: ChatProviderHost, tools: [ToolDescriptor] = []) {
        host.perform([
            .startChatReply(
                conversation: 1,
                message: 7,
                transcript: [asked("what is the capital?")],
                tools: tools
            )
        ])
    }

    /// Ask, then wait for the reply to end.
    ///
    /// Waits on the ending rather than on a count of yields. A reply arriving in
    /// six hundred pieces needs six hundred hops through the main actor, and a
    /// number that looked generous for three would have made this suite flaky
    /// exactly where it is most load-bearing.
    static func start(
        _ host: ChatProviderHost,
        into actions: Actions,
        tools: [ToolDescriptor] = []
    ) async {
        send(host, tools: tools)
        #expect(await eventually { actions.hasEnded }, "the reply never ended")
    }

    // MARK: - Streaming

    @Test("a reply split in the middle of a word arrives whole")
    func aReplySplitMidWordArrivesWhole() async {
        let whole = """
        event: message_start
        data: {"type":"message_start","message":{"model":"claude-sonnet-4-5-20250929"}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Edinburgh"}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}

        event: message_stop
        data: {"type":"message_stop"}


        """

        // Sliced at four characters, which lands inside `data:`, inside a JSON
        // string and inside the word itself.
        var chunks: [String] = []
        var rest = Substring(whole)
        while !rest.isEmpty {
            let cut = rest.index(rest.startIndex, offsetBy: 4, limitedBy: rest.endIndex) ?? rest.endIndex
            chunks.append(String(rest[..<cut]))
            rest = rest[cut...]
        }

        let actions = Self.Actions()
        let host = Self.host(transport: ScriptedTransport(chunks: chunks), into: actions)
        await Self.start(host, into: actions)

        #expect(actions.text == "Edinburgh")
        #expect(actions.failure == nil)
        #expect(actions.all.contains { action in
            if case let .chatReplyFinished(_, stop) = action { return stop == .endOfTurn }
            return false
        })
    }

    /// What actually answered, not what was asked for. It is what the message
    /// keeps, so an old answer keeps the label it was really given.
    @Test("the model that replied is the one recorded, not the one requested")
    func theRecordedModelIsTheOneThatReplied() async {
        let actions = Self.Actions()
        let host = Self.host(
            transport: ScriptedTransport(chunks: [
                "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"model\":\"claude-sonnet-4-5-20250929\"}}\n\n",
                "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n",
            ]),
            into: actions
        )
        await Self.start(host, into: actions)

        let reported = actions.all.compactMap { action -> String? in
            guard case let .chatReplyStarted(_, model) = action else { return nil }
            return model
        }
        #expect(reported == ["claude-sonnet-4-5-20250929"])
    }

    // MARK: - Tools

    /// The whole round trip through the real core: a call arrives on the wire
    /// under a flat name and reaches the reducer as a server and a tool.
    @Test("a tool call reaches the core resolved to its server")
    func aToolCallReachesTheCoreResolved() async {
        let actions = Self.Actions()
        let host = Self.host(
            transport: ScriptedTransport(chunks: [
                "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"model\":\"m\"}}\n\n",
                "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"browser__read_page\",\"input\":{}}}\n\n",
                "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}\n\n",
                "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n",
                "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"}}\n\n",
                "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n",
            ]),
            tools: [Self.readPage],
            into: actions
        )
        await Self.start(
            host,
            into: actions,
            tools: [ToolDescriptor(
                server: "browser",
                tool: "read_page",
                summary: "Read",
                inputSchemaJson: #"{"type":"object"}"#,
                readOnlyHint: true,
                destructiveHint: false,
                openWorldHint: false
            )]
        )

        let calls = actions.all.compactMap { action -> ToolInvocation? in
            guard case let .chatToolCallRequested(_, invocation) = action else { return nil }
            return invocation
        }
        #expect(calls.count == 1)
        #expect(calls.first?.server == "browser")
        #expect(calls.first?.tool == "read_page")
    }

    /// A host must not offer what the core did not allow: a call the core
    /// cannot name is refused, so offering more only produces work thrown away.
    @Test("only the tools the core allowed are offered to the model")
    func onlyAllowedToolsAreOffered() async {
        let transport = ScriptedTransport(chunks: [
            "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
        ])
        let secret = ToolSpec(
            server: "shell",
            tool: "run",
            summary: "Run anything",
            inputSchemaJson: "{}"
        )

        let actions = Self.Actions()
        let host = Self.host(
            transport: transport,
            tools: [Self.readPage, secret],
            into: actions
        )
        await Self.start(
            host,
            into: actions,
            tools: [ToolDescriptor(
                server: "browser",
                tool: "read_page",
                summary: "Read",
                inputSchemaJson: #"{"type":"object"}"#,
                readOnlyHint: true,
                destructiveHint: false,
                openWorldHint: false
            )]
        )

        let body = transport.seen.request?.body ?? ""
        #expect(body.contains("browser__read_page"))
        #expect(!body.contains("shell__run"), "a tool the core never allowed was offered")
    }

    // MARK: - Cancellation

    /// Escape, with the reply genuinely in flight. What arrived is kept, the
    /// socket is torn down, and no failure is put on a thread somebody stopped
    /// on purpose.
    @Test("cancelling a reply in flight closes the connection and reports nothing")
    func cancellingClosesTheConnection() async {
        let opened = StallingTransport.Box()
        let actions = Self.Actions()
        let host = Self.host(transport: StallingTransport(opened: opened), into: actions)

        // Waits on the connection rather than on an ending: this reply never
        // gets one, which is the whole point of stopping it.
        Self.send(host)
        #expect(await eventually { opened.started }, "the request never went out")
        #expect(await eventually {
            actions.all.contains { if case .chatReplyStarted = $0 { return true }; return false }
        }, "nothing had arrived to be kept")

        host.perform([.cancelChatReply(message: 7)])

        #expect(await eventually { opened.cancelled }, "the socket stayed open after Escape")
        #expect(actions.failure == nil, "a stopped reply was reported as broken")
        #expect(!actions.all.contains { if case .chatReplyFinished = $0 { return true }; return false })
    }

    // MARK: - Failures

    /// The first failure anybody hits, and it has to say which thing to fix.
    @Test("a first run with no key fails before a socket is opened")
    func aMissingKeyFailsBeforeConnecting() async {
        let transport = ScriptedTransport(chunks: ["should never be read"])
        let actions = Self.Actions()
        let host = Self.host(transport: transport, token: nil, into: actions)
        await Self.start(host, into: actions)

        #expect(transport.seen.request == nil, "a request went out with no key")
        #expect(actions.failure?.kind == .notAuthorised)
        #expect(actions.failure?.detail.contains("claude") == true)
    }

    /// A key that is wrong rather than missing. Same screen, and it must not be
    /// the one that says "you sent a bad request" — which is exactly what this
    /// provider's `type` field claims.
    @Test("a key the provider rejects is reported as authorisation, not a bad request")
    func aRejectedKeyIsAnAuthorisationFailure() async {
        let actions = Self.Actions()
        let host = Self.host(
            transport: ScriptedTransport(
                status: 401,
                chunks: [
                    #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#
                ]
            ),
            into: actions
        )
        await Self.start(host, into: actions)

        #expect(actions.failure?.kind == .notAuthorised)
        #expect(actions.failure?.detail.contains("x-api-key") == true, "the provider's own words were lost")
    }

    /// Nothing answered. A local model server that is not running and a laptop
    /// with no network are one category, because they are one sentence.
    @Test("a provider that is down is reported as a connection failure")
    func aProviderThatIsDownIsAConnectionFailure() async {
        let actions = Self.Actions()
        let host = Self.host(
            transport: ScriptedTransport(failure: URLError(.cannotConnectToHost)),
            into: actions
        )
        await Self.start(host, into: actions)

        #expect(actions.failure?.kind == .connectionFailed)
    }

    /// Nothing configured at all: no request, no socket, and the one failure
    /// whose useful action is a settings screen rather than "try again".
    @Test("no provider configured fails without asking the Keychain")
    func noProviderConfiguredFailsImmediately() async {
        let actions = Self.Actions()
        let host = ChatProviderHost()
        host.transport = ScriptedTransport()
        host.resolve = { _ in nil }
        host.token = { _ in Issue.record("the Keychain was read with nothing configured"); return nil }
        host.emit = { actions.append($0) }

        await Self.start(host, into: actions)
        #expect(actions.failure?.kind == .noProviderConfigured)
    }

    /// A stream that stops mid-sentence has no ending of its own. Without one
    /// the thread spins for ever, which is the failure a person actually sees.
    @Test("a stream that is cut off still ends")
    func aStreamCutOffStillEnds() async {
        let actions = Self.Actions()
        let host = Self.host(
            transport: ScriptedTransport(chunks: [
                "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"model\":\"m\"}}\n\n",
                "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n",
                "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Edin\"}}\n\n",
            ]),
            into: actions
        )
        await Self.start(host, into: actions)

        #expect(actions.text == "Edin", "what arrived was thrown away")
        #expect(actions.failure?.kind == .malformedResponse)
    }

    /// A gateway's HTML with a 200 on it. Not a stream, and it must not be read
    /// as an empty reply.
    @Test("a response that is not a stream is reported rather than shown as empty")
    func aResponseThatIsNotAStreamIsReported() async {
        let actions = Self.Actions()
        let host = Self.host(
            transport: ScriptedTransport(chunks: ["<html><body>hello</body></html>"]),
            into: actions
        )
        await Self.start(host, into: actions)

        #expect(actions.text.isEmpty)
        #expect(actions.failure?.kind == .malformedResponse)
    }

    // MARK: - The token

    /// The token reaches one header and nothing else. Not the URL, where it
    /// would be in every log on the path, and not the body.
    @Test("a token travels in one header and nowhere else")
    func aTokenTravelsInOneHeader() async throws {
        let secret = "sk-do-not-log-me"
        let transport = ScriptedTransport(chunks: [
            "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
        ])
        let actions = Self.Actions()
        let host = Self.host(transport: transport, token: secret, into: actions)
        await Self.start(host, into: actions)

        // `try #require`, not `try? #require` with a `guard ... else { return }`.
        // The old shape returned quietly when no request had gone out, and a
        // test that returns early passes: three assertions about where a secret
        // must not appear were being skipped in exactly the case where nothing
        // could be checked at all (ADR-0018).
        let request = try #require(transport.seen.request, "no request went out")

        #expect(!request.url.contains(secret))
        #expect(!request.body.contains(secret))
        #expect(request.headers.filter { $0.value.contains(secret) }.count == 1)
    }
}
