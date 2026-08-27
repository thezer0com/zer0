#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import Foundation
import WebKit

/// Copying an image, through the space's cookie jar (ADR-0091's revisit).
///
/// The fetch is ADR-0027's machinery pointed somewhere new: it goes out over
/// the tab's own data store — the same jar a download rides — but the
/// destination is the pasteboard rather than the disk. `IconFetcher` is not
/// this and must not become it: an icon is fetched anonymously on purpose,
/// and an image a person asked to copy is fetched as that person.
///
/// Both hosts, one pipeline. The fetch, the limits and the decode are the
/// same work on both platforms, and only the clipboard is the platform's —
/// `NSPasteboard` with TIFF and PNG on the Mac, `UIPasteboard` with a
/// `UIImage` on the phone — so the platform's types stop at their own `#if`
/// and the shared shell set compiles this unchanged (ADR-0123).
@MainActor
final class ImageCopy {
    /// What one copy came to. Closed on purpose: two things can be true (the
    /// bytes are on the clipboard, or they are not), and the reason a copy
    /// did not land is a category a person can read — never the error a
    /// socket or a server handed over, which is ADR-0018's rule pointed at
    /// a failure nobody could otherwise name.
    enum Outcome: Equatable, Sendable {
        /// The decoded bytes are on the clipboard. Claimed only after the
        /// write answered, so a success said before the pasteboard took the
        /// bytes is a promise the next paste breaks.
        case copied
        case failed(Failure)
    }

    /// Why a copy did not happen, in categories safe to draw as a sentence.
    enum Failure: Error, Equatable, Sendable {
        /// The address the menu named is not one. Refused rather than
        /// repaired: a guess at what was meant is a bug with a delay on it.
        case invalidAddress
        /// The tab that asked is gone, so there is no jar to fetch through —
        /// any other tab's jar would fetch as somebody else (ADR-0027's
        /// reason, one door along).
        case noTabPage
        /// What came back was not a picture — a sign-in page, a refusal, or
        /// bytes that will not decode into one.
        case notAnImage
        /// Past a ceiling: bytes on the wire, or pixels once decoded.
        /// Nothing a person copies is worth unbounded memory for.
        case tooLarge
        /// The transfer itself failed — offline, refused, timed out. No
        /// distinction between them is claimed, because none is known.
        case unreachable
        /// The clipboard refused the bytes. Rare, and the one failure with
        /// something to do about it: another app may be holding it.
        case clipboard
    }

    /// Where the bytes land. A parameter rather than `.general` baked in, so
    /// a test can catch what a person's clipboard would have.
    ///
    /// Nothing a person copies is worth unbounded memory for. `maxBytes` is a
    /// parameter for the same reason the pasteboard is.
    #if canImport(AppKit)
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general, maxBytes: Int = 32 * 1024 * 1024) {
        self.pasteboard = pasteboard
        self.maxBytes = maxBytes
    }
    #else
    private let pasteboard: UIPasteboard

    init(pasteboard: UIPasteboard = .general, maxBytes: Int = 32 * 1024 * 1024) {
        self.pasteboard = pasteboard
        self.maxBytes = maxBytes
    }
    #endif

    private let maxBytes: Int

    /// A compressed image can still be a wall of pixels; decoding one that
    /// large costs more than any copy was worth.
    private nonisolated static let maxPixels: Int64 = 80_000_000

    /// Carries out one `CopyImage`, and says what it came to.
    ///
    /// The report is the shape the method exists in: a row that says "Copy
    /// Image" and then fails used to leave silence, and silence after a
    /// promise is the one feedback failure worth naming. It arrives exactly
    /// once, on the main actor, after the clipboard write has answered — so
    /// a `.copied` is a fact rather than a hope.
    @discardableResult
    func copy(
        url: String,
        from view: PageView,
        report: @escaping @MainActor (Outcome) -> Void
    ) -> Task<Void, Never> {
        guard let target = URL(string: url) else {
            return Task {
                guard !Task.isCancelled else { return }
                report(.failed(.invalidAddress))
            }
        }
        // The jar is taken off the view the command named, for the same
        // reason a download starts from a tab: only that view's configuration
        // carries the space's cookies.
        let jar = view.configuration.websiteDataStore.httpCookieStore

        return Task {
            let cookies = await Self.cookies(in: jar)
            guard !Task.isCancelled else { return }
            switch await Self.load(
                target,
                cookies: cookies,
                maxBytes: maxBytes,
                using: session
            ) {
            case let .success(decoded):
                guard !Task.isCancelled else { return }
                report(place(decoded, on: pasteboard))
            case let .failure(failure):
                guard !Task.isCancelled else { return }
                report(.failed(failure))
            }
        }
    }

    /// Everything about this configuration is a refusal to carry an identity
    /// of its own: the cookie the jar named goes on the request and nothing
    /// else does, so the fetch cannot pick up or leave a second identity.
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = ["Accept": "image/*"]
        return URLSession(configuration: config)
    }()

    /// The cookies the jar holds for this address, folded into the one header
    /// a request carries.
    ///
    /// `withCheckedContinuation` rather than an `await` on the method itself:
    /// this SDK imports `getAllCookies` with an optional completion handler,
    /// so the plain call is the fire-and-forget one and returns `Void` — there
    /// is no async variant to reach for.
    private static func cookies(in jar: WKHTTPCookieStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            jar.getAllCookies { continuation.resume(returning: $0) }
        }
    }

    private nonisolated static func cookieHeader(
        from cookies: [HTTPCookie],
        for url: URL
    ) -> String? {
        let matching = cookies.filter { Self.serves($0, url) }
        guard !matching.isEmpty else { return nil }
        return HTTPCookie.requestHeaderFields(with: matching)["Cookie"]
    }

    /// Rebuild a redirected request's cookie header for its new address.
    /// `URLSession` otherwise carries the manually supplied header across the
    /// redirect even though its own cookie handling is disabled.
    nonisolated static func redirected(
        _ request: URLRequest,
        to target: URL,
        cookies: [HTTPCookie]
    ) -> URLRequest {
        var redirected = request
        redirected.url = target
        redirected.setValue(cookieHeader(from: cookies, for: target), forHTTPHeaderField: "Cookie")
        return redirected
    }

    /// `HTTPCookie` exposes no matching of its own, so the rules a cookie
    /// carries are applied here (RFC 6265): a domain cookie — leading dot —
    /// serves the apex and every host beneath it; a cookie stored without one
    /// is host-only and serves exactly that host. A path serves the whole tree
    /// under it and nothing that merely starts with the same letters, which is
    /// the difference between `/images` and `/images-old`.
    ///
    /// Internal rather than private so the tests can hold it to those rules
    /// directly: the authenticated-copy test proves the plumbing, not the
    /// edge cases, and a matcher nobody can call is a matcher nobody can
    /// check.
    nonisolated static func serves(_ cookie: HTTPCookie, _ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let domain = cookie.domain.lowercased()
        let onDomain: Bool
        if domain.hasPrefix(".") {
            let apex = domain.dropFirst()
            onDomain = host == apex || host.hasSuffix(".\(apex)")
        } else {
            onDomain = host == domain
        }
        let path = cookie.path.isEmpty ? "/" : cookie.path
        let requestPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath
            ?? "/"
        let underPath = Self.pathMatches(cookie: path, request: requestPath)
        let onScheme = !cookie.isSecure || url.scheme?.lowercased() == "https"
        return onDomain && underPath && onScheme
    }

    private nonisolated static func pathMatches(cookie: String, request: String) -> Bool {
        if cookie == request { return true }
        guard request.hasPrefix(cookie) else { return false }
        if cookie.hasSuffix("/") { return true }
        let boundary = request.index(request.startIndex, offsetBy: cookie.count)
        return boundary < request.endIndex && request[boundary] == "/"
    }

    /// `nonisolated` so the transfer, the byte counting and the decode happen
    /// off the main actor. The pasteboard is the only main-thread thing in
    /// this class, and it is touched by the caller.
    private nonisolated static func load(
        _ url: URL,
        cookies: [HTTPCookie],
        maxBytes: Int,
        using session: URLSession
    ) async -> Result<Decoded, Failure> {
        let fetched: Result<Data, Failure>
        if url.scheme?.lowercased() == "data" {
            fetched = inlineBytes(of: url, maxBytes: maxBytes)
        } else {
            fetched = await networkBytes(
                of: url,
                cookies: cookies,
                maxBytes: maxBytes,
                using: session
            )
        }
        switch fetched {
        case let .failure(failure):
            return .failure(failure)
        case let .success(bytes):
            return decode(bytes)
        }
    }

    private nonisolated static func networkBytes(
        of url: URL,
        cookies: [HTTPCookie],
        maxBytes: Int,
        using session: URLSession
    ) async -> Result<Data, Failure> {
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        if let cookieHeader = cookieHeader(from: cookies, for: url) {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }

        do {
            let delegate = RedirectDelegate(cookies: cookies)
            let (stream, response) = try await session.bytes(for: request, delegate: delegate)
            if let http = response as? HTTPURLResponse {
                // A body nobody can use — a sign-in page, a refusal — is not
                // an image, whatever the menu said.
                guard (200..<300).contains(http.statusCode) else { return .failure(.notAnImage) }
                // The cheap refusal, before a byte of body is read. A server
                // that lies about the length is caught by the loop below.
                if http.expectedContentLength > Int64(maxBytes) { return .failure(.tooLarge) }
            } else if url.scheme?.lowercased() != "file" {
                return .failure(.unreachable)
            }

            var body = Data()
            body.reserveCapacity(min(maxBytes, 64 * 1024))
            for try await byte in stream {
                body.append(byte)
                // Abandoning the stream cancels the transfer, so an image
                // past the limit costs us the limit and not the image.
                if body.count > maxBytes { return .failure(.tooLarge) }
            }
            return .success(body)
        } catch {
            // The transfer failed before any image was in hand. Which way it
            // failed is not known here, so it is not said.
            return .failure(.unreachable)
        }
    }

    /// `data:[<mediatype>][;base64],<bytes>` — the address is the whole
    /// transfer, so the limits apply to the address itself.
    private nonisolated static func inlineBytes(
        of url: URL,
        maxBytes: Int
    ) -> Result<Data, Failure> {
        let text = url.absoluteString
        guard let comma = text.firstIndex(of: ",") else { return .failure(.notAnImage) }
        let meta = String(text[text.index(text.startIndex, offsetBy: 5)..<comma])
        let payload = String(text[text.index(after: comma)...])

        // A structured media type that is not an image is refused; a bare
        // `data:,…` or `data:;base64,…` carries no type at all and gets the
        // benefit of the doubt, the way a browser treats it.
        guard meta.lowercased().hasPrefix("image/") || !meta.contains("/") else {
            return .failure(.notAnImage)
        }
        guard payload.utf8.count <= maxBytes else { return .failure(.tooLarge) }
        let bytes = meta.lowercased().contains("base64")
            ? Data(base64Encoded: payload)
            : percentDecoded(payload)
        guard let bytes else { return .failure(.notAnImage) }
        return .success(bytes)
    }

    private nonisolated static func percentDecoded(_ payload: String) -> Data? {
        let source = Array(payload.utf8)
        var decoded = Data()
        decoded.reserveCapacity(source.count)
        var index = 0
        while index < source.count {
            if source[index] == 0x25 {
                guard index + 2 < source.count,
                      let high = hex(source[index + 1]),
                      let low = hex(source[index + 2])
                else { return nil }
                decoded.append(high << 4 | low)
                index += 3
            } else {
                decoded.append(source[index])
                index += 1
            }
        }
        return decoded
    }

    private nonisolated static func hex(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30 ... 0x39: byte - 0x30
        case 0x41 ... 0x46: byte - 0x41 + 10
        case 0x61 ... 0x66: byte - 0x61 + 10
        default: nil
        }
    }

    // The platform's half: what a decode hands over, and how the clipboard
    // takes it. One `#if` each side of the pipeline, and nothing from either
    // SDK anywhere above it.

    #if canImport(AppKit)
    /// What a successful decode hands the pasteboard: both formats, because
    /// which one a destination reads is the destination's business.
    private typealias Decoded = (tiff: Data, png: Data)

    private nonisolated static func decode(_ data: Data) -> Result<Decoded, Failure> {
        guard let image = NSImage(data: data),
              image.size.width > 0, image.size.height > 0
        else { return .failure(.notAnImage) }

        let pixels = image.representations.reduce(Int64(0)) { total, rep in
            total + Int64(rep.pixelsWide) * Int64(rep.pixelsHigh)
        }
        guard pixels > 0, pixels <= maxPixels else { return .failure(.tooLarge) }

        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return .failure(.notAnImage) }
        return .success((tiff, png))
    }

    /// The write, after a decode that already answered — never before it, so
    /// the clipboard cannot be handed a sign-in page's bytes as a picture.
    /// Success is claimed only once the pasteboard has taken both types.
    private func place(_ decoded: Decoded, on pasteboard: NSPasteboard) -> Outcome {
        let item = NSPasteboardItem()
        guard item.setData(decoded.tiff, forType: .tiff),
              item.setData(decoded.png, forType: .png)
        else { return .failed(.clipboard) }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item]) ? .copied : .failed(.clipboard)
    }
    #else
    /// What a successful decode hands the pasteboard: PNG bytes. The
    /// `UIImage` is made on the main actor, where it is written — an image
    /// is not `Sendable`, and the decode stays off the actor while the
    /// object stays on it.
    private typealias Decoded = Data

    private nonisolated static func decode(_ data: Data) -> Result<Decoded, Failure> {
        guard let image = UIImage(data: data),
              image.size.width > 0, image.size.height > 0
        else { return .failure(.notAnImage) }
        guard let cg = image.cgImage else { return .failure(.notAnImage) }
        let pixels = Int64(cg.width) * Int64(cg.height)
        guard pixels > 0, pixels <= maxPixels else { return .failure(.tooLarge) }
        guard let png = image.pngData() else { return .failure(.notAnImage) }
        return .success(png)
    }

    /// The write, after a decode that already answered. `UIPasteboard`'s
    /// image setter returns nothing, so the setter returning *is* the write
    /// having happened — the honest limit of what this platform can be told,
    /// and why the Mac's half checks an answer instead of assuming one.
    private func place(_ png: Decoded, on pasteboard: UIPasteboard) -> Outcome {
        guard let image = UIImage(data: png) else { return .failed(.notAnImage) }
        pasteboard.image = image
        return .copied
    }
    #endif
}

private final class RedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let cookies: [HTTPCookie]

    init(cookies: [HTTPCookie]) {
        self.cookies = cookies
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard let target = request.url else { return nil }
        return ImageCopy.redirected(request, to: target, cookies: cookies)
    }
}
