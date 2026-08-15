import Foundation
import Testing
import WebKit
import Zer0Core

@testable import Zer0Shell

/// Throwaway probe: measures whether `storage.local` survives a change of
/// extension identity across process restarts.
///
/// Answers the two questions ADR-0104 §"When to revisit" leaves open:
///
/// - **P1:** What does an extension lose when `baseURL` and `uniqueIdentifier`
///   move from WebKit's per-launch defaults to a stable scheme + id?
/// - **P2:** Does `storage.local` survive the change of identity **between
///   launches**, after the fix?
///
/// One subprocess per (case, step): the orchestrator (`scripts/probe-identity.sh`)
/// writes in one process, reads in another, and tabulates whether the read saw
/// the write. Each case varies the `ZER0_PROBE_BASE_URL` / `ZER0_PROBE_UNIQUE_ID`
/// env vars that the `#if DEBUG` shim in `ExtensionHost.load` reads.
///
/// Not a lock. Gated by `ZER0_SHOT=1`, so CI never runs it.
@MainActor
struct ZZExtensionIdentityProbe {

    // The id zer0 already computes from the package's public key
    // (crates/zer0-core/src/ext/crx.rs:131 — SHA-256[..16] mapped to 'a'..'p').
    // Same for every case so the fixture is identical; only the env vars
    // driving the context's baseURL / uniqueIdentifier differ.
    private static let stableId = "aeblfdkhhhdcdjpifhhbdiojplfjncoa"

    /// One subprocess does one thing: write or read, in one of four cases.
    /// The orchestrator wires `CASE` and `STEP`; the test is inert without them.
    @Test(
        "storage.local across identity changes",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    func storageAcrossIdentity() async throws {
        let caseName = ProcessInfo.processInfo.environment["CASE"] ?? "unknown"
        let step = ProcessInfo.processInfo.environment["STEP"] ?? "write"

        // A persistent profile shared between the write and read subprocesses
        // of the same case. The extension context uses WKWebsiteDataStore.default()
        // (ADR-0104 measured that assigning a different one hangs WKWebView.init),
        // so storage.local is backed by whatever default() persists to disk.
        //
        // `storagePath: nil` matches what ExtensionApiTests uses, and is the only
        // configuration under which a background service worker loads at all in
        // this harness — measured. A non-nil path produces
        // `backgroundContentFailedToLoad` for every worker, including one whose
        // script is just `chrome.action.setTitle`. The implication is that the
        // probe cannot today measure cross-launch storage.local persistence:
        // there is no path under which the worker both loads and persists.
        let model = BrowserModel(storagePath: nil)
        let host = try #require(model.extensions)

        // The control case is filesystem-only: it proves the subprocess plumbing
        // works, independent of WebKit's storage semantics. If this fails, every
        // other result is unreadable.
        if caseName == "control-default-store" {
            let base = ProcessInfo.processInfo.environment["ZER0_PROBE_DB"]
                ?? NSTemporaryDirectory()
            let marker = URL(fileURLWithPath: base)
                .appendingPathComponent("control-marker.txt")
            if step == "write" {
                try "hello".write(to: marker, atomically: true, encoding: .utf8)
                Self.report(caseName, step, "wrote-file")
            } else {
                let value = (try? String(contentsOf: marker, encoding: .utf8))
                    ?? "<missing>"
                Self.report(caseName, step, value)
            }
            return
        }

        // The worker script: write sets a value, read gets it back. The action
        // title is the one channel out of a service worker that needs neither a
        // native host nor the network (ExtensionApiTests.swift:104-111).
        //
        // The package is built exactly as ExtensionApiTests.package() builds
        // one: with the repository's own compat file prepended and the manifest
        // pointing at `zer0-compat.js`. Without the compat file, `chrome.*`
        // calls throw inside the service worker and WebKit reports "background
        // content failed to load" — measured. ExtensionFixture does not inject
        // compat, so it cannot back a worker that calls chrome.storage.
        let script = step == "write"
            ? """
            chrome.storage.local.set({ probe: "hello" }, function () {
              chrome.action.setTitle({ title: "said:wrote" });
            });
            """
            : """
            chrome.storage.local.get(["probe"], function (result) {
              chrome.action.setTitle({ title: "said:" + JSON.stringify(result) });
            });
            """
        let installed = try Self.package(
            named: "IdentityProbe",
            permissions: ["storage"],
            background: script
        )
        let decision = defaultConsentDecision(
            request: model.consentRequest(for: installed),
            decidedAtMs: 1_000
        )
        // Mirror ExtensionApiTests.run(): persist the consent into the model
        // before load, not just into the context. host.load re-applies it, but
        // the model-side record is what the API ledger reads from, and without
        // it the worker's first chrome.* call can land before the ledger has
        // a grant for this extension.
        await model.applyConsent(decision)
        let context = try await host.load(installed, granting: decision)
        Self.say("case=\(caseName) step=\(step) "
            + "baseURL=\(context.baseURL.absoluteString) "
            + "uniqueId=\(String(describing: context.uniqueIdentifier))")

        // Wait for the worker to report. The worker starts on `load` but may
        // need a moment; the timeout is a hang detector, not a timing assertion.
        let label = await Self.waitForAction(context)
        Self.report(caseName, step, label)
        for error in context.errors {
            Self.say("context error: \((error as NSError).localizedDescription)")
        }
    }

    // MARK: - Channels out

    /// Builds an unpacked extension directory with the repository's own compat
    /// file injected, mirroring ExtensionApiTests.package(). The directory is
    /// cleaned up when the test process exits (it lives in the system temp
    /// dir), so each subprocess gets a fresh one.
    private static func package(
        named name: String,
        permissions: [String],
        background script: String
    ) throws -> InstalledExtension {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zer0-ext-idprobe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let compat = try String(
            contentsOf: SourceScan.repoRoot.appending(path: "crates/zer0-core/src/ext/compat.js"),
            encoding: .utf8
        )
        try script.write(
            to: directory.appendingPathComponent("background.js"),
            atomically: true, encoding: .utf8
        )
        try (compat + "\nimportScripts(\"background.js\");\n").write(
            to: directory.appendingPathComponent("zer0-compat.js"),
            atomically: true, encoding: .utf8
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
            atomically: true, encoding: .utf8
        )

        return InstalledExtension(
            id: stableId,
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
        )
    }

    private static func say(_ line: String) {
        print("[probe] \(line)")
    }

    private static func report(_ caseName: String, _ step: String, _ value: String) {
        print("[probe] case=\(caseName) step=\(step) read=\"\(value)\"")
    }

    /// Polls `context.action(for: nil)?.label` until it starts with "said:",
    /// matching the channel ExtensionApiTests uses.
    private static func waitForAction(
        _ context: WKWebExtensionContext
    ) async -> String {
        let met = await eventually(timeout: .seconds(30)) {
            let title = context.action(for: nil)?.label ?? ""
            return title.hasPrefix("said:")
        }
        let title = context.action(for: nil)?.label ?? "<nothing>"
        return met ? String(title.dropFirst(5)) : title
    }
}
