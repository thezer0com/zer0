#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import Foundation
import Observation
import Zer0Core

/// The configuration file, kept in step with the disk and with the Keychain.
///
/// Two things live here and neither of them is a decision. **When to re-read**
/// is a platform question — a `DispatchSource` here, `inotify` on Linux — and
/// **what a credential's value is** is a platform question too. Everything
/// else, including what a missing credential means and which provider a chat
/// opens on, is answered by the core through `Zer0Config`.
///
/// # The reload story
///
/// Three ways a change arrives, because no one of them is enough:
///
/// 1. **A watch on the file.** Catches an editor writing in place.
/// 2. **A watch on its directory.** Catches everything else, and that is most
///    of it: `vim`, `git checkout` and every atomic writer replace the file by
///    rename, which leaves the original inode — and any watch on it — pointing
///    at something nobody will ever read again.
/// 3. **Coming back to the front.** The backstop. A watch does not fire for a
///    file on a network mount, `fswatch` limits are real, and a `git pull`
///    while zer0 was in the background has to land. Re-reading on focus costs
///    one `stat` and covers all of it.
///
/// # Why it waits a moment
///
/// Most editors save by truncating and then writing, so between those two
/// syscalls the file is empty — and a watch fires on the truncation. Reacting
/// immediately means reading an empty file several times a minute while
/// somebody edits. So events are coalesced over a short window, and the core
/// keeps the last configuration that parsed regardless (`ConfigFile`), which is
/// what makes catching one mid-save harmless rather than merely unlikely.
@MainActor
@Observable
public final class ConfigHost {
    private let core: Zer0Config
    private let secrets: any SecretStore

    /// The last configuration that parsed. Not necessarily what is on disk this
    /// instant — see `isReadable`.
    public private(set) var config: Config
    public private(set) var diagnostics: [ConfigDiagnostic]

    /// Whether the file on disk right now could be read. False means `config`
    /// is stale and the interface has to say so rather than showing settings
    /// that disagree with the file open in somebody's editor.
    public private(set) var isReadable: Bool

    /// Which credential names the Keychain has. Names only — no value is read
    /// until something is about to be sent.
    public private(set) var availableCredentials: [String] = []

    /// Set when the Keychain itself would not answer, which is different from
    /// it not having a key. Locked keychain, denied access; not "you have not
    /// added this one yet".
    public private(set) var credentialStoreError: String?

    /// Called when a reload changed something. The chat and MCP hosts hang off
    /// this; it does not fire for a touch that changed nothing, so hitting save
    /// with no edits does not tear down every MCP connection.
    public var onChange: (() -> Void)?

    /// How long events are coalesced for. Settable so tests do not wait.
    var settleFor: Duration = .milliseconds(250)

    @ObservationIgnored private nonisolated(unsafe) var directoryWatch: (any DispatchSourceFileSystemObject)?
    @ObservationIgnored private nonisolated(unsafe) var fileWatch: (any DispatchSourceFileSystemObject)?
    @ObservationIgnored private nonisolated(unsafe) var pendingReload: Task<Void, Never>?
    @ObservationIgnored private nonisolated(unsafe) var focusObserver: (any NSObjectProtocol)?

    public convenience init() {
        let path = defaultConfigPath()
        self.init(path: path, secrets: Keychain(configPath: path))
    }

    init(path: String, secrets: any SecretStore, watching: Bool = true) {
        core = Zer0Config.open(path: path)
        self.secrets = secrets
        config = core.config()
        diagnostics = core.diagnostics()
        isReadable = core.isReadable()

        refreshCredentials()
        if watching {
            startWatching()
            observeFocus()
        }
    }

    deinit {
        pendingReload?.cancel()
        directoryWatch?.cancel()
        fileWatch?.cancel()
        // The tests build these by the dozen, and a block observer that outlives
        // its object keeps the object alive to receive notifications forever.
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
    }

    public var path: String { core.path() }

    /// Whether there is a file at all. False is a first launch, which the
    /// settings window draws as an empty state offering to write the example —
    /// not as an error.
    public var exists: Bool { core.exists() }

    /// Only what a person has to act on. Warnings are worth showing in the
    /// settings window next to the thing they are about; errors are worth a
    /// banner.
    public var errors: [ConfigDiagnostic] {
        diagnostics.filter { $0.severity == .error }
    }

    // MARK: - Reading

    /// Re-read now, and report whether anything changed.
    @discardableResult
    public func reloadNow() -> Bool {
        let changed = core.reload()
        config = core.config()
        diagnostics = core.diagnostics()
        isReadable = core.isReadable()
        refreshCredentials()
        // The file may have been replaced by rename, in which case the watch is
        // holding an inode nobody will write to again.
        rearmFileWatch()
        if changed { onChange?() }
        return changed
    }

    /// Ask the Keychain which of the names in the file it has.
    ///
    /// Names only, and this is the only call made without something specific to
    /// send: reading the values here would mean holding every key the person
    /// has in memory from launch, to answer a question about presence.
    func refreshCredentials() {
        do {
            let present = Set(try secrets.names())
            availableCredentials = core.credentialRefs().filter { present.contains($0) }
            credentialStoreError = nil
        } catch {
            // A store that will not answer is not a store with nothing in it.
            // Reporting no credentials would make every provider look
            // unconfigured and invite somebody to paste their keys in again.
            credentialStoreError = error.localizedDescription
        }
        core.setAvailableCredentials(names: availableCredentials)
    }

    /// Whether this provider can be used, and if not, precisely why.
    public func readiness(ofProvider id: String) -> Readiness {
        core.providerReadiness(id: id)
    }

    public func readiness(ofServer id: String) -> Readiness {
        core.mcpReadiness(id: id)
    }

    /// Which provider a new chat opens on, given what is actually usable here.
    public func effectiveProvider() -> ProviderConfig? {
        core.effectiveProvider()
    }

    /// The value behind a credential name, at the moment it is needed.
    ///
    /// The only call in the app that produces a secret, and it goes straight to
    /// whoever is about to make the request. Nothing caches the result, and
    /// nothing hands it to the core.
    public func secret(named name: String) throws -> String {
        try secrets.secret(named: name)
    }

    // MARK: - Writing

    /// Put a key in the Keychain under a name the file can refer to.
    ///
    /// The only function in the app that takes a secret as an argument, and it
    /// writes to the Keychain and nowhere else. There is no path from here to
    /// the config file, because `Zer0Config` has no call that accepts a value.
    public func storeSecret(_ secret: String, named name: String) throws {
        try secrets.store(secret, named: name)
        refreshCredentials()
    }

    public func removeSecret(named name: String) throws {
        try secrets.remove(named: name)
        refreshCredentials()
    }

    public func upsertProvider(_ provider: ProviderConfig) throws {
        try core.upsertProvider(provider: provider)
        reloadNow()
    }

    public func removeProvider(id: String) throws {
        try core.removeProvider(id: id)
        reloadNow()
    }

    public func setProvider(id: String, enabled: Bool) throws {
        try core.setProviderEnabled(id: id, enabled: enabled)
        reloadNow()
    }

    public func setDefaultProvider(id: String?) throws {
        try core.setDefaultProvider(id: id)
        reloadNow()
    }

    public func upsertServer(_ server: McpServerConfig) throws {
        try core.upsertMcpServer(server: server)
        reloadNow()
    }

    public func removeServer(id: String) throws {
        try core.removeMcpServer(id: id)
        reloadNow()
    }

    public func setServer(id: String, enabled: Bool) throws {
        try core.setMcpServerEnabled(id: id, enabled: enabled)
        reloadNow()
    }

    /// Write the commented example, for a machine with no file yet. Refuses
    /// when one is already there.
    public func writeExample() throws {
        try core.writeExample()
        reloadNow()
        startWatching()
    }

    /// Reveal the file, so "your settings are in a file" ends somewhere.
    ///
    /// On iOS there is no Finder to reveal in and no Files-app guarantee about
    /// where the sandbox's documents live from the person's side of the
    /// screen; the honest answer is to do nothing here and let the iOS UI that
    /// one day shows this file decide how a person reaches it.
    public func revealInFinder() {
        #if canImport(AppKit)
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        #endif
    }

    // MARK: - Watching

    private func startWatching() {
        let url = URL(fileURLWithPath: path)
        watchDirectory(url.deletingLastPathComponent().path)
        rearmFileWatch()
    }

    /// The watch that catches nearly everything.
    ///
    /// `vim`, `git checkout`, and every writer that values its data replace a
    /// file by writing a temporary one and renaming it over the top — including
    /// ours. That leaves a watch on the old inode pointing at something nobody
    /// will read again, so the directory is what has to be watched.
    private func watchDirectory(_ directory: String) {
        directoryWatch?.cancel()
        let descriptor = open(directory, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in self?.scheduleReload() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        directoryWatch = source
    }

    /// Catches an editor writing in place, and is re-armed after every reload
    /// because a rename gives the path a new inode.
    private func rearmFileWatch() {
        fileWatch?.cancel()
        fileWatch = nil
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename, .attrib],
            queue: .main
        )
        source.setEventHandler { [weak self] in self?.scheduleReload() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        fileWatch = source
    }

    /// Coalesce a burst of events into one read.
    ///
    /// A save is a truncate and then a write, and both fire. Without this the
    /// file is read while it is empty, which the core survives — it keeps the
    /// last configuration that parsed — but which would still flip
    /// `isReadable` off and on and flicker a banner at somebody who is only
    /// typing.
    private func scheduleReload() {
        pendingReload?.cancel()
        pendingReload = Task { [weak self, settleFor] in
            try? await Task.sleep(for: settleFor)
            guard !Task.isCancelled else { return }
            self?.reloadNow()
        }
    }

    /// The backstop. Watches do not fire on every filesystem, and a `git pull`
    /// while zer0 was behind another window still has to land.
    private func observeFocus() {
        // `didBecomeActive` is a real equivalent on both platforms, not a
        // stand-in: each is the system saying "this app is in front again",
        // which is the whole of what the backstop needs.
        #if canImport(AppKit)
        let name = NSApplication.didBecomeActiveNotification
        #else
        let name = UIApplication.didBecomeActiveNotification
        #endif
        focusObserver = NotificationCenter.default.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.reloadNow() }
        }
    }
}
