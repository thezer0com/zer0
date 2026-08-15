import Foundation
import Zer0Core

/// Carries out `StartChatReply` and streams the answer back as `Action`s.
///
/// The sibling of `EngineHost`, and built the same way: it performs, it does
/// not decide. It opens the connection, reads the Keychain, and tears the
/// connection down when somebody presses Escape. What a `content_block_delta`
/// is, whether a 401 means "your key is wrong" or "you sent a bad request", and
/// whether a stop is a finished turn or a refusal are all questions it asks the
/// core and never answers.
///
/// Nothing about a provider is written here. Which one answers, at what
/// address, under what model, arrives resolved from configuration — this host
/// could not name a vendor if it wanted to.
@MainActor
final class ChatProviderHost {
    /// Everything a reply needs, resolved from configuration before it starts.
    ///
    /// A value rather than a lookup the host performs, because resolving it is
    /// configuration's business and performing it is this host's, and a host
    /// that did both would be the place a provider's name leaked into the shell.
    struct Resolved {
        let endpoint: ProviderEndpoint
        let model: String
        /// The tools this reply may offer.
        ///
        /// Filtered against what `StartChatReply` carried before anything is
        /// sent, because the core refuses a call it did not allow and offering
        /// more only produces a turn thrown away. `ToolDescriptor` now carries
        /// the schema and the annotations, so this list should be *derived*
        /// from the allowed one rather than resolved beside it — until it is,
        /// the filter is the only thing keeping the two honest.
        let tools: [ToolSpec]
        let system: String?
    }

    /// How a provider is looked up for a conversation. `nil` means nothing is
    /// configured, which is the first thing anybody sees and its own failure.
    var resolve: (@MainActor (ConversationId) -> Resolved?)?

    /// Reads one provider's key out of the Keychain.
    ///
    /// A closure, and the only route to a secret this host has. It holds no
    /// file handle, no service name and no key of its own, so "do not read a
    /// token from a file" is a property of the type rather than a rule someone
    /// has to remember. Whoever assembles the browser supplies the Keychain;
    /// a test supplies a string.
    var token: (@Sendable (String) async throws -> String?)?

    /// Where facts go. Set by the model, exactly as `EngineHost.emit` is.
    var emit: (@MainActor (Action) -> Void)?

    /// Swappable so tests never touch a network. The real one is
    /// `URLSessionChatTransport`; a test hands over a script of bytes.
    var transport: ChatTransport = URLSessionChatTransport()

    /// One task per reply in flight, keyed by the message being written into.
    /// Keyed by message rather than by conversation because that is what
    /// `CancelChatReply` names, and because two replies in one thread is a
    /// state the core can produce and this host must not lose track of.
    private var live: [MessageId: Task<Void, Never>] = [:]

    func perform(_ commands: [EngineCommand]) {
        for command in commands {
            perform(command)
        }
    }

    private func perform(_ command: EngineCommand) {
        switch command {
        case let .startChatReply(conversation, message, transcript, tools):
            start(
                conversation: conversation,
                message: message,
                transcript: transcript,
                allowed: tools
            )

        case let .cancelChatReply(message):
            // Nothing is reported back. The core already knows — it asked — and
            // an error on a thread somebody deliberately stopped would be the
            // browser arguing with them.
            live.removeValue(forKey: message)?.cancel()

        // Every other command belongs to another host. Listed rather than
        // swept up by a `default:`, so a new command breaks this build until
        // somebody decides whether it is ours (ADR-0031).
        case .createWebView, .adoptWebView, .destroyWebView, .loadUrl, .reload, .goBack, .goForward,
             .focusWebView, .setMuted, .setZoom, .deleteDataStore, .acceptDownload,
             .askDownloadDestination, .cancelDownload, .startDownload, .resumeDownload,
             .printPage, .fetchIcon,
             .runToolCall, .cancelToolCall, .capturePageContext, .listTools(_),
             .raiseWindow(_),
             // A browser window is a scene. This host has no views and no
             // scenes, so both belong to the app.
             .openBrowserWindow, .closeBrowserWindow,
             // Answering a page's request for a camera and stopping a capture
             // are both `EngineHost`'s: they name a web view, which this host
             // has none of.
             .answerSitePermission, .stopCapture,
             // And so is letting a page carry on out of `alert()`: the handler
             // it names was handed over with a web view.
             .answerPageDialog,
             // And so are both halves of what a server asked: each names a
             // completion handler the engine handed over with a navigation,
             // which this host has none of.
             .answerHttpAuth, .answerServerTrust:
            break
        }
    }

    private func start(
        conversation: ConversationId,
        message: MessageId,
        transcript: [Message],
        allowed: [ToolDescriptor]
    ) {
        guard let resolved = resolve?(conversation) else {
            emit?(.chatFailed(
                conversation: conversation,
                message: message,
                kind: .noProviderConfigured,
                detail: "no provider is set up"
            ))
            return
        }

        // Only what the core allowed. A host that offered more would produce
        // calls the core refuses, which is a model being told to do work that
        // is thrown away.
        let tools = resolved.tools.filter { spec in
            allowed.contains { $0.server == spec.server && $0.tool == spec.tool }
        }

        live[message]?.cancel()
        live[message] = Task { [weak self] in
            await self?.run(
                conversation: conversation,
                message: message,
                transcript: transcript,
                tools: tools,
                resolved: resolved
            )
            self?.live.removeValue(forKey: message)
        }
    }

    private func run(
        conversation: ConversationId,
        message: MessageId,
        transcript: [Message],
        tools: [ToolSpec],
        resolved: Resolved
    ) async {
        let request: HttpRequest
        do {
            // The token is read here and is gone when this scope ends. It is
            // never stored on the host, never logged, and never put anywhere a
            // crash reporter would find it.
            let secret = chatProviderNeedsToken(endpoint: resolved.endpoint)
                ? try await token?(resolved.endpoint.id)
                : nil
            request = try chatRequest(
                endpoint: resolved.endpoint,
                token: secret,
                model: resolved.model,
                system: resolved.system,
                transcript: transcript,
                tools: tools
            )
        } catch let ChatRequestError.Provider(error) {
            // The first-run failure, caught before a socket is opened: a
            // missing key names the provider whose setting is wrong.
            fail(conversation: conversation, message: message, error: error)
            return
        } catch {
            fail(
                conversation: conversation,
                message: message,
                error: chatUnreachable(message: error.localizedDescription)
            )
            return
        }

        let stream = ChatStream(wire: resolved.endpoint.wire, tools: tools)
        var status: UInt16 = 0
        var retryAfter: String?
        /// A failed response is read as an error, not as a stream, so its body
        /// is collected whole rather than decoded.
        var errorBody = Data()

        do {
            for try await event in transport.stream(request) {
                try Task.checkCancellation()

                switch event {
                case let .response(code, advice):
                    status = code
                    retryAfter = advice

                case let .bytes(chunk):
                    guard (200 ..< 300).contains(status) else {
                        // Capped: a proxy's error page can be a megabyte, and
                        // none of it past the first screen says anything.
                        if errorBody.count < 64 * 1024 { errorBody.append(chunk) }
                        continue
                    }
                    deliver(
                        stream.push(bytes: chunk),
                        conversation: conversation,
                        message: message,
                        model: resolved.model
                    )
                }
            }
        } catch is CancellationError {
            _ = stream.cancel()
            return
        } catch {
            // The connection never opened or died on its way. One category for
            // "the wifi is off" and "the local model server is not running",
            // because they are one sentence.
            fail(
                conversation: conversation,
                message: message,
                error: chatUnreachable(message: error.localizedDescription)
            )
            return
        }

        if Task.isCancelled {
            _ = stream.cancel()
            return
        }

        guard (200 ..< 300).contains(status) else {
            fail(
                conversation: conversation,
                message: message,
                error: chatDecodeError(
                    wire: resolved.endpoint.wire,
                    status: status,
                    body: String(decoding: errorBody, as: UTF8.self),
                    retryAfter: retryAfter
                )
            )
            return
        }

        // Always called. It is what turns a reply that simply stopped into an
        // ending somebody can see rather than a thread that spins for ever.
        deliver(
            stream.finish(),
            conversation: conversation,
            message: message,
            model: resolved.model
        )
    }

    private func deliver(
        _ events: [StreamEvent],
        conversation: ConversationId,
        message: MessageId,
        model: String
    ) {
        for event in events {
            switch event {
            case let .started(reported):
                // What actually answered, which is rarely the string that was
                // asked for. Recorded on the message so last week's answers
                // keep last week's label (ADR-0018).
                emit?(.chatReplyStarted(message: message, model: reported ?? model))

            case let .textDelta(text):
                emit?(.chatReplyDelta(message: message, text: text))

            case .reasoningDelta:
                // The core has nowhere to put this yet, and showing a model's
                // scratch work as its answer would be worse than not showing
                // it. This is the line to change when the transcript grows a
                // place for reasoning.
                break

            case .toolCallStarted:
                // Advisory: the name is known before the arguments are. There
                // is no action for it yet, and inventing one here would be the
                // shell deciding what a conversation looks like.
                break

            case let .toolCall(invocation):
                emit?(.chatToolCallRequested(message: message, invocation: invocation))

            case .usage:
                break

            case let .finished(stop):
                if let ended = chatReplyStop(stop: stop) {
                    emit?(.chatReplyFinished(message: message, stop: ended))
                } else if let refused = chatReplyRefusal(stop: stop) {
                    // A refusal drawn as a finished reply is an empty bubble
                    // presented as an answer.
                    emit?(.chatFailed(
                        conversation: conversation,
                        message: message,
                        kind: refused,
                        detail: "the provider declined to answer"
                    ))
                }

            case let .failed(error):
                fail(conversation: conversation, message: message, error: error)
            }
        }
    }

    private func fail(conversation: ConversationId, message: MessageId, error: ProviderError) {
        // `nil` is cancellation, which is not a failure and must not put an
        // error on a thread somebody stopped on purpose.
        guard let kind = chatErrorKind(error: error) else { return }
        emit?(.chatFailed(
            conversation: conversation,
            message: message,
            kind: kind,
            detail: error.message
        ))
    }
}

// MARK: - The connection

/// What a transport reports while a response is arriving.
enum ChatTransportEvent: Sendable {
    /// The headers landed. Always first, and exactly once.
    case response(status: UInt16, retryAfter: String?)
    /// More of the body, in whatever size the network produced.
    case bytes(Data)
}

/// Performing a request. The one seam that touches a socket.
///
/// A protocol so a test can hand over a script of bytes — including one split
/// in the middle of a word — without a server, a port or a timeout. The rule
/// that tests never reach a network is enforced by this being injectable, not
/// by everyone remembering.
protocol ChatTransport: Sendable {
    func stream(_ request: HttpRequest) -> AsyncThrowingStream<ChatTransportEvent, Error>
}

/// The real one.
struct URLSessionChatTransport: ChatTransport {
    /// Generous, because a model can think for a long time before it says
    /// anything, and it is *between* bytes rather than overall — a reply that
    /// is still arriving after two minutes is working, not stuck.
    var timeoutBetweenBytes: TimeInterval = 120

    func stream(_ request: HttpRequest) -> AsyncThrowingStream<ChatTransportEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let url = URL(string: request.url) else {
                        throw URLError(.badURL)
                    }
                    var urlRequest = URLRequest(url: url)
                    urlRequest.httpMethod = request.method
                    urlRequest.timeoutInterval = timeoutBetweenBytes
                    // Never `httpBody` with a streamed upload: this is a small
                    // JSON document and the transcript is already in memory.
                    urlRequest.httpBody = Data(request.body.utf8)
                    for header in request.headers {
                        urlRequest.setValue(header.value, forHTTPHeaderField: header.name)
                    }
                    // Without this a proxy is free to hand back a buffered
                    // response, and a reply that arrives all at once after
                    // twenty seconds is the feature not working.
                    urlRequest.setValue("no-store", forHTTPHeaderField: "cache-control")

                    let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
                    let http = response as? HTTPURLResponse
                    continuation.yield(.response(
                        status: UInt16(http?.statusCode ?? 0),
                        retryAfter: http?.value(forHTTPHeaderField: "Retry-After")
                    ))

                    // `AsyncBytes` yields one byte at a time; handing each one
                    // across the FFI separately would be absurd. Batched at a
                    // newline because that is where every one of these wires
                    // ends a message, so the batch is usually exactly one. It
                    // is only a batching hint: the decoder is correct at any
                    // boundary, which is what its tests prove.
                    var pending = Data()
                    for try await byte in bytes {
                        pending.append(byte)
                        if byte == 0x0A {
                            continuation.yield(.bytes(pending))
                            pending.removeAll(keepingCapacity: true)
                        }
                    }
                    if !pending.isEmpty {
                        continuation.yield(.bytes(pending))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // Escape has to reach the socket, not just the loop reading it.
            // Without this the connection stays open, the provider keeps
            // generating, and it is still billed.
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
