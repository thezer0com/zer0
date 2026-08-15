import AppKit
import Foundation
import Zer0Core

/// Cached bytes, turned into something a row can draw.
///
/// Everything that decides anything about icons — which URL, whether a space
/// may ask for one, what a server is allowed to hand back, how long a site
/// with none is left alone — is in the core. This is the other half: decoding,
/// and not decoding the same picture forty times a frame.
@MainActor
final class SiteIcons {
    /// Reads the core's cache. A closure rather than a `Zer0` so a test can
    /// drive this with no browser behind it.
    private let bytes: (SpaceId, String) -> Data?

    /// Decoded once and kept for the run. An icon does not change while the
    /// app is open, and every sidebar row asks for its own on every redraw.
    private var drawn: [Key: NSImage] = [:]

    /// Sites the core had nothing for, and the revision we asked at.
    ///
    /// Without this, a list of forty rows with no icons is forty trips across
    /// the FFI per frame. With it, they are forty dictionary lookups, and the
    /// question is only re-asked when the core says something changed — which
    /// is what makes a row that was a letter become a picture the moment the
    /// bytes land, and not before.
    private var absent: [Key: UInt64] = [:]

    init(bytes: @escaping (SpaceId, String) -> Data?) {
        self.bytes = bytes
    }

    private struct Key: Hashable {
        let space: SpaceId
        let host: String
    }

    /// This site's icon in this space, or `nil` for a row that should draw its
    /// letter.
    ///
    /// `nil` covers never asked, asked and refused, and given something that
    /// would not decode. The badge draws the same thing for all three, which
    /// is the point: the fallback is what shows while a real icon is still on
    /// its way, so a row never flashes empty.
    func image(space: SpaceId, host: String?, revision: UInt64) -> NSImage? {
        guard let host, !host.isEmpty else { return nil }
        let key = Key(space: space, host: host.lowercased())

        if let hit = drawn[key] { return hit }
        if absent[key] == revision { return nil }

        // A file that came off the network and then off the disk gets one more
        // chance to be nothing: `NSImage` will happily return an object with no
        // size for bytes it could not make sense of, and drawing that is a
        // blank square where the letter used to be.
        guard let data = bytes(key.space, key.host),
              let image = NSImage(data: data),
              image.size.width > 0, image.size.height > 0
        else {
            absent[key] = revision
            return nil
        }

        drawn[key] = image
        return image
    }
}

/// Going and getting one, anonymously.
///
/// Not through the tab's web view, and that is the decision rather than a
/// shortcut. An icon fetched through a space's cookie jar is a request the site
/// can attribute to whoever is signed in there, and it would be the browser
/// adding a correlation the page load did not already give away. A request
/// carrying no cookie, no credential and no cache entry says strictly less.
///
/// Per-space isolation is kept where it belongs instead: the *cache* is keyed
/// by cookie jar in the core, so a second space still makes its own request
/// rather than being served from the first one's answer.
@MainActor
final class IconFetcher {
    var emit: (@MainActor (Action) -> Void)?

    /// Everything about this configuration is a refusal to carry something.
    ///
    /// `.ephemeral` keeps cookies and cache in memory; the rest takes them
    /// away entirely, so a favicon request cannot pick up an identity on the
    /// way out or leave one behind.
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // Ten seconds is longer than any icon worth having takes, and short
        // enough that a site that hangs does not hold a row on a letter for a
        // minute before giving up.
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 2
        config.httpAdditionalHeaders = ["Accept": "image/*"]
        return URLSession(configuration: config)
    }()

    /// Carry out one `FetchIcon`.
    ///
    /// Always answers, with bytes or with a failure. A request that quietly
    /// went nowhere would leave the core believing one is still in flight, and
    /// that site would never be asked again for the rest of the run.
    func fetch(dataStoreId: String, host: String, url: String, maxBytes: UInt32) {
        Task { [weak self] in
            guard let session = self?.session else { return }
            let data = await Self.load(url, maxBytes: maxBytes, using: session)
            guard let self else { return }

            emit?(data.map {
                .iconFetched(dataStoreId: dataStoreId, host: host, bytes: $0)
            } ?? .iconFetchFailed(dataStoreId: dataStoreId, host: host))
        }
    }

    /// `nonisolated` so the transfer and the byte counting happen off the main
    /// actor. A hundred kilobytes counted on the main thread is a hundred
    /// kilobytes of scrolling nobody gets back.
    private nonisolated static func load(
        _ url: String,
        maxBytes: UInt32,
        using session: URLSession
    ) async -> Data? {
        guard let target = URL(string: url) else { return nil }

        var request = URLRequest(url: target)
        request.httpShouldHandleCookies = false
        // Neither the page that declared this icon nor the fact that it was a
        // page at all is the server's business.
        request.setValue(nil, forHTTPHeaderField: "Referer")

        do {
            let (stream, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode)
            else { return nil }
            // The cheap refusal, before a byte of body is read. A server that
            // lies about the length is caught by the loop below.
            if http.expectedContentLength > Int64(maxBytes) { return nil }

            var data = Data()
            data.reserveCapacity(min(Int(maxBytes), 64 * 1024))
            for try await byte in stream {
                data.append(byte)
                // Abandoning the stream cancels the transfer, so a site
                // serving four megabytes for its favicon costs us the limit
                // and not the four megabytes.
                if data.count > Int(maxBytes) { return nil }
            }
            return data
        } catch {
            // Offline, DNS, TLS, timeout, a cancelled read. The core files
            // every one of them the same way, because the row does: it keeps
            // its letter.
            return nil
        }
    }
}
