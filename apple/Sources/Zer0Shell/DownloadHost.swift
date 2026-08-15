import AppKit
import Foundation
import WebKit
import Zer0Core

/// The `WKDownload` half of downloading.
///
/// This file knows about `WKDownloadDelegate`, `NSProgress` and
/// `NSFileWriteOutOfSpaceError`. It decides nothing: every fact it learns goes
/// in as an `Action`, and the destination — the one decision with a security
/// consequence — comes back out of the core as a command.
///
/// The order is worth stating, because the whole design hangs off it:
///
/// 1. WebKit hands over a `WKDownload`; it is adopted and given an id.
/// 2. WebKit asks where to put it. The handler is **held**, and the question
///    goes to the core as `DownloadStarted`.
/// 3. The core answers with `AcceptDownload`, `AskDownloadDestination` or
///    `CancelDownload`, and the held handler is what carries that out.
///
/// Holding the handler is what lets a save panel exist at all: the transfer
/// simply waits, and nothing is written until somebody has said where.
@MainActor
final class DownloadHost: NSObject, WKDownloadDelegate {
    /// One download in flight, from adoption to the last delegate callback.
    private final class Live {
        let id: String
        let download: WKDownload
        let tab: TabId?
        /// WebKit's "where do I write this" handler, held until the core says.
        var destination: (@MainActor (URL?) -> Void)?
        /// A save panel is up. Without this a download whose destination has
        /// not been answered yet is indistinguishable from one nobody replied
        /// to, and the second must be cancelled rather than left hanging.
        var awaitingPanel = false
        /// What was last reported, so the ticker only speaks when something
        /// moved.
        var reported: Int64 = -1

        init(id: String, download: WKDownload, tab: TabId?) {
            self.id = id
            self.download = download
            self.tab = tab
        }
    }

    private var byId: [String: Live] = [:]
    private var byDownload: [ObjectIdentifier: Live] = [:]

    /// What it would take to carry on, for downloads that stopped in this run.
    ///
    /// **In memory, and nowhere near the disk.** A resume blob names a partial
    /// file, a validator the server has to still agree with, and a byte offset;
    /// it is meaningless to another process and stale by tomorrow. Writing it
    /// down would buy a Resume button that fails on the one occasion somebody
    /// needs it, which ADR-0018 rates worse than no button. The core's record
    /// cannot carry it either — `StorableDownload` has no field for it — so
    /// this map is the only place it exists (ADR-0101).
    private var resumeData: [String: Data] = [:]
    /// Oldest first, so what goes over the bound below is the least likely to
    /// be pressed.
    private var resumeOrder: [String] = []

    /// How many stopped downloads keep their resume data.
    ///
    /// Measured at ~6.5 kB a blob, so this is not really about memory: it is
    /// about the map having a stated bound rather than growing with whatever
    /// somebody did today. What falls off the end is **said** — the core is told
    /// that row can no longer be carried on from — so no button outlives the
    /// thing it would spend.
    private static let maxResumable = 64

    /// Set by the engine host so facts travel back into the reducer.
    var emit: (@MainActor (Action) -> Void)?

    // Not observable state; only ever assigned on the main actor.
    private var ticker: Task<Void, Never>?

    deinit {
        ticker?.cancel()
    }

    // MARK: - Taking a download on

    /// Adopt a download WebKit has just created.
    func adopt(_ download: WKDownload, tab: TabId?) {
        adopt(download, as: UUID().uuidString, tab: tab)
    }

    /// The same, under an id that already means something.
    ///
    /// A resumed transfer keeps the id of the download it is carrying on, and
    /// that is not tidiness: the core kept the row, the partial file is on disk
    /// under that row's name, and a fresh id would put a second row over the
    /// same file with the first one's byte count frozen beside it.
    private func adopt(_ download: WKDownload, as id: String, tab: TabId?) {
        let live = Live(id: id, download: download, tab: tab)
        byId[id] = live
        byDownload[ObjectIdentifier(download)] = live
        download.delegate = self
    }

    /// Ask for a URL as a file rather than as a page. This is what Try Again
    /// on a failed download does.
    ///
    /// The id is minted here rather than when WebKit answers, and is handed
    /// back. Nothing needed it before; `chrome.downloads.download` does, because
    /// the extension is told the identity of what it started and there has to
    /// be one to tell it. Minting it at the moment the request goes out is also
    /// the only point at which it is certainly not the id of something else.
    @discardableResult
    func start(_ url: String, in webView: WKWebView, tab: TabId) -> String? {
        guard let target = URL(string: url) else { return nil }
        let id = UUID().uuidString

        webView.startDownload(using: URLRequest(url: target)) { [weak self] download in
            MainActor.assumeIsolated {
                self?.adopt(download, as: id, tab: tab)
            }
        }
        return id
    }

    // MARK: - Carrying out the core's answer

    /// Write it here. The core has already made sure nothing is at this path
    /// and that the folder above it exists, which is what `WKDownload`
    /// requires and, more to the point, what stops a download replacing a file.
    func accept(id: String, path: String) {
        guard let live = byId[id], let handler = live.destination else { return }
        live.destination = nil
        live.awaitingPanel = false
        handler(URL(fileURLWithPath: path))
        startTicking()
    }

    /// Put a save panel up and report back what it says.
    ///
    /// A sheet rather than a modal run loop: the delegate callback we are
    /// inside must return, and the download waits perfectly happily while it
    /// does.
    func ask(id: String, directory: String, filename: String) {
        guard let live = byId[id] else { return }
        live.awaitingPanel = true

        let panel = NSSavePanel()
        panel.directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        panel.nameFieldStringValue = filename
        panel.canCreateDirectories = true
        // The name without its extension, so typing replaces what you would
        // want to change and leaves ".pdf" alone.
        panel.nameFieldLabel = "Save as:"

        let answer: @MainActor (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            guard response == .OK, let url = panel.url else {
                self.emit?(.cancelDownload(id: id))
                return
            }
            // The panel has already asked about replacing, so this is the
            // person's own decision rather than something happening to them.
            // Removing it here keeps the core's promise — a download never
            // writes over a file — literally true of what reaches WebKit.
            try? FileManager.default.removeItem(at: url)
            self.emit?(.downloadDestinationChosen(id: id, path: url.path))
        }

        if let window = live.download.webView?.window {
            panel.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated { answer(response) }
            }
        } else {
            panel.begin { response in
                MainActor.assumeIsolated { answer(response) }
            }
        }
    }

    /// Stop it. Refusing the destination is how a download is declined before
    /// it starts; after that there is a transfer to cancel.
    ///
    /// Stopping is also how a download is *paused*. `WKDownload.cancel` hands
    /// back what it would take to carry on, when the server said enough for that
    /// to be possible, and keeping it is the whole of pause: there is no paused
    /// state because there is nothing a stopped-and-resumable download would do
    /// differently from one.
    func cancel(id: String) {
        guard let live = byId[id] else { return }

        if let handler = live.destination {
            live.destination = nil
            handler(nil)
            // Nothing was ever written, so there is nothing to carry on from.
            forget(live)
            return
        }

        live.download.cancel { [weak self] data in
            MainActor.assumeIsolated { self?.hold(data, for: id) }
        }
        forget(live)
    }

    /// Carry on from where `id` stopped.
    ///
    /// The core only asks for this when the host has said it still holds the
    /// blob, so both guards below are the two of us having come apart. Both fail
    /// loudly rather than quietly: the core has already put the row back to
    /// arriving, and a row that says it is arriving while nothing is happening
    /// is the exact shape ADR-0018 exists to forbid.
    func resume(id: String, in webView: WKWebView?, tab: TabId) {
        guard let data = resumeData[id], let webView else {
            refuseResume(id: id)
            return
        }
        release(id)

        webView.resumeDownload(fromResumeData: data) { [weak self] download in
            MainActor.assumeIsolated {
                self?.adopt(download, as: id, tab: tab)
            }
        }
        startTicking()
    }

    private func refuseResume(id: String) {
        release(id)
        emit?(.downloadResumability(id: id, resumable: false))
        emit?(.downloadFailed(
            id: id,
            kind: .unknown,
            message: "This download can no longer be picked up where it stopped."
        ))
    }

    // MARK: - Holding what a resume would spend

    /// Keep the blob, and tell the core the row may offer to carry on.
    ///
    /// `nil` is the engine saying this transfer cannot be resumed at all — a
    /// server with no validator, a response with no length — and it is passed on
    /// as such rather than ignored, because a download that could be resumed a
    /// moment ago must stop saying so.
    private func hold(_ data: Data?, for id: String) {
        guard let data else {
            release(id)
            emit?(.downloadResumability(id: id, resumable: false))
            return
        }
        if resumeData.updateValue(data, forKey: id) == nil {
            resumeOrder.append(id)
        }
        emit?(.downloadResumability(id: id, resumable: true))

        while resumeOrder.count > Self.maxResumable, let oldest = resumeOrder.first {
            release(oldest)
            emit?(.downloadResumability(id: oldest, resumable: false))
        }
    }

    private func release(_ id: String) {
        resumeData.removeValue(forKey: id)
        resumeOrder.removeAll { $0 == id }
    }

    // MARK: - Progress

    /// One ticker for every download, rather than KVO on each.
    ///
    /// `NSProgress` fires far more often than a screen can show, and every
    /// report costs a dispatch through the reducer and a snapshot. A quarter
    /// of a second is faster than the eye and cheap enough to ignore.
    private func startTicking() {
        guard ticker == nil else { return }

        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.reportProgress() else { return }
            }
        }
    }

    /// Report anything that moved. Returns whether anything is still running.
    @discardableResult
    private func reportProgress() -> Bool {
        for live in byId.values {
            let progress = live.download.progress
            let received = max(0, progress.completedUnitCount)
            guard received != live.reported else { continue }

            live.reported = received
            emit?(.downloadProgressed(
                id: live.id,
                receivedBytes: UInt64(received),
                totalBytes: Self.total(of: progress)
            ))
        }
        if byId.isEmpty {
            ticker = nil
            return false
        }
        return true
    }

    /// A total of zero or less is `NSProgress` saying it does not know, which
    /// is a different thing from a file of no length.
    private static func total(of progress: Progress) -> UInt64? {
        progress.totalUnitCount > 0 ? UInt64(progress.totalUnitCount) : nil
    }

    private func forget(_ live: Live) {
        byId.removeValue(forKey: live.id)
        byDownload.removeValue(forKey: ObjectIdentifier(live.download))
        if byId.isEmpty {
            ticker?.cancel()
            ticker = nil
        }
    }

    // MARK: - Where files go

    /// The system's Downloads folder, created if it is somehow not there.
    ///
    /// The platform knows where this is; the core decides whether to use it.
    static func systemDownloadDirectory() -> String {
        let url = FileManager.default
            .urls(for: .downloadsDirectory, in: .userDomainMask)
            .first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Downloads", isDirectory: true)

        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    /// Show the file in Finder, selected.
    ///
    /// More useful than opening it: half the time what you want is to drag it
    /// somewhere, and the other half you want to check it is really there.
    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    static func open(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    // MARK: - WKDownloadDelegate

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping @MainActor (URL?) -> Void
    ) {
        guard let live = byDownload[ObjectIdentifier(download)], let emit else {
            // A download we do not have a record of is one nothing can show,
            // stop or find afterwards. Refusing it is better than writing a
            // file nobody knows about.
            completionHandler(nil)
            return
        }
        live.destination = completionHandler

        let length = response.expectedContentLength
        emit(.downloadStarted(
            id: live.id,
            tab: live.tab,
            url: download.originalRequest?.url?.absoluteString
                ?? response.url?.absoluteString
                ?? "",
            suggestedFilename: suggestedFilename,
            // `NSURLResponseUnknownLength` is -1. Anything below zero is the
            // server declining to say, and that stays unknown all the way to
            // the screen rather than becoming a plausible number.
            totalBytes: length > 0 ? UInt64(length) : nil,
            defaultDirectory: Self.systemDownloadDirectory()
        ))

        // The core answers every `DownloadStarted` synchronously, so by here
        // the handler has been used or a panel is up. If neither happened,
        // something is wrong and a held handler would hang the transfer with
        // nothing on screen explaining it.
        if live.destination != nil, !live.awaitingPanel {
            live.destination = nil
            completionHandler(nil)
            forget(live)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let live = byDownload[ObjectIdentifier(download)] else { return }

        // One last exact count. When the server never sent a length, this is
        // the number that turns "unknown size" into a fact.
        emit?(.downloadProgressed(
            id: live.id,
            receivedBytes: UInt64(max(0, download.progress.completedUnitCount)),
            totalBytes: Self.total(of: download.progress)
        ))
        emit?(.downloadFinished(id: live.id))
        forget(live)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let live = byDownload[ObjectIdentifier(download)] else { return }

        // A cancelled transfer is not a breakage, and the core already knows
        // if the person asked for it. Reporting it as a failure would put
        // "the connection dropped" next to something they stopped themselves.
        if (error as NSError).code == NSURLErrorCancelled,
           (error as NSError).domain == NSURLErrorDomain {
            emit?(.cancelDownload(id: live.id))
        } else {
            // One last exact count, before the state moves — the reducer refuses
            // a progress report about a download that has already stopped. The
            // ticker runs four times a second, so a transfer that dropped inside
            // its first quarter-second had reported nothing at all: the row said
            // "0 bytes so far" over a partial file on disk, and then offered to
            // carry on from it. Measured, and found by a test that asserted the
            // count was above zero.
            emit?(.downloadProgressed(
                id: live.id,
                receivedBytes: UInt64(max(0, download.progress.completedUnitCount)),
                totalBytes: Self.total(of: download.progress)
            ))
            emit?(.downloadFailed(
                id: live.id,
                kind: Self.kind(of: error),
                message: error.localizedDescription
            ))
        }
        // After the state moved, never before: the core refuses to mark a
        // running download resumable, so a report that arrived first would be
        // dropped and the row would offer Try Again for a transfer that could
        // have carried on. Measured — a connection dropped partway hands back a
        // blob, which is the case this whole feature is for.
        hold(resumeData, for: live.id)
        forget(live)
    }

    /// Translate the platform's error into the core's category.
    ///
    /// The same split as `HostedWebView.kind(of:)`: what the categories *mean*
    /// is decided in the core, and picking one from an `NSError` is the host's
    /// job because a Linux host will have entirely different numbers for the
    /// same things.
    static func kind(of error: Error) -> DownloadErrorKind {
        let error = error as NSError

        switch error.domain {
        case NSURLErrorDomain:
            return urlErrorKind(error.code)
        case NSCocoaErrorDomain:
            return cocoaErrorKind(error.code)
        default:
            return .unknown
        }
    }

    private static func urlErrorKind(_ code: Int) -> DownloadErrorKind {
        switch code {
        case NSURLErrorNotConnectedToInternet,
             NSURLErrorDataNotAllowed,
             NSURLErrorInternationalRoamingOff:
            .offline

        case NSURLErrorTimedOut:
            .timeout

        case NSURLErrorCannotConnectToHost,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorCannotFindHost,
             NSURLErrorDNSLookupFailed,
             NSURLErrorBadServerResponse,
             NSURLErrorResourceUnavailable:
            .connectionFailed

        case NSURLErrorSecureConnectionFailed,
             NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid:
            .certificateInvalid

        case NSURLErrorCannotWriteToFile,
             NSURLErrorCannotCreateFile,
             NSURLErrorCannotMoveFile,
             NSURLErrorCannotRemoveFile,
             NSURLErrorNoPermissionsToReadFile:
            .cannotWrite

        default:
            .unknown
        }
    }

    /// Writing the file is Foundation's job once WebKit hands it over, so a
    /// full disk arrives in `NSCocoaErrorDomain` rather than the URL one.
    private static func cocoaErrorKind(_ code: Int) -> DownloadErrorKind {
        switch code {
        case NSFileWriteOutOfSpaceError:
            .noSpace
        case NSFileWriteNoPermissionError,
             NSFileWriteVolumeReadOnlyError,
             NSFileWriteInvalidFileNameError,
             NSFileNoSuchFileError,
             NSFileWriteFileExistsError:
            .cannotWrite
        default:
            .unknown
        }
    }
}
