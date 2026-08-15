import Foundation
import Testing
import WebKit
import Zer0Core

@testable import Zer0Shell

/// What real packages get from `chrome.downloads`, `chrome.idle` and
/// `chrome.management`, measured rather than reasoned about.
///
/// ADR-0084 and ADR-0100 both name a harness they wished they had kept: the
/// measurement each rests on was a throwaway, so re-running it on a new macOS
/// means writing it again. This is that harness, kept.
///
///     ZER0_SHOT=1 swift test --filter ZZExtensionApiProbe
///
/// It reads every package under `ZER0_EXT_CORPUS`, or the browser's own
/// extensions folder when that is not set. **It copies before it touches
/// anything**: the compatibility file is written into the copy, so a package a
/// person actually has installed is never modified by a test run.
///
/// Gated like every other harness here, because it pumps the run loop for tens
/// of seconds and would starve the timing tests (`scripts/check.sh`).
@MainActor
struct ZZExtensionApiProbe {
    private var corpus: URL {
        if let named = ProcessInfo.processInfo.environment["ZER0_EXT_CORPUS"] {
            return URL(fileURLWithPath: named, isDirectory: true)
        }
        return FileManager.default
            .homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/zer0/extensions")
    }

    @Test(.disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil))
    func whatRealPackagesGet() async throws {
        let packages = (try? FileManager.default.contentsOfDirectory(
            at: corpus, includingPropertiesForKeys: nil
        )) ?? []
        print("PROBE corpus: \(corpus.path) — \(packages.count) package(s)")

        for package in packages where package.hasDirectoryPath {
            do {
                try await measure(package)
            } catch {
                print("PROBE \(package.lastPathComponent): could not be loaded — \(error)")
            }
        }
    }

    /// Copy, inject, load, and ask the worker what it has.
    private func measure(_ package: URL) async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "zer0-probe-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: package, to: scratch)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let manifestURL = scratch.appending(path: "manifest.json")
        var manifest = try JSONSerialization.jsonObject(
            with: Data(contentsOf: manifestURL)
        ) as? [String: Any] ?? [:]
        let name = (manifest["name"] as? String) ?? package.lastPathComponent
        let declared = (manifest["permissions"] as? [String]) ?? []

        // The classic-worker shape `ext::compat::inject` writes, plus a witness
        // at the end. Without the witness a worker that came up clean having
        // never run our file reads as a success (ADR-0100).
        guard var background = manifest["background"] as? [String: Any],
              let entry = background["service_worker"] as? String
        else {
            print("PROBE \(name): no service worker to get in front of")
            return
        }
        let compat = try String(
            contentsOf: SourceScan.repoRoot.appending(path: "crates/zer0-core/src/ext/compat.js"),
            encoding: .utf8
        )
        try (compat + """

        try { importScripts(\(json(entry))); } catch (e) { self.zer0Threw = e && e.message; }

        """).write(to: scratch.appending(path: "zer0-compat.js"), atomically: true, encoding: .utf8)
        background["service_worker"] = "zer0-compat.js"
        manifest["background"] = background
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)

        let installed = InstalledExtension(
            id: package.lastPathComponent,
            path: scratch.path,
            manifest: ExtensionManifest(
                name: name,
                version: (manifest["version"] as? String) ?? "0",
                description: nil,
                manifestVersion: 3,
                permissions: declared,
                hostPermissions: (manifest["host_permissions"] as? [String]) ?? [],
                hasAction: manifest["action"] != nil,
                compat: nil
            )
        )

        let model = BrowserModel(storagePath: nil)
        let request = model.consentRequest(for: installed)
        let decision = defaultConsentDecision(request: request, decidedAtMs: 1_000)
        await model.applyConsent(decision)
        guard let host = model.extensions else { return }
        let context = try await host.load(installed, granting: decision)

        // Long enough for a large worker to get through its own startup.
        try? await Task.sleep(nanoseconds: 4_000_000_000)

        let notYet = request.requests.compactMap { row -> String? in
            if case .notBuiltYet = row.notProvided { return row.key }
            return nil
        }
        let refused = request.requests.compactMap { row -> String? in
            if case .declined = row.notProvided { return row.key }
            return nil
        }
        print("""
        PROBE \(name) \(installed.manifest.version)
          background failed: \(model.extensions?.backgroundContentFailed(installed.id) == true)
          errors:            \(context.errors.map(\.localizedDescription))
          not built yet:     \(notYet)
          refused:           \(refused)
          switchable:        \(request.requests.filter { $0.notProvided == nil }.count) of \(request.requests.count)
        """)
    }

    private func json(_ value: String) -> String {
        String(
            decoding: (try? JSONSerialization.data(withJSONObject: [value])) ?? Data(),
            as: UTF8.self
        ).dropFirst().dropLast().description
    }
}
