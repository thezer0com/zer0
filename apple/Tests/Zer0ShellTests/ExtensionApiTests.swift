import Foundation
import Testing
import WebKit
import Zer0Core

@testable import Zer0Shell

/// `chrome.downloads` and `chrome.idle`, all the way through.
///
/// A real package with the real compatibility file in it, loaded into the real
/// `WKWebExtensionController` this browser builds, calling
/// `chrome.downloads.download` against a real HTTP server, with a real file on
/// disk at the end.
///
/// Everything else about this API is tested in the core, where it is decided —
/// and that proves the rules and proves nothing about whether the plumbing is
/// connected. "A method exists on `chrome.downloads`" is not evidence that
/// anything downloads, which is the whole reason this file exists.
@MainActor
struct ExtensionApiTests {
    /// A package whose background worker runs `script` after the compatibility
    /// file, exactly as an installed one does.
    ///
    /// The compat file is the repository's own bytes rather than a copy, for
    /// the reason `ExtensionCompatTests` reads them too: a second copy is a
    /// second thing to keep in step, and the one that drifts is the one under
    /// test.
    private func package(
        named name: String,
        permissions: [String],
        background script: String
    ) throws -> (installed: InstalledExtension, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zer0-ext-api-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let compat = try String(
            contentsOf: SourceScan.repoRoot.appending(path: "crates/zer0-core/src/ext/compat.js"),
            encoding: .utf8
        )
        try script.write(
            to: directory.appendingPathComponent("background.js"), atomically: true, encoding: .utf8
        )
        // The classic-worker shape `ext::compat::inject` writes: the file, then
        // `importScripts` of the extension's own entry point.
        try (compat + "\nimportScripts(\"background.js\");\n").write(
            to: directory.appendingPathComponent("zer0-compat.js"),
            atomically: true,
            encoding: .utf8
        )

        let quoted = permissions.map { "\"\($0)\"" }.joined(separator: ", ")
        try """
        {
          "manifest_version": 3,
          "name": "\(name)",
          "version": "1.0.0",
          "permissions": [\(quoted)],
          "action": {},
          "background": { "service_worker": "zer0-compat.js" }
        }
        """.write(
            to: directory.appendingPathComponent("manifest.json"),
            atomically: true,
            encoding: .utf8
        )

        return (
            InstalledExtension(
                id: "api-\(UUID().uuidString)",
                path: directory.path,
                manifest: ExtensionManifest(
                    name: name,
                    version: "1.0.0",
                    description: nil,
                    manifestVersion: 3,
                    permissions: permissions,
                    hostPermissions: [],
                    hasAction: true,
                    compat: nil
                )
            ),
            directory
        )
    }

    /// Load it, holding everything the sheet would have arrived with ticked.
    ///
    /// Through the model rather than around it, so the ledger the API asks is
    /// the one the person's answer would have written.
    private func run(
        _ installed: InstalledExtension,
        in model: BrowserModel
    ) async throws -> WKWebExtensionContext {
        let request = model.consentRequest(for: installed)
        let decision = defaultConsentDecision(request: request, decidedAtMs: 1_000)
        await model.applyConsent(decision)
        let host = try #require(model.extensions)
        return try await host.load(installed, granting: decision)
    }

    /// What the worker put in its action title, which is the one channel out of
    /// a service worker that needs neither a native host nor the network.
    private func said(_ context: WKWebExtensionContext) async -> String {
        for _ in 0..<200 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            let title = context.action(for: nil)?.label ?? ""
            if title.hasPrefix("said:") { return String(title.dropFirst(5)) }
        }
        return context.action(for: nil)?.label ?? "<nothing>"
    }

    private func scratch(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zer0-ext-api-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func model(savingInto folder: URL) -> BrowserModel {
        let m = BrowserModel(storagePath: nil)
        m.updatePreferences { $0.downloadDirectory = folder.path }
        return m
    }

    // MARK: - The evidence

    /// The whole point: an extension asks for a file and the file arrives.
    @Test("an extension downloads a file and it lands on disk")
    func anExtensionReallyDownloads() async throws {
        let folder = try scratch("lands")
        let body = Data(repeating: 0x7A, count: 64 * 1024)
        let server = try await TinyHTTPServer(routes: [
            "/file": .attachment(named: "from-extension.bin", body: body),
        ])
        defer { server.stop() }

        let m = model(savingInto: folder)
        // Somewhere for the download to be routed through: a download goes out
        // over a tab's cookie jar, so a browser with no page open refuses.
        let tab = try #require(m.snapshot.activeTab)
        m.send(.navigateTo(tab: tab, input: "http://127.0.0.1:\(server.port)/empty"))

        let (installed, directory) = try package(
            named: "Downloader",
            permissions: ["downloads"],
            background: """
            chrome.downloads.download({ url: "http://127.0.0.1:\(server.port)/file" })
              .then(function (id) { chrome.action.setTitle({ title: "said:id=" + id }); })
              .catch(function (e) { chrome.action.setTitle({ title: "said:threw=" + e.message }); });
            """
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try await run(installed, in: m)

        let answered = await said(context)
        #expect(answered == "id=1", "answered: \(answered)")
        #expect(await eventually { m.downloads.first?.state == .completed })

        let landed = folder.appendingPathComponent("from-extension.bin")
        #expect(try Data(contentsOf: landed).count == body.count)
        #expect(m.downloads.first?.path == landed.path)
    }

    /// Started, then found again through the extension's own API, then stopped
    /// through it. Each of the three is a different road into the same list.
    @Test("an extension finds and stops the download it started")
    func searchAndCancelReachTheSameList() async throws {
        let folder = try scratch("search")
        let server = try await TinyHTTPServer(routes: [
            // Slow enough to still be arriving when it is looked for.
            "/slow": .slowAttachment(
                named: "slow.bin", pieces: 40, pieceSize: 64 * 1024, gap: 0.25
            ),
        ])
        defer { server.stop() }

        let m = model(savingInto: folder)
        let tab = try #require(m.snapshot.activeTab)
        m.send(.navigateTo(tab: tab, input: "http://127.0.0.1:\(server.port)/empty"))

        let (installed, directory) = try package(
            named: "Watcher",
            permissions: ["downloads"],
            background: """
            chrome.downloads.download({ url: "http://127.0.0.1:\(server.port)/slow" })
              .then(function (id) {
                return chrome.downloads.search({ id: id }).then(function (found) {
                  return chrome.downloads.cancel(id).then(function () {
                    chrome.action.setTitle({
                      title: "said:found=" + found.length + " state=" + found[0].state +
                             " url=" + (found[0].url.indexOf("/slow") !== -1)
                    });
                  });
                });
              })
              .catch(function (e) { chrome.action.setTitle({ title: "said:threw=" + e.message }); });
            """
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try await run(installed, in: m)

        let answered = await said(context)
        #expect(answered == "found=1 state=in_progress url=true", "answered: \(answered)")
        #expect(await eventually { m.downloads.first?.state == .cancelled })
    }

    /// The refusal an extension gets for the two this browser will not do, in
    /// the extension's own words rather than in a stack trace.
    @Test("pause and resume come back as a refusal that says why")
    func pauseAndResumeAreRefused() async throws {
        let folder = try scratch("pause")
        let m = model(savingInto: folder)

        let (installed, directory) = try package(
            named: "Pauser",
            permissions: ["downloads"],
            background: """
            chrome.downloads.pause(1)
              .then(function () { chrome.action.setTitle({ title: "said:it-agreed" }); })
              .catch(function (e) { chrome.action.setTitle({ title: "said:" + e.message }); });
            """
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try await run(installed, in: m)

        let answered = await said(context)
        #expect(answered.contains("does not pause or resume"), "answered: \(answered)")
        #expect(answered.contains("this run"), "answered: \(answered)")
    }

    /// A permission withheld is a call refused, and the refusal names the key.
    /// The switch on the Extensions screen is what this is: without it, turning
    /// `downloads` off would leave the API answering anyway.
    @Test("a withheld permission is a refused call")
    func aWithheldPermissionIsARefusedCall() async throws {
        let folder = try scratch("withheld")
        let m = model(savingInto: folder)

        let (installed, directory) = try package(
            named: "Refused",
            permissions: ["downloads"],
            background: """
            chrome.downloads.search({})
              .then(function (f) { chrome.action.setTitle({ title: "said:answered=" + f.length }); })
              .catch(function (e) { chrome.action.setTitle({ title: "said:" + e.message }); });
            """
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        // Everything refused, which is what switching the row off records.
        let request = m.consentRequest(for: installed)
        var nothing = defaultConsentDecision(request: request, decidedAtMs: 1_000)
        nothing = consentDecisionSetting(
            decision: nothing, kind: .api, key: "downloads", granted: false
        )
        await m.applyConsent(nothing)
        let host = try #require(m.extensions)
        let context = try await host.load(installed, granting: nothing)

        let answered = await said(context)
        #expect(answered.contains("downloads"), "answered: \(answered)")
        #expect(answered.contains("not holding"), "answered: \(answered)")
    }

    /// `chrome.idle` answers about this machine, and the answer is the
    /// machine's rather than a constant somebody wrote down.
    ///
    /// The threshold arithmetic is the core's and is tested there. What can
    /// only be tested here is that the two facts the shell measures —
    /// `CGEventSource`'s idle clock and whether the screen is locked — really
    /// travel, so this reads the lock state itself and requires the extension's
    /// answer to agree with it. A build that answered a constant fails on
    /// whichever machine disagrees with the constant, and a build that stopped
    /// reading the lock fails on a locked one.
    @Test("idle answers out of this machine rather than out of a constant")
    func idleAnswersOutOfTheSystem() async throws {
        let folder = try scratch("idle")
        let m = model(savingInto: folder)

        let (installed, directory) = try package(
            named: "Idler",
            permissions: ["idle"],
            background: """
            chrome.idle.queryState(999999)
              .then(function (never) {
                chrome.action.setTitle({ title: "said:" + never });
              })
              .catch(function (e) { chrome.action.setTitle({ title: "said:threw=" + e.message }); });
            """
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try await run(installed, in: m)

        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let locked = session?["CGSSessionScreenIsLocked"] as? Bool ?? false
        let answered = await said(context)

        // A threshold nothing could exceed, so the only two answers a real
        // reading can give are "the screen is locked" and "somebody is here".
        #expect(answered == (locked ? "locked" : "active"), "answered: \(answered)")
    }

    /// `management.getSelf` out of the extension's own manifest, and nothing
    /// else on that namespace — the position the Extensions screen states.
    @Test("an extension can describe itself and cannot reach another")
    func managementDescribesOnlyItself() async throws {
        let folder = try scratch("management")
        let m = model(savingInto: folder)

        let (installed, directory) = try package(
            named: "Selfie",
            permissions: ["storage"],
            background: """
            chrome.management.getSelf(function (self) {
              chrome.action.setTitle({
                title: "said:" + self.name + "/" + self.version +
                       "/getAll=" + typeof chrome.management.getAll +
                       "/setEnabled=" + typeof chrome.management.setEnabled
              });
            });
            """
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try await run(installed, in: m)

        #expect(
            await said(context) == "Selfie/1.0.0/getAll=undefined/setEnabled=undefined"
        )
    }
}
