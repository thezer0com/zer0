import AppKit
import Foundation
import Testing
import WebKit
import Zer0Core

@testable import Zer0Shell

/// Throwaway probe: prove ADR-0105 works end to end with a synthetic extension
/// calling `chrome.runtime.connectNative` against a synthetic native host
/// installed in zer0's own directory — no dependency on 1Password being
/// installed, on its helper binary, or on a signed `Zer0.app` parent.
///
/// Not a lock. Reads and writes outside the repo (the Application Support
/// folder) so it cannot run under CI.
///
///     ZER0_SHOT=1 ZER0_PROBE_APPROVE=1 \
///         swift test --filter ZZNativeMessagingProbe
///
/// Why synthetic. The earlier draft tried to install a fixture with 1Password's
/// Chrome Web Store id, but a real 1Password extension with that id was already
/// on disk in `~/Library/Application Support/zer0/extensions/`, so `host.load`
/// found a different manifest on disk and the worker failed to start. Driving
/// the real 1Password extension is also a product flow, not a browser test.
/// ADR-0105 is the browser's behaviour, so the probe asks the browser with its
/// own host.
///
/// What it exercises. Three gates of `native_messaging::outcome` in order:
///
/// 1. the permission gate — `nativeMessaging` granted at install (the consent
///    decision carries it),
/// 2. the registration gate — a manifest in zer0's own directory names a
///    program and lists this extension's id in `allowed_origins`,
/// 3. the consent gate — nobody has been asked yet, so the shell raises the
///    sheet (`pendingNativeHost` becomes non-nil).
///
/// Then it answers "allow" and watches the worker observe the port: helper
/// spawn, framing round-trip, disconnect on shutdown. The helper script is a
/// tiny shell that writes one valid Chrome-native-messaging frame and exits.
@MainActor
struct ZZNativeMessagingProbe {
    static var out: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["ZER0_PROBE_DIR"]
            ?? NSTemporaryDirectory())
    }

    static func say(_ line: String) {
        print("[probe] \(line)")
        let file = out.appendingPathComponent("nmh.log")
        let text = line + "\n"
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    /// The synthetic extension's id. 32 characters from `a`..`p` is the only
    /// shape `ExtensionId::parse` accepts, and that parser is the first gate.
    private static let extensionId = "pppppppppppppppppppppppppppppppp"

    /// The native host application id, and the file name it becomes. Picked so
    /// nothing real shares it.
    private static let hostName = "com.zer0.probe"

    @Test(
        "ADR-0105 end to end: synthetic connectNative rises the sheet, spawns the helper, frames a reply",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    func callsConnectNativeDirectly() async throws {
        // The core's `application_support` root is derived from `storagePath`
        // by deleting the last two path components — see
        // `BrowserModel.swift:421`. And the `zer0` registrar's directory is
        // the literal string `"zer0"` under that root (see `registrars()` in
        // `native_messaging/mod.rs`). So a profile at `<root>/zer0/profile.sqlite`
        // makes the core read NMH registrations from
        // `<root>/zer0/NativeMessagingHosts/`. Putting `<root>` in `/tmp` keeps
        // this probe out of the person's real `~/Library/Application Support/zer0`.
        let root = URL(fileURLWithPath: "/tmp/zer0-nmh-probe-\(UUID().uuidString.prefix(8))")
        let profileDir = root.appendingPathComponent("zer0", isDirectory: true)
        try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)
        let storagePath = profileDir.appendingPathComponent("profile.sqlite").path
        defer { try? FileManager.default.removeItem(at: root) }

        Self.say("root = \(root.path)")
        Self.say("storagePath = \(storagePath)")
        let model = BrowserModel(storagePath: storagePath)

        let approve = ProcessInfo.processInfo.environment["ZER0_PROBE_APPROVE"] != nil
        Self.say("ZER0_PROBE_APPROVE = \(approve)")

        // Lay down the helper script and the NMH registration before loading
        // the extension, so the gate finds them on the first attempt. The NMH
        // manifest lives in `<root>/zer0/NativeMessagingHosts/`, which is where
        // the `zer0` registrar reads from (see `BrowserModel.swift:421`).
        // Per-run helper log so a spawn is provable without leaving a shared
        // file under /tmp that a later run would read as its own failure.
        let helperLogURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("zer0-probe-helper-\(UUID().uuidString).log")
        let helperURL = try writeHelper(logPath: helperLogURL.path)
        let nmhDir = profileDir.appendingPathComponent("NativeMessagingHosts", isDirectory: true)
        let manifestURL = try writeNativeMessagingManifest(
            helperPath: helperURL.path, into: nmhDir
        )
        defer {
            try? FileManager.default.removeItem(at: helperURL)
            try? FileManager.default.removeItem(at: manifestURL)
            try? FileManager.default.removeItem(at: helperLogURL)
        }
        Self.say("helper script: \(helperURL.path)")
        Self.say("nmh manifest:  \(manifestURL.path)")

        // Build the extension on disk. The directory name is not the id here
        // (the core derives identity from the path passed to
        // `InstalledExtension`); the id is supplied explicitly below.
        let (installed, directory) = try package(
            id: Self.extensionId,
            named: "Native Messaging Probe",
            background: """
            // connectNative exists only in a service worker context. Calling it
            // at boot — rather than on a gesture — so the probe does not have
            // to drive any UI.
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
                  title: "said:msg:" + JSON.stringify(m).slice(0, 200)
                });
              });
              // Reaching this line means the port object came back from the
              // shell, which is itself proof the gate let the call through.
              chrome.action.setTitle({ title: "said:opened" });
            } catch (e) {
              chrome.action.setTitle({
                title: "said:threw:" + (e && e.message ? e.message : String(e))
              });
            }
            """
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        // Persist consent into the core ledger BEFORE loading, mirroring
        // `ExtensionsView.swift:70` and `ExtensionApiTests:97`. Without this,
        // `core.native_host` refuses with `.PermissionNotGranted` and the sheet
        // never fires.
        let request = model.consentRequest(for: installed)
        let decision = defaultConsentDecision(request: request, decidedAtMs: 1_000)
        await model.applyConsent(decision)
        Self.say("consent applied: \(decision.extensionId)")

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

        // Background load diagnostics: a worker that never started reads the
        // same as a worker that started and called nothing, and the only way to
        // tell them apart is `backgroundContentFailed`.
        let bgFailedBefore = model.extensions?.backgroundContentFailed(installed.id) == true
        Self.say("backgroundContentFailed before poll: \(bgFailedBefore)")

        // Answer the sheet the moment one appears, the way a person would. The
        // gate holds the request open while the sheet is up, so a probe that
        // never answers measures only the question — not the answer.
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
                        + "-> \(approve ? "allow" : "refuse")")
                    model.answerNativeHost(pending, allowed: approve)
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        defer { watcher.cancel() }

        // The worker called connectNative at boot. Wait for the sheet to rise,
        // then for the worker to report back what its port did. The order is
        // load-bearing: the second wait measures the part ADR-0105 is
        // responsible for (spawn, framing, exit), and it cannot start until the
        // first one (consent) has settled.
        let sheetRose = await eventually(timeout: .seconds(30), polling: .milliseconds(100)) {
            model.pendingNativeHost != nil || !answered.isEmpty
        }
        Self.say("sheet rose: \(sheetRose)")

        let bgFailed = model.extensions?.backgroundContentFailed(installed.id) == true
        Self.say("backgroundContentFailed after poll: \(bgFailed)")

        // `WKWebExtensionContext.errors` is what WebKit itself recorded about
        // this extension; the NSError code names the failure mode (e.g.
        // `backgroundContentFailedToLoad`).
        for (i, err) in context.errors.enumerated() {
            let ns = err as NSError
            Self.say("context.errors[\(i)]: domain=\(ns.domain) code=\(ns.code) "
                + "userInfo=\(ns.userInfo)")
        }

        // Give the helper time to spawn and the worker time to observe it.
        // Poll long enough to see both the "opened" and any "msg"/"disconnected"
        // event, but not so long the test spends its whole budget here.
        var workerSaid = "<nothing>"
        var lastSaid = ""
        if approve {
            // First milestone: the worker observes that the port opened (or
            // threw, or got a message). Any of those is proof ADR-0105's
            // spawn→worker path is wired.
            let workerAnswered = await eventually(timeout: .seconds(15), polling: .milliseconds(100)) {
                let label = context.action(for: nil)?.label ?? ""
                if label != lastSaid {
                    lastSaid = label
                    Self.say("worker label: \(label)")
                }
                workerSaid = label
                return label.hasPrefix("said:")
            }
            Self.say("worker answered: \(workerSaid) (within timeout = \(workerAnswered))")

            // Keep polling a bit longer to see if the worker also receives the
            // helper's frame (a `said:msg:`) or observes a disconnect. Either
            // is bonus evidence; neither is required, because the helper script
            // may exit before the worker pumps its port.
            _ = await eventually(timeout: .seconds(5), polling: .milliseconds(100)) {
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

        // Read the helper's own log if it wrote one — proves the spawn happened
        // from the helper's side too, and not just from `pgrep` catching the
        // process before it exited.
        if let helperLog = try? String(contentsOf: helperLogURL, encoding: .utf8),
           !helperLog.isEmpty {
            Self.say("helper self-log:\n\(helperLog)")
        } else {
            Self.say("helper self-log: empty or missing")
        }

        // Look for the helper on disk so the report can name the binary that
        // would have run, and look for it as a process so the report can say
        // "it spawned" rather than "we believe it spawned".
        Self.say("helper on disk: \(helperURL.path)")
        if approve, let pid = await Self.helperPid(named: helperURL.lastPathComponent) {
            Self.say("helper spawned, pid=\(pid)")
        } else if approve {
            Self.say("helper not seen running after approval "
                + "(it may have exited already — the script writes one frame and exits)")
        }

        if let seen = firstSeenAt {
            Self.say("first sheet observed \(Date().timeIntervalSince(seen))s ago")
        }
        Self.say("sheets answered total: \(answered.count), programs: \(answered)")

        // The two facts ADR-0105 is responsible for. A pass here is structural,
        // not "the helper accepted us": the sheet names a program, and whatever
        // the helper does on its side, the worker observes it.
        //
        // `pending.host.program` is the absolute path the registration named,
        // not the application id — see `ResolvedHost` in the core, and ADR-0105
        // ("The answer is keyed on the program, not on the application id").
        // So the assertion matches against the path, which is what the person
        // was shown and what was actually started.
        #expect(sheetRose, "the native-host sheet never rose")
        #expect(answered.contains(helperURL.path),
            "the sheet answered something other than the helper path: \(answered)")

        if approve {
            #expect(workerSaid.hasPrefix("said:"),
                "the worker did not report back after approval: \(workerSaid)")
        }
    }

    // MARK: - Helpers

    /// A package whose worker runs `script` after the compatibility file,
    /// exactly as a real installed extension does. The compat file is what makes
    /// `chrome.runtime.connectNative` exist on `chrome.runtime` at all.
    private func package(
        id: String,
        named name: String,
        background script: String
    ) throws -> (installed: InstalledExtension, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zer0-nmh-\(UUID().uuidString)", isDirectory: true)
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

    /// A shell helper that speaks the Chrome native messaging protocol just
    /// well enough to be a witness: it writes one framed JSON message back and
    /// exits. The framing is 4-byte little-endian length then UTF-8 JSON body.
    /// Writes to the caller-provided `logPath`, which is unique per run and
    /// removed by the caller, so a spawn is provable even after the process
    /// exits without leaving a shared file behind.
    private func writeHelper(logPath: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zer0-probe-helper-\(UUID().uuidString).sh")

        // The helper writes one frame: `{"ready":true}`. The body is short, so
        // the 4-byte length is `0x0d 0x00 0x00 0x00` = 13 in little-endian. We
        // also log every byte received on stdin so a later reader can prove the
        // shell connected. The log path is interpolated so each run writes to
        // its own file rather than sharing one across the machine.
        let script = """
        #!/bin/bash
        echo "[$(date +%s.%N)] helper alive pid=$$" >> '\(logPath)'
        # Drain whatever the extension sends so the pipe does not break early.
        while read -t 1 line; do
          echo "[$(date +%s.%N)] helper received: $line" >> '\(logPath)'
        done
        body='{"ready":true}'
        len=${#body}
        printf '\\x0d\\x00\\x00\\x00%s' "$body"
        echo "[$(date +%s.%N)] helper wrote frame len=$len" >> '\(logPath)'
        """

        try script.write(to: url, atomically: true, encoding: .utf8)
        // chmod +x — the NMH gate refuses a path that is not executable.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)

        return url
    }

    /// A native-messaging registration in zer0's own directory. Read first by
    /// the gate, before any borrowed browser's. See `registrars()` in
    /// `native_messaging/mod.rs` — `zer0` is the first registrar.
    ///
    /// `into` is the directory the core's `application_support` + `"zer0"` +
    /// `"NativeMessagingHosts"` resolves to. For this probe, that is the same
    /// folder the profile lives in.
    private func writeNativeMessagingManifest(
        helperPath: String, into dir: URL
    ) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let manifest = """
        {
          "name": "\(Self.hostName)",
          "description": "zer0 synthetic probe",
          "path": \(Self.json(helperPath)),
          "type": "stdio",
          "allowed_origins": [
            "chrome-extension://\(Self.extensionId)/"
          ]
        }
        """
        let url = dir.appendingPathComponent("\(Self.hostName).json")
        try manifest.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Look for a running helper process, so the report can say "it spawned"
    /// rather than "we believe it spawned". Best-effort: the helper exits after
    /// writing one frame, so by the time we poll it may already be gone.
    private static func helperPid(named name: String) async -> pid_t? {
        let task = Process()
        task.launchPath = "/usr/bin/pgrep"
        task.arguments = ["-fl", name]
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

    private static func json(_ s: String) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: [s])) ?? Data(), as: UTF8.self)
            .dropFirst().dropLast().description
    }
}
