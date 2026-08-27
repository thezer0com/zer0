#if canImport(AppKit)
import AppKit
import Foundation
import Network
import Testing
import WebKit
import Zer0Core

@testable import Zer0Shell

/// Copying an image, all the way through (ADR-0091's revisit, issue #124).
///
/// A real HTTP server that refuses the request without the cookie, a real
/// `WKWebsiteDataStore` holding one, and a real pasteboard at the end: the
/// row's whole promise is that the bytes are the ones that space can see, and
/// that is a claim about plumbing, which is not checkable without the
/// plumbing in the room.
@MainActor
struct ImageCopyTests {
    /// A clipboard of our own. A test that wrote to the person's would be a
    /// test that vandalised the machine it ran on.
    private func board() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("zer0-image-copy-\(UUID().uuidString)"))
    }

    private func view(holding cookie: HTTPCookie?) async -> PageView {
        let store = WKWebsiteDataStore.nonPersistent()
        if let cookie {
            // The completion is waited for, not decoration: `setCookie` has an
            // optional handler, so the plain call is fire-and-forget and the
            // copy's own read of the jar can beat it — the fetch then goes out
            // anonymous, the server answers 401, and the test fails for a
            // reason that is the test's.
            await withCheckedContinuation { continuation in
                store.httpCookieStore.setCookie(cookie) { continuation.resume() }
            }
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        return PageView(frame: .zero, configuration: configuration)
    }

    private func sessionCookie() -> HTTPCookie {
        HTTPCookie(properties: [
            .name: "session",
            .value: "zer0",
            .domain: "127.0.0.1",
            .path: "/",
        ])!
    }

    /// A 4×4 PNG, built rather than embedded: the bytes have to decode on the
    /// other side, and a fixture nobody can read is a fixture that tests
    /// nothing about reading.
    private func png() throws -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 4,
            pixelsHigh: 4,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        for x in 0 ..< 4 {
            for y in 0 ..< 4 {
                rep.setColor(
                    NSColor(calibratedRed: Double(x) / 4, green: Double(y) / 4, blue: 0.5, alpha: 1),
                    atX: x, y: y
                )
            }
        }
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    @Test("an image behind a login is copied through the space's jar")
    func anAuthenticatedImageLands() async throws {
        let image = try png()
        let server = try await CookieGateServer(cookie: "session=zer0", body: image)
        defer { server.stop() }

        let board = board()
        // The view is held for as long as the copy is in flight. An ephemeral
        // store's backing dies with the last web view using it, and a copy
        // whose view went away fetches anonymous — exactly what would happen
        // in the browser if the tab closed, which is the fail-closed path.
        let view = await view(holding: sessionCookie())
        ImageCopy(pasteboard: board).copy(
            url: "http://127.0.0.1:\(server.port)/img.png",
            from: view
        ) { _ in }

        #expect(await eventually { board.data(forType: .png) != nil })
        let landed = try #require(board.data(forType: .png))
        #expect(NSBitmapImageRep(data: landed)?.pixelsWide == 4)
        #expect(board.data(forType: .tiff) != nil)
        _ = view
    }

    /// The whole reason the fetch names a tab: the same request without the
    /// jar's cookie is refused by the server, and nothing lands — no sign-in
    /// page's bytes where the picture was going.
    @Test("the same image without the cookie puts nothing on the pasteboard")
    func anUnauthenticatedCopyLandsNothing() async throws {
        let server = try await CookieGateServer(cookie: "session=zer0", body: try png())
        defer { server.stop() }

        let board = board()
        ImageCopy(pasteboard: board).copy(
            url: "http://127.0.0.1:\(server.port)/img.png",
            from: await view(holding: nil)
        ) { _ in }

        try await Task.sleep(for: .milliseconds(500))
        #expect(board.data(forType: .png) == nil)
        #expect(board.data(forType: .tiff) == nil)
        #expect(board.changeCount == 0)
    }

    @Test("a body that is not an image puts nothing on the pasteboard")
    func aLoginPageIsNotAPicture() async throws {
        let server = try await CookieGateServer(
            cookie: "session=zer0",
            body: Data("<html>sign in</html>".utf8),
            contentType: "text/html"
        )
        defer { server.stop() }

        let board = board()
        ImageCopy(pasteboard: board).copy(
            url: "http://127.0.0.1:\(server.port)/img.png",
            from: await view(holding: sessionCookie())
        ) { _ in }

        try await Task.sleep(for: .milliseconds(500))
        #expect(board.data(forType: .png) == nil)
        #expect(board.changeCount == 0)
    }

    @Test("an image past the limit puts nothing on the pasteboard")
    func aBombIsRefused() async throws {
        let big = Data(repeating: 0x7A, count: 4096)
        let server = try await CookieGateServer(cookie: "session=zer0", body: big)
        defer { server.stop() }

        let board = board()
        ImageCopy(pasteboard: board, maxBytes: 1024).copy(
            url: "http://127.0.0.1:\(server.port)/img.png",
            from: await view(holding: sessionCookie())
        ) { _ in }

        try await Task.sleep(for: .milliseconds(500))
        #expect(board.data(forType: .png) == nil)
        #expect(board.changeCount == 0)
    }

    @Test("a data address is copied without a server")
    func aDataAddressLands() async throws {
        let encoded = try png().base64EncodedString()
        let board = board()
        ImageCopy(pasteboard: board).copy(
            url: "data:image/png;base64,\(encoded)",
            from: await view(holding: nil)
        ) { _ in }

        #expect(await eventually { board.data(forType: .png) != nil })
        #expect(NSBitmapImageRep(data: try #require(board.data(forType: .png)))?.pixelsWide == 4)
    }

    @Test("a percent-encoded data address preserves binary image bytes")
    func aPercentEncodedBinaryDataAddressLands() async throws {
        let payload = try png().map { String(format: "%%%02X", $0) }.joined()
        let board = board()
        ImageCopy(pasteboard: board).copy(
            url: "data:image/png,\(payload)",
            from: await view(holding: nil)
        ) { _ in }

        #expect(await eventually { board.data(forType: .png) != nil })
        #expect(NSBitmapImageRep(data: try #require(board.data(forType: .png)))?.pixelsWide == 4)
    }

    @Test("both image formats are published as one pasteboard item")
    func onePasteboardItemCarriesBothFormats() async throws {
        let encoded = try png().base64EncodedString()
        let board = board()
        ImageCopy(pasteboard: board).copy(
            url: "data:image/png;base64,\(encoded)",
            from: await view(holding: nil)
        ) { _ in }

        #expect(await eventually { board.data(forType: .png) != nil })
        let items = try #require(board.pasteboardItems)
        #expect(items.count == 1)
        let item = try #require(items.first)
        #expect(item.data(forType: .png) != nil)
        #expect(item.data(forType: .tiff) != nil)
    }

    @Test("cancelling a copy publishes neither bytes nor an outcome")
    func cancellationIsSilent() async throws {
        let server = try await CookieGateServer(
            cookie: nil,
            body: try png(),
            responseDelay: .milliseconds(500)
        )
        defer { server.stop() }

        let board = board()
        var reported: ImageCopy.Outcome?
        let job = ImageCopy(pasteboard: board).copy(
            url: "http://127.0.0.1:\(server.port)/img.png",
            from: await view(holding: nil)
        ) { reported = $0 }
        job.cancel()

        try await Task.sleep(for: .seconds(1))
        #expect(reported == nil)
        #expect(board.changeCount == 0)
    }

    @Test("destroying a tab cancels its copy")
    func tabDestructionCancelsPublication() async throws {
        let delayed = try await CookieGateServer(
            cookie: nil,
            body: try png(),
            responseDelay: .milliseconds(500)
        )
        defer { delayed.stop() }

        let board = board()
        let copy = ImageCopy(pasteboard: board)
        let host = EngineHost(imageCopy: copy)
        let tab = TabId(91)
        let window = WindowId(17)
        var reports: [(WindowId, ImageCopy.Outcome)] = []
        host.imageCopyWindow = { $0 == tab ? window : nil }
        host.imageCopyReported = { reports.append(($0, $1)) }
        host.perform([.createWebView(
            tab: tab,
            configuration: .space(
                dataStoreId: UUID().uuidString,
                profile: SpaceProfile(userAgent: nil, ephemeral: true)
            ),
            navigationState: nil
        )])

        host.perform([.copyImage(
            tab: tab,
            url: "http://127.0.0.1:\(delayed.port)/old.png"
        )])
        host.perform([.destroyWebView(tab: tab)])

        try await Task.sleep(for: .seconds(1))
        #expect(reports.isEmpty)
        #expect(board.changeCount == 0)
    }

    @Test("a newer copy is the only one published")
    func aNewerCopySupersedesAnOlderOne() async throws {
        let delayed = try await CookieGateServer(
            cookie: nil,
            body: try png(),
            responseDelay: .milliseconds(500)
        )
        defer { delayed.stop() }

        let board = board()
        let host = EngineHost(imageCopy: ImageCopy(pasteboard: board))
        let tab = TabId(93)
        let window = WindowId(19)
        var reports: [ImageCopy.Outcome] = []
        host.imageCopyWindow = { $0 == tab ? window : nil }
        host.imageCopyReported = { _, outcome in reports.append(outcome) }
        host.perform([.createWebView(
            tab: tab,
            configuration: .space(
                dataStoreId: UUID().uuidString,
                profile: SpaceProfile(userAgent: nil, ephemeral: true)
            ),
            navigationState: nil
        )])

        host.perform([.copyImage(
            tab: tab,
            url: "http://127.0.0.1:\(delayed.port)/old.png"
        )])
        host.perform([.copyImage(
            tab: tab,
            url: "data:image/png;base64,\(try png().base64EncodedString())"
        )])

        #expect(await eventually { reports == [.copied] })
        try await Task.sleep(for: .seconds(1))
        #expect(reports == [.copied])
        #expect(board.data(forType: .png) != nil)
    }

    @Test("an invalid address is reported through the host")
    func anInvalidAddressIsReportedThroughTheHost() async {
        let board = board()
        let host = EngineHost(imageCopy: ImageCopy(pasteboard: board))
        let tab = TabId(92)
        let window = WindowId(18)
        var reported: ImageCopy.Outcome?
        host.imageCopyWindow = { $0 == tab ? window : nil }
        host.imageCopyReported = { _, outcome in reported = outcome }
        host.perform([.createWebView(
            tab: tab,
            configuration: .space(
                dataStoreId: UUID().uuidString,
                profile: SpaceProfile(userAgent: nil, ephemeral: true)
            ),
            navigationState: nil
        )])

        host.perform([.copyImage(tab: tab, url: "http://exa%zzmple.com/image.png")])

        #expect(await eventually { reported != nil })
        #expect(reported == .failed(.invalidAddress))
        #expect(board.changeCount == 0)
    }

    // MARK: - What a copy says back

    /// The row promised something, so the answer has to arrive — and say the
    /// one thing that is true. Held here against success rather than failure
    /// because a `.copied` is the claim the notice will draw, and a claim
    /// nobody locks drifts into "the fetch started".
    @Test("a copy that lands says so, after the clipboard took the bytes")
    func aCopyThatLandsSaysSo() async throws {
        let server = try await CookieGateServer(cookie: "session=zer0", body: try png())
        defer { server.stop() }

        let board = board()
        // Held for as long as the copy is in flight, for the reason the
        // authenticated test above holds its own: an ephemeral store's
        // backing dies with the last web view using it.
        let view = await view(holding: sessionCookie())
        var reported: ImageCopy.Outcome?
        ImageCopy(pasteboard: board).copy(
            url: "http://127.0.0.1:\(server.port)/img.png",
            from: view
        ) { reported = $0 }

        #expect(await eventually { reported != nil })
        #expect(reported == .copied)
        // The claim and the bytes are the same fact, not two: success said
        // with nothing on the pasteboard would be the one promise this class
        // exists to keep, broken.
        #expect(board.data(forType: .png) != nil)
        _ = view
    }

    /// Every way a copy refuses, and the one category each earns. The
    /// categories are the whole point — the interface may say what kind of
    /// thing went wrong and never what a server or a socket said on the way
    /// through.
    @Test("a copy that cannot land names its reason")
    func aRefusalNamesItsReason() async throws {
        let refused = try await CookieGateServer(cookie: "session=zer0", body: try png())
        defer { refused.stop() }
        let big = Data(repeating: 0x7A, count: 4096)
        let bomb = try await CookieGateServer(cookie: "session=zer0", body: big)
        defer { bomb.stop() }

        func outcome(
            url: String, maxBytes: Int = 32 * 1024 * 1024, cookie: HTTPCookie? = nil
        ) async throws -> ImageCopy.Outcome {
            // Held for as long as the copy is in flight, for the reason the
            // authenticated test above holds its own: an ephemeral store's
            // backing dies with the last web view using it.
            let view = await view(holding: cookie)
            var reported: ImageCopy.Outcome?
            ImageCopy(pasteboard: board(), maxBytes: maxBytes).copy(
                url: url,
                from: view
            ) { reported = $0 }
            // The refusal paths have no work left to wait out, but the answer
            // still crosses an actor, so it is waited for rather than assumed
            // instant.
            #expect(await eventually { reported != nil })
            return try #require(reported)
        }

        // Without the cookie the server answers 401, and a body nobody can
        // use is not an image whatever the menu said.
        #expect(try await outcome(url: "http://127.0.0.1:\(refused.port)/img.png")
            == .failed(.notAnImage))
        // With it, the same server's honest length is past the ceiling and
        // the refusal comes before a byte of body is read.
        #expect(try await outcome(
            url: "http://127.0.0.1:\(bomb.port)/img.png",
            maxBytes: 1024,
            cookie: sessionCookie()
        ) == .failed(.tooLarge))
        // An address that is not one — broken percent-encoding, which no
        // amount of encoding-invalid-characters repair can save — refused
        // out loud rather than guessed at.
        #expect(try await outcome(url: "http://exa%zzmple.com/img.png")
            == .failed(.invalidAddress))
    }

    /// Which cookies a request may carry is the whole promise of the
    /// authenticated copy, and the edge cases are rules rather than plumbing:
    /// a domain cookie serves the apex (`github.com`'s `.github.com` is the
    /// measured case that broke), a host-only cookie serves nothing else, and
    /// a path serves its tree and not a sibling that starts the same.
    @Test("a cookie serves exactly the hosts and paths it was promised")
    func cookieMatchingFollowsTheRules() {
        func cookie(domain: String, path: String = "/", secure: Bool = false) -> HTTPCookie {
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: "session",
                .value: "1",
                .domain: domain,
                .path: path,
            ]
            if secure { properties[.secure] = "TRUE" }
            return HTTPCookie(properties: properties)!
        }
        func url(_ string: String) -> URL {
            URL(string: string)!
        }

        // A domain cookie: the apex and every host beneath it.
        #expect(ImageCopy.serves(cookie(domain: ".example.com"), url("https://example.com/")))
        #expect(ImageCopy.serves(cookie(domain: ".example.com"), url("https://a.example.com/x")))
        #expect(!ImageCopy.serves(cookie(domain: ".example.com"), url("https://notexample.com/")))
        #expect(!ImageCopy.serves(cookie(domain: ".example.com"), url("https://example.org/")))

        // A host-only cookie: exactly that host, not its subdomains.
        #expect(ImageCopy.serves(cookie(domain: "example.com"), url("https://example.com/")))
        #expect(!ImageCopy.serves(cookie(domain: "example.com"), url("https://a.example.com/")))

        // A path: the tree under it, and nothing that merely starts the same.
        #expect(ImageCopy.serves(cookie(domain: ".example.com", path: "/images"), url("https://example.com/images")))
        #expect(ImageCopy.serves(cookie(domain: ".example.com", path: "/images"), url("https://example.com/images/a.png")))
        #expect(!ImageCopy.serves(cookie(domain: ".example.com", path: "/images"), url("https://example.com/images-old/a.png")))
        #expect(!ImageCopy.serves(cookie(domain: ".example.com", path: "/images"), url("https://example.com/img")))
        #expect(ImageCopy.serves(cookie(domain: ".example.com", path: "/images/"), url("https://example.com/images/a.png")))
        #expect(ImageCopy.serves(cookie(domain: ".example.com", path: "/images%2Fprivate"), url("https://example.com/images%2Fprivate/a.png")))
        #expect(!ImageCopy.serves(cookie(domain: ".example.com", path: "/images/private"), url("https://example.com/images%2Fprivate/a.png")))

        // A secure cookie stays on the secure scheme.
        #expect(ImageCopy.serves(cookie(domain: ".example.com", secure: true), url("https://example.com/")))
        #expect(!ImageCopy.serves(cookie(domain: ".example.com", secure: true), url("http://example.com/")))
    }

    @Test("redirects rebuild cookies for the redirected host scheme and path")
    func redirectsCannotCarryAnIneligibleCookie() throws {
        let cookie = try #require(HTTPCookie(properties: [
            .name: "session",
            .value: "secret",
            .domain: "example.com",
            .path: "/private/",
            .secure: "TRUE",
        ]))
        var request = URLRequest(url: try #require(URL(string: "https://example.com/private/image.png")))
        request.setValue("session=secret", forHTTPHeaderField: "Cookie")

        let otherHost = try #require(URL(string: "https://cdn.example/private/image.png"))
        #expect(ImageCopy.redirected(request, to: otherHost, cookies: [cookie])
            .value(forHTTPHeaderField: "Cookie") == nil)

        let otherScheme = try #require(URL(string: "http://example.com/private/image.png"))
        #expect(ImageCopy.redirected(request, to: otherScheme, cookies: [cookie])
            .value(forHTTPHeaderField: "Cookie") == nil)

        let otherPath = try #require(URL(string: "https://example.com/public/image.png"))
        #expect(ImageCopy.redirected(request, to: otherPath, cookies: [cookie])
            .value(forHTTPHeaderField: "Cookie") == nil)

        let eligible = try #require(URL(string: "https://example.com/private/next.png"))
        #expect(ImageCopy.redirected(request, to: eligible, cookies: [cookie])
            .value(forHTTPHeaderField: "Cookie") == "session=secret")
    }
}

/// Serves one body, but only to a request carrying the cookie; anything else
/// is a 401. `TinyHTTPServer` routes by path alone, and the thing under test
/// here is the request's headers — so this is its own server rather than a
/// widening of the one the download tests share.
private final class CookieGateServer: @unchecked Sendable {
    private let listener: NWListener
    let port: UInt16

    init(
        cookie: String?,
        body: Data,
        contentType: String = "image/png",
        responseDelay: Duration = .zero
    ) async throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters, on: .any)

        let ready = AsyncStream<Void>.makeStream()
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.continuation.finish() }
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let served = cookie.map { request.lowercased().contains("cookie: \($0)") } ?? true
                let response = served
                    ? Data(
                        "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                            .utf8) + body
                    : Data("HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                Task {
                    try? await Task.sleep(for: responseDelay)
                    connection.send(content: response, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                }
            }
        }
        listener.start(queue: .global())
        for await _ in ready.stream {}

        guard let assigned = listener.port?.rawValue else {
            listener.cancel()
            throw CocoaError(.fileNoSuchFile)
        }
        port = assigned
    }

    func stop() {
        listener.cancel()
    }
}
#endif
