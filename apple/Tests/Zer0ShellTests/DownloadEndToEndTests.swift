import Foundation
import Network
import Testing
import WebKit
import Zer0Core

@testable import Zer0Shell

/// A download, all the way through.
///
/// A real HTTP server, a real `WKWebView`, real `WKDownload` delegate
/// callbacks, and a real file on disk at the end. Everything else about
/// downloads is checked without WebKit in the room, which proves the rules and
/// proves nothing about whether the plumbing is connected — and "the browser
/// cannot download a file" was a plumbing problem, not a rules problem.
///
/// The server binds port 0 and is told what to serve per test, so these do not
/// touch the network and cannot collide with anything else running.
@MainActor
struct DownloadEndToEndTests {
    /// A folder of our own. Downloads must never land in the real Downloads
    /// folder from a test run.
    private func scratch(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zer0-e2e-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func model(savingInto folder: URL) -> BrowserModel {
        let m = BrowserModel(storagePath: nil)
        m.updatePreferences { $0.downloadDirectory = folder.path }
        return m
    }

    private func navigate(_ m: BrowserModel, to url: String) throws {
        let tab = try #require(m.snapshot.activeTab)
        m.send(.navigateTo(tab: tab, input: url))
    }

    @Test("a file comes down through WebKit and lands where the core said")
    func aRealFileLands() async throws {
        let folder = try scratch("lands")
        let body = Data(repeating: 0x7A, count: 128 * 1024)
        let server = try await TinyHTTPServer(routes: [
            "/file": .attachment(named: "zer0-e2e.bin", body: body),
        ])
        defer { server.stop() }

        let m = model(savingInto: folder)
        try navigate(m, to: "http://127.0.0.1:\(server.port)/file")

        #expect(await eventually { m.downloads.first?.state == .completed })

        let download = try #require(m.downloads.first)
        #expect(download.filename == "zer0-e2e.bin")
        let landed = folder.appendingPathComponent("zer0-e2e.bin")
        #expect(download.path == landed.path)
        #expect(try Data(contentsOf: landed).count == body.count)
        // The size stops being a guess the moment the file is whole.
        #expect(download.totalBytes == UInt64(body.count))
        #expect(downloadFraction(download: download) == 1.0)
    }

    @Test("a Content-Disposition that climbs out of the folder does not get out")
    func traversalIsContainedForReal() async throws {
        let folder = try scratch("traversal")
        // `..` past the root is clamped to the root, so this lands at /tmp
        // wherever the download folder happens to be — which is what makes it
        // a real escape target. The name is this run's own, though: a fixed
        // one is a file a single genuine failure leaves behind forever, and
        // every later run on that machine then reports an escape it did not
        // make.
        let name = "zer0-pwned-e2e-\(UUID().uuidString).txt"
        let escapee = "/tmp/" + name
        defer { try? FileManager.default.removeItem(atPath: escapee) }

        let server = try await TinyHTTPServer(routes: [
            "/file": .attachment(
                named: "../../../../../../tmp/\(name)",
                body: Data("if this is at /tmp, the sanitiser failed".utf8)
            ),
        ])
        defer { server.stop() }

        let m = model(savingInto: folder)
        try navigate(m, to: "http://127.0.0.1:\(server.port)/file")

        #expect(await eventually { m.downloads.first?.state == .completed })

        // What lands is asserted, not what it is called. This WebKit replaces
        // separators with `_` before the delegate ever sees the name, so the
        // string arrives as "_.._.._..tmp_zer0-pwned-e2e-….txt" and our own
        // sanitiser has nothing left to strip. That is not a contract — it is
        // undocumented, it has changed before, and a `webkit2gtk` host will
        // have its own answer — so `safe_filename` stays. What must hold on
        // every engine is the two facts below.
        let download = try #require(m.downloads.first)
        #expect(URL(fileURLWithPath: download.path).deletingLastPathComponent().path == folder.path)
        #expect(
            !FileManager.default.fileExists(atPath: escapee),
            "a served filename wrote outside the download folder"
        )
        #expect(!download.filename.contains("/"), "the name is still a name, not a path")
    }

    @Test("downloading the same file twice keeps both")
    func aSecondCopyDoesNotReplaceTheFirst() async throws {
        let folder = try scratch("twice")
        let first = Data("first".utf8)
        let second = Data("second copy, longer".utf8)

        let serverA = try await TinyHTTPServer(routes: [
            "/file": .attachment(named: "report.pdf", body: first),
        ])
        let m = model(savingInto: folder)
        try navigate(m, to: "http://127.0.0.1:\(serverA.port)/file")
        #expect(await eventually { m.downloads.first?.state == .completed })
        serverA.stop()

        let serverB = try await TinyHTTPServer(routes: [
            "/file": .attachment(named: "report.pdf", body: second),
        ])
        defer { serverB.stop() }
        try navigate(m, to: "http://127.0.0.1:\(serverB.port)/file")
        #expect(await eventually { m.downloads.count == 2 && m.downloads.first?.state == .completed })

        #expect(m.downloads.first?.filename == "report-2.pdf")
        #expect(
            try Data(contentsOf: folder.appendingPathComponent("report.pdf")) == first,
            "the file that was already there was written over"
        )
        #expect(try Data(contentsOf: folder.appendingPathComponent("report-2.pdf")) == second)
    }

    @Test("a response with no length arrives whole, and only then has a size")
    func anUnknownLengthStillCompletes() async throws {
        let folder = try scratch("nolength")
        let body = Data(repeating: 0x41, count: 64 * 1024)
        let server = try await TinyHTTPServer(routes: [
            // No Content-Length: the body ends when the connection does. This
            // is the shape that has no percentage to show.
            "/file": .attachmentWithoutLength(named: "stream.bin", body: body),
        ])
        defer { server.stop() }

        let m = model(savingInto: folder)
        try navigate(m, to: "http://127.0.0.1:\(server.port)/file")

        #expect(await eventually { m.downloads.first != nil })
        // While it is running there is nothing to draw a determinate bar from.
        if let running = m.downloads.first, running.state == .inProgress {
            #expect(running.totalBytes == nil)
            #expect(downloadFraction(download: running) == nil)
        }

        #expect(await eventually { m.downloads.first?.state == .completed })
        let download = try #require(m.downloads.first)
        #expect(download.totalBytes == UInt64(body.count), "a finished file has a size")
        #expect(
            try Data(contentsOf: folder.appendingPathComponent("stream.bin")).count == body.count
        )
    }

    @Test("stopping a download in flight stops it")
    func cancellingStops() async throws {
        let folder = try scratch("cancel")
        let server = try await TinyHTTPServer(routes: [
            // Trickled, so there is still something to stop by the time we ask.
            "/file": .slowAttachment(
                named: "big.bin", pieces: 40, pieceSize: 64 * 1024, gap: 0.2
            ),
        ])
        defer { server.stop() }

        let m = model(savingInto: folder)
        try navigate(m, to: "http://127.0.0.1:\(server.port)/file")
        #expect(await eventually { m.downloads.first?.state == .inProgress })

        let id = try #require(m.downloads.first?.id)
        m.cancelDownload(id)

        #expect(m.downloads.first?.state == .cancelled)
        #expect(m.downloads.first?.error == nil)

        // WebKit answers a cancel with NSURLErrorCancelled a moment later, and
        // that answer must not turn "you stopped it" into "it broke". It is
        // not checked here, and the 300ms sleep that used to sit at this line
        // was not checking it either: `DownloadHost.cancel` forgets the
        // download before WebKit replies, so the delegate finds no record and
        // emits nothing. Whatever the rule did, the two expectations above
        // were already true at millisecond zero and stayed true — a wait that
        // could only ever agree with itself.
        //
        // The rule has a lock, and it is deterministic:
        // `DownloadTests.swift::DownloadRoundTripTests/cancellingIsNotAFailure`
        // pushes the late failure in by hand and holds that the state stays
        // cancelled with no error attached.
    }
}

/// Carrying on where a download stopped, through WebKit and onto disk.
///
/// Every one of these is end to end for the same reason the suite above is: the
/// rules about when Resume is offered are checked in the core without WebKit in
/// the room, which proves the rules and proves nothing about whether the blob
/// the engine hands over ever reaches the engine again. See ADR-0101.
@MainActor
struct DownloadResumeTests {
    private func scratch(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zer0-resume-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func model(savingInto folder: URL) -> BrowserModel {
        let m = BrowserModel(storagePath: nil)
        m.updatePreferences { $0.downloadDirectory = folder.path }
        return m
    }

    private func navigate(_ m: BrowserModel, to url: String) throws {
        let tab = try #require(m.snapshot.activeTab)
        m.send(.navigateTo(tab: tab, input: url))
    }

    /// Every byte, and every byte the one the server sent. A resume that
    /// restarted from zero would also produce a file of the right length.
    private func isWhole(_ url: URL, _ bytes: Int) throws -> Bool {
        let data = try Data(contentsOf: url)
        return data.count == bytes && data.allSatisfy { $0 == 0x7A }
    }

    /// The case the whole feature is for: a large file on a connection that
    /// gives up partway.
    @Test("a dropped connection is carried on from where it stopped")
    func aDroppedConnectionIsCarriedOnFromWhereItStopped() async throws {
        let folder = try scratch("dropped")
        let size = 2 * 1024 * 1024
        let server = try await TinyHTTPServer(routes: [
            "/file": .resumableFile(named: "big.bin", bytes: size, sendOnly: 256 * 1024),
        ])
        defer { server.stop() }

        let m = model(savingInto: folder)
        try navigate(m, to: "http://127.0.0.1:\(server.port)/file")

        #expect(await eventually { m.downloads.first?.state == .failed })
        #expect(await eventually { m.downloads.first?.resumable == true })
        let stoppedAt = try #require(m.downloads.first?.receivedBytes)
        #expect(stoppedAt > 0 && stoppedAt < UInt64(size), "it stopped partway: \(stoppedAt)")

        let id = try #require(m.downloads.first?.id)
        m.resumeDownload(id)

        #expect(await eventually { m.downloads.first?.state == .completed })
        #expect(m.downloads.count == 1, "one file, one row")
        #expect(try isWhole(folder.appendingPathComponent("big.bin"), size))
        // Spent. A row that still offered to carry on would be offering to spend
        // a blob nothing holds.
        #expect(m.downloads.first?.resumable == false)
    }

    /// Stopping is pausing, which is why there is no paused state.
    @Test("stopping and carrying on lands the whole file, once")
    func stoppingAndCarryingOnLandsTheWholeFileOnce() async throws {
        let folder = try scratch("paused")
        let size = 2 * 1024 * 1024
        let server = try await TinyHTTPServer(routes: [
            // Trickled, so there is still something to stop by the time we ask.
            "/file": .resumableFile(named: "paused.bin", bytes: size, gap: 0.1),
        ])
        defer { server.stop() }

        let m = model(savingInto: folder)
        try navigate(m, to: "http://127.0.0.1:\(server.port)/file")
        #expect(await eventually { (m.downloads.first?.receivedBytes ?? 0) > 128 * 1024 })

        let id = try #require(m.downloads.first?.id)
        m.cancelDownload(id)
        #expect(m.downloads.first?.state == .cancelled)
        #expect(await eventually { m.downloads.first?.resumable == true })

        m.resumeDownload(id)

        #expect(await eventually { m.downloads.first?.state == .completed })
        #expect(m.downloads.count == 1, "a fresh id would put a second row over one file")
        #expect(try isWhole(folder.appendingPathComponent("paused.bin"), size))
    }

    /// The `false` half of the promise. Measured: with no `Accept-Ranges` and no
    /// validator, WebKit hands back `nil` — so this row must offer Try Again and
    /// not a Resume that would spend nothing.
    @Test("a server that cannot be resumed from never offers it")
    func aServerThatCannotBeResumedFromNeverOffersIt() async throws {
        let folder = try scratch("noresume")
        let server = try await TinyHTTPServer(routes: [
            "/file": .unresumableFile(named: "plain.bin", bytes: 2 * 1024 * 1024, sendOnly: 300 * 1024),
        ])
        defer { server.stop() }

        let m = model(savingInto: folder)
        try navigate(m, to: "http://127.0.0.1:\(server.port)/file")

        #expect(await eventually { m.downloads.first?.state == .failed })
        // Given a moment to arrive and still absent, rather than read the instant
        // the failure lands: the report comes after the state it is about.
        #expect(await eventually(timeout: .seconds(1)) { m.downloads.first?.resumable == true } == false)

        let id = try #require(m.downloads.first?.id)
        m.resumeDownload(id)
        #expect(m.downloads.first?.state == .failed, "nothing was asked of the engine")
    }

    /// ADR-0091 replaced the engine's two dead download rows with ours. This is
    /// what says the replacements reach a file, which the rule tests never did.
    @Test("a save row in the context menu lands a file")
    func aSaveRowInTheContextMenuLandsAFile() async throws {
        let folder = try scratch("menu")
        let body = Data(repeating: 0x5A, count: 64 * 1024)
        let server = try await TinyHTTPServer(routes: [
            "/page": .html("<a href='/file'>x</a>"),
            "/file": .attachment(named: "from-the-menu.bin", body: body),
        ])
        defer { server.stop() }

        let m = model(savingInto: folder)
        let tab = try #require(m.snapshot.activeTab)
        try navigate(m, to: "http://127.0.0.1:\(server.port)/page")
        #expect(await eventually { m.engine.webView(for: tab)?.url != nil })

        // What `PageView` sends when the row is chosen. The rows themselves are
        // the core's answer for the target, which `PageMenuTests` holds.
        m.send(.chosePageMenuItem(
            tab: tab,
            item: .saveLinkedFile,
            target: PageTarget(
                linkUrl: "http://127.0.0.1:\(server.port)/file",
                imageUrl: nil,
                selection: nil,
                canGoBack: false,
                canGoForward: false
            )
        ))

        #expect(await eventually { m.downloads.first?.state == .completed })
        #expect(m.downloads.first?.filename == "from-the-menu.bin")
        #expect(
            try Data(contentsOf: folder.appendingPathComponent("from-the-menu.bin")) == body
        )
    }
}

// MARK: - A server, small enough to read

/// What one route answers with: a raw HTTP head, then a body in one or more
/// pieces.
///
/// Pieces exist for one reason. Over loopback a whole response is handed to the
/// kernel in a single write, so a "big" download finishes before a test can
/// react to it — and a cancel test that cancels something already finished
/// proves nothing. `gap` is what makes a transfer last long enough to stop.
struct TinyResponse: Sendable {
    let head: Data
    let chunks: [Data]
    let gap: Double
    /// The whole file this route serves, when it is one that answers a `Range`
    /// request.
    ///
    /// Kept separately from `chunks` because the two differ in exactly the case
    /// worth testing: a route that declares a length and then gives up partway
    /// sends less than the file it is claiming to send. Only a route that says
    /// `Accept-Ranges` in its headers carries one — a server that ignores a
    /// range and starts again from byte zero is how a "resumed" download
    /// silently corrupts the file it is appending to.
    var whole: Data?

    init(head: Data, chunks: [Data], gap: Double, whole: Data? = nil) {
        self.head = head
        self.chunks = chunks
        self.gap = gap
        self.whole = whole
    }

    static func attachment(named filename: String, body: Data) -> TinyResponse {
        TinyResponse(
            head: head(
                [
                    "Content-Type: application/octet-stream",
                    "Content-Length: \(body.count)",
                    "Content-Disposition: attachment; filename=\"\(filename)\"",
                    "Connection: close",
                ]),
            chunks: [body],
            gap: 0
        )
    }

    /// Declares its length and then takes its time about it.
    static func slowAttachment(
        named filename: String,
        pieces: Int,
        pieceSize: Int,
        gap: Double
    ) -> TinyResponse {
        TinyResponse(
            head: head(
                [
                    "Content-Type: application/octet-stream",
                    "Content-Length: \(pieces * pieceSize)",
                    "Content-Disposition: attachment; filename=\"\(filename)\"",
                    "Connection: close",
                ]),
            chunks: Array(repeating: Data(repeating: 0x7A, count: pieceSize), count: pieces),
            gap: gap
        )
    }

    /// No `Content-Length`, so the body ends when the connection does and
    /// `expectedContentLength` comes through as -1.
    static func attachmentWithoutLength(named filename: String, body: Data) -> TinyResponse {
        TinyResponse(
            head: head(
                [
                    "Content-Type: application/octet-stream",
                    "Content-Disposition: attachment; filename=\"\(filename)\"",
                    "Connection: close",
                ]),
            chunks: [body],
            gap: 0
        )
    }

    /// The size of one write. Small enough that a transfer lasts long enough to
    /// be stopped, big enough that a megabyte does not take a thousand of them.
    static let piece = 64 * 1024

    /// Everything a server has to say before WebKit will hand back resume data:
    /// a length, a validator, and a promise that it will honour a byte range.
    ///
    /// `sendOnly` is the flaky connection: the head still declares the whole
    /// length, the body stops short, and the connection closes — which is what
    /// arrives as `NSURLErrorNetworkConnectionLost`. Measured on a real
    /// `WKWebView`: this shape hands back 6,421 bytes of resume data, and the
    /// same shape with the two validators removed hands back `nil`.
    static func resumableFile(
        named filename: String,
        bytes: Int,
        sendOnly: Int? = nil,
        gap: Double = 0
    ) -> TinyResponse {
        let whole = Data(repeating: 0x7A, count: bytes)
        return TinyResponse(
            head: head([
                "Content-Type: application/octet-stream",
                "Content-Length: \(bytes)",
                "Content-Disposition: attachment; filename=\"\(filename)\"",
                "Accept-Ranges: bytes",
                "ETag: \"zer0-\(bytes)\"",
                "Last-Modified: Wed, 21 Oct 2026 07:28:00 GMT",
                "Connection: close",
            ]),
            chunks: pieces(of: whole.prefix(sendOnly ?? bytes)),
            gap: gap,
            whole: whole
        )
    }

    /// The same shape with nothing a resume could be built on. Declares a
    /// length, gives up partway, and offers neither a validator nor a range.
    static func unresumableFile(named filename: String, bytes: Int, sendOnly: Int) -> TinyResponse {
        TinyResponse(
            head: head([
                "Content-Type: application/octet-stream",
                "Content-Length: \(bytes)",
                "Content-Disposition: attachment; filename=\"\(filename)\"",
                "Connection: close",
            ]),
            chunks: pieces(of: Data(repeating: 0x7A, count: sendOnly)),
            gap: 0
        )
    }

    private static func pieces(of body: some DataProtocol) -> [Data] {
        stride(from: 0, to: body.count, by: piece).map {
            Data(body.dropFirst($0).prefix(piece))
        }
    }

    /// The same file from `offset` on, answered as `206 Partial Content`.
    func ranged(from offset: Int) -> TinyResponse {
        guard let whole, offset > 0, offset < whole.count else { return self }
        return TinyResponse(
            head: TinyResponse.head(
                [
                    "Content-Type: application/octet-stream",
                    "Content-Length: \(whole.count - offset)",
                    "Content-Range: bytes \(offset)-\(whole.count - 1)/\(whole.count)",
                    "Accept-Ranges: bytes",
                    "ETag: \"zer0-\(whole.count)\"",
                    "Last-Modified: Wed, 21 Oct 2026 07:28:00 GMT",
                    "Connection: close",
                ],
                status: "206 Partial Content"
            ),
            chunks: TinyResponse.pieces(of: whole.dropFirst(offset)),
            gap: gap,
            whole: whole
        )
    }

    static let notFound = TinyResponse(
        head: head(["Content-Length: 0", "Connection: close"], status: "404 Not Found"),
        chunks: [],
        gap: 0
    )

    static func head(_ headers: [String], status: String = "200 OK") -> Data {
        Data("HTTP/1.1 \(status)\r\n\(headers.joined(separator: "\r\n"))\r\n\r\n".utf8)
    }
}

/// Serves a fixed table of responses on a port the system picks.
///
/// A `file://` URL would be simpler and would not exercise any of this: there
/// is no `Content-Disposition` on a file, so the hostile-filename case — the
/// one worth testing end to end — cannot happen over one.
final class TinyHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    let port: UInt16

    init(routes: [String: TinyResponse]) async throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters, on: .any)

        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                let response = (routes[path] ?? .notFound).ranged(from: Self.rangeStart(in: request))
                connection.send(content: response.head, completion: .contentProcessed { _ in
                    Self.send(response.chunks[...], of: response, over: connection)
                })
            }
        }

        let ready = AsyncStream<Void>.makeStream()
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.continuation.finish() }
        }
        listener.start(queue: .global())
        for await _ in ready.stream {}

        guard let assigned = listener.port?.rawValue else {
            listener.cancel()
            throw TinyServerError.noPort
        }
        port = assigned
    }

    /// The first byte a `Range: bytes=N-` header asks for, or 0.
    private static func rangeStart(in request: String) -> Int {
        guard let line = request
            .split(separator: "\r\n")
            .first(where: { $0.lowercased().hasPrefix("range:") }),
            let equals = line.firstIndex(of: "="),
            let dash = line[equals...].firstIndex(of: "-")
        else { return 0 }
        return Int(line[line.index(after: equals)..<dash]) ?? 0
    }

    /// One piece at a time, waiting `gap` between them. Closing at the end is
    /// what terminates a body with no declared length.
    private static func send(
        _ remaining: ArraySlice<Data>,
        of response: TinyResponse,
        over connection: NWConnection
    ) {
        guard let piece = remaining.first else {
            connection.cancel()
            return
        }
        connection.send(content: piece, completion: .contentProcessed { _ in
            let rest = remaining.dropFirst()
            guard response.gap > 0, !rest.isEmpty else {
                send(rest, of: response, over: connection)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + response.gap) {
                send(rest, of: response, over: connection)
            }
        })
    }

    func stop() {
        listener.cancel()
    }
}

enum TinyServerError: Error {
    case noPort
}
