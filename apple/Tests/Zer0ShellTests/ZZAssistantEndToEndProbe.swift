import Foundation
import Network
import Testing
import Zer0Core

@testable import Zer0Shell

/// Throwaway probe: the assistant, all the way through, against a synthetic
/// provider. A local HTTP server speaks the OpenAI-compatible wire, a real
/// config.toml in a temp dir names it, a real Keychain entry (under a `.test`
/// service nothing real reads) holds a dummy key, and the real
/// `ConfiguredChatHost` wiring carries a question from the core reducer to the
/// socket and the streamed answer back into the conversation. Static reading
/// proved the parts; this is somebody watching them talk.
///
/// Not a lock. It writes to the Keychain (a test service, removed afterwards)
/// and binds a socket, so it cannot run under CI.
///
///     ZER0_SHOT=1 swift test --filter ZZAssistantEndToEndProbe
///
/// Why not `BrowserModel` itself. It takes its `ConfigHost` from
/// `ChatSettingsModel.shared`, a process singleton over the person's real
/// `~/.config/zer0/config.toml` and real Keychain service, with no injection
/// point — driving it would mean writing to the author's jar. The probe builds
/// the same three lines BrowserModel does (`engine.emit`, `engine.chat`,
/// `core.dispatch` → `engine.perform`) around a temp config, which is the
/// entire wiring minus the SwiftUI scene that adopts it.
///
/// What it exercises, in the order the browser does it:
///
/// 1. the file parses and the credential name exists, so the core calls the
///    provider Ready and `effectiveProvider()` returns it;
/// 2. Settings' key check (`GET /v1/models`) turns the key green;
/// 3. a question sent as a real `Action` reaches `ConfiguredChatHost` as
///    `StartChatReply`, crosses `URLSession` with the Keychain's key in
///    exactly one header, and the SSE reply streams back one delta per frame
///    into the conversation;
/// 4. the assembled reply parses as prose blocks, and a second turn proves
///    the transcript travelled with it.
@MainActor
struct ZZAssistantEndToEndProbe {
    static func say(_ line: String) {
        print("[probe] \(line)")
        trace(line)
    }

    /// To a file, unbuffered: stdout is block-buffered under a pipe, and a hung
    /// run has to be diagnosable from outside.
    nonisolated static func trace(_ line: String) {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("zer0-assistant-probe.log")
        let text = line + "\n"
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    @Test(
        "the assistant answers end to end against a synthetic provider",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    func assistantAnswersEndToEnd() async throws {
        // --- the server, before anything points at it ------------------------
        let server = try await AssistantMockServer(scripts: [
            AssistantMockServer.turn(["Hello", " from", " the", " mock"]),
            AssistantMockServer.turn(["Try", " this", ":\n\n```sh\n", "echo hi", "\n```\n"]),
        ])
        defer { server.stop() }

        // --- the file, in a folder of our own --------------------------------
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zer0-assistant-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let configPath = dir.appendingPathComponent("config.toml").path
        try """
        [chat]
        default_provider = "zz-assistant-test"

        [[provider]]
        id = "zz-assistant-test"
        name = "Assistant Probe"
        kind = "openai-compatible"
        base_url = "http://127.0.0.1:\(server.port)"
        credential = "zz-assistant-test"
        models = ["mock-model"]
        default_model = "mock-model"
        """.write(toFile: configPath, atomically: true, encoding: .utf8)
        Self.say("config: \(configPath)")

        // --- the key, in the real Keychain under a service nothing reads -----
        let keychain = AssistantProbeKeychain(configPath: configPath)
        // A leftover from a crashed run is removed rather than updated, so
        // teardown below always removes something this run put there.
        try? keychain.remove(named: Self.credential)
        try keychain.store("dummy-key", named: Self.credential)
        Self.say("keychain: \(Self.credential) stored under \(AssistantProbeKeychain.service)")

        // --- configuration resolves the provider ------------------------------
        let config = ConfigHost(path: configPath, secrets: keychain, watching: false)
        #expect(config.errors.isEmpty, "config diagnostics: \(config.diagnostics.map(\.message))")
        let provider = try #require(config.effectiveProvider())
        #expect(provider.id == Self.credential, "the file's provider is not the effective one")
        Self.say("provider: ready, effective = \(provider.id), model = \(provider.defaultModel ?? "?")")

        // --- Settings' key check, against the same server ---------------------
        let check = await NetworkChatProviderProbe().check(provider: provider, key: "dummy-key")
        #expect(check == .working(["mock-model"]), "key check said \(check)")
        Self.say("models: GET /v1/models → working([mock-model])")

        // --- the wiring, the same three lines BrowserModel writes ------------
        let browser = AssistantProbeBrowser()
        let chat = ConfiguredChatHost(config: config, appVersion: "probe") { [weak browser] action in
            browser?.send(action)
        }
        browser.wire(chat: chat)

        // --- turn one: a question through the real reducer --------------------
        browser.send(.openChat(about: .nothing, ask: "What is the answer?"))

        #expect(await eventually {
            browser.core.conversations().first?.messages.last?.state == .complete
        }, "the reply never completed: \(browser.core.conversations())")

        let conversation = try #require(browser.core.conversations().first)
        let reply = try #require(conversation.messages.last)
        #expect(reply.role == .assistant)
        #expect(reply.state == .complete)
        #expect(reply.text == "Hello from the mock")
        #expect(reply.model == "mock-model", "the label is not the model that answered")
        #expect(conversation.error == nil, "an error rode along: \(String(describing: conversation.error))")
        #expect(
            browser.drainDeltas() == ["Hello", " from", " the", " mock"],
            "the reply did not arrive one delta per SSE frame"
        )
        let blocks = proseBlocks(text: reply.text)
        #expect(!blocks.isEmpty, "the reply parsed into no prose blocks")
        Self.say("turn 1: reply = \"\(reply.text)\" model = \(reply.model ?? "?") prose = \(blocks.count) block(s)")

        // --- turn two: the transcript must travel ------------------------------
        // Re-read rather than reuse `conversation`: it is a value snapshot
        // from before this turn, and the assertions below are about the
        // thread as it stands now.
        browser.send(.sendChatMessage(conversation: conversation.id, text: "Show me code"))
        #expect(await eventually {
            browser.core.conversations().first?.messages.last?.state == .complete
        }, "the second reply never completed: \(browser.core.conversations())")

        let after = try #require(browser.core.conversations().first)
        let second = try #require(after.messages.last)
        #expect(second.text == "Try this:\n\n```sh\necho hi\n```\n")
        #expect(after.error == nil)
        #expect(
            proseBlocks(text: second.text).contains { block in
                if case .code = block.kind { return true }
                return false
            },
            "a fenced reply did not become a code block"
        )
        Self.say("turn 2: reply parses with a code block, transcript = \(after.messages.count) messages")

        // --- what actually went over the wire ---------------------------------
        let posts = server.requests.filter { $0.path == "/v1/chat/completions" }
        #expect(posts.count == 2, "expected two completions, saw \(posts.count)")
        #expect(server.requests.contains { $0.method == "GET" && $0.path == "/v1/models" })

        let first = try #require(posts.first)
        #expect(first.method == "POST")
        #expect(first.headers["authorization"] == "Bearer dummy-key", "the key did not arrive as the bearer")
        let body = String(decoding: first.body, as: UTF8.self)
        #expect(body.contains("mock-model"))
        #expect(body.contains("What is the answer?"))
        #expect(body.contains("\"stream\":true"))
        Self.say("wire: POST /v1/chat/completions, \(first.body.count) bytes, Authorization: Bearer \(ChatKeyDisplay.redact("dummy-key"))")

        let secondBody = String(decoding: try #require(posts.last).body, as: UTF8.self)
        #expect(secondBody.contains("Show me code"), "the second question did not travel")
        #expect(secondBody.contains("Hello from the mock"), "the first reply did not travel with it")
        Self.say("wire: turn 2 carried the whole transcript (\(secondBody.count) bytes)")

        // --- teardown, verified rather than assumed ---------------------------
        try keychain.remove(named: Self.credential)
        let remaining = try AssistantProbeKeychain.names()
        #expect(!remaining.contains(Self.credential), "the Keychain entry survived teardown")
        Self.say("keychain: entry removed, service now holds \(remaining.count) name(s)")
    }

    static let credential = "zz-assistant-test"
}

// MARK: - The browser, minus the scene

/// `BrowserModel`'s chat wiring with nothing visual on it: the real core, the
/// real `EngineHost` routing, and the real `ConfiguredChatHost`. What a window
/// would add is drawing, and drawing is not part of the claim under test.
@MainActor
private final class AssistantProbeBrowser {
    let core: Zer0
    let engine = EngineHost()
    private(set) var deltas: [String] = []

    init() {
        core = Zer0.inMemory(
            firstSpaceName: "Personal",
            dataStoreId: UUID().uuidString,
            capabilities: HostCapabilities(extensionRuntime: false)
        )
    }

    func wire(chat: ChatHost) {
        // The same three lines `BrowserModel.init` writes, in the same order.
        engine.emit = { [weak self] action in self?.send(action) }
        engine.chat = chat
    }

    func send(_ action: Action) {
        if case let .chatReplyDelta(_, text) = action { deltas.append(text) }
        let commands = core.dispatch(action: action)
        engine.perform(commands)
    }

    /// Hand over the deltas seen so far and start collecting again, so each
    /// turn can be asserted on its own.
    func drainDeltas() -> [String] {
        let out = deltas
        deltas = []
        return out
    }
}

// MARK: - The Keychain, under a service nothing real reads

/// The real Keychain code — `SecItemAdd`, `SecItemCopyMatching`, the same
/// queries `Keychain` itself runs — reached through the static entry points
/// that take an explicit service, so the probe never writes to a jar anybody
/// else reads. Removed in the same test that created it.
@MainActor
private final class AssistantProbeKeychain: SecretStore {
    nonisolated static let service = Keychain.service + ".test"

    let configPath: String
    init(configPath: String) {
        self.configPath = configPath
    }

    static func names() throws -> [String] {
        try Keychain.names(service: service)
    }

    func names() throws -> [String] { try Self.names() }

    func secret(named name: String) throws -> String {
        try Keychain.secret(named: name, service: Self.service)
    }

    func store(_ secret: String, named name: String) throws {
        try Keychain.store(secret, named: name, service: Self.service, configPath: configPath)
    }

    func remove(named name: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: name,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Keychain.error(status, name: name)
        }
    }
}

// MARK: - The server, small enough to read

/// Serves just enough of the OpenAI-compatible wire for the probe: a model
/// list, and chat completions as Server-Sent Events with a gap between frames
/// so the reply is genuinely streaming rather than one buffer handed over the
/// loopback. Every request is recorded — method, path, headers, body — because
/// the point of the probe is seeing what actually went out.
private final class AssistantMockServer: @unchecked Sendable {
    struct Request {
        let method: String
        let path: String
        /// Lowercased names, so the assertions match either spelling.
        let headers: [String: String]
        let body: Data
    }

    private let listener: NWListener
    private(set) var port: UInt16 = 0
    private let lock = NSLock()
    private var recorded: [Request] = []
    /// One script of SSE frames per chat turn, consumed in order.
    private var scripts: [[Data]]
    private var nextScript = 0

    init(scripts: [[String]]) async throws {
        self.scripts = scripts.map { $0.map { Data($0.utf8) } }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters, on: .any)

        // Same order as `TinyHTTPServer`, which binds fine in this process:
        // the connection handler is in place before `start`. Measured on this
        // macOS beta, a listener started with no handler fails with EINVAL —
        // and a waiter that only ends on `.ready` would turn that into a hang.
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global())
            self?.read(connection, into: Data())
        }

        let ready = AsyncThrowingStream<Void, Error>.makeStream()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.continuation.finish()
            case let .failed(error): ready.continuation.finish(throwing: error)
            default: break
            }
        }
        listener.start(queue: .global())
        for try await _ in ready.stream {}

        guard let assigned = listener.port?.rawValue else {
            listener.cancel()
            throw ProbeServerError.noPort
        }
        port = assigned
    }

    var requests: [Request] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func stop() {
        listener.cancel()
    }

    // --- reading ------------------------------------------------------------

    /// Reads a whole request — head plus `Content-Length` bytes of body —
    /// before answering, so the assertions see the entire JSON the browser
    /// sent rather than whichever segment arrived first.
    private func read(_ connection: NWConnection, into accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, error in
            var buffer = accumulated
            if let data { buffer.append(data) }

            if let head = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headText = String(decoding: buffer[..<head.lowerBound], as: UTF8.self)
                let expected = Self.contentLength(in: headText)
                let bodyStart = head.upperBound
                if buffer.distance(from: bodyStart, to: buffer.endIndex) >= expected {
                    let request = Self.parse(
                        head: headText,
                        body: buffer.subdata(in: bodyStart..<buffer.endIndex)
                    )
                    self.remember(request)
                    self.respond(to: request, over: connection)
                    return
                }
            }

            if error == nil {
                self.read(connection, into: buffer)
            } else {
                connection.cancel()
            }
        }
    }

    private func remember(_ request: Request) {
        lock.lock()
        recorded.append(request)
        lock.unlock()
    }

    private static func parse(head: String, body: Data) -> Request {
        let lines = head.split(separator: "\r\n")
        let requestLine = lines.first.map(String.init) ?? ""
        let fields = requestLine.split(separator: " ")
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return Request(
            method: fields.first.map(String.init) ?? "",
            path: fields.count > 1 ? String(fields[1]) : "",
            headers: headers,
            body: body
        )
    }

    private static func contentLength(in head: String) -> Int {
        for line in head.split(separator: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "content-length" { return Int(value) ?? 0 }
        }
        return 0
    }

    // --- writing ------------------------------------------------------------

    private func respond(to request: Request, over connection: NWConnection) {
        switch (request.method, request.path) {
        case ("GET", "/v1/models"):
            let body = Self.modelsBody
            connection.send(
                content: Self.head(status: "200 OK", headers: [
                    "Content-Type: application/json",
                    "Content-Length: \(body.count)",
                    "Connection: close",
                ]) + body,
                completion: .contentProcessed { _ in connection.cancel() }
            )

        case ("POST", "/v1/chat/completions"):
            let frames = takeScript() ?? []
            connection.send(
                content: Self.head(status: "200 OK", headers: [
                    "Content-Type: text/event-stream",
                    "Cache-Control: no-cache",
                    "Connection: close",
                ]),
                completion: .contentProcessed { _ in
                    Self.send(frames[...], over: connection)
                }
            )

        default:
            let body = Data(
                #"{"error":{"message":"no such route","type":"invalid_request_error"}}"#.utf8
            )
            connection.send(
                content: Self.head(status: "404 Not Found", headers: [
                    "Content-Type: application/json",
                    "Content-Length: \(body.count)",
                    "Connection: close",
                ]) + body,
                completion: .contentProcessed { _ in connection.cancel() }
            )
        }
    }

    private func takeScript() -> [Data]? {
        lock.lock()
        defer { lock.unlock() }
        guard nextScript < scripts.count else { return nil }
        defer { nextScript += 1 }
        return scripts[nextScript]
    }

    /// One frame at a time, waiting between them. A stream handed over whole
    /// would still decode, but it would not be streaming, and streaming is
    /// half of what this probe exists to watch happen.
    private static func send(_ remaining: ArraySlice<Data>, over connection: NWConnection) {
        guard let frame = remaining.first else {
            connection.cancel()
            return
        }
        connection.send(content: frame, completion: .contentProcessed { _ in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.03) {
                send(remaining.dropFirst(), over: connection)
            }
        })
    }

    private static func head(status: String, headers: [String]) -> Data {
        Data("HTTP/1.1 \(status)\r\n\(headers.joined(separator: "\r\n"))\r\n\r\n".utf8)
    }

    private static let modelsBody = Data(#"{"data":[{"id":"mock-model"}]}"#.utf8)

    // --- the scripts ----------------------------------------------------------

    /// One chat turn: a role delta that says nothing, one frame per text
    /// delta, a `finish_reason`, and the sentinel.
    static func turn(_ deltas: [String]) -> [String] {
        var frames: [String] = [
            sse(#"{"id":"c","model":"mock-model","choices":[{"index":0,"delta":{"role":"assistant","content":""}}]}"#)
        ]
        for delta in deltas {
            frames.append(
                sse(#"{"id":"c","model":"mock-model","choices":[{"index":0,"delta":{"content":"\#(jsonEscaped(delta))"}}]}"#)
            )
        }
        frames.append(
            sse(#"{"id":"c","model":"mock-model","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#)
        )
        frames.append("data: [DONE]\n\n")
        return frames
    }

    static func sse(_ payload: String) -> String {
        "data: \(payload)\n\n"
    }

    static func jsonEscaped(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}

private enum ProbeServerError: Error {
    case noPort
}
