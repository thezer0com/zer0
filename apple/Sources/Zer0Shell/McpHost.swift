import Foundation
import Zer0Core

/// The pipes half of speaking MCP.
///
/// This file knows about `Process`, file handles and timeouts. It decides
/// nothing. Every line it writes was built by the core, every line it reads is
/// handed straight back to the core to be understood, and every conclusion —
/// which protocol revision this server speaks, whether a tool result counts as
/// an error, what a content block turns into — comes back out of Rust.
///
/// That split is not tidiness. A Linux host will have to reimplement the thirty
/// lines in `StdioPipe`; it must not also reimplement JSON-RPC, era detection
/// or the vocabulary of the consent screen, because two hosts that reimplement
/// a decision are two hosts that will eventually disagree about it (ADR-0002).
///
/// ## What it refuses to do
///
/// It never goes through a shell. `Process` is given an executable URL and an
/// argument vector, so a command line is not a string anything can inject into.
/// It never inherits the browser's environment wholesale; a server gets a
/// minimal one plus exactly the variables it was configured to receive.
/// And it never lets one server's misbehaviour cost memory without bound: a
/// line longer than `Limits.line` ends the connection rather than growing.

/// What one line of JSON-RPC travels over.
///
/// A protocol rather than `Process` directly, so the whole client can be driven
/// by a test that never spawns anything. A server that fails to start, one that
/// answers with rubbish and one that never answers at all are the three cases
/// worth testing, and none of them should need a real program on disk.
@MainActor
protocol McpLink: AnyObject {
    /// Called with each complete line the far end sent.
    var onLine: (@MainActor (String) -> Void)? { get set }
    /// Called once, when the far end goes away for any reason.
    var onClose: (@MainActor (McpFailure, String) -> Void)? { get set }
    /// Send one message. `era` is what the core's probe settled on, and `nil`
    /// only for the probe itself.
    ///
    /// It is an argument rather than a property because it is a fact about the
    /// message: over HTTP the headers differ by era and must agree with the
    /// body, and a link holding its own copy would be a second place that could
    /// be out of step with the one the request was built from. A transport that
    /// does not care ignores it, which is what a pipe does.
    func send(_ line: String, era: ServerEra?)
    func close()
}

@MainActor
final class McpHost {
    enum Limits {
        /// The longest line a server may send. Past this the connection ends:
        /// a server that never writes a newline is a server that would
        /// otherwise consume the browser's memory one byte at a time.
        static let line = 4 * 1024 * 1024
        /// How much of stderr is kept to explain a failure with. A server that
        /// prints a stack trace and dies should be quotable, not archived.
        static let diagnostics = 4 * 1024
    }

    /// Everything this host learns goes back into the reducer, exactly as every
    /// other host does it: `toolCallFinished`, `toolCallFailed`, and
    /// `toolsListed` for what a server says it offers.
    ///
    /// A listing goes in as an `Action` and not through a side channel onto the
    /// register, because the register is what decides whether a call may run.
    /// Two ways in would be two ways for what a tool *is* to disagree with what
    /// was approved about it.
    var emit: (@MainActor (Action) -> Void)?

    /// Where a server has got to. Goes into the register in the core rather
    /// than through an `Action`, because it is not something the browser
    /// reducer has an opinion about — see the note in the ADR about the two
    /// entry points this feature has and why they have not been merged.
    var setServerState: (@MainActor (String, McpServerState) -> Void)?

    /// How a link is made. Replaced in tests.
    var makeLink: (@MainActor (McpServerConfig, [String: String]) throws -> McpLink)?

    /// Where a secret named in the configuration is actually kept.
    ///
    /// A closure rather than a keychain call inline, because the core never
    /// holds a credential and this file should not be the second place that
    /// decides where they live.
    var secret: (@MainActor (String) -> String?)?

    private var servers: [String: Live] = [:]
    private let appVersion: String

    init(appVersion: String = "0.1.0") {
        self.appVersion = appVersion
    }

    // MARK: - One server

    /// Everything in flight for one server.
    private final class Live {
        let config: McpServerConfig
        let link: McpLink
        /// Which shape of the protocol this server speaks. `nil` until the
        /// probe settles. Cached for the life of the process, which is what the
        /// specification asks for.
        var era: ServerEra?
        var nextId: Int64 = 1
        /// What each outstanding id is an answer to, so a reply can be read
        /// without guessing from its shape.
        var expecting: [Int64: Expect] = [:]
        /// The tool call an id belongs to, for reporting and for cancelling.
        var callForId: [Int64: String] = [:]
        var idForCall: [String: Int64] = [:]
        /// Tools gathered across pages of `tools/list`.
        var listing: [ReportedTool] = []
        var pagesFetched: UInt32 = 0
        /// Timeout work, cancelled when the answer arrives first.
        var deadlines: [Int64: Task<Void, Never>] = [:]

        init(config: McpServerConfig, link: McpLink) {
            self.config = config
            self.link = link
        }

        func take() -> Int64 {
            defer { nextId += 1 }
            return nextId
        }
    }

    // MARK: - Starting and stopping

    /// Connect to a server and work out what it speaks.
    ///
    /// The environment is built here and never logged: `secret` resolves the
    /// names the configuration carries into values that exist only in this
    /// process and the child's.
    func start(_ config: McpServerConfig) {
        guard servers[config.id] == nil else { return }

        var environment: [String: String] = [:]
        // A minimal base rather than `ProcessInfo.environment`. A server does
        // not need the browser's whole environment to run, and handing it over
        // would hand over whatever else happens to be in there.
        for passthrough in ["PATH", "HOME", "LANG", "TMPDIR"] {
            if let value = ProcessInfo.processInfo.environment[passthrough] {
                environment[passthrough] = value
            }
        }
        for variable in config.env {
            environment[variable.name] = variable.value
        }
        var missing: [String] = []
        for variable in config.secretEnv {
            // Keyed by `credential`, not by `name`. The two are deliberately
            // different: `name` is what the server expects in its environment
            // (GITHUB_PERSONAL_ACCESS_TOKEN), `credential` is what the config
            // file calls the secret and what the Keychain is filed under
            // (github). Asking for the wrong one finds nothing, and every
            // server with a secret fails to start saying its credential is
            // missing while it sits in the Keychain the whole time.
            guard let value = secret?(variable.credential), !value.isEmpty else {
                // Both names, because they answer different halves of the
                // question. The credential is what someone adds in Settings
                // and what the Keychain is filed under; the variable is what
                // the server's own documentation calls it, which is how they
                // know they are looking at the right server.
                missing.append("\(variable.credential) (\(variable.name))")
                continue
            }
            environment[variable.name] = value
        }
        guard missing.isEmpty else {
            // Starting anyway would produce a server that runs, lists nothing
            // and blames itself. Naming the variable is the only useful thing
            // to say here.
            fail(config.id, .unauthorized, "Missing credential: \(missing.joined(separator: ", ")).")
            return
        }

        let link: McpLink
        do {
            guard let makeLink else {
                fail(config.id, .rejected, "No transport is configured.")
                return
            }
            link = try makeLink(config, environment)
        } catch {
            fail(config.id, .notFound, error.localizedDescription)
            return
        }

        let live = Live(config: config, link: link)
        servers[config.id] = live
        link.onLine = { [weak self] line in self?.receive(line, from: config.id) }
        link.onClose = { [weak self] failure, detail in
            self?.closed(config.id, failure, detail)
        }

        setServerState?(config.id, .starting(sinceMs: UInt64(Date().timeIntervalSince1970 * 1000)))

        // The probe: ask the modern question first. What comes back — including
        // nothing — decides the era, in the core.
        let id = live.take()
        live.expecting[id] = .discover
        arm(live, id, after: .seconds(15))
        link.send(mcpDiscoverRequest(id: id, appVersion: appVersion), era: nil)
    }

    func stop(_ id: String) {
        guard let live = servers.removeValue(forKey: id) else { return }
        for deadline in live.deadlines.values { deadline.cancel() }
        live.link.close()
    }

    func stopAll() {
        for id in servers.keys { stop(id) }
    }

    var runningIds: [String] { Array(servers.keys) }

    // MARK: - Carrying out what the core asked for

    /// Ask what a server has, or every connected server when nobody is named.
    func listTools(server: String?) {
        guard let server else {
            for id in servers.keys { listTools(from: id) }
            return
        }
        listTools(from: server)
    }

    func listTools(from server: String) {
        guard let live = servers[server], let era = live.era else { return }
        live.listing = []
        live.pagesFetched = 0
        requestPage(live, era: era, cursor: nil)
    }

    private func requestPage(_ live: Live, era: ServerEra, cursor: String?) {
        let id = live.take()
        live.expecting[id] = .toolsList
        arm(live, id, after: .seconds(20))
        live.link.send(
            mcpToolsListRequest(id: id, era: era, cursor: cursor, appVersion: appVersion),
            era: era
        )
    }

    /// Run a tool. Only ever called because the core said it may.
    func run(call: String, server: String, tool: String, arguments: String) {
        guard let live = servers[server], let era = live.era else {
            emit?(.toolCallFailed(
                call: call,
                kind: .toolUnavailable,
                detail: "That server is not connected."
            ))
            return
        }
        // Built in the core, which is also where a model's arguments are
        // checked for being an object at all. `nil` means the model wrote
        // something that is not a set of arguments, and nothing is sent.
        guard let line = mcpToolsCallRequest(
            id: live.nextId,
            era: era,
            tool: tool,
            argumentsJson: arguments,
            appVersion: appVersion
        ) else {
            emit?(.toolCallFailed(
                call: call,
                kind: .toolFailed,
                detail: "The assistant did not write usable arguments for this tool."
            ))
            return
        }

        let id = live.take()
        live.expecting[id] = .toolsCall
        live.callForId[id] = call
        live.idForCall[call] = id
        arm(live, id, after: .seconds(60))
        live.link.send(line, era: era)
    }

    /// Ask a server to stop working on something.
    ///
    /// A request, not an undo. The work may well be finished; the specification
    /// is explicit that both sides have to live with that race, and so does the
    /// transcript, which says "stopped waiting" rather than "did not happen".
    func cancel(call: String) {
        let key = call
        for live in servers.values {
            guard let id = live.idForCall[key] else { continue }
            live.deadlines[id]?.cancel()
            live.deadlines[id] = nil
            live.expecting[id] = nil
            live.callForId[id] = nil
            live.idForCall[key] = nil
            // Only meaningful over stdio. On Streamable HTTP the cancellation
            // signal is closing the response stream, and this message is one
            // the specification says not to send.
            if live.config.transport == .stdio {
                live.link.send(
                    mcpCancelNotification(requestId: id, reason: "The person stopped it."),
                    era: live.era
                )
            }
            return
        }
    }

    // MARK: - Reading what came back

    private func receive(_ raw: String, from server: String) {
        guard let live = servers[server] else { return }
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }

        guard let id = mcpReplyId(raw: line) else {
            // No id: a notification, or something that is not the protocol at
            // all. Only one notification matters to us and the core says which.
            if case .toolsChanged = mcpParseNotification(raw: line) {
                listTools(from: server)
            }
            return
        }
        guard let expect = live.expecting[id] else {
            // An answer to something we never asked, or to something already
            // given up on. A late answer does not resurrect a call that has
            // already been reported as timed out.
            return
        }
        live.expecting[id] = nil
        live.deadlines[id]?.cancel()
        live.deadlines[id] = nil

        handle(mcpParseReply(raw: line, expect: expect), id: id, expect: expect, live: live)
    }

    private func handle(_ reply: Reply, id: Int64, expect: Expect, live: Live) {
        switch expect {
        case .discover:
            settleEra(reply, live: live)
        case .initialize:
            settleLegacy(reply, live: live)
        case .toolsList:
            gather(reply, live: live)
        case .toolsCall:
            finish(reply, id: id, live: live)
        }
    }

    /// What the answer to `server/discover` says about the whole server.
    private func settleEra(_ reply: Reply, live: Live) {
        switch mcpDetectEra(reply: reply) {
        case let .settled(era):
            live.era = era
            guard case let .discovered(name, version, _) = reply else { return }
            ready(live, protocolVersion: mcpProtocolVersion(), name: name, version: version)

        case let .incompatible(supported):
            fail(
                live.config.id,
                .versionMismatch,
                supported.isEmpty
                    ? "This server does not speak a version of MCP that zer0 knows."
                    : "This server speaks \(supported.joined(separator: ", ")). zer0 speaks "
                        + "\(mcpProtocolVersion())."
            )
            stop(live.config.id)

        case .fallBack:
            let id = live.take()
            live.expecting[id] = .initialize
            arm(live, id, after: .seconds(15))
            live.link.send(mcpInitializeRequest(id: id, appVersion: appVersion), era: .legacy)
        }
    }

    private func settleLegacy(_ reply: Reply, live: Live) {
        switch reply {
        case let .initialized(protocolVersion, name, version):
            live.era = .legacy
            // The notification that finishes the old handshake. A modern server
            // never sees it, because a modern server has no handshake.
            live.link.send(mcpInitializedNotification(), era: .legacy)
            ready(live, protocolVersion: protocolVersion, name: name, version: version)

        case let .failed(_, message):
            fail(live.config.id, .malformed, message)
            stop(live.config.id)

        case .discovered, .versionRefused, .tools, .called, .toolsChanged, .ignored, .malformed:
            fail(
                live.config.id,
                .malformed,
                "This server did not answer either handshake zer0 knows."
            )
            stop(live.config.id)
        }
    }

    private func gather(_ reply: Reply, live: Live) {
        guard let era = live.era else { return }
        switch reply {
        case let .tools(tools, nextCursor, hasMore):
            live.listing.append(contentsOf: tools)
            live.pagesFetched += 1
            // A cursor is opaque and the server controls it, so a server can
            // hand one out forever. Following it forever is the bug.
            if hasMore, live.pagesFetched < mcpMaxToolPages() {
                requestPage(live, era: era, cursor: nextCursor)
                return
            }
            // The core adopts the list from here: it sanitises the names, drops
            // the collisions, caps the count and takes the fingerprints. This
            // host has no opinion about any of that.
            emit?(.toolsListed(server: live.config.id, tools: live.listing))

        case let .failed(_, message):
            fail(live.config.id, .malformed, message)

        case let .malformed(detail):
            fail(live.config.id, .malformed, detail)

        case .discovered, .versionRefused, .initialized, .called, .toolsChanged, .ignored:
            fail(live.config.id, .malformed, "The server answered a tool list with something else.")
        }
    }

    private func finish(_ reply: Reply, id: Int64, live: Live) {
        guard let call = live.callForId[id] else { return }
        live.callForId[id] = nil
        live.idForCall[call] = nil

        switch reply {
        case let .called(isError, text):
            // A tool's own verdict on itself is not the call failing. The model
            // is meant to see this and correct itself, so it goes back as a
            // result and not as an error.
            if isError {
                emit?(.toolCallFailed(call: call, kind: .toolFailed, detail: text))
            } else {
                emit?(.toolCallFinished(call: call, result: text))
            }

        case let .failed(_, message):
            emit?(.toolCallFailed(call: call, kind: .toolUnavailable, detail: message))

        case let .malformed(detail):
            emit?(.toolCallFailed(call: call, kind: .toolUnavailable, detail: detail))

        case .discovered, .versionRefused, .initialized, .tools, .toolsChanged, .ignored:
            emit?(.toolCallFailed(
                call: call,
                kind: .toolUnavailable,
                detail: "The server answered with something that was not a result."
            ))
        }
    }

    // MARK: - Going wrong

    /// Nothing came back in time.
    ///
    /// Armed per request rather than per server, because a server can be
    /// perfectly healthy and still have one tool that hangs — and killing the
    /// server over it would take the other tools with it.
    private func arm(_ live: Live, _ id: Int64, after duration: Duration) {
        live.deadlines[id] = Task { [weak self, weak live] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self, let live else { return }
            await MainActor.run { self.expired(live, id) }
        }
    }

    private func expired(_ live: Live, _ id: Int64) {
        guard let expect = live.expecting[id] else { return }
        live.expecting[id] = nil
        live.deadlines[id] = nil

        switch expect {
        case .discover, .initialize:
            fail(live.config.id, .handshakeTimeout, McpFailure.handshakeTimeout.reasonText)
            stop(live.config.id)

        case .toolsList:
            fail(live.config.id, .handshakeTimeout, "The server stopped answering.")

        case .toolsCall:
            guard let call = live.callForId[id] else { return }
            live.callForId[id] = nil
            live.idForCall[call] = nil
            if live.config.transport == .stdio {
                live.link.send(
                    mcpCancelNotification(requestId: id, reason: "zer0 stopped waiting."),
                    era: live.era
                )
            }
            // "Stopped waiting", not "did not happen". The server may have
            // finished the work; claiming otherwise would be the browser
            // asserting something it cannot know (ADR-0018).
            emit?(.toolCallFailed(
                call: call,
                kind: .timeout,
                detail: "zer0 stopped waiting for this tool. It may still have run."
            ))
        }
    }

    private func closed(_ id: String, _ failure: McpFailure, _ detail: String) {
        guard let live = servers[id] else { return }
        // Anything still out is out for good. Left running, each one would sit
        // spinning forever waiting on a process that no longer exists.
        for (requestId, call) in live.callForId {
            live.deadlines[requestId]?.cancel()
            emit?(.toolCallFailed(
                call: call,
                kind: .toolUnavailable,
                detail: "The server stopped while this was running. It may still have run."
            ))
        }
        servers.removeValue(forKey: id)
        for deadline in live.deadlines.values { deadline.cancel() }
        fail(id, failure, detail)
    }

    private func ready(_ live: Live, protocolVersion: String, name: String, version: String) {
        setServerState?(live.config.id, .ready(
            protocolVersion: protocolVersion,
            serverName: name.isEmpty ? live.config.name : name,
            serverVersion: version
        ))
        listTools(from: live.config.id)
    }

    private func fail(_ id: String, _ failure: McpFailure, _ message: String) {
        setServerState?(id, .failed(failure: failure, message: message))
    }
}

extension McpFailure {
    /// The core's sentence for this failure, so no view writes its own.
    var reasonText: String { mcpFailureReason(failure: self) }
}

// MARK: - The actual pipes

// Foundation's `Process` is not in the iOS SDK. `makeMcpLink` refuses a stdio
// server out loud on iOS, so the pipes never run there; they live where
// `Process` does.
#if canImport(AppKit)
/// A child process, spoken to over its stdin and stdout.
///
/// The only part of this file a Linux port has to replace, and deliberately the
/// dullest part.
@MainActor
final class StdioLink: McpLink {
    var onLine: (@MainActor (String) -> Void)?
    var onClose: (@MainActor (McpFailure, String) -> Void)?

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private var buffer = Data()
    private var diagnostics = Data()
    private var closed = false

    enum LaunchError: LocalizedError {
        case noCommand
        case notExecutable(String)

        var errorDescription: String? {
            switch self {
            case .noCommand: "This server has no command to run."
            case let .notExecutable(path): "zer0 could not run \(path)."
            }
        }
    }

    init(command: String, args: [String], environment: [String: String]) throws {
        guard !command.isEmpty else { throw LaunchError.noCommand }

        // An executable URL and an argument vector. Never a shell: a command
        // line that goes through `sh -c` is a command line anything in it can
        // inject into, and the arguments here come out of a file on disk.
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = args
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        // `readabilityHandler` and `terminationHandler` are documented as
        // running on a queue of Foundation's choosing, which is never the main
        // one. These three used to call `MainActor.assumeIsolated` directly,
        // which asserts something false: the assumption is not checked away in
        // release, it traps, and a crash report caught it doing exactly that
        // (`_swift_task_checkIsolatedSwift` → `dispatch_assert_queue_fail`)
        // the first time a server produced output.
        //
        // `DispatchQueue.main.async` rather than `Task { @MainActor in … }`,
        // because this is a byte stream being reassembled into lines: the main
        // queue is FIFO, and unstructured tasks carry no ordering guarantee
        // between each other. Chunks arriving out of order would corrupt the
        // framing rather than fail loudly, which is the worse kind of wrong.
        // Inside the hop the assumption is true, so it costs nothing.
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(chunk) } }
        }
        // Drained and mostly discarded. The specification is explicit that
        // output on stderr does not mean an error, so it is kept only to have
        // something to quote when the process dies.
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.noted(chunk) } }
        }
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.ended(status) } }
        }

        do {
            try process.run()
        } catch {
            throw LaunchError.notExecutable(command)
        }
    }

    // The era changes nothing over a pipe: framing is a newline either way,
    // and the era already changed the body before it got here.
    func send(_ line: String, era _: ServerEra?) {
        guard process.isRunning, let data = (line + "\n").data(using: .utf8) else { return }
        // A server that has stopped reading would otherwise block the whole
        // browser here.
        try? input.fileHandleForWriting.write(contentsOf: data)
    }

    func close() {
        guard !closed else { return }
        closed = true
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil

        // Closing stdin is how the specification says to ask a server to stop,
        // and a well-behaved one exits on end-of-file. Termination is what
        // happens to the rest.
        try? input.fileHandleForWriting.close()
        guard process.isRunning else { return }
        let running = process
        Task {
            try? await Task.sleep(for: .seconds(2))
            if running.isRunning { running.terminate() }
            try? await Task.sleep(for: .seconds(1))
            if running.isRunning { kill(running.processIdentifier, SIGKILL) }
        }
    }

    private func received(_ chunk: Data) {
        guard !closed, !chunk.isEmpty else { return }
        buffer.append(chunk)

        while let end = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex ..< end]
            buffer.removeSubrange(buffer.startIndex ... end)
            guard let text = String(data: line, encoding: .utf8) else { continue }
            onLine?(text)
        }

        // A server that never writes a newline would otherwise buy memory a
        // byte at a time until the browser dies. Ending the connection is the
        // honest response and it has a sentence attached.
        if buffer.count > McpHost.Limits.line {
            buffer = Data()
            closed = true
            onClose?(.malformed, "The server sent a line too long to read.")
            close()
        }
    }

    private func noted(_ chunk: Data) {
        diagnostics.append(chunk)
        if diagnostics.count > McpHost.Limits.diagnostics {
            diagnostics.removeFirst(diagnostics.count - McpHost.Limits.diagnostics)
        }
    }

    private func ended(_ status: Int32) {
        guard !closed else { return }
        closed = true
        let said = String(data: diagnostics, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        onClose?(
            .crashed,
            said.isEmpty ? "The server exited with status \(status)." : said
        )
    }
}
#endif
