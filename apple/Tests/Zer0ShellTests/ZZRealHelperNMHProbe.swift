import AppKit
import Foundation
import Testing
import WebKit
import Zer0Core

@testable import Zer0Shell

/// Throwaway probe: drive `chrome.runtime.connectNative("com.1password.1password")`
/// from a synthetic extension, but resolve to the REAL `1Password-BrowserSupport`
/// helper binary — not the synthetic shell script the sister probe uses.
///
/// Goal: measure empirically whether the real helper accepts zer0's current
/// signing (Apple Development with Team ID `24X5CQGA86`).
///
/// **Important limitation.** A swift-test runner — not `Zer0.app` — is the
/// process that spawns the helper here. `1Password-BrowserSupport` inspects
/// its parent's signature, so the SecCode check this probe triggers runs
/// against the test runner, not the bundle in `apple/.build/Zer0.app`. The
/// helper's verdict in this probe is therefore the verdict for an ad-hoc-signed
/// test runner (the default), which is *not* the verdict for `Zer0.app`.
///
/// What this probe *does* prove, end to end:
///
/// 1. The borrowed manifest at `~/Library/Application Support/Google/Chrome/
///    NativeMessagingHosts/com.1password.1password.json` is read by zer0's
///    core (the `Google/Chrome` borrowed registrar).
/// 2. The path it names resolves to the real helper binary.
/// 3. `chrome.runtime.connectNative` makes the consent sheet rise.
/// 4. Allow → the shell spawns the real helper as a child.
/// 5. The helper writes a verdict back, which arrives at the worker as a port
///    message and is observable via `context.action(for: nil)?.label`.
///
/// For the actual question — "does the real helper accept `Zer0.app` signed
/// with Apple Development Team ID `24X5CQGA86`?" — the standalone wrapper at
/// `/tmp/wrapper.swift` (signed with `--identifier com.thezer0.zer0` against
/// the same Apple Development identity) is the instrument that answers it,
/// because there the calling process is itself the wrapped signature the
/// helper inspects. This probe is the re-runnable, in-repo version of that
/// experiment's plumbing layer.
///
/// Not a lock. Depends on 1Password being installed at
/// `/Applications/1Password.app`. Reads and writes outside the repo.
///
///     ZER0_RUST_PROFILE=debug ZER0_SHOT=1 ZER0_PROBE_APPROVE=1 \
///         swift test --filter ZZRealHelperNMHProbe
@MainActor
struct ZZRealHelperNMHProbe {
    static var out: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["ZER0_PROBE_DIR"]
            ?? NSTemporaryDirectory())
    }

    static func say(_ line: String) {
        print("[probe-real-helper] \(line)")
        let file = out.appendingPathComponent("real-helper.log")
        let text = line + "\n"
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    /// The synthetic extension's id. Real 1Password's id
    /// (`aeblfdkhhhdcdjpifhhbdiojplfjncoa`) is what the real Chrome manifest
    /// lists in `allowed_origins`, so we reuse it: the manifest copy stays
    /// byte-identical to Chrome's, which makes the test a fair plumbing check.
    /// The fixture's directory lives in the probe's own `/tmp` root, so it
    /// cannot collide with a real 1Password install on disk.
    private static let extensionId = "aeblfdkhhhdcdjpifhhbdiojplfjncoa"

    /// The real 1Password NMH application id — the one Chrome's manifest
    /// registers under the name `com.1password.1password`.
    private static let hostName = "com.1password.1password"

    /// The real helper binary path, as Chrome's manifest names it.
    private static let realHelperPath = "/Applications/1Password.app/Contents/Library/LoginItems/1Password Browser Helper.app/Contents/MacOS/1Password-BrowserSupport"

    /// Where Chrome's real NMH manifest lives.
    private static let realChromeManifestPath = NSString(
        "~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.1password.1password.json"
    ).expandingTildeInPath

    @Test(
        "ADR-0105 plumbing with the real 1Password-BrowserSupport helper: sheet rises, helper spawns, worker reads its verdict",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    func realHelperPlumbing() async throws {
        // 1. Isolated /tmp root. The core's `application_support` root is
        //    derived from `storagePath` by deleting the last two path
        //    components (`zer0/profile.sqlite`) — see `BrowserModel.swift:421`.
        //    Putting the root in `/tmp` keeps this probe out of the person's
        //    real `~/Library/Application Support/zer0`.
        let root = URL(fileURLWithPath: "/tmp/zer0-real-helper-\(UUID().uuidString.prefix(8))")
        let profileDir = root.appendingPathComponent("zer0", isDirectory: true)
        try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)
        let storagePath = profileDir.appendingPathComponent("profile.sqlite").path
        defer { try? FileManager.default.removeItem(at: root) }

        Self.say("root = \(root.path)")
        Self.say("storagePath = \(storagePath)")

        // 2. Copy the real Chrome NMH manifest into the probe root so the
        //    core's `Google/Chrome` borrowed registrar finds it. The manifest
        //    is copied byte-for-byte: `path` stays absolute (points at the
        //    real helper) and `allowed_origins` already lists the real
        //    1Password extension id we reuse here.
        guard FileManager.default.fileExists(atPath: Self.realChromeManifestPath) else {
            Self.say("ABORT: \(Self.realChromeManifestPath) not found; Chrome manifest of 1Password not installed.")
            throw NSError(domain: "probe", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Chrome NMH manifest for 1Password not present",
            ])
        }
        let borrowedDir = root
            .appendingPathComponent("Google", isDirectory: true)
            .appendingPathComponent("Chrome", isDirectory: true)
            .appendingPathComponent("NativeMessagingHosts", isDirectory: true)
        try FileManager.default.createDirectory(at: borrowedDir, withIntermediateDirectories: true)
        let manifestURL = borrowedDir
            .appendingPathComponent("\(Self.hostName).json")
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: Self.realChromeManifestPath),
            to: manifestURL
        )
        Self.say("borrowed manifest: \(manifestURL.path)")

        // Sanity: confirm the real helper binary is on disk where the manifest
        // points. The core refuses a manifest whose `path` is missing, so this
        // keeps the error readable.
        guard FileManager.default.fileExists(atPath: Self.realHelperPath) else {
            Self.say("ABORT: \(Self.realHelperPath) not found; 1Password not installed.")
            throw NSError(domain: "probe", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "1Password helper binary not at expected path",
            ])
        }
        Self.say("real helper path: \(Self.realHelperPath)")

        // Also report our own signature so the log is self-explaining: this is
        // the calling-process identity the helper will inspect.
        Self.say("calling process: pid=\(ProcessInfo.processInfo.processIdentifier) "
            + "bundleId=\(Bundle.main.bundleIdentifier ?? "<none>") "
            + "exec=\(Bundle.main.executableURL?.path ?? CommandLine.arguments[0])")

        // 3. Baseline timestamp so `log show` after the run has a sharp start.
        let baseline = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let baselineIso = formatter.string(from: baseline)
        Self.say("baseline (UTC): \(baselineIso)")

        // 4. Build the synthetic extension. Reuses 1Password's real id so the
        //    copied manifest's `allowed_origins` matches without modification.
        //    The fixture's background calls `connectNative` at boot so the
        //    probe does not have to drive any UI.
        let (installed, directory) = try package(
            id: Self.extensionId,
            named: "Real Helper Probe",
            background: """
            var hostName = \(Self.json(Self.hostName));
            try {
              var port = chrome.runtime.connectNative(hostName);
              port.onDisconnect.addListener(function (err) {
                chrome.action.setTitle({
                  title: "said:disconnected:"
                    + ((err && err.message) ? err.message : "no-error")
                });
              });
              port.onMessage.addListener(function (m) {
                chrome.action.setTitle({
                  title: "said:msg:" + JSON.stringify(m).slice(0, 400)
                });
              });
              // Reaching this line means the port object came back from the
              // shell, which proves the gate let the call through.
              chrome.action.setTitle({ title: "said:opened" });
            } catch (e) {
              chrome.action.setTitle({
                title: "said:threw:" + (e && e.message ? e.message : String(e))
              });
            }
            """
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        // 5. Persist consent into the core ledger BEFORE loading. Without
        //    this, `core.native_host` refuses with `.PermissionNotGranted`
        //    and the sheet never fires. Mirrors `ExtensionsView.swift:70`
        //    and `ExtensionApiTests:97`.
        let model = BrowserModel(storagePath: storagePath)
        let approve = ProcessInfo.processInfo.environment["ZER0_PROBE_APPROVE"] != nil
        let request = model.consentRequest(for: installed)
        let decision = defaultConsentDecision(request: request, decidedAtMs: 1_000)
        await model.applyConsent(decision)
        Self.say("consent applied: \(decision.extensionId); approve=\(approve)")

        guard let host = model.extensions else {
            throw NSError(domain: "probe", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "model.extensions was nil",
            ])
        }
        let context = try await host.load(installed, granting: decision)
        _ = host.apply(decision, to: context)
        Self.say("loaded: \(installed.manifest.name) \(installed.manifest.version)")

        let before = model.pendingNativeHost?.host.program
        Self.say("pendingNativeHost before boot: \(before ?? "<nil>")")

        // 6. Watcher: answer the NMH consent sheet the moment one appears. The
        //    gate holds the request open while the sheet is up, so a probe
        //    that never answers measures only the question — not the answer.
        var answered: [String] = []
        var firstSeenAt: Date?
        let watcher = Task { @MainActor in
            while !Task.isCancelled {
                if let pending = model.pendingNativeHost {
                    if answered.isEmpty { firstSeenAt = Date() }
                    answered.append(pending.host.program)
                    Self.say("sheet appeared: program=\(pending.host.program) "
                        + "extensionId=\(pending.extensionId) "
                        + "registrar=\(pending.host.registrar) "
                        + "registrarIsOurs=\(pending.host.registrarIsOurs) "
                        + "-> \(approve ? "allow" : "refuse")")
                    model.answerNativeHost(pending, allowed: approve)
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        defer { watcher.cancel() }

        // 7. Wait for the sheet to rise, then for the worker to report back.
        let sheetRose = await eventually(timeout: .seconds(30), polling: .milliseconds(100)) {
            model.pendingNativeHost != nil || !answered.isEmpty
        }
        Self.say("sheet rose: \(sheetRose)")

        // 8. Poll for the worker's verdict. The worker sets its action title
        //    to one of `said:opened`, `said:msg:<json>`, `said:disconnected:`
        //    or `said:threw:<err>`. Any of those is a verdict from the helper
        //    path; the message form is the JSON the helper wrote on stdout,
        //    captured for posterity.
        var workerSaid = "<nothing>"
        var lastSaid = ""
        if approve {
            let workerAnswered = await eventually(timeout: .seconds(20), polling: .milliseconds(100)) {
                let label = context.action(for: nil)?.label ?? ""
                if label != lastSaid {
                    lastSaid = label
                    Self.say("worker label: \(label)")
                }
                workerSaid = label
                return label.hasPrefix("said:")
            }
            Self.say("worker answered: \(workerSaid) (within timeout = \(workerAnswered))")

            // Keep polling a bit longer to see any follow-up. The helper
            // writes its verdict and may exit immediately, but the worker
            // observer callbacks are async and a longer window catches both
            // the message and the disconnect that follows it.
            _ = await eventually(timeout: .seconds(10), polling: .milliseconds(100)) {
                let label = context.action(for: nil)?.label ?? ""
                if label != lastSaid {
                    lastSaid = label
                    Self.say("worker label (follow-up): \(label)")
                    workerSaid = label
                }
                return false  // run until the timeout
            }
        } else {
            _ = await eventually(timeout: .seconds(5)) { false }
            workerSaid = context.action(for: nil)?.label ?? "<nothing>"
            Self.say("worker saw (refused arm): \(workerSaid)")
        }

        // 9. Surface WebKit's own errors, since a worker that never started
        //    reads the same as a worker that started and called nothing.
        for (i, err) in context.errors.enumerated() {
            let ns = err as NSError
            Self.say("context.errors[\(i)]: domain=\(ns.domain) code=\(ns.code) "
                + "userInfo=\(ns.userInfo)")
        }

        // 10. Look for the helper as a running process so the report can say
        //     "it spawned" rather than "we believe it spawned".
        Self.say("helper on disk: \(Self.realHelperPath)")
        if approve, let pid = await Self.helperPid() {
            Self.say("helper spawned, pid=\(pid)")
        } else if approve {
            Self.say("helper not seen running after approval "
                + "(it likely exited — the helper writes its verdict and quits)")
        }

        if let seen = firstSeenAt {
            Self.say("first sheet observed \(Date().timeIntervalSince(seen))s ago")
        }
        Self.say("sheets answered total: \(answered.count), programs: \(answered)")

        // 11. Fetch the helper's own os_log for the probe window. The helper
        //     does not log the verdict JSON to os_log (it writes it to stdout
        //     for the caller), but its sandbox/bootstrap lines prove spawn on
        //     a second independent channel.
        let logs = await Self.fetchHelperLogs(since: baselineIso)
        if logs.isEmpty {
            Self.say("helper os_log: <empty>")
        } else {
            Self.say("helper os_log (first 40 lines):\n" + logs.split(separator: "\n").prefix(40).joined(separator: "\n"))
        }

        // 12. Verdict — what the helper told the worker (best read from the
        //     worker's `said:msg:<json>` label). On a test runner the helper
        //     refuses with `BrowserVerificationFailed/UnknownBrowser`, which
        //     is the expected artefact of the calling process being a swift
        //     test runner and NOT `Zer0.app`. For the real verdict on
        //     `Zer0.app`'s own signature, see the standalone wrapper test.
        Self.say("=== verdict from worker label ===\n\(workerSaid)")
        Self.say("=== classification ===\n\(Self.classify(workerSaid))")

        // The plumbing-level expectations. A pass here means the sheet names
        // the real helper path and the worker observed *something* back — not
        // that the helper accepted us.
        #expect(sheetRose, "the native-host sheet never rose for the real helper")
        #expect(answered.contains(Self.realHelperPath),
            "the sheet answered something other than the real helper path: \(answered)")

        if approve {
            #expect(workerSaid.hasPrefix("said:"),
                "the worker did not report back after approval: \(workerSaid)")
        }
    }

    // MARK: - Helpers

    /// A package whose worker runs `script` after the compatibility file,
    /// exactly as a real installed extension does. The compat file is what
    /// makes `chrome.runtime.connectNative` exist on `chrome.runtime` at all.
    private func package(
        id: String,
        named name: String,
        background script: String
    ) throws -> (installed: InstalledExtension, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zer0-real-helper-\(UUID().uuidString)", isDirectory: true)
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

        try """
        {
          "manifest_version": 3,
          "name": "\(name)",
          "version": "1.0.0",
          "permissions": ["nativeMessaging"],
          "action": {},
          "background": { "service_worker": "zer0-compat.js" }
        }
        """.write(
            to: directory.appendingPathComponent("manifest.json"),
            atomically: true, encoding: .utf8
        )

        let installed = InstalledExtension(
            id: id,
            path: directory.path,
            manifest: ExtensionManifest(
                name: name,
                version: "1.0.0",
                description: nil,
                manifestVersion: 3,
                permissions: ["nativeMessaging"],
                hostPermissions: [],
                hasAction: true,
                compat: nil
            )
        )
        return (installed, directory)
    }

    /// Look for a running real helper. Best-effort: the helper writes its
    /// verdict and may exit within milliseconds, so by the time we poll it
    /// may already be gone.
    private static func helperPid() async -> pid_t? {
        let task = Process()
        task.launchPath = "/usr/bin/pgrep"
        task.arguments = ["-fl", "1Password-BrowserSupport"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(decoding: data, as: UTF8.self)
            for line in output.split(separator: "\n") {
                if let pidString = line.split(separator: " ").first,
                   let pid = pid_t(pidString) {
                    return pid
                }
            }
        } catch {
            return nil
        }
        return nil
    }

    /// The helper's os_log for the probe window. The helper does not log the
    /// verdict JSON here (that goes to stdout for the caller), but the
    /// sandbox/container bootstrap lines prove spawn on an independent channel.
    private static func fetchHelperLogs(since baselineIso: String) async -> String {
        let task = Process()
        task.launchPath = "/usr/bin/log"
        task.arguments = [
            "show",
            "--predicate", "process == \"1Password-BrowserSupport\"",
            "--start", baselineIso,
            "--style", "compact",
            "--info", "--debug",
        ]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(decoding: data, as: UTF8.self)
        } catch {
            return "<log show failed: \(error)>"
        }
    }

    /// Map the worker's label to a one-line verdict the report can carry.
    /// The interesting strings are the ones the helper itself writes:
    ///   - `BrowserVerificationFailed/UnknownBrowser` — helper does not
    ///     recognise the calling process at all
    ///   - `DoesNotMatchTeam` — calling process's Team ID is not on the list
    ///   - `UnsupportedBrowser` — bundle id not in `browsers` list and no
    ///     enrolment row exists
    ///   - a handshake message (`hello`/`get-desktop-app-status` reply) —
    ///     helper accepted
    private static func classify(_ workerSaid: String) -> String {
        if workerSaid.contains("BrowserVerificationFailed") || workerSaid.contains("UnknownBrowser") {
            return "REFUSED: helper says UnknownBrowser / BrowserVerificationFailed"
        }
        if workerSaid.contains("DoesNotMatchTeam") {
            return "REFUSED: helper says DoesNotMatchTeam (Team ID mismatch)"
        }
        if workerSaid.contains("UnsupportedBrowser") {
            return "REFUSED: helper says UnsupportedBrowser (bundle id not enrolled)"
        }
        if workerSaid.contains("Untrusted") {
            return "REFUSED: helper says Untrusted (generic refusal)"
        }
        if workerSaid.contains("said:msg:") {
            return "ACCEPTED: helper wrote a non-refusal message"
        }
        if workerSaid.contains("said:opened") {
            return "PORT-OPENED without subsequent refusal (inconclusive — short window)"
        }
        if workerSaid.contains("said:disconnected:") {
            return "DISCONNECTED: \(workerSaid); check the disconnect reason"
        }
        return "UNCLASSIFIED: \(workerSaid)"
    }

    private static func json(_ s: String) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: [s])) ?? Data(), as: UTF8.self)
            .dropFirst().dropLast().description
    }
}
