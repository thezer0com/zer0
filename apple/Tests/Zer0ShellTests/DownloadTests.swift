import Foundation
import Testing
import WebKit
import Zer0Core

@testable import Zer0Shell

/// A folder of our own per test, so two of them never argue over a filename.
///
/// The label alone was not "of our own": swift-testing runs these in parallel
/// and two runs can overlap, so the UUID is what makes the sentence above true
/// rather than merely intended.
private struct Scratch: ~Copyable {
    let url: URL

    init(_ name: String) {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "zer0-shell-download-tests-\(name)-\(UUID().uuidString)", isDirectory: true
            )
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    var path: String { url.path }

    func put(_ name: String) {
        FileManager.default.createFile(atPath: url.appendingPathComponent(name).path, contents: Data())
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

/// The round trip a real download makes: WebKit says "here is a file called
/// this", the core decides where it goes, and the shell is left holding a path.
@MainActor
struct DownloadRoundTripTests {
    private func model() -> BrowserModel { BrowserModel(storagePath: nil) }

    private func start(
        _ m: BrowserModel,
        id: String = "d1",
        named suggested: String,
        into directory: String,
        totalBytes: UInt64? = 1000
    ) {
        m.send(.downloadStarted(
            id: id,
            tab: m.snapshot.activeTab,
            url: "https://example.com/file",
            suggestedFilename: suggested,
            totalBytes: totalBytes,
            defaultDirectory: directory
        ))
    }

    @Test("a filename from a server cannot write outside the download folder")
    func traversalIsContained() async throws {
        let scratch = Scratch("traversal")
        let m = model()
        m.updatePreferences { $0.downloadDirectory = scratch.path }

        start(m, named: "../../../../etc/passwd", into: scratch.path)

        let download = try #require(m.downloads.first)
        #expect(download.filename == "passwd")
        #expect(URL(fileURLWithPath: download.path).deletingLastPathComponent().path == scratch.path)
    }

    @Test("a download adds a file and never replaces one")
    func collisionsAreNumbered() async throws {
        let scratch = Scratch("collision")
        scratch.put("report.pdf")
        let m = model()
        m.updatePreferences { $0.downloadDirectory = scratch.path }

        start(m, named: "report.pdf", into: scratch.path)

        let download = try #require(m.downloads.first)
        #expect(download.filename == "report-2.pdf")
        #expect(FileManager.default.fileExists(atPath: scratch.url.appendingPathComponent("report.pdf").path))
    }

    @Test("a download that fails carries the cause, and the copy names it")
    func failureNamesItsCause() async throws {
        let scratch = Scratch("failure")
        let m = model()
        m.updatePreferences { $0.downloadDirectory = scratch.path }
        start(m, named: "big.iso", into: scratch.path)

        m.send(.downloadFailed(id: "d1", kind: .noSpace, message: "no room"))

        let download = try #require(m.downloads.first)
        #expect(download.state == .failed)
        #expect(download.error?.kind == .noSpace)
        #expect(DownloadCopy.status(download) == "The disk is full")
        #expect(DownloadCopy.failureMessage(download.error).contains("room"))
    }

    @Test("stopping a download is never reported back as a breakage")
    func cancellingIsNotAFailure() async throws {
        let scratch = Scratch("cancel")
        let m = model()
        m.updatePreferences { $0.downloadDirectory = scratch.path }
        start(m, named: "big.iso", into: scratch.path)

        m.cancelDownload("d1")
        // WebKit answers a cancel with NSURLErrorCancelled a moment later.
        m.send(.downloadFailed(id: "d1", kind: .connectionFailed, message: "cancelled"))

        let download = try #require(m.downloads.first)
        #expect(download.state == .cancelled)
        #expect(download.error == nil)
    }

    @Test("quitting asks first while something is still coming down")
    func quittingWarns() async throws {
        let scratch = Scratch("quit")
        let m = model()
        m.updatePreferences { $0.downloadDirectory = scratch.path }
        #expect(!m.shouldWarnBeforeQuitting)

        start(m, named: "big.iso", into: scratch.path)
        #expect(m.shouldWarnBeforeQuitting)

        m.send(.downloadFinished(id: "d1"))
        #expect(!m.shouldWarnBeforeQuitting, "nothing is lost once it has landed")
    }

    @Test("removing an entry leaves the file where it is")
    func removingKeepsTheFile() async throws {
        let scratch = Scratch("remove")
        let m = model()
        m.updatePreferences { $0.downloadDirectory = scratch.path }
        start(m, named: "keep.bin", into: scratch.path)
        let path = try #require(m.downloads.first?.path)
        FileManager.default.createFile(atPath: path, contents: Data("bytes".utf8))
        m.send(.downloadFinished(id: "d1"))

        m.removeDownload("d1")

        #expect(m.downloads.isEmpty)
        #expect(FileManager.default.fileExists(atPath: path))
    }
}

/// ADR-0018 applied to a progress bar: a length nobody sent does not become a
/// percentage on the way to the screen.
@MainActor
struct DownloadHonestyTests {
    private func download(received: UInt64, total: UInt64?) -> Download {
        Download(
            id: "d1",
            url: "https://example.com/f",
            tab: nil,
            filename: "f.bin",
            path: "/tmp/f.bin",
            state: .inProgress,
            receivedBytes: received,
            totalBytes: total,
            error: nil,
            startedAtMs: 0,
            resumable: false
        )
    }

    @Test("an unknown content length produces no fraction to draw a bar from")
    func indeterminateHasNoFraction() async throws {
        #expect(downloadFraction(download: download(received: 4096, total: nil)) == nil)
    }

    @Test("an unknown content length says what arrived and claims nothing else")
    func indeterminateStatusClaimsNothing() async throws {
        let line = DownloadCopy.status(download(received: 4096, total: nil))

        #expect(!line.contains("%"), "\(line) states a percentage nothing backs")
        #expect(!line.contains(" of "), "\(line) states a total nobody sent")
        #expect(line.contains("4"), "what has arrived is a fact and belongs on screen")
    }

    @Test("a known content length is stated as both halves")
    func determinateStatesBoth() async throws {
        let d = download(received: 500, total: 1000)

        #expect(downloadFraction(download: d) == 0.5)
        #expect(DownloadCopy.status(d).contains(" of "))
    }

    @Test("a total the server got wrong is not turned into a bar")
    func aWrongTotalIsNotAFraction() async throws {
        #expect(downloadFraction(download: download(received: 2000, total: 1000)) == nil)
        #expect(downloadFraction(download: download(received: 1, total: 0)) == nil)
    }

    /// The shape, not just the words.
    ///
    /// A row picks between a bar and a spinner from these two, and they have to
    /// disagree in every state or the two facts get drawn as one. A bar has a
    /// scale; a spinner does not; and an indeterminate *bar* — the same track
    /// at a different fill — is the shape that quietly claims a scale nobody
    /// sent, which is what ADR-0027 and ADR-0018 both forbid.
    @Test("no total means no bar, and the row says so with a different shape")
    func noTotalGetsTheSpinnerAndNotABar() async throws {
        let unknown = download(received: 4096, total: nil)

        #expect(DownloadCopy.fraction(unknown) == nil, "a bar drawn from nothing")
        #expect(DownloadCopy.isArrivingWithNoTotal(unknown))
    }

    @Test("a total means a bar, and never the spinner as well")
    func aTotalGetsTheBarAndNotTheSpinner() async throws {
        let known = download(received: 500, total: 1000)

        #expect(DownloadCopy.fraction(known) == 0.5)
        #expect(!DownloadCopy.isArrivingWithNoTotal(known))
    }

    /// The core answers from the byte counts alone, so a download that stopped
    /// at 40% still has a fraction. Nothing is arriving, so nothing draws
    /// either shape — a bar left behind by a transfer that ended is the same
    /// stale assertion as a match count for a query nobody is asking anymore.
    @Test("a download that stopped draws neither shape")
    func aStoppedDownloadDrawsNothing() async throws {
        for state in [DownloadState.completed, .cancelled, .interrupted, .failed] {
            var d = download(received: 400, total: 1000)
            d.state = state

            #expect(DownloadCopy.fraction(d) == nil, "\(state) still draws a bar")
            #expect(!DownloadCopy.isArrivingWithNoTotal(d), "\(state) still spins")
        }
    }

    @Test("a download interrupted by a quit says that, and not that it failed")
    func interruptedSaysWhatHappened() async throws {
        var d = download(received: 10, total: 100)
        d.state = .interrupted

        #expect(DownloadCopy.status(d) == "Stopped when zer0 quit")
    }
}

/// Mapping a platform error onto the core's categories. Everything here is a
/// failure somebody has to read a sentence about, so getting the category
/// wrong shows up as the wrong sentence.
@MainActor
struct DownloadErrorMappingTests {
    private func url(_ code: Int) -> NSError {
        NSError(domain: NSURLErrorDomain, code: code)
    }

    private func cocoa(_ code: Int) -> NSError {
        NSError(domain: NSCocoaErrorDomain, code: code)
    }

    @Test("a network failure lands in the category its sentence belongs to")
    func networkErrors() async throws {
        #expect(DownloadHost.kind(of: url(NSURLErrorNotConnectedToInternet)) == .offline)
        #expect(DownloadHost.kind(of: url(NSURLErrorTimedOut)) == .timeout)
        #expect(DownloadHost.kind(of: url(NSURLErrorNetworkConnectionLost)) == .connectionFailed)
        #expect(DownloadHost.kind(of: url(NSURLErrorServerCertificateUntrusted)) == .certificateInvalid)
    }

    @Test("a full disk is not reported as a network problem")
    func diskErrors() async throws {
        // Foundation writes the file once WebKit hands it over, so this
        // arrives in a different domain from everything above.
        #expect(DownloadHost.kind(of: cocoa(NSFileWriteOutOfSpaceError)) == .noSpace)
        #expect(DownloadHost.kind(of: cocoa(NSFileWriteNoPermissionError)) == .cannotWrite)
        #expect(DownloadHost.kind(of: url(NSURLErrorCannotWriteToFile)) == .cannotWrite)
    }

    @Test("an error we do not recognise says so instead of guessing")
    func unknownStaysUnknown() async throws {
        let strange = NSError(domain: "SomeFrameworkNobodyHasHeardOf", code: 7)

        #expect(DownloadHost.kind(of: strange) == .unknown)
        // And in that case the engine's own words beat anything we would make up.
        let error = DownloadError(kind: .unknown, message: "the far end hung up")
        #expect(DownloadCopy.failureMessage(error) == "the far end hung up")
    }

    @Test("every failure category has a sentence, not just a name")
    func everyCategoryHasCopy() async throws {
        let kinds: [DownloadErrorKind] = [
            .offline, .connectionFailed, .timeout, .certificateInvalid,
            .cannotWrite, .noSpace, .nameUnavailable, .unknown,
        ]

        for kind in kinds {
            let message = DownloadCopy.failureMessage(DownloadError(kind: kind, message: ""))
            #expect(!message.isEmpty, "\(kind) has nothing to say")
            #expect(message.hasSuffix("."), "\(kind) is not a sentence")
            #expect(!DownloadCopy.failureTitle(kind).isEmpty)
        }
    }
}

/// ⇧⌘J, and where it lands.
@MainActor
struct DownloadShortcutTests {
    @Test("⇧⌘J opens downloads, the way it does in Chrome")
    func shortcutIsChromes() async throws {
        let m = BrowserModel(storagePath: nil)
        let chord = try #require(m.chord(for: .showDownloads))

        #expect(chord.key == .char(value: "j"))
        #expect(chord.modifiers.primary)
        #expect(chord.modifiers.shift)
    }

    /// It opens the list, and the list is a page. It used to open the Settings
    /// window at a Downloads pane; that pane is gone, because two screens for
    /// one thing is a defect and the one on screen is always the stale one
    /// (ADR-0063).
    @Test("it opens the downloads page rather than a settings pane")
    func itOpensTheDownloadsPage() async throws {
        let m = BrowserModel(storagePath: nil)
        m.showingSettings = false

        m.perform(.showDownloads)

        #expect(m.showingSettings == false)
        let tab = try #require(m.snapshot.activeTab)
        #expect(
            m.snapshot.tabs.first { $0.id == tab }?.url
                == internalAddressUrl(address: .downloads)
        )
    }
}
