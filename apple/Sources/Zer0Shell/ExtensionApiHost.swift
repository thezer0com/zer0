import AppKit
import Foundation
import WebKit
import Zer0Core

/// The one door an extension's own JavaScript reaches this browser through.
///
/// ## Why a URL scheme and not any of the obvious things
///
/// Measured on macOS 26.6, from a real MV3 background service worker loaded
/// into a real `WKWebExtensionController`:
///
/// | Route | Reaches the worker |
/// | --- | --- |
/// | `WKUserScript` on the controller's `userContentController` | no (ADR-0100) |
/// | `chrome.runtime.sendNativeMessage` | only if the package declared `nativeMessaging` |
/// | `fetch` to `http://127.0.0.1:<port>` | no — the load fails |
/// | `fetch` to a scheme handled here | **yes** |
///
/// The second row is what settles it. A worker granted `downloads` and nothing
/// else answers `typeof chrome.runtime.sendNativeMessage` with `undefined`, so
/// native messaging can only serve packages that asked for something else
/// entirely — and rewriting a manifest to add `nativeMessaging` would put a
/// Critical permission on the consent sheet that the extension never asked for.
///
/// ## Who is asking, and why that cannot be forged
///
/// WebKit sets `Origin: webkit-extension://<uuid>` on the request, and that
/// uuid is the context's `baseURL` host. `Origin` is a forbidden header name in
/// `fetch`, so an extension cannot write it; and this scheme is registered only
/// on the *extension* controller's configuration, so no ordinary page has a way
/// to reach this handler at all.
///
/// Everything after identifying the caller is the core's answer, including
/// every refusal.
@MainActor
final class ExtensionApiHost: NSObject, WKURLSchemeHandler {
    /// The scheme extensions fetch. Not `zer0:` — that is a name a person could
    /// type — and long enough that no site is going to have registered it.
    static let scheme = "zer0-extension-api"

    /// Where a call is addressed. The method is in the path so a request for
    /// something this browser does not answer is refused without its body ever
    /// being parsed.
    static let host = "call"

    private weak var model: BrowserModel?
    /// Asked which extension a `webkit-extension://<uuid>` origin belongs to.
    ///
    /// Weak, and assigned after construction rather than passed in, because the
    /// controller's configuration has to name this handler before the host that
    /// owns it exists. A strong reference here would be the cycle.
    weak var extensions: ExtensionHost?

    init(model: BrowserModel) {
        self.model = model
    }

    func webView(_: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url,
              url.host == Self.host,
              let method = method(in: url)
        else {
            // A shape this does not recognise gets a refusal rather than a
            // guess at what was meant, and it is the same JSON shape every
            // other refusal has so the other side never has to branch.
            answer(task, with: Self.refusal("zer0 does not answer that address."))
            return
        }

        guard let extensionId = callerOf(task.request) else {
            answer(task, with: Self.refusal("zer0 could not tell which extension is asking."))
            return
        }

        guard let model else {
            answer(task, with: Self.refusal("zer0 is shutting down."))
            return
        }

        let body = task.request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? "null"
        let answered = model.extensionApiCall(
            extensionId: extensionId,
            method: method,
            body: body,
            host: Self.hostFacts()
        )

        // Exhaustive, with no `default:`. A new outcome in the core has to earn
        // its behaviour here before the shell will compile (AGENTS.md).
        switch answered.outcome {
        case .nothing:
            answer(task, with: answered.json)
        case let .startDownload(tab, url):
            start(url, in: tab, answering: task)
        case let .showFile(path):
            DownloadHost.reveal(path)
            answer(task, with: answered.json)
        case let .openFile(path):
            DownloadHost.open(path)
            answer(task, with: answered.json)
        }
    }

    /// The tasks being answered later than they were asked, and whether WebKit
    /// has taken any of them back.
    ///
    /// Answering a stopped `WKURLSchemeTask` raises an Objective-C exception,
    /// which Swift cannot catch and which therefore takes the process down
    /// rather than reddening anything — the same shape of crash ADR-0101 hit
    /// with a duplicate message handler.
    ///
    /// Only the one road that waits is tracked, and its entry is dropped when it
    /// finishes. A set of every task ever stopped would grow for the life of the
    /// process to answer a question about the handful that are in flight.
    private var waiting: [ObjectIdentifier: Bool] = [:]

    func webView(_: WKWebView, stop task: any WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        if waiting[id] != nil { waiting[id] = true }
    }

    // MARK: - Starting a download the extension asked for

    /// Ask the engine for the file, and answer once there is a download to name.
    ///
    /// **Held open until the row exists**, and that is the decision rather than
    /// caution. `startDownload` answers the moment the request goes out, which
    /// is before `WKDownload` has asked where to write and therefore before the
    /// core has a row. An extension told the id at *that* moment gets a number
    /// it cannot use: `download().then(id => cancel(id))` — the most ordinary
    /// thing an extension does with the answer — would refuse, because there is
    /// nothing under that id yet. So the promise settles when the answer is
    /// true, which is what `chrome.downloads.download` means everywhere else.
    private func start(_ url: String, in tab: TabId, answering task: any WKURLSchemeTask) {
        guard let model, let started = model.startDownloadForExtension(url: url, tab: tab) else {
            answer(task, with: Self.refusal("zer0 could not start that download."))
            return
        }
        let id = ObjectIdentifier(task)
        waiting[id] = false
        Task { @MainActor [weak self] in
            defer { self?.waiting.removeValue(forKey: id) }
            for _ in 0..<Self.rowAttempts {
                // `true` means WebKit has taken the task back, and answering one
                // it has taken back is a crash rather than a failure.
                guard let self, self.waiting[id] == false else { return }
                if model.downloads.contains(where: { $0.id == started }) {
                    self.answer(task, with: model.extensionDownloadStarted(started))
                    return
                }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            // A request that never became a download. Saying so beats handing
            // over a number for nothing, and beats never answering at all —
            // a promise that never settles is a worker that waits for ever.
            self?.answer(task, with: Self.refusal("zer0 could not start that download."))
        }
    }

    /// How long to wait for a request to become a download, in 25ms turns.
    ///
    /// Ten seconds. Long enough for a slow DNS answer on the way to the first
    /// byte; short enough that a promise which is never going to settle settles.
    private static let rowAttempts = 400

    // MARK: - Facts only this side can measure

    /// What `chrome.idle` is really about, read from the system.
    ///
    /// Both numbers are measured here and neither is interpreted here: what
    /// counts as idle, and whether a locked screen outranks a recent keystroke,
    /// are the core's to answer.
    ///
    /// `combinedSessionState` counts every input type the event system knows
    /// about, which is what "has anybody touched this machine" means — asking
    /// about `.keyDown` alone would call somebody reading with a mouse in their
    /// hand idle.
    private static func hostFacts() -> HostFacts {
        let seconds = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: CGEventType(rawValue: ~UInt32(0)) ?? .null
        )
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let locked = session?["CGSSessionScreenIsLocked"] as? Bool ?? false
        return HostFacts(
            secondsSinceInput: UInt64(max(0, seconds)),
            screenLocked: locked
        )
    }

    // MARK: - Reading the request

    /// The method being called, or `nil` for an address that is not one.
    ///
    /// Only `namespace.method` shapes, so a path carrying a slash, a traversal
    /// or a query cannot become a method name the core then has to defend
    /// against.
    private func method(in url: URL) -> String? {
        let path = url.path.trimmingPrefix("/")
        guard !path.isEmpty, !path.contains("/"), path.count < 64 else { return nil }
        return String(path)
    }

    /// Which extension made this request.
    ///
    /// The `Origin` header, matched against the base URL WebKit gave each
    /// context. Not the referer, which a worker can change, and not anything in
    /// the body, which is the extension's own writing.
    private func callerOf(_ request: URLRequest) -> String? {
        guard let origin = request.value(forHTTPHeaderField: "Origin"),
              let host = URL(string: origin)?.host
        else { return nil }
        return extensions?.extensionId(withBaseHost: host)
    }

    // MARK: - Answering

    /// Every answer is `200` with a JSON body, including every refusal.
    ///
    /// A status code would be a second channel saying the same thing, and the
    /// two would drift; the file on the other side reads one field. The CORS
    /// header is not optional — measured, a response without it reaches the
    /// handler and then fails the worker's `fetch` with `TypeError: Load
    /// failed`, which is indistinguishable from this browser not answering.
    private func answer(_ task: any WKURLSchemeTask, with json: String) {
        guard let url = task.request.url else { return }
        let body = Data(json.utf8)
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "application/json",
                "Content-Length": "\(body.count)",
                "Access-Control-Allow-Origin": "*",
            ]
        )
        guard let response else { return }
        task.didReceive(response)
        task.didReceive(body)
        task.didFinish()
    }

    /// A refusal in the shape the core's refusals already have, for the three
    /// things the core is never asked about because they are about this side.
    private static func refusal(_ message: String) -> String {
        // Through `JSONSerialization` rather than by wrapping it in quotes, for
        // the reason `compat.rs` gives about entry points: a message is prose
        // and prose contains quotes. If even that fails there is a refusal with
        // no reason in it, which is worse than this one and better than a body
        // the other side cannot parse.
        guard let data = try? JSONSerialization.data(withJSONObject: ["error": message]),
              let json = String(data: data, encoding: .utf8)
        else {
            return #"{"error":"zer0 refused this and could not say why."}"#
        }
        return json
    }
}
