import Foundation
import Zer0Core

/// Talking to a program outside the browser.
///
/// This file knows about `Process`, file handles and a length prefix. It
/// decides nothing: which program an extension may start, whether anybody has
/// said yes to it, what a message is and how big one may be all come out of the
/// core (ADR-0105). A Linux host reimplements the thirty lines in
/// `NativeHostProcess`; it must not also reimplement the rules.
///
/// ## What it refuses to do
///
/// It never goes through a shell — `Process` gets an executable URL and an
/// argument vector, and both come from the core rather than from a string
/// anything could inject into. It never hands over the browser's environment
/// wholesale. It never lets one program's misbehaviour cost memory without
/// bound: a length past the core's cap, or a body that is not a message, ends
/// the connection instead of growing a buffer.

// MARK: - The two ends

/// The extension end of a conversation.
///
/// A protocol rather than `WKWebExtension.MessagePort` directly, so the whole
/// of this file can be driven by a test that never loads an extension. The real
/// one is `MessagePortPeer` in `ExtensionHost.swift`.
@MainActor
protocol NativeMessagingPeer: AnyObject {
    /// Set by this file. Called with each message the extension sent, as JSON.
    var onMessage: (@MainActor (String) -> Void)? { get set }
    /// Set by this file. Called once, when the extension hangs up.
    var onHangUp: (@MainActor () -> Void)? { get set }
    /// One message, as JSON, for the extension.
    func deliver(_ json: String)
    /// End the conversation. `reason` is `nil` for an ordinary close.
    func end(reason: String?)
}

/// The program end of a conversation.
///
/// Also a protocol, for the same reason and with more force: a test that
/// spawned a real program would be a test that depends on what is installed on
/// the machine running it.
@MainActor
protocol NativeHostLink: AnyObject {
    /// Set by this file. Called with each whole message the program sent.
    var onMessage: (@MainActor (String) -> Void)? { get set }
    /// Set by this file. Called once, when the program goes away for any
    /// reason, with something quotable.
    var onClose: (@MainActor (String) -> Void)? { get set }
    func send(_ json: String)
    func close()
}

// MARK: - The host

@MainActor
final class NativeMessagingHost {
    /// What the core answers about one request. The only way a program is ever
    /// named. Replaced in tests.
    var lookUp: ((_ extensionId: String, _ applicationId: String) -> NativeHostOutcome)?

    /// Put a question on screen. The answer arrives back at `answer(_:_:_:)`.
    var ask: ((_ extensionId: String, _ host: ResolvedHost) -> Void)?

    /// How a program is started. Replaced in tests so nothing spawns.
    var makeLink: ((_ host: ResolvedHost, _ extensionId: String) throws -> NativeHostLink)?

    /// How long a one-shot message waits for its one reply.
    ///
    /// `chrome.runtime.sendNativeMessage` is a promise, and a promise that
    /// never settles is a worker that waits for ever. Thirty seconds is long
    /// enough for a password manager to unlock and short enough to be a
    /// failure rather than a hang.
    static let replyTimeout: Duration = .seconds(30)

    /// One live conversation, held for as long as it is live.
    private final class Connection {
        let key: Key
        let link: NativeHostLink
        let peer: NativeMessagingPeer?
        /// Set for a one-shot `sendNativeMessage`, which ends at its first
        /// reply. `nil` for a port, which ends when somebody hangs up.
        var reply: ((String?, String?) -> Void)?
        var deadline: Task<Void, Never>?

        init(key: Key, link: NativeHostLink, peer: NativeMessagingPeer?) {
            self.key = key
            self.link = link
            self.peer = peer
        }
    }

    /// What a decision is about: one extension starting one program. Not the
    /// application id — see the ledger's own note on why.
    struct Key: Hashable {
        let extensionId: String
        let program: String
    }

    /// A request that is on screen rather than running.
    private struct Waiting {
        let host: ResolvedHost
        let peer: NativeMessagingPeer?
        let opened: ((String?) -> Void)?
        let reply: ((String?, String?) -> Void)?
        /// Set for a one-shot exchange: the message that was to be sent, kept
        /// with the request rather than beside it, so it cannot outlive the
        /// request or be picked up by a different one.
        let firstMessage: String?
    }

    private var connections: [ObjectIdentifier: Connection] = [:]
    private var waiting: [Key: [Waiting]] = [:]

    // MARK: - A long-lived port

    /// An extension called `chrome.runtime.connectNative`.
    ///
    /// `opened` is WebKit's completion handler: `nil` means the connection is
    /// live, a sentence means it is not. It may be called later than this
    /// returns, which is what lets a question be asked before a program starts
    /// — a port that failed and a port that is waiting on a person look the
    /// same from JavaScript, and only one of them can end up working.
    func connect(
        extensionId: String,
        applicationId: String,
        peer: NativeMessagingPeer,
        opened: @escaping (String?) -> Void
    ) {
        gate(extensionId: extensionId, applicationId: applicationId, refuse: opened) { host in
            Waiting(host: host, peer: peer, opened: opened, reply: nil, firstMessage: nil)
        }
    }

    // MARK: - One message and one reply

    /// An extension called `chrome.runtime.sendNativeMessage`.
    ///
    /// `reply` takes the answer as JSON, or a sentence saying why there is
    /// none. Exactly one of the two, exactly once.
    func send(
        extensionId: String,
        applicationId: String,
        message: String,
        reply: @escaping (String?, String?) -> Void
    ) {
        gate(
            extensionId: extensionId,
            applicationId: applicationId,
            refuse: { reply(nil, $0 ?? "zer0 refused this.") }
        ) { host in
            Waiting(
                host: host,
                peer: nil,
                opened: nil,
                reply: reply,
                firstMessage: message
            )
        }
    }

    // MARK: - The gate

    /// Ask the core, then either start, ask a person, or refuse.
    ///
    /// **Every road to a process goes through here**, which is why the lookup
    /// is one call and not three: an outcome the core did not produce is not
    /// reachable from this file.
    private func gate(
        extensionId: String,
        applicationId: String,
        refuse: @escaping (String?) -> Void,
        waitingFor: (ResolvedHost) -> Waiting
    ) {
        guard let lookUp else {
            refuse("zer0 is not able to start programs.")
            return
        }

        switch lookUp(extensionId, applicationId) {
        case let .refused(_, sentence):
            refuse(sentence)

        case let .start(host):
            open(host, extensionId: extensionId, waiting: waitingFor(host))

        case let .ask(host):
            let key = Key(extensionId: extensionId, program: host.program)
            let alreadyOnScreen = waiting[key] != nil
            waiting[key, default: []].append(waitingFor(host))
            // One sheet per program, however many requests are stacked behind
            // it. 1Password's extension asks for two application ids on the
            // first press of its button; both resolve to one program, and two
            // sheets for one decision is the defect that shape is chosen to
            // avoid.
            if !alreadyOnScreen {
                ask?(extensionId, host)
            }
        }
    }

    /// Somebody answered.
    ///
    /// Everything queued behind that question is carried out here, in the order
    /// it arrived.
    func answer(extensionId: String, program: String, allowed: Bool) {
        let key = Key(extensionId: extensionId, program: program)
        guard let queued = waiting.removeValue(forKey: key) else { return }
        for request in queued {
            guard allowed else {
                request.opened?("You did not allow this extension to start \(program).")
                request.reply?(nil, "You did not allow this extension to start \(program).")
                continue
            }
            open(request.host, extensionId: extensionId, waiting: request)
        }
    }

    /// Whether anything is queued behind a question, so a sheet that is
    /// dismissed without an answer can be told from one that was never asked.
    func isWaiting(extensionId: String, program: String) -> Bool {
        waiting[Key(extensionId: extensionId, program: program)] != nil
    }

    // MARK: - Starting one

    private func open(_ host: ResolvedHost, extensionId: String, waiting request: Waiting) {
        guard let makeLink else {
            request.opened?("zer0 is not able to start programs.")
            request.reply?(nil, "zer0 is not able to start programs.")
            return
        }

        let link: NativeHostLink
        do {
            link = try makeLink(host, extensionId)
        } catch {
            let sentence = "zer0 could not start \(host.program)."
            request.opened?(sentence)
            request.reply?(nil, sentence)
            return
        }

        let key = Key(extensionId: extensionId, program: host.program)
        let connection = Connection(key: key, link: link, peer: request.peer)
        connection.reply = request.reply
        let id = ObjectIdentifier(link)
        connections[id] = connection

        link.onMessage = { [weak self] json in self?.received(json, on: id) }
        link.onClose = { [weak self] detail in self?.closed(id, detail) }

        // The extension's own messages go straight down the pipe. Nothing here
        // reads them: what a message means is between the extension and the
        // program, and a browser that looked would be a browser that could get
        // it wrong.
        request.peer?.onMessage = { [weak self] json in
            guard let self, self.connections[id] != nil else { return }
            link.send(json)
        }
        request.peer?.onHangUp = { [weak self] in self?.stop(id) }

        request.opened?(nil)

        if let message = request.firstMessage {
            link.send(message)
            connection.deadline = Task { [weak self] in
                try? await Task.sleep(for: Self.replyTimeout)
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.expired(id, program: host.program) }
            }
        }
    }

    // MARK: - Reading

    private func received(_ json: String, on id: ObjectIdentifier) {
        guard let connection = connections[id] else { return }

        // A one-shot exchange ends at its first answer. A second message from a
        // program that was asked one question is not an answer to it.
        if let reply = connection.reply {
            connection.reply = nil
            connection.deadline?.cancel()
            reply(json, nil)
            stop(id)
            return
        }
        connection.peer?.deliver(json)
    }

    private func closed(_ id: ObjectIdentifier, _ detail: String) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        connection.deadline?.cancel()
        // "Stopped", not "did not happen": the program may well have done the
        // work before it went (ADR-0018).
        connection.reply?(nil, detail)
        connection.peer?.end(reason: detail)
    }

    private func expired(_ id: ObjectIdentifier, program: String) {
        guard let connection = connections[id], let reply = connection.reply else { return }
        connection.reply = nil
        reply(nil, "\(program) did not answer. It may still have run.")
        stop(id)
    }

    /// End one conversation from this side.
    func stop(_ id: ObjectIdentifier) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        connection.deadline?.cancel()
        connection.link.close()
    }

    /// End every conversation. Called when the browser is going away, because a
    /// child that outlives its parent is a program nothing will ever stop.
    func stopAll() {
        for id in connections.keys { stop(id) }
        waiting.removeAll()
    }

    var liveCount: Int { connections.count }
}

// MARK: - The actual pipes

// Foundation's `Process` is not in the iOS SDK, and an iPhone's sandbox would
// refuse to run a child program even if it were. The host above treats a
// missing `makeLink` as the honest refusal ("zer0 is not able to start
// programs."), so iOS simply never sets one; the pipes live where `Process`
// does.
#if canImport(AppKit)
/// A child process, spoken to over its stdin and stdout with Chrome's framing.
///
/// The only part of this file a Linux port has to replace, and deliberately the
/// dullest part.
@MainActor
final class NativeHostProcess: NativeHostLink {
    var onMessage: (@MainActor (String) -> Void)?
    var onClose: (@MainActor (String) -> Void)?

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private var buffer = Data()
    /// How big the buffer has to get before the core is asked again. Without
    /// this, a program writing a large reply in small chunks is rescanned once
    /// per chunk.
    ///
    /// Zero to start, and zero again after each message, so the first question
    /// after a message is always the core's rather than a length this file
    /// worked out for itself.
    private var needed: UInt64 = 0
    private var diagnostics = Data()
    private var closed = false

    enum LaunchError: LocalizedError {
        case notExecutable(String)

        var errorDescription: String? {
            switch self {
            case let .notExecutable(path): "zer0 could not run \(path)."
            }
        }
    }

    /// `host` has already been through the core, so the path is absolute, is
    /// not a link, and is something a person said yes to. Nothing here checks
    /// any of that again — a second copy of the rule is a second place for it
    /// to be wrong.
    init(host: ResolvedHost, extensionId: String) throws {
        process.executableURL = URL(fileURLWithPath: host.program)
        // Chrome's one argument, composed in the core so that no host can hand
        // a program an id this browser never verified.
        process.arguments = [nativeHostArgument(extensionId: extensionId)].compactMap { $0 }
        // A minimal environment rather than `ProcessInfo.environment`. A
        // program does not need the browser's whole environment to run, and
        // handing it over would hand over whatever else is in there.
        var environment: [String: String] = [:]
        for passthrough in ["PATH", "HOME", "LANG", "TMPDIR"] {
            if let value = ProcessInfo.processInfo.environment[passthrough] {
                environment[passthrough] = value
            }
        }
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        // `DispatchQueue.main.async` rather than `MainActor.assumeIsolated`
        // directly, and rather than `Task { @MainActor in … }`. The first is
        // false — these handlers run on a queue of Foundation's choosing, and
        // the assumption is not checked away in release, it traps. The second
        // loses ordering, and this is a byte stream being reassembled: chunks
        // arriving out of order would corrupt the framing rather than fail
        // loudly. `McpHost` learned both of these from a real crash report.
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.read(chunk) } }
        }
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
            throw LaunchError.notExecutable(host.program)
        }
    }

    func send(_ json: String) {
        guard !closed, process.isRunning else { return }
        // Framed in the core, which is also where a body that is not JSON and
        // one that is too big are refused. `nil` is a message this browser
        // will not send, and sending nothing is the whole of what to do about
        // it — the alternative is writing a length a program then waits on.
        guard let framed = nativeMessageFrame(json: json) else { return }
        try? input.fileHandleForWriting.write(contentsOf: framed)
    }

    func close() {
        guard !closed else { return }
        closed = true
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil

        // Closing stdin is how a native messaging host is asked to stop, and a
        // well-behaved one exits on end-of-file. Termination is what happens to
        // the rest, and `SIGKILL` is what happens to a program that ignores
        // that: a child nothing can stop is the failure this whole feature must
        // not introduce.
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

    private func read(_ chunk: Data) {
        guard !closed, !chunk.isEmpty else { return }
        buffer.append(chunk)

        while UInt64(buffer.count) >= needed {
            switch nativeMessageStep(buffer: buffer) {
            case let .waiting(needed):
                self.needed = needed
                return

            case let .message(json, consumed):
                buffer.removeFirst(Int(consumed))
                needed = 0
                onMessage?(json)

            case let .tooLarge(declared, limit):
                fail("\(name) tried to send \(declared) bytes at once, and zer0 reads \(limit).")
                return

            case let .malformed(detail):
                // There is no resynchronising mark in this format, so there is
                // nothing to skip forward to. Carrying on would hand the
                // extension messages assembled out of the middle of others.
                fail("\(name) sent something that was not a message: \(detail)")
                return
            }
        }
    }

    private var name: String {
        process.executableURL?.lastPathComponent ?? "The program"
    }

    private func fail(_ sentence: String) {
        buffer = Data()
        closed = true
        onClose?(sentence)
        // `closed` is already set, so this only tears the process down.
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        try? input.fileHandleForWriting.close()
        let running = process
        Task {
            try? await Task.sleep(for: .seconds(1))
            if running.isRunning { running.terminate() }
        }
    }

    /// Drained and mostly discarded, so a program that prints a stack trace and
    /// dies is quotable rather than archived.
    private func noted(_ chunk: Data) {
        diagnostics.append(chunk)
        if diagnostics.count > 4096 {
            diagnostics.removeFirst(diagnostics.count - 4096)
        }
    }

    private func ended(_ status: Int32) {
        guard !closed else { return }
        closed = true
        let said = String(data: diagnostics, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        onClose?(said.isEmpty ? "\(name) stopped with status \(status)." : said)
    }
}
#endif
