import Foundation
import Zer0Core

/// A tool server reached over Streamable HTTP.
///
/// The other half of `McpLink`, beside `StdioLink`, and deliberately as dull as
/// that one. It holds a `URL`, a `URLSession` and a token; it decides nothing.
/// Which addresses may be reached, which headers a request carries, what a
/// status code means and how a body comes apart into messages are all answered
/// by `mcp_http` in the core, for the reason ADR-0002 gives: a Linux host
/// reimplements the forty lines below, not the policy.
///
/// ## Why there is no connection here
///
/// One POST, one response. There is no long-lived `GET`, because the
/// server-to-client stream is optional and ADR-0050 already decided this
/// browser re-lists on connect rather than subscribing to
/// `notifications/tools/list_changed`.
///
/// That absence is the feature. A local proxy somebody quits and restarts all
/// day never leaves this object holding a dead socket, because it never held a
/// live one: the next request either works or does not, and "does not" is one
/// sentence rather than a reconnection state machine. What `zer0` has to get
/// right is saying so — see `McpFailure.unreachable`.
@MainActor
final class HttpLink: McpLink {
    var onLine: (@MainActor (String) -> Void)?
    var onClose: (@MainActor (McpFailure, String) -> Void)?

    private let url: URL
    private let token: String?
    private let session: URLSession
    private let guard_: RedirectGuard

    /// What a legacy server called this conversation. Modern servers have no
    /// sessions; the core is what refuses to send this to one.
    private var mcpSession: String?

    private var closed = false
    /// Requests still out, and the last notification, so ordering can be kept
    /// where it matters. See `send`.
    private var outstanding: [Int: Task<Void, Never>] = [:]
    private var barrier: Task<Void, Never>?
    private var nextTicket = 0

    /// A URL that has already been through `mcpEndpointVerdict`.
    ///
    /// Taking a `URL` rather than a `String` is the small structural half of
    /// that: this initialiser cannot be handed the raw text out of the file, so
    /// the check cannot be the thing somebody forgets. The other half is
    /// `ConfiguredChatHost`, which is the only place that turns one into the
    /// other.
    init(url: URL, token: String?) {
        self.url = url
        self.token = token

        let configuration = URLSessionConfiguration.ephemeral
        // Longer than any deadline `McpHost` arms, on purpose. Both layers
        // would otherwise be entitled to give up first, and only one of them
        // knows whether what timed out was a handshake or a tool.
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 300
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        // A tool server is not a website and shares nothing with one.
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        guard_ = RedirectGuard()
        session = URLSession(configuration: configuration, delegate: guard_, delegateQueue: nil)
    }

    /// Post one message.
    ///
    /// **A notification is a barrier.** Over a pipe, ordering comes free with
    /// the pipe; over HTTP, two requests started a microsecond apart arrive in
    /// whichever order the server feels like. That matters exactly once, and it
    /// is a correctness bug rather than a slow day: `notifications/initialized`
    /// finishes the legacy handshake, and a `tools/list` that overtakes it
    /// reaches a server that has not been initialised yet.
    ///
    /// So a message with no id waits for everything already out, and everything
    /// issued after it waits for it. Requests among themselves stay concurrent,
    /// which is what keeps one slow tool from holding up a listing.
    func send(_ line: String, era: ServerEra?) {
        guard !closed else { return }

        nextTicket += 1
        let ticket = nextTicket
        // No id means a notification. The core is what knows that.
        let isNotification = mcpReplyId(raw: line) == nil
        let waitFor: [Task<Void, Never>] =
            isNotification
                ? Array(outstanding.values) + [barrier].compactMap { $0 }
                : [barrier].compactMap { $0 }

        // `Task` inherits this object's isolation, so everything below already
        // runs on the main actor.
        let task = Task { [weak self] in
            for earlier in waitFor { _ = await earlier.value }
            guard !Task.isCancelled, let self, !closed else { return }
            await post(line, era: era)
            outstanding[ticket] = nil
        }
        outstanding[ticket] = task
        if isNotification { barrier = task }
    }

    func close() {
        guard !closed else { return }
        closed = true
        barrier = nil
        for task in outstanding.values { task.cancel() }
        outstanding.removeAll()
        session.invalidateAndCancel()
    }

    // MARK: - One exchange

    private func post(_ line: String, era: ServerEra?) async {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(line.utf8)
        for header in mcpHttpHeaders(era: era, session: mcpSession, line: line) {
            request.setValue(header.value, forHTTPHeaderField: header.name)
        }
        // The one place a credential becomes a header, and it is never held on
        // this object beyond the string it was constructed with.
        if let token, let authorization = mcpAuthorizationHeader(token: token) {
            request.setValue(authorization.value, forHTTPHeaderField: authorization.name)
        }

        let body: Data
        let response: HTTPURLResponse
        do {
            let (data, raw) = try await session.data(for: request)
            guard let http = raw as? HTTPURLResponse else {
                finish(.malformed, "That address did not answer over HTTP.")
                return
            }
            body = data
            response = http
        } catch let error as URLError where error.code == .cancelled {
            // Our own `close`, or a redirect the guard refused. Neither is news.
            return
        } catch {
            // Connection refused is the normal state of a local proxy somebody
            // has quit, so this sentence is the one a person reads most often.
            // It says the address could not be reached, and stops there,
            // because zer0 does not know why (ADR-0018).
            finish(.unreachable, describe(error))
            return
        }

        guard !closed else { return }

        // A legacy server may name the conversation, and then require the name
        // back on everything after. Bookkeeping, so it lives here.
        if let named = response.value(forHTTPHeaderField: "Mcp-Session-Id"), !named.isEmpty {
            mcpSession = named
        }

        guard (200 ..< 300).contains(response.statusCode) else {
            let outcome = mcpHttpStatusFailure(
                status: UInt16(clamping: response.statusCode),
                allow: response.value(forHTTPHeaderField: "Allow"),
                authenticate: response.value(forHTTPHeaderField: "WWW-Authenticate")
            )
            finish(outcome.failure, outcome.message)
            return
        }

        // Not one message per line. A server may answer a POST with an event
        // stream, and `202` to a notification carries nothing at all.
        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? ""
        let text = String(decoding: body, as: UTF8.self)
        for message in mcpHttpReplyLines(contentType: contentType, body: text) {
            onLine?(message)
        }
    }

    /// A failure that ends this link, said once.
    ///
    /// Whatever was queued behind it is dropped rather than sent. `McpHost`
    /// has already been told the server is gone and has failed everything that
    /// was in flight; posting the rest would be talking to a connection nobody
    /// is listening to any more.
    private func finish(_ failure: McpFailure, _ detail: String) {
        guard !closed else { return }
        closed = true
        barrier = nil
        for task in outstanding.values { task.cancel() }
        outstanding.removeAll()
        onClose?(failure, detail)
    }

    private func describe(_ error: Error) -> String {
        let sentence = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        return sentence.isEmpty ? McpFailure.unreachable.reasonText : sentence
    }
}

/// Refuses a redirect that leaves the addresses `zer0` is allowed to reach.
///
/// Without this the endpoint rule is advisory: a server answering `301` to
/// `http://elsewhere` would have `URLSession` follow it without asking, and the
/// address somebody approved would not be the address that got the assistant's
/// messages. The check is the same core function the configuration went
/// through, so there is one answer to "may this be reached" and not two.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let destination = request.url?.absoluteString else {
            completionHandler(nil)
            return
        }
        switch mcpEndpointVerdict(url: destination) {
        case .allowed:
            completionHandler(request)
        case .refused:
            // `nil` turns the redirect into the response, which surfaces as a
            // 3xx and gets the core's sentence about an unusable answer.
            completionHandler(nil)
        }
    }
}
