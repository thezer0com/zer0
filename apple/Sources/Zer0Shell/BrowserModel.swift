import AppKit
import Foundation
import Observation
import SwiftUI
import Zer0Core

enum ExtensionInstallError: LocalizedError {
    case download(status: Int)
    /// The store answered, and answered with no package.
    case storeServedNothing(id: String, chromeVersion: String)

    var errorDescription: String? {
        switch self {
        case let .download(status):
            "The extension could not be downloaded (HTTP \(status))."
        case let .storeServedNothing(id, chromeVersion):
            """
            The Chrome Web Store has no package for \(id). It answered with \
            nothing and did not say why — the two reasons it does that are an \
            item that is no longer offered, and one it will not serve to \
            Chrome \(chromeVersion), which is the version zer0 asks with.
            """
        }
    }

    /// What a fetch from the store amounts to, before a byte of it is parsed.
    ///
    /// The one door: every install in the product goes through the single
    /// `URLSession` call in `installExtension(id:)`, and this is the check on
    /// its way out of that call.
    ///
    /// It exists because `204 No Content` is a *success* status, so the range
    /// check above it waves it through and hands `install_extension` an empty
    /// buffer — which fails in the CRX parser as "not a CRX package", a
    /// sentence about a file the person never had. Measured on 2026-08-10, 15
    /// of 18 ids answered 204 when asked with the Chrome version that shipped
    /// before ADR-0078, and 2 of the 18 answer it at any version, so this is
    /// not a state that goes away by choosing a better number.
    ///
    /// Keyed on there being no bytes rather than on the status, because that is
    /// the fact the sentence claims. What is *not* claimed is a reason: this
    /// side cannot tell a withdrawn extension from a version floor, and
    /// guessing between them would be a bug with a delay on it.
    static func refusal(
        toStoreResponse data: Data,
        status: Int,
        id: String,
        chromeVersion: String
    ) -> ExtensionInstallError? {
        guard (200..<300).contains(status) else { return .download(status: status) }
        guard data.isEmpty else { return nil }
        return .storeServedNothing(id: id, chromeVersion: chromeVersion)
    }
}

/// Bridges the Rust core to SwiftUI.
///
/// The only way state changes is `send(_:)`: dispatch into the reducer, hand
/// the resulting commands to the engine, then re-read the snapshot. There is
/// no second source of truth on this side.
@MainActor
@Observable
public final class BrowserModel {
    private let core: Zer0
    let engine = EngineHost()
    /// Puts the system's file picker up for a file control the core decided to
    /// show. `@ObservationIgnored` because nothing about it is drawn — it is
    /// the one of the four page panels that AppKit owns (ADR-0089).
    ///
    /// A `var` so a test can put one in whose panel is not AppKit's. That is
    /// not a convenience: an `NSOpenPanel` presented from inside a WebKit
    /// delegate callback never comes back in a process with no
    /// `NSApplication.run`, so everything up to AppKit is asserted through this
    /// and what AppKit draws is verified by running the browser.
    @ObservationIgnored var filePanels = FilePanelPresenter()
    private(set) var extensions: ExtensionHost?
    @ObservationIgnored private(set) var storeInstall: StoreInstallHost?
    /// Programs outside the browser, for the extensions allowed to talk to
    /// them. `@ObservationIgnored` because nothing on screen reads it — what a
    /// view watches is `pendingNativeHost` below.
    @ObservationIgnored private(set) var nativeMessaging: NativeMessagingHost?

    /// Saved logins, and the only object in the app that moves a password
    /// (ADR-0064).
    @ObservationIgnored private(set) var passwords: PasswordHost?

    /// WebKit's own content blocking, compiled from the core's rule list.
    ///
    /// One object for the whole browser rather than one per space, and that is
    /// the decision rather than a shortcut. A space is a cookie jar and an
    /// identity (ADR-0007); blocking is neither. The compiled list is an
    /// immutable artefact that every controller can share, so a per-space
    /// version would compile N identical copies of the same bytecode to
    /// produce N identical answers — and it would put "which rules are on"
    /// in a second place, when what people actually want, "not on this site",
    /// already exists per host and is finer-grained than a space (ADR-0058).
    let blocking = ContentBlocking()

    /// The config file and the Keychain, which is where a provider and its key
    /// come from.
    ///
    /// Shared with `ChatSettingsModel` rather than built twice: two
    /// `ConfigHost`s over one file are two answers to "which provider answers",
    /// and they disagree the moment somebody changes a setting.
    @ObservationIgnored let configuration: ConfigHost

    /// Extensions currently unpacked on disk, whether loaded or not.
    private(set) var installedExtensions: [InstalledExtension] = []

    /// The extensions with a button on show, in the order the core draws them.
    ///
    /// Read from the core rather than filtered here: which ones appear, in what
    /// order, and that one with no `action` in its manifest never does, are all
    /// behaviour, and two shells must not disagree about any of them.
    private(set) var pinnedExtensions: [InstalledExtension] = []

    /// Bumped when WebKit says an action's icon, title or badge changed.
    ///
    /// **Nothing about an action is cached, so this is the only thing a view has
    /// to watch.** Every button reads its icon, label and badge fresh from
    /// `WKWebExtensionContext.action(for:)` as it draws, for the reason ADR-0020
    /// gives about tabs: a second copy of the truth goes stale, and a stale
    /// extension icon makes a claim about the page in front of you that is no
    /// longer so. SwiftUI needs *some* value to change before it will ask again,
    /// and this is that value and nothing else.
    private(set) var extensionActionRevision = 0

    public private(set) var snapshot: BrowserSnapshot

    /// Bumped once per dispatch, for the one screen the snapshot does not
    /// describe.
    ///
    /// A conversation is not in `BrowserSnapshot`. `ChatPage` asks the core for
    /// the thread it is showing, one call at a time, and a function call is not
    /// something the observation system can invalidate — so nothing that page
    /// reads changes when a reply arrives, and SwiftUI does not re-run a body
    /// whose observed values compare equal to what they were.
    ///
    /// **Measured, because the obvious fix does not work.** Reading `snapshot`
    /// from `ChatPage` looks like it would be enough: `refresh()` reassigns it
    /// after every dispatch. It is not. A chat message changes no tab, no space
    /// and no download, so the new snapshot compares equal to the old one and
    /// the page stayed on screen unchanged with two messages in the core behind
    /// it — while `openTab`, through the identical code path, redrew it. Both
    /// were rendered offscreen and photographed.
    ///
    /// Same pattern and same reason as `extensionActionRevision` above: SwiftUI
    /// needs *some* value to change before it will ask again, and this is that
    /// value and nothing else.
    private(set) var conversationRevision: UInt64 = 0

    /// How many browser scenes the app still owes the core.
    ///
    /// A counter and not a flag, for the reason `pageSearchRequests` is one:
    /// two ⌘Ns in a row are two windows, and a flag already `true` is a second
    /// press that does nothing.
    public private(set) var windowsToOpen: Int = 0

    /// Called by the app once it has actually opened one.
    public func openedOneWindow() {
        windowsToOpen = max(0, windowsToOpen - 1)
    }

    /// Purely presentational, so it lives here and not in the core.
    public var sidebarVisible: Bool = true
    public var showingSettings: Bool = false
    public var sessionWarningDismissed: Bool = false
    /// Which section Settings should land on. ⇧⌘, goes to Extensions: opening
    /// a window on whatever you looked at last is a small daily annoyance.
    public var settingsSection: SettingsSection = .general

    /// ⌘F, on one of the browser's own pages that searches itself.
    ///
    /// A counter and not a flag, because two presses in a row are two requests
    /// and a flag already `true` is a second press that does nothing — which is
    /// exactly the case that matters: ⌘F with the cursor somewhere else is how
    /// you get back to the field.
    public private(set) var pageSearchRequests: Int = 0

    /// Command bar state. Open is a UI concern; the ranked results are not.
    var commandBarOpen: Bool = false
    var commandBarQuery: String = ""
    private(set) var suggestions: [Suggestion] = []
    /// Which gesture opened the bar, because the same bar serves both and Enter
    /// has to mean different things. Carried, not interpreted: what each intent
    /// does is `Zer0.commandBarAction`, in the core.
    private(set) var commandBarIntent: CommandBarIntent = .openNewTab

    /// Kept pages, newest first.
    ///
    /// Held here rather than read out of the core inside a view body, for the
    /// reason the site icon cache is not observable: a list re-read during
    /// layout is state mutated from inside a view, which is a warning and a
    /// loop waiting to happen. This is refreshed when something changes it.
    private(set) var bookmarks: [Bookmark] = []

    /// Whether the shelf of kept pages is open in the sidebar.
    ///
    /// Purely presentational — where the shelf is drawn and whether it is
    /// unrolled is exactly the kind of thing two platforms may disagree about
    /// — so it lives here and not in the core, the same way `sidebarVisible`
    /// does.
    ///
    /// Closed by default. A bookmark's whole promise is that it costs no room
    /// in the list you look at all day, and a shelf that unrolls itself on
    /// every launch would be charging that rent back.
    var bookmarksVisible: Bool = false

    /// What ⌘D just did, and to what. `nil` is no panel on screen.
    ///
    /// Something has to say the press landed. Without it ⌘D is a key that
    /// changes nothing you can see, which is the failure mode ADR-0011 calls
    /// the worst there is: no error, no feedback, and the person presses three
    /// times thinking it did not register.
    private(set) var keeping: KeptPage?

    /// The page ⌘D acted on, and whether this press is what kept it.
    struct KeptPage: Equatable {
        var bookmark: Bookmark
        /// False when the page was already kept before this press. The panel
        /// says so rather than claiming a save that did not happen (ADR-0018).
        var isNew: Bool
        /// Whether the space it was kept from writes nothing else down.
        ///
        /// The panel says so out loud. Somebody in a throwaway space is
        /// entitled to be told that this one thing is going to outlive it,
        /// *before* it does — a destructive surprise warns beforehand or it is
        /// not a warning.
        var fromEphemeralSpace: Bool
    }

    /// Find-in-page. Observable, so opening it actually shows the bar.
    let finder = PageFinder()

    /// Decoded site icons. Not observable: what changes is
    /// `snapshot.iconRevision`, and a view that reads that already redraws.
    /// Observing the cache as well would mean mutating observed state from
    /// inside a view body, which is a warning and a loop waiting to happen.
    @ObservationIgnored private let siteIcons: SiteIcons

    // Not part of observable state, and nonisolated so deinit can cancel them.
    // Only ever assigned on the main actor, and Task.cancel() is safe from any
    // thread.
    @ObservationIgnored private nonisolated(unsafe) var ticker: Task<Void, Never>?
    @ObservationIgnored private nonisolated(unsafe) var saver: Task<Void, Never>?
    @ObservationIgnored private nonisolated(unsafe) var pendingSave: Task<Void, Never>?

    /// Whether the previous run ended properly. False means it crashed or was
    /// killed, and the restored session may be slightly behind.
    public private(set) var lastRunEndedCleanly = true

    /// Why the first save that reached disk in this run happened.
    ///
    /// Written once and never again, and exposed only so a test can see it.
    /// The thing worth proving about a structural change is that *it* wrote the
    /// session down rather than the twenty second periodic saver picking up the
    /// pieces, and the only way to ask that without this was to give the
    /// debounce a deadline under twenty seconds and see whether it beat it.
    /// That made the answer depend on how busy the machine was: measured in
    /// this suite, a `Task.sleep(for: .seconds(2))` on the main actor resumed
    /// twenty-four seconds late, because several hundred main-actor tests are
    /// in flight at once and the actor is one lane. The save was correct every
    /// time; the clock was not.
    ///
    /// Naming which save won is a fact about this model that stays true however
    /// late anybody looks at it, so a periodic rescue is refused by identity
    /// instead of by outrunning it.
    public private(set) var firstSaveWritten: SaveReason?

    /// The last tab a page asked to close itself, whether or not it was allowed
    /// to. Recorded on the way in and never cleared, and exposed only so a test
    /// can see it.
    ///
    /// The thing worth proving about `window.close()` is that the refusal is
    /// **ours**: the page really called it, WebKit really reported it, and the
    /// core really declined. Without this the only way to ask was to wait a
    /// second and observe that the tab was still there — which is also what a
    /// `WKUIDelegate` that was never wired up looks like, and what a page whose
    /// script never ran looks like. A test that passes when nothing happened at
    /// all is the most dangerous kind, because nobody ever looks at it again.
    ///
    /// Naming which tab was asked about is a fact that stays true however late
    /// anybody reads it, so the arrival can be waited for instead of slept
    /// through.
    public private(set) var pageAskedToCloseATab: TabId?

    /// Why the stored session could not be read, if it could not.
    ///
    /// When this is set, nothing is being saved. Browsing for an hour and only
    /// finding out at the next launch would be the worst possible way to learn
    /// it, so the UI says so now.
    public private(set) var loadError: String?

    /// Whether the session warning belongs on screen right now.
    ///
    /// Named rather than inlined into the view so the condition can be tested:
    /// a banner that silently stops appearing is a warning nobody ever gets.
    public var showsSessionWarning: Bool {
        loadError != nil && !sessionWarningDismissed
    }

    public convenience init() {
        self.init(storagePath: BrowserModel.defaultStoragePath())
    }

    /// `storagePath: nil` keeps everything in memory, which is what the tests
    /// use so they never touch a real session.
    init(storagePath: String?) {
        if let storagePath {
            core = Zer0.open(
                dbPath: storagePath,
                firstSpaceName: "Personal",
                dataStoreId: UUID().uuidString
            )
        } else {
            core = Zer0.inMemory(
                firstSpaceName: "Personal",
                dataStoreId: UUID().uuidString
            )
        }
        // The one place the system's language crosses into the core, and the
        // only thing it changes is which `_locales` bundle a package's own name
        // and description are read from. Getting the locale is the platform's
        // job; the fallback chain when it is absent is the core's.
        core.setUiLocale(locale: Locale.preferredLanguages.first)
        configuration = ChatSettingsModel.shared.configHost
        snapshot = core.snapshot()
        siteIcons = SiteIcons(bytes: { [core] space, host in
            core.icon(space: space, host: host)
        })
        // Reading this clears it, so it happens exactly once per launch.
        lastRunEndedCleanly = core.takeCleanShutdown()
        loadError = core.loadError()

        engine.emit = { [weak self] action in
            self?.send(action)
        }

        // One of the browser's own addresses that resolves to a window rather
        // than a page. Which window is the core's answer; opening it is the
        // same path ⌘, and the menu already take (ADR-0054).
        engine.raiseWindow = { [weak self] command in
            self?.perform(command)
        }

        // The core has decided a browser window exists and what is in it; this
        // is the part that gets a scene on screen. The id is queued rather than
        // passed, because SwiftUI materialises the window later and gives us no
        // way to hand a value to the view that will host it (ADR-0065).
        engine.openBrowserWindow = { [weak self] window in
            BrowserWindows.expect(window)
            self?.windowsToOpen += 1
        }
        engine.closeBrowserWindow = { window in
            BrowserWindows.window(for: window)?.close()
        }

        // The engine's context menu offers to "Search with Google" whatever
        // Settings names, which is this interface stating something false. The
        // row that replaces it asks the core, every time it is drawn, so the
        // engine somebody picked a minute ago is the one on the menu
        // (ADR-0091).
        engine.searchEngineName = { [weak self] in
            self?.currentSearchEngineName
        }

        // A real provider and real tool servers, resolved from configuration.
        //
        // `UnconfiguredChatHost` is still the answer when nothing is set up —
        // it just is not this object's job any more. `ConfiguredChatHost`
        // resolves nothing when no provider is usable, and the provider host
        // turns that into `NoProviderConfigured`, which is the same sentence
        // arrived at through the path that also works once a key exists.
        let chat = ConfiguredChatHost(config: configuration) { [weak self] action in
            self?.send(action)
        }
        chat.knownTools = { [weak self] in self?.knownTools ?? [] }
        // Where a connection has got to, into the register that decides whether
        // its tools may be offered at all.
        //
        // Adopting here rather than somewhere earlier is deliberate: the first
        // state a server ever reports is `starting`, which is the moment the
        // browser actually began talking to it, and adopting is idempotent. The
        // register used to be told none of this — nothing in the shell called
        // `adoptMcpServer` or `setMcpServerState` at all, so `toolsListed`
        // arrived for a server the register had never heard of and was dropped,
        // every configured server read as `idle`, and no failure a connection
        // could have reached a screen.
        chat.serverStateChanged = { [weak self] id, state in
            guard let self else { return }
            _ = core.adoptMcpServer(id: id)
            core.setMcpServerState(id: id, state: state)
            // Whatever is showing connections, if anything is. Pushed rather
            // than polled, and subscribed to from that side, so this object
            // does not know a settings pane exists.
            connectionsChanged?(id, state)
        }
        engine.chat = chat

        let host = ExtensionHost(model: self)
        extensions = host
        engine.configureExtensions = { [weak host] config in
            host?.attach(to: config)
        }
        // And the other direction: a tab showing a page that *belongs* to an
        // extension is not configured, it is built from that extension's own
        // configuration. `nil` refuses, which is what a base host nothing
        // loaded deserves.
        engine.extensionPageConfiguration = { [weak host] baseHost in
            host?.pageConfiguration(forBaseHost: baseHost)
        }

        // The store's own install button, made to work. The hosts it is allowed
        // on come from the core, so there is one answer to "is this the store"
        // and the script cannot be given a wider one (ADR-0062).
        // Where this platform keeps application data, which is the one thing
        // about native messaging the host answers (ADR-0105). Derived from the
        // profile rather than asked of `FileManager`, so a browser opened on a
        // temporary profile reads the registrations beside it and never the
        // ones belonging to the person running the tests.
        core.setApplicationSupportDirectory(
            path: storagePath.map {
                URL(fileURLWithPath: $0)
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .path
            }
        )

        let native = NativeMessagingHost()
        nativeMessaging = native
        // The one call that turns an application id into a path. Everything
        // else here is pipes.
        native.lookUp = { [core] extensionId, applicationId in
            core.nativeHost(extensionId: extensionId, applicationId: applicationId)
        }
        native.ask = { [weak self] extensionId, host in
            self?.askAboutNativeHost(extensionId: extensionId, host: host)
        }
        native.makeLink = { host, extensionId in
            try NativeHostProcess(host: host, extensionId: extensionId)
        }

        let store = StoreInstallHost(model: self, hosts: core.extensionStoreHosts())
        storeInstall = store
        engine.configureStoreInstall = { [weak store] config, tab in
            store?.attach(to: config, tab: tab)
        }

        // Saved logins (ADR-0064). Both closures ask the core rather than
        // answering here: which Space a tab is in decides which identity's
        // password is in play, and whether that Space writes anything down at
        // all is `Browser::records_to_disk` — the one door ADR-0023 asked for
        // rather than a fourth place the ephemeral branch is spelled out.
        let passwords = PasswordHost(
            store: KeychainPasswords(spaceName: { [weak self] in
                guard let self, let space = self.activeSpace else { return "Space" }
                return space.name
            }),
            scope: { [weak self] tab in
                guard let self, let space = self.spaceOf(tab) else { return nil }
                return self.core.passwordKeychainScope(space: space)
            },
            saveVerdict: { [weak self] tab, form in
                guard let self, let space = self.spaceOf(tab) else {
                    // No space means no answer, and the safe direction when
                    // there is no answer is not writing something down.
                    return .refuse(because: .ephemeral)
                }
                return self.core.passwordSaveVerdict(space: space, form: form)
            }
        )
        self.passwords = passwords
        engine.configurePasswords = { [weak passwords] config, tab in
            passwords?.attach(to: config, tab: tab)
        }

        // Blocking, before anything loads. Nothing is fetched and nothing is
        // decided here: the core hands over the rules, this compiles them.
        engine.configureBlocking = { [weak self] config in
            self?.blocking.attach(to: config.userContentController)
        }
        blocking.liveControllers = { [weak self] in self?.engine.contentControllers ?? [] }
        blocking.refresh(from: core)

        loadInstalledExtensions()

        // Before rehydrate, not after: a restored tab is a view being built,
        // and a view built on the shipped default when this person had turned
        // something off would be the setting quietly not applying to exactly
        // the tabs they already had open (ADR-0074).
        applyEnginePolicy()

        // Rebuild web views for whatever was restored from disk.
        engine.perform(core.rehydrate())
        tick()

        if snapshot.tabs.isEmpty {
            send(.openTab(
                space: nil,
                url: ProcessInfo.processInfo.environment["ZER0_OPEN_URL"],
                parent: nil
            ))
        }
        refresh()
        startTimers()
    }

    deinit {
        ticker?.cancel()
        saver?.cancel()
        pendingSave?.cancel()
    }

    nonisolated static func defaultStoragePath() -> String {
        // The bundle id, not a literal: stable and canary carry different ids
        // (ADR-0109), so each channel lands in its own Application Support
        // directory and a canary session never overwrites a stable one. The
        // fallback is the stable id, which is what a binary run outside its
        // `.app` most nearly is.
        let bundleId = Bundle.main.bundleIdentifier ?? "com.thezer0.browser"
        let base = storageDir(forBundleId: bundleId)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("session.sqlite").path
    }

    /// The directory a channel's session lives under, as a function of its
    /// bundle id so the isolation rule can be tested without the test
    /// runner's own bundle id leaking in — under `swift test`,
    /// `Bundle.main.bundleIdentifier` is the runner's id, not a built
    /// `.app`'s, and asserting against the literal would test the runner.
    /// `nonisolated` because it touches no actor state, only the path rule.
    nonisolated static func storageDir(forBundleId bundleId: String) -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleId, isDirectory: true)
    }

    // MARK: - The one way in

    func send(_ action: Action) {
        let previousActive = snapshot.activeTab
        let previousSpace = snapshot.activeSpace
        let previousSpaceOrder = snapshot.spaces.map(\.id)
        if case let .pageClosedWindow(tab) = action { pageAskedToCloseATab = tab }
        let commands = core.dispatch(action: action)
        engine.perform(commands)
        refresh()
        spaceTravel = Self.travel(
            from: previousSpace,
            to: snapshot.activeSpace,
            through: previousSpaceOrder
        )
        notifyExtensions(of: commands, previousActive: previousActive)
        notifyExtensions(of: action)

        if Self.isStructural(action) {
            scheduleSave()
        }
    }

    /// Whether this action changed something a restart should remember.
    ///
    /// A navigation commit or a new tab is worth writing down. A title
    /// arriving or a progress update is not: those fire constantly, and the
    /// next real change carries them along anyway.
    static func isStructural(_ action: Action) -> Bool {
        switch action {
        case .openTab, .closeTab, .moveTab, .moveTabToGroup, .setTabKind, .reopenClosedTab,
             // A tab a page opened is a tab, and a window a page opened is a
             // window: both change the arrangement a restart comes back to, and
             // the page that asked for them is not around to ask again
             // (ADR-0075).
             .pageOpenedWindow, .pageClosedWindow,
             // A page that sent itself out of its extension leaves the tab on a
             // different address in a different browsing context, which is the
             // same change `navigationCommitted` is written down for — and it
             // arrives instead of one, because the commit that would have
             // followed is the one the engine refused (ADR-0104).
             .pageLeftExtension,
             // Half of these rows open a tab or a window and the other half do
             // not, and the core is the only thing that knows which. Saving
             // after a Back that changed nothing structural costs one debounced
             // write; not saving after a link opened in a new window costs the
             // window (ADR-0091).
             .chosePageMenuItem,
             // It opens a tab, or moves you to one. Either way the arrangement
             // a restart should come back to is different afterwards.
             .openInternalPage,
             .navigationCommitted, .createSpace, .closeSpace, .renameSpace,
             .setSpaceProfile, .addRoute, .removeRoute, .setRouteEnabled,
             // ⌃3 names a destination the way clicking its chip does, so it is
             // written down for the same reason `activateSpace` is. `cycleSpace`
             // sits below with the rest: stepping is a scan, and where a scan
             // stopped is not something a restart owes anybody.
             .activateSpace, .selectSpaceByIndex, .activateTab,
             // Which windows are open and what is in them is the arrangement a
             // restart comes back to, as much as tab order is (ADR-0065).
             // `focusWindow` is not here: which window is in front changes
             // several times a minute and the next real change carries it.
             .openWindow, .closeWindow,
             // A split that came back as two loose tabs would keep every page
             // and lose the one thing the person actually arranged. The ratio
             // is sent once, on release, so it is not the flood it looks like.
             .toggleSplit, .splitWith, .focusOtherPane, .setSplitRatio,
             // A download list that lost its last few rows to a crash would be
             // a list of files you cannot find, which is the whole reason it
             // exists.
             .downloadStarted, .downloadDestinationChosen, .downloadFinished,
             .downloadFailed, .cancelDownload, .retryDownload, .resumeDownload,
             .removeDownload, .clearFinishedDownloads,
             // A thread is at least as much work as a download, and losing the
             // question somebody typed is losing something they cannot get
             // back by pressing anything.
             .openChat, .sendChatMessage, .clearConversation, .cancelChat,
             // A second thread about one page is somebody's deliberate act, and
             // the address of the tab now showing it is what brings either back
             // after a restart (ADR-0060).
             .startAnotherConversation, .showConversation,
             // And a refusal that did not survive the crash is a refusal that
             // gets asked again, which is the whole of ADR-0028.
             .decideToolCall, .setToolConsent, .forgetToolConsent,
             // A page somebody pressed a key to keep is the one thing in this
             // browser that is meant to still be there in March. Losing one to
             // a crash twenty seconds later is losing something no other state
             // can be recovered from.
             .saveBookmark, .editBookmark, .removeBookmark,
             // And an answer given to a page carries the same sentence: a
             // refusal that did not survive the crash is a refusal the site
             // gets to ask about again.
             .decideSitePermission, .setSitePermission, .forgetSitePermission:
            true
        case .titleChanged, .navigationStarted, .navigationFinished,
             .navigationFailed, .audioStateChanged, .setTabMuted, .setTabZoom,
             .navigateTo, .goBack, .goForward, .reload, .cycleTab, .cycleSpace,
             .selectTabByIndex, .tick,
             // Icons write themselves, into a file of their own, the moment
             // they arrive (ADR-0044). Nothing about them is waiting on the
             // session save, and putting one on that path would make a picture
             // landing trigger a full rewrite of the session.
             .iconsDeclared, .iconFetched, .iconFetchFailed,
             // A page's colour describes the page that is loaded, not the
             // session. A restored tab has no page yet, so writing the colour
             // down would only mean reading back a claim about a window that
             // does not exist — the same reason `last_error` is not stored.
             .colorsDeclared,
             // Four a second while a file comes down, and the next real change
             // carries the byte count along anyway.
             .downloadProgressed,
             // Whether a stopped download can be carried on from is a fact about
             // this run of the process and is never written down: there is no
             // field for it in a stored row (ADR-0101). And a page asking to
             // print changes nothing at all about the session.
             .downloadResumability, .pageAskedToPrint,
             // Same shape, faster: a reply arrives a token at a time, and the
             // save that matters is the one after it finishes.
             .chatReplyStarted, .chatReplyDelta, .chatReplyFinished,
             .chatToolCallRequested, .chatFailed,
             .toolCallFinished, .toolCallFailed,
             // What a server can do is read from configuration at launch and
             // is never written into the session (ADR-0049).
             .toolsListed,
             // The page's text is deliberately not stored at all, so the
             // arrival of one changes nothing a save would keep.
             .pageContextCaptured,
             // Nothing is written down by a page *asking*. Whatever a save
             // would keep arrives with the answer, one action later.
             .sitePermissionRequested,
             // Nothing a server asks, or is told, reaches the session file. The
             // credential goes to the Keychain, which is its own store and
             // saves itself; a certificate exception is deliberately never
             // written down at all (ADR-0094).
             .httpAuthRequested, .decideHttpAuth,
             .serverTrustRejected, .trustThisCertificate,
             // And nothing at all is written down by either half of a page
             // dialog. What a page said to you, and what you said back, are
             // facts about a call that is blocking a script right now — a
             // relaunch is not on the other end of it, so there is nothing a
             // save could keep (ADR-0089).
             .pageRaisedDialog, .answeredPageDialog,
             // Which window is in front changes on every click into a window
             // and on every key press, and the next real change carries it.
             .focusWindow,
             // A page dying changes nothing a restart should come back to. The
             // tab, its address and its place are all exactly as they were, and
             // the error is deliberately not stored — a restored tab that
             // opened saying "this page stopped responding" would be a claim
             // about a process that has not been started yet (ADR-0016).
             .pageProcessEnded,
             // Where a tab has been *is* worth writing down, and it still does
             // not schedule a write: this arrives on the heels of the
             // `navigationCommitted` that caused it, and that commit has
             // already started the two-second debounce this rides out on.
             // Scheduling a second one would double the writes for a browser
             // that is being used, and buy at most two seconds.
             .navigationStateChanged,
             // And a refusal writes nothing at all. It says the bytes we had
             // were no good, which the next save leaves out on its own.
             .navigationStateRefused:
            false
        }
    }

    /// Coalesce a burst of changes into one write.
    ///
    /// Opening five tabs in a row is one save, not five full rewrites.
    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.saveNow(reason: .structuralChange)
        }
    }

    /// Some facts change a tab without producing any command, so they would
    /// otherwise never reach an extension.
    private func notifyExtensions(of action: Action) {
        guard let extensions else { return }

        switch action {
        case let .titleChanged(tab, _):
            extensions.tabChanged(tab, [.title])
        case let .navigationCommitted(tab, _):
            extensions.tabChanged(tab, [.URL])
        case let .navigationFinished(tab):
            extensions.tabChanged(tab, [.loading])
        case let .audioStateChanged(tab, _):
            extensions.tabChanged(tab, [.playingAudio])
        case let .setTabKind(tab, _):
            extensions.tabChanged(tab, [.pinned])
        // A drop can land in a different group from the one it started in,
        // which is the same fact as pinning or unpinning the tab.
        case let .moveTabToGroup(tab, _, _, _):
            extensions.tabChanged(tab, [.pinned])
        // Listed rather than caught by `default:`. A new Action that ought to
        // reach an extension would compile against a wildcard and then simply
        // never arrive — a silence nobody would think to look for.
        case .openTab, .closeTab, .activateTab, .moveTab, .setTabMuted,
             .setTabZoom, .cycleTab, .selectTabByIndex, .reopenClosedTab,
             // A tab a page opened opens and closes through the same commands
             // an ordinary one does, so `tabOpened` and `tabClosed` already
             // reach an extension off the stream below. Reporting the action
             // here as well would say it twice.
             .pageOpenedWindow, .pageClosedWindow,
             // A tab crossing out of an extension gets a new view, and the
             // `DestroyWebView`/`CreateWebView` pair that carries it already
             // reaches an extension as `tabClosed`/`tabOpened` off the command
             // stream below. Reporting the action here as well would say it
             // twice (ADR-0104).
             .pageLeftExtension,
             // A row in a context menu opens tabs, windows and downloads
             // through the same commands everything else uses, so `tabOpened`
             // and the rest already reach an extension off the stream below.
             .chosePageMenuItem,
             // Keeping a page changes nothing about any tab, which is the
             // whole point of it: there is no `chrome.tabs` property that
             // moved, because no tab did.
             .saveBookmark, .editBookmark, .removeBookmark,
             .navigateTo, .goBack, .goForward, .reload,
             .activateSpace, .createSpace, .renameSpace, .closeSpace,
             .cycleSpace, .selectSpaceByIndex, .setSpaceProfile,
             // The window notifications an extension gets come off the command
             // stream below, where the window already has an identity to name.
             .openWindow, .closeWindow, .focusWindow,
             // A split changes nothing an extension can observe: no tab
             // property moves, and the change of focus already reaches it as
             // `didActivateTab` off the command stream below.
             .toggleSplit, .splitWith, .focusOtherPane, .setSplitRatio,
             .addRoute, .removeRoute, .setRouteEnabled,
             .tick, .navigationStarted, .navigationFailed,
             // A server asking who you are, and what it was told, are about a
             // navigation rather than about a tab. `chrome.tabs` has no
             // property that moves, and an extension told a site had asked for
             // a password would be learning where somebody signs in with no API
             // behind it.
             .httpAuthRequested, .decideHttpAuth,
             .serverTrustRejected, .trustThisCertificate,
             // `chrome.tabs` has a `favIconUrl`, and we do not fill it in: it
             // is a URL, and what we hold is bytes filed under a host. Saying
             // nothing is better than sending an extension somewhere to fetch
             // an icon we already have.
             .iconsDeclared, .iconFetched, .iconFetchFailed,
             // `chrome.tabs` has no colour on it. There is nothing to send and
             // nowhere to send it.
             .colorsDeclared,
             // Downloads are not tabs. `chrome.downloads` is a separate API we
             // do not implement, and reporting them as tab changes would be
             // worse than saying nothing.
             .downloadStarted, .downloadDestinationChosen, .downloadProgressed,
             .downloadFinished, .downloadFailed, .downloadResumability,
             .cancelDownload, .retryDownload, .resumeDownload, .removeDownload,
             .clearFinishedDownloads,
             // Printing changes nothing about any tab, and there is no
             // `chrome.printing` here to hear about it.
             .pageAskedToPrint,
             // Chat is not a tab, and there is no `chrome.*` API for it. An
             // extension being told what somebody asked a model would be a
             // leak with no API behind it.
             .openChat, .sendChatMessage, .cancelChat, .clearConversation,
             // Moving between the threads about one page re-points a chat tab's
             // address, and that address is one of ours. An extension told
             // about it would learn a conversation id and be able to reach
             // nothing with it, which is a disclosure with no API on the far
             // side (ADR-0054, ADR-0060).
             .startAnotherConversation, .showConversation,
             // Same sentence for the browser's other own pages. A tab opening
             // on one does reach an extension — as `didOpenTab` off the command
             // stream below, with the address the tab actually holds — and
             // there is no second thing to say about it here.
             .openInternalPage,
             .decideToolCall, .setToolConsent, .forgetToolConsent,
             // A page asking the machine for a camera is not a tab property.
             // `chrome.tabs` has nothing for it, and telling an extension what
             // a site asked you for would be a leak with no API behind it.
             .sitePermissionRequested, .decideSitePermission,
             .setSitePermission, .forgetSitePermission,
             // The same sentence for what a page *said*. `chrome.tabs` has
             // nothing for an `alert()`, and telling an extension what a site
             // wrote in one would be a disclosure with no API behind it.
             .pageRaisedDialog, .answeredPageDialog,
             .pageContextCaptured, .chatReplyStarted, .chatReplyDelta,
             .chatToolCallRequested, .chatReplyFinished, .chatFailed,
             .toolCallFinished, .toolCallFailed, .toolsListed,
             // A page dying is not a tab property either. `chrome.tabs` has
             // `status`, and it means loading or complete — neither of which is
             // true of a page whose process is gone. What an extension does see
             // is the reload, when a person asks for one.
             .pageProcessEnded,
             // And where a tab has been is the engine's own archive, kept so a
             // relaunch can hand it back. There is no `chrome.tabs` property it
             // corresponds to, and an extension handed one could read nothing
             // from it anyway.
             .navigationStateChanged, .navigationStateRefused:
            break
        }
    }

    /// Keep an extension's view of the browser in step with ours.
    ///
    /// The command stream already says exactly what happened, so it drives the
    /// extension notifications too rather than diffing snapshots.
    private func notifyExtensions(of commands: [EngineCommand], previousActive: TabId?) {
        guard let extensions else { return }

        for command in commands {
            switch command {
            case let .createWebView(tab, _, _):
                extensions.tabOpened(tab)
            // A tab is a tab however its view was made. An extension told about
            // the ones a person opened and not the ones a page opened would
            // have a tab list with holes in it, and the holes would be exactly
            // the sign-in windows (ADR-0075).
            case let .adoptWebView(tab):
                extensions.tabOpened(tab)
            case let .destroyWebView(tab):
                extensions.tabClosed(tab)
            case let .focusWebView(tab):
                if tab != previousActive {
                    extensions.tabActivated(tab, previous: previousActive)
                }
            case let .loadUrl(tab, _):
                extensions.tabChanged(tab, [.URL, .loading])
            case let .setMuted(tab, _):
                extensions.tabChanged(tab, [.muted])
            // `WKWebExtensionWindow` exists so an extension can tell windows
            // apart, so it has to hear when one arrives or goes (ADR-0065).
            case let .openBrowserWindow(window):
                extensions.windowOpened(window)
                extensions.windowFocused(window)
            case let .closeBrowserWindow(window):
                extensions.windowClosed(window)
            case .reload, .goBack, .goForward, .deleteDataStore, .setZoom,
                 .acceptDownload, .askDownloadDestination, .cancelDownload,
                 .startDownload, .resumeDownload, .printPage, .fetchIcon,
                 // Reading a page for a conversation changes nothing about the
                 // tab, and the rest never touch one.
                 .capturePageContext, .startChatReply, .cancelChatReply,
                 .runToolCall, .cancelToolCall, .listTools(_),
                 // Raises a window and leaves every tab exactly as it was,
                 // which is nothing an extension has an opinion about.
                 .raiseWindow(_),
                 // Answering a page and stopping a capture both change what a
                 // page may do and nothing at all about the tab.
                 .answerSitePermission, .stopCapture,
                 // Letting a page out of `alert()` unblocks a script and
                 // changes nothing an extension has an opinion about.
                 .answerPageDialog,
                 // Answering a server settles a navigation. What an extension
                 // observes is the commit or the failure that follows, which
                 // reaches it through the actions above.
                 .answerHttpAuth, .answerServerTrust:
                break
            }
        }
    }

    private func refresh() {
        snapshot = core.snapshot()
        bookmarks = core.bookmarks()
        conversationRevision &+= 1
        // Three of the four page panels are SwiftUI sheets and are drawn from
        // this snapshot by `BrowserView`. The fourth is the system's file
        // picker, which is AppKit and has to be *put up* rather than declared —
        // so it is opened from here, off the same one snapshot, rather than
        // from a second mechanism that could disagree about which question is
        // live (ADR-0089).
        filePanels.present(
            snapshot.pageDialogs,
            window: { [weak self] tab in self?.engine.webView(for: tab)?.window },
            answer: { [weak self] request, answer in
                self?.answerPageDialog(request, answer, silence: false)
            }
        )
    }

    // MARK: - Clock and persistence

    private func startTimers() {
        // Archiving is measured in hours, so a minute of granularity is plenty.
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                self?.tick()
            }
        }
        // Saving on a schedule rather than on every action: a save is a full
        // rewrite, and doing that per keystroke would be absurd.
        saver = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                self?.save()
            }
        }
    }

    private func tick() {
        send(.tick(nowMs: UInt64(Date().timeIntervalSince1970 * 1000)))
    }

    /// Best effort. A failed save must not take the browser down with it.
    public func save() {
        saveNow(reason: .periodic)
    }

    /// Write the session out now, cancelling any pending debounced save.
    public func saveNow(reason: SaveReason) {
        pendingSave?.cancel()
        pendingSave = nil

        do {
            try core.save()
            // After the write, not before: a save that threw did not happen,
            // and recording it as the first one would be claiming a write that
            // is not on disk.
            if firstSaveWritten == nil { firstSaveWritten = reason }
            if reason == .quitting {
                // Every child goes with us. A native messaging host outliving
                // the browser is a program nothing will ever stop, and its
                // parent is the only thing that was ever going to.
                nativeMessaging?.stopAll()
                // Written last, so its presence means everything before it
                // reached disk.
                core.markCleanShutdown()
            }
        } catch {
            NSLog("[zer0] session save failed (\(reason.rawValue)): \(error.localizedDescription)")
        }
    }

    // MARK: - Reading state

    var activeTab: BrowserTab? {
        guard let id = snapshot.activeTab else { return nil }
        return snapshot.tabs.first { $0.id == id }
    }

    var activeSpace: Space? {
        snapshot.spaces.first { $0.id == snapshot.activeSpace }
    }

    /// Where saved logins live, for the pane that lists them (ADR-0064).
    var passwordStore: (any PasswordStore)? { passwords?.store }

    /// The Keychain scope for the Space on screen, or `nil` when that Space
    /// records nothing. `nil` is not an error to report — it is a private
    /// Space having nothing to list.
    var activeSpaceKeychainScope: String? {
        core.passwordKeychainScope(space: snapshot.activeSpace)
    }

    /// Which Space a tab belongs to, which is which identity is in play.
    ///
    /// `nil` for a tab that is gone. The callers that matter — the ones that
    /// reach for a saved login (ADR-0064) — treat that as "no answer", and the
    /// safe direction when there is no answer is to offer nothing.
    func spaceOf(_ tab: TabId) -> SpaceId? {
        snapshot.tabs.first { $0.id == tab }?.space
    }

    /// Favorites are global; everything else belongs to the space you are in.
    ///
    /// Every one of these takes the window it is drawing for. `nil` means the
    /// one the core has in front, which is the right answer for a caller that
    /// is not inside a browser window at all — but a second window passing
    /// `nil` would list the first window's pages, which is the whole reason
    /// these grew an argument (ADR-0065).
    func favoriteTabs(in window: WindowId? = nil) -> [BrowserTab] {
        snapshot.tabs.filter { $0.kind == .favorite && $0.window == (window ?? snapshot.keyWindow) }
    }

    func pinnedTabs(in window: WindowId? = nil) -> [BrowserTab] {
        tabsInActiveSpace(of: window).filter { $0.kind == .pinned }
    }

    func todayTabs(in window: WindowId? = nil) -> [BrowserTab] {
        tabsInActiveSpace(of: window).filter { $0.kind == .today }
    }

    private func tabsInActiveSpace(of window: WindowId?) -> [BrowserTab] {
        let id = window ?? snapshot.keyWindow
        guard let space = snapshot.windows.first(where: { $0.id == id })?.activeSpace
        else { return [] }
        return snapshot.tabs.filter { $0.space == space && $0.window == id }
    }

    /// The tab with the keyboard in a window, and the pair it is showing.
    func activeTab(in window: WindowId?) -> TabId? {
        let id = window ?? snapshot.keyWindow
        return snapshot.windows.first { $0.id == id }?.activeTab
    }

    func activeSpace(in window: WindowId?) -> SpaceId {
        let id = window ?? snapshot.keyWindow
        return snapshot.windows.first { $0.id == id }?.activeSpace ?? snapshot.activeSpace
    }

    /// A split is only this window's if both of its panes are.
    func activeSplit(in window: WindowId?) -> Split? {
        let id = window ?? snapshot.keyWindow
        guard let split = snapshot.spaces.first(where: { $0.id == activeSpace(in: window) })?.split
        else { return nil }
        let mine = [split.leading, split.trailing].allSatisfy { pane in
            snapshot.tabs.first { $0.id == pane }?.window == id
        }
        return mine ? split : nil
    }

    func spaceName(_ id: SpaceId) -> String {
        snapshot.spaces.first { $0.id == id }?.name ?? "Space"
    }

    // MARK: - Site icons

    /// The icon a row should draw, or `nil` for one that should draw its
    /// letter.
    ///
    /// `space` defaults to the one you are in, which is the right answer for
    /// every list that is not a list of tabs: history and the command bar show
    /// what you would get if you opened the page *here*, and here is the only
    /// jar those rows could be talking about.
    func icon(forHost host: String?, in space: SpaceId? = nil) -> NSImage? {
        siteIcons.image(
            space: space ?? snapshot.activeSpace,
            host: host,
            revision: snapshot.iconRevision
        )
    }

    // MARK: - What a badge stands for

    /// The mark a row draws for a site, in the jar you are in.
    ///
    /// For every list that is not a list of tabs — history, bookmarks, the
    /// command bar — where "here" is the only jar the row could mean.
    func badge(forHost host: String?) -> SiteBadge.Subject {
        .site(host: host, icon: icon(forHost: host))
    }

    /// The mark a tab's row draws.
    ///
    /// **The one door.** Whether a tab wears a favicon, a letter or the
    /// browser's own mark is decided here and nowhere else: a rule spelled out
    /// at each of the places a badge is drawn is a rule with one bug per place
    /// it was not spelled out.
    ///
    /// A page whose address is ours wears our mark. The scheme is not
    /// recognised here — `internalAddress` is the core's, and it is already the
    /// single place an address is known to be one of ours — so a new
    /// `zer0://` page inherits the mark by existing, and breaks this build if
    /// it wants something else.
    ///
    /// Chat is the exception, and ADR-0060 is what makes it well defined: a
    /// conversation is *about* a page, so it wears that page's icon rather than
    /// ours.
    func badge(for tab: BrowserTab) -> SiteBadge.Subject {
        guard let address = tab.url.flatMap({ internalAddress(url: $0) }) else {
            // An ordinary page, read out of the jar the tab actually belongs
            // to. A favorite follows you between spaces and still loads in one
            // of them.
            return .site(host: tab.host, icon: icon(forHost: tab.host, in: tab.space))
        }

        switch address {
        case let .chat(conversation):
            // A tab addressing a thread that does not exist — a restored
            // `zer0://chat?conversation=7` whose conversation is gone — names
            // no page, and guessing one from the tab beside it would be worse
            // than saying nothing (ADR-0018).
            guard let conversation, let thread = self.conversation(conversation) else { return .zer0 }
            return badge(for: thread)
        case .history, .downloads, .settings:
            return .zer0
        }
    }

    /// The mark a conversation wears: the icon of the page it is about.
    ///
    /// **The anchor is the source of truth and the tab showing it has no
    /// standing.** The same thread opens from a different tab and the page it is
    /// about does not change, so the host comes from the anchor and the jar the
    /// icon is read from comes from the anchor's space — which is total, where a
    /// lookup through a tab can fail (ADR-0060).
    ///
    /// A thread about no page in particular — one typed into the command bar —
    /// has no favicon that would be true, so it falls back to the mark every
    /// other page of ours wears. A letter taken from a host it does not have,
    /// or the icon of whatever tab happens to be in front, would both be the
    /// row naming a subject nobody chose.
    ///
    /// **Nothing here can reach the network.** `icon(forHost:in:)` reads the
    /// core's cache and never asks for a fetch; whether one is ever made is
    /// decided when a page declares its icons, and for an ephemeral space the
    /// answer there is no (ADR-0044). So a conversation in a private window
    /// names its page and draws the letter, which is honest: the address is a
    /// fact and the picture was never fetched.
    func badge(for conversation: Conversation) -> SiteBadge.Subject {
        switch conversation.scope {
        case let .page(space, page):
            let host = URL(string: page)?.host()
            return .site(host: host, icon: icon(forHost: host, in: space))
        case .space:
            return .zer0
        }
    }

    // MARK: - Command bar

    func openCommandBar(intent: CommandBarIntent) {
        // Two floating panels answering two different questions at once is one
        // too many, and the bar is the newer press. Whatever was typed into the
        // other one is written down on its way out, by the one door every
        // dismissal of it goes through.
        keeping = nil
        commandBarIntent = intent
        switch intent {
        // Editing where you are means starting from where you are. The field
        // selects it all, so typing replaces it.
        case .navigateCurrentTab:
            commandBarQuery = snapshot.activeTab.map { core.addressBarText(tab: $0) } ?? ""
        case .openNewTab:
            commandBarQuery = ""
        }
        commandBarOpen = true
        updateSuggestions()
    }

    func updateSuggestions() {
        suggestions = core.suggest(query: commandBarQuery, limit: 8)
    }

    /// Act on a command-bar row.
    ///
    /// Where the destination lands is the core's call, not this file's: the
    /// intent the bar was opened with goes in, the action to dispatch comes
    /// back. `inNewTab` is the deliberate override — ⌘↩ and ⌘-click — which
    /// says "over there" whatever the bar was opened for.
    func accept(_ suggestion: Suggestion, inNewTab: Bool = false) {
        commandBarOpen = false
        send(core.commandBarAction(
            intent: inNewTab ? .openNewTab : commandBarIntent,
            suggestion: suggestion
        ))
    }

    // MARK: - Keeping a page

    /// ⌘D. Keep the page you are on, and say so.
    ///
    /// Never destructive. A second press on a page that is already kept opens
    /// the same panel saying it is already kept — removing is a button in that
    /// panel, which is a thing you have to look at to press.
    func keepCurrentPage() {
        guard let tab = snapshot.activeTab else { return }
        // Asked before, so the panel can honestly say whether this press is
        // what kept it. Asking afterwards would make every press read as new.
        let existing = core.bookmarkForTab(tab: tab)
        send(.saveBookmark(tab: nil))

        guard let bookmark = core.bookmarkForTab(tab: tab) else { return }
        keeping = KeptPage(
            bookmark: bookmark,
            isNew: existing == nil,
            fromEphemeralSpace: activeSpace?.profile.ephemeral ?? false
        )
    }

    /// Close the panel ⌘D opened. Esc, or clicking away.
    func stopKeeping() {
        keeping = nil
    }

    /// Open the same panel on a bookmark that is already kept, from the shelf.
    ///
    /// The same panel rather than a second one: "what a kept page looks like
    /// while you edit it" is one screen, and two of them would drift apart by
    /// the second change to either.
    func beginRenaming(_ bookmark: Bookmark) {
        keeping = KeptPage(bookmark: bookmark, isNew: false, fromEphemeralSpace: false)
    }

    /// Rename what is being kept, or relabel it.
    ///
    /// `tags` arrives as typed — comma separated — and is split here and
    /// normalised in the core, so "Rust, rust" is one label whichever side of
    /// the bridge you look from.
    func rename(_ bookmark: Bookmark, to title: String, tags: String) {
        send(.editBookmark(
            bookmark: bookmark.id,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            tags: Self.tagList(tags)
        ))
        // The panel holds a copy, so it has to be told what it now says.
        if var kept = keeping, kept.bookmark.id == bookmark.id {
            kept.bookmark = core.bookmarkFor(url: bookmark.url) ?? kept.bookmark
            keeping = kept
        }
    }

    /// What the tags field means. Split here rather than in the view so the
    /// field and anything else that ever takes tags agree.
    static func tagList(_ typed: String) -> [String] {
        typed
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func forget(_ bookmark: Bookmark) {
        send(.removeBookmark(bookmark: bookmark.id))
        if keeping?.bookmark.id == bookmark.id { keeping = nil }
    }

    /// What is kept for the page in this tab, if anything. Drives the verb on
    /// the page action and the state of the sidebar's context menu item.
    func bookmark(for tab: TabId) -> Bookmark? {
        core.bookmarkForTab(tab: tab)
    }

    /// ⇧⌘B. Show the shelf — which means opening the sidebar it lives in,
    /// because a shelf revealed inside a panel that is not on screen is a
    /// shortcut that does nothing.
    func showBookmarkShelf() {
        if bookmarksVisible, sidebarVisible {
            bookmarksVisible = false
            return
        }
        sidebarVisible = true
        bookmarksVisible = true
    }

    func openBookmark(_ bookmark: Bookmark, inNewTab: Bool = true) {
        if inNewTab || snapshot.activeTab == nil {
            send(.openTab(space: nil, url: bookmark.url, parent: nil))
        } else if let tab = snapshot.activeTab {
            send(.navigateTo(tab: tab, input: bookmark.url))
        }
    }

    // MARK: - Tabs

    /// ⌘T opens the command bar rather than a blank page: you almost always
    /// know where you are going. Whatever you pick lands in a tab of its own.
    public func openTab() {
        openCommandBar(intent: .openNewTab)
    }

    /// ⌘L: the same bar, seeded with where you already are so it can be edited,
    /// and Enter changes where *this* tab is pointing. That is what an address
    /// bar does everywhere else, and ⌘L is not the place to be original.
    public func focusCommandBar() {
        openCommandBar(intent: .navigateCurrentTab)
    }

    public func closeActiveTab() {
        guard let tab = snapshot.activeTab else { return }
        send(.closeTab(tab: tab))
    }

    /// Whether closing the window right now should ask first.
    ///
    /// `confirmCloseOver` was a stepper that persisted a number and changed
    /// nothing. This is what makes it mean something.
    public var shouldConfirmClosingWindow: Bool {
        let threshold = preferences.confirmCloseOver
        guard threshold > 0 else { return false }

        // Pinned and favorite tabs come back on their own, so they do not
        // count towards "you are about to lose things".
        let losable = snapshot.tabs.filter { $0.kind == .today }.count
        return losable > Int(threshold)
    }

    public var losableTabCount: Int {
        snapshot.tabs.filter { $0.kind == .today }.count
    }

    func activate(_ tab: TabId) {
        send(.activateTab(tab: tab))
    }

    func close(_ tab: TabId) {
        send(.closeTab(tab: tab))
    }

    func setKind(_ tab: TabId, _ kind: TabKind) {
        send(.setTabKind(tab: tab, kind: kind))
    }

    func toggleMute(_ tab: BrowserTab) {
        send(.setTabMuted(tab: tab.id, muted: !tab.muted))
    }

    func move(_ tab: TabId, to space: SpaceId, index: Int) {
        send(.moveTab(tab: tab, space: space, index: UInt32(max(0, index))))
    }

    /// Commit a drag.
    ///
    /// The sidebar says where the tab was let go; the order that comes back is
    /// whatever the core makes of it. Nothing on this side rearranges a list
    /// locally and hopes the core agrees — that is how rows snap back to where
    /// they were half a second after the drop.
    func drop(_ tab: TabId, into slot: TabDropSlot) {
        send(.moveTabToGroup(
            tab: tab,
            space: slot.space,
            kind: slot.kind,
            before: slot.before
        ))
    }

    public func goBack() {
        guard let tab = snapshot.activeTab else { return }
        send(.goBack(tab: tab))
    }

    public func goForward() {
        guard let tab = snapshot.activeTab else { return }
        send(.goForward(tab: tab))
    }

    public func reload(fromOrigin: Bool = false) {
        guard let tab = snapshot.activeTab else { return }
        send(.reload(tab: tab, fromOrigin: fromOrigin))
    }

    /// Copy a specific tab's address.
    public func copyURL(of tab: TabId) {
        guard let url = snapshot.tabs.first(where: { $0.id == tab })?.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    /// With no address bar on screen, copying the URL needs its own way out.
    public func copyCurrentURL() {
        guard let url = activeTab?.url else { return }
        copy(url)
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Spaces

    /// Which way through the chip row the last space change went: `1` to the
    /// right, `-1` to the left, `0` for a change that was not travel.
    ///
    /// Not a decision — a fact about what just happened, read off two
    /// consecutive snapshots. It is here rather than in the sidebar because a
    /// space changes from four places (a chip, ⌃⇥ through the keymap, the menu,
    /// and a space closing under you), and a view that watched only its own
    /// buttons would get the direction wrong for the other three.
    ///
    /// Consumed by the sidebar to decide which edge the tab list arrives from.
    /// A shell that wanted no such animation could ignore it entirely, which is
    /// the test for whether something is appearance: this is a fact, and what
    /// is done with it is not.
    private(set) var spaceTravel: Int = 0

    /// `0` when there is nowhere to have travelled from — the first snapshot,
    /// a space that no longer exists because it was just closed, or a change
    /// that was not a change. A closed space is deliberately not travel: the
    /// list did not arrive from the left, the place it was in stopped existing.
    static func travel(from: SpaceId?, to: SpaceId?, through order: [SpaceId]) -> Int {
        guard let from, let to, from != to,
              let start = order.firstIndex(of: from),
              let end = order.firstIndex(of: to)
        else { return 0 }
        return end > start ? 1 : -1
    }

    func activate(space: SpaceId) {
        send(.activateSpace(space: space))
    }

    public func createSpace(named name: String) {
        // A fresh UUID is a fresh cookie jar. Reusing one would merge the new
        // space's logins with a deleted space's leftovers.
        send(.createSpace(name: name, dataStoreId: UUID().uuidString, ephemeral: false))
    }

    // MARK: - Windows

    /// Tell the core which window the platform has in front.
    ///
    /// Cheap and idempotent: the core compares and returns nothing to carry
    /// out, so calling it on every key press and every `didBecomeKey` costs a
    /// comparison.
    public func focusWindow(_ window: WindowId) {
        guard snapshot.keyWindow != window else { return }
        send(.focusWindow(window: window))
    }

    /// ⌘N.
    public func openWindow() {
        send(.openWindow(onto: .currentSpace))
    }

    /// ⇧⌘N. A window onto a fresh ephemeral space, which is what private
    /// browsing already is here (ADR-0007, ADR-0023).
    ///
    /// The jar's name is generated in the shell for the same reason
    /// `createSpace` generates one: the core has no source of randomness and
    /// has to stay deterministic under test.
    public func openPrivateWindow() {
        send(.openWindow(onto: .newPrivateSpace(
            name: "Private", dataStoreId: UUID().uuidString
        )))
    }

    /// ⇧⌘W. Closes the window the press came from, which is the key window by
    /// the time this runs.
    ///
    /// Returns whether the core took it. It refuses the last window, and the
    /// caller has somewhere better to send the press in that case: the
    /// platform's own `performClose:`, which is what makes ⇧⌘W on the last
    /// window quit rather than do nothing at all.
    @discardableResult
    public func closeCurrentWindow() -> Bool {
        let window = snapshot.keyWindow
        send(.closeWindow(window: window))
        return !snapshot.windows.contains { $0.id == window }
    }

    /// The window went away on the platform's side — the red button, the menu,
    /// `performClose:`. The core has to hear about it or it keeps a window full
    /// of live tabs that nobody can see.
    ///
    /// Harmless when the core closed it first: it has already forgotten the id.
    public func windowClosedOnScreen(_ window: WindowId) {
        guard snapshot.windows.contains(where: { $0.id == window }) else { return }
        send(.closeWindow(window: window))
    }

    func rename(space: SpaceId, to name: String) {
        send(.renameSpace(space: space, name: name))
    }

    func closeSpace(_ space: SpaceId) {
        send(.closeSpace(space: space))
    }

    func setProfile(_ space: SpaceId, _ profile: SpaceProfile) {
        send(.setSpaceProfile(space: space, profile: profile))
    }

    // MARK: - Two pages at once

    /// The pair on screen right now, if there is one.
    ///
    /// Read off the space rather than kept here: which two tabs are shown
    /// together is state the session restores, and a second copy on this side
    /// would be a second thing to keep in step.
    public var activeSplit: Split? { activeSpace?.split }

    /// The two tabs on screen, or nil for one.
    ///
    /// What the entrance animation keys on: it changes when the pair changes
    /// and not when the divider merely moves, so a drag is not fighting a
    /// spring the whole way across.
    public var splitPanes: [TabId]? {
        activeSplit.map { [$0.leading, $0.trailing] }
    }

    /// Whether this tab is one of the two currently on screen.
    func isInSplit(_ tab: TabId) -> Bool {
        activeSplit?.contains(tab) ?? false
    }

    /// The other pane's tab, for a row that wants to say who it is beside.
    func splitCompanion(of tab: TabId) -> TabId? {
        activeSplit?.other(tab)
    }

    /// ⌘\: two pages side by side, or back to one.
    ///
    /// When the space had nothing to pair with, the core opens the second pane
    /// as a fresh tab. A blank half-window with no explanation is the one
    /// outcome worth avoiding, so the bar comes up pointed at it — the same
    /// thing ⌘T does, for the same reason.
    public func toggleSplit() {
        send(.toggleSplit)

        guard activeSplit != nil, let tab = activeTab,
              tab.url == nil, tab.pendingUrl == nil
        else { return }
        openCommandBar(intent: .navigateCurrentTab)
    }

    /// Bring a tab in beside the one you are on.
    func splitWith(_ tab: TabId) {
        send(.splitWith(tab: tab))
    }

    /// Where the divider ended up, as the leading pane's share of the width.
    /// The core clamps it; nothing here decides how far it may go.
    func setSplitRatio(_ ratio: Double) {
        guard let space = activeSpace?.id else { return }
        send(.setSplitRatio(space: space, ratio: ratio))
    }

    /// Which pane a hit-tested view belongs to, if any.
    ///
    /// By identity rather than by geometry: a click that landed in a page has
    /// to move the keyboard to that page's pane, and a `WKWebView` swallows the
    /// click before any SwiftUI gesture sees it. Comparing the view the window
    /// says it hit against the view the engine is hosting cannot disagree with
    /// what is on screen the way two sets of coordinates could.
    func pane(containing view: NSView) -> TabId? {
        guard let split = activeSplit else { return nil }

        for tab in [split.leading, split.trailing] {
            guard let hosted = engine.webView(for: tab) else { continue }
            var node: NSView? = view
            while let current = node {
                if current === hosted { return tab }
                node = current.superview
            }
        }
        return nil
    }

    // MARK: - The keyboard

    /// What a key press means, or `nil` to let it through untouched.
    ///
    /// Every chord in the keymap arrives here, not just the one chord per
    /// command that a menu item can advertise. Before this existed, ⌘[ and ⌘]
    /// were in the keymap, covered by a passing test, and reached nothing:
    /// `chord(for:)` hands the menu `Back`'s *first* binding, which is ⌘←.
    public func command(
        forKeyCode keyCode: UInt16,
        characters: String,
        modifiers: NSEvent.ModifierFlags
    ) -> UiCommand? {
        if let stop = stopLoadingCommand(keyCode: keyCode, modifiers: modifiers) {
            return stop
        }
        guard KeyPress.couldBeAShortcut(modifiers) else { return nil }

        for chord in KeyPress.chords(
            keyCode: keyCode,
            characters: characters,
            baseCharacter: KeyboardLayout.baseCharacter(for: keyCode),
            modifiers: modifiers
        ) {
            if let command = core.commandForChord(chord: chord) { return command }
        }
        return nil
    }

    /// Run whatever the press means, if it means anything **here**.
    ///
    /// `role` is not optional and has no default: the monitor listens to the
    /// whole application, and a caller that has not said which window the press
    /// came from is a caller that has not thought about it. That omission is the
    /// defect this argument exists for — ⌘W with Settings in front closed a tab
    /// behind it, and so did ⌘T, ⌘R and every other chord in the keymap.
    @discardableResult
    public func handleKeyDown(
        keyCode: UInt16,
        characters: String,
        modifiers: NSEvent.ModifierFlags,
        from role: WindowRole
    ) -> KeyDisposition {
        guard let command = command(
            forKeyCode: keyCode, characters: characters, modifiers: modifiers
        ) else { return .passOn }

        // ⇧⌘W over the last browser window. The core refuses to leave the
        // browser with nowhere to draw a page, and a chord that does nothing is
        // worse than one that does the ordinary thing — so it falls through to
        // `performClose:`, which is how every other Mac window closes and which
        // takes the app with it when it is the last one (ADR-0017).
        if command == .closeWindow, role.windowId != nil, snapshot.windows.count <= 1 {
            return .closesTheWindow
        }

        if command.reaches(role) {
            // Which window before what to do. Everything `perform` reaches for
            // — the active tab, the active space, the split — resolves through
            // the core's key window, so pointing it at the window this press
            // actually came from is what stops ⌘W closing a tab in the window
            // behind this one (ADR-0065). One line, at the one door every press
            // goes through, rather than a window argument on forty actions.
            if let id = role.windowId { focusWindow(id) }
            perform(command)
            return .handled
        }

        switch command.scope {
        case .frontmost:
            return .closesTheWindow

        case .browserWindow:
            // Swallowed rather than passed on, and the reason is AppKit: a menu
            // item's key equivalent is matched against the whole application,
            // whatever window is in front. Handing ⌘T back would only mean the
            // File menu opens the tab instead — the same invisible tab, one
            // layer further down. The monitor runs before the menu, so this is
            // the only place the press can be stopped.
            //
            // A bare key is different. Escape is `StopLoading` here, and it is
            // also how About closes and how a sheet in Settings is dismissed;
            // that arbitration belongs to whatever has focus (ADR-0013), so it
            // goes back to the window that is actually in front.
            return KeyPress.couldBeAShortcut(modifiers) ? .swallowed : .passOn

        case .opensItsOwnWindow:
            // Unreachable: `reaches` already ran it. Kept explicit rather than
            // behind a `default:` so a new scope has to be decided here.
            return .passOn
        }
    }

    /// Escape stops a load, the way it does in Chrome — but only when there is
    /// a load to stop and nothing on screen is waiting to be dismissed by it.
    ///
    /// Escape is the one bare key in the keymap, and it is also how the command
    /// bar, the find bar and Settings are closed. Claiming it unconditionally
    /// would break every one of those to reach a command people press rarely,
    /// so it is claimed only when it would otherwise do nothing at all.
    private func stopLoadingCommand(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> UiCommand? {
        let bare = !modifiers.contains(.command) && !modifiers.contains(.control)
            && !modifiers.contains(.option) && !modifiers.contains(.shift)
        guard keyCode == KeyPress.escapeKeyCode, bare else { return nil }
        guard !commandBarOpen, !finder.isOpen, !showingSettings else { return nil }
        guard let tab = activeTab, !tab.loadingComplete else { return nil }
        return .stopLoading
    }

    // MARK: - Commands

    /// Every named command the browser can be asked to do, from a menu, a
    /// shortcut or anywhere else.
    ///
    /// One switch means a new command cannot be half-wired: it either has a
    /// case here or it does not compile.
    public func perform(_ command: UiCommand) {
        switch command {
        case .newTab:
            openTab()
        case .closeTab:
            closeActiveTab()
        case .reopenClosedTab:
            send(.reopenClosedTab)
        case .openLocation:
            focusCommandBar()

        case .back:
            goBack()
        case .forward:
            goForward()
        case .reload:
            reload()
        case .reloadIgnoringCache:
            reload(fromOrigin: true)
        case .copyCurrentUrl:
            copyCurrentURL()

        case .nextTab:
            send(.cycleTab(delta: 1))
        case .previousTab:
            send(.cycleTab(delta: -1))
        case let .selectTab(index):
            send(.selectTabByIndex(index: UInt32(index)))
        case let .runPinnedExtension(index):
            runPinnedExtension(index)

        case .addBookmark:
            keepCurrentPage()
        case .toggleBookmarks:
            showBookmarkShelf()

        case .togglePinTab:
            guard let tab = activeTab else { return }
            setKind(tab.id, tab.kind == .today ? .pinned : .today)
        case .toggleMuteTab:
            guard let tab = activeTab else { return }
            toggleMute(tab)
        case .toggleBlockingHere:
            toggleBlockingOnCurrentSite()

        case .openChat:
            // Which tab "this page" means is the core's call, not ours, and so
            // is what happens when there is no page at all.
            send(.openChat(about: .currentPage, ask: nil))

        case .newWindow:
            openWindow()
        case .newPrivateWindow:
            openPrivateWindow()
        case .closeWindow:
            closeCurrentWindow()

        case .newSpace:
            createSpace(named: "New Space")
        case .nextSpace:
            send(.cycleSpace(delta: 1))
        case .previousSpace:
            send(.cycleSpace(delta: -1))
        // Which space is the nth, and what a digit past the end does, are the
        // core's — the same arrangement ⌘1 has with `selectTabByIndex`.
        case let .selectSpace(index):
            send(.selectSpaceByIndex(index: UInt32(index)))

        case .toggleSplitView:
            toggleSplit()
        case .focusOtherPane:
            send(.focusOtherPane)

        case .savePage:
            guard let tab = activeTab else { return }
            engine.savePage(tab.id, suggestedName: tab.displayTitle)
        case .printPage:
            guard let tab = snapshot.activeTab else { return }
            engine.printPage(tab)
        case .stopLoading:
            guard let tab = snapshot.activeTab else { return }
            engine.stopLoading(tab)
        case .toggleDevTools:
            guard let tab = snapshot.activeTab else { return }
            switch engine.toggleDevTools(tab) {
            // Nothing to say. It is up, or it is away, or the page in front of
            // you is native views with nothing to inspect.
            case .shown, .hidden, nil:
                break
            case .unavailable:
                reportInspectorUnavailable()
            }
        case .viewSource:
            viewSource()

        case .findInPage:
            findInPage()
        case .findNext:
            runFind(forwards: true)
        case .findPrevious:
            runFind(forwards: false)

        // Pages, not panes. Which tab they land in — a new one, or the one
        // already showing them — is the core's call, the same way ⌘E's is.
        case .showHistory:
            send(.openInternalPage(address: .history))
        case .showDownloads:
            send(.openInternalPage(address: .downloads))

        case .toggleSidebar:
            sidebarVisible.toggle()
        case .showSettings:
            settingsSection = .general
            showingSettings = true
        case .showExtensions:
            settingsSection = .extensions
            showingSettings = true

        case .zoomIn:
            adjustZoom(by: 0.1)
        case .zoomOut:
            adjustZoom(by: -0.1)
        case .zoomReset:
            guard let tab = activeTab else { return }
            send(.setTabZoom(tab: tab.id, factor: 1.0))
        }
    }

    /// Open the current page's source in a new tab.
    ///
    /// `view-source:` is not a scheme WebKit will load, so the source is
    /// fetched and handed over as a data URL instead.
    private func viewSource() {
        guard let tab = snapshot.activeTab,
              let webView = engine.webView(for: tab)
        else { return }

        webView.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] result, _ in
            MainActor.assumeIsolated {
                guard let self, let html = result as? String else { return }

                let escaped = html
                    .replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "<", with: "&lt;")
                let document = "<html><body><pre>\(escaped)</pre></body></html>"

                guard let encoded = document.addingPercentEncoding(
                    withAllowedCharacters: .alphanumerics
                ) else { return }
                self.send(.openTab(
                    space: nil,
                    url: "data:text/html;charset=utf-8,\(encoded)",
                    parent: tab
                ))
            }
        }
    }

    /// The browser's own address the active tab is showing, if it is showing
    /// one. `nil` is an ordinary web page — or no page at all.
    var activeInternalAddress: InternalAddress? {
        guard let tab = snapshot.activeTab,
              let url = snapshot.tabs.first(where: { $0.id == tab })?.url
        else { return nil }
        return internalAddress(url: url)
    }

    /// What ⌘F means on the page in front of you.
    ///
    /// On a web page it is WebKit's find. On one of the browser's own pages it
    /// cannot be: there is no document for `WKFindConfiguration` to run over, so
    /// the bar would open, search nothing, and say "not found" about a page full
    /// of rows — a lie the shape of an answer (ADR-0018).
    ///
    /// So a page that searches itself gets the request, and a page that does not
    /// gets no bar at all. Silence is the honest outcome there: nothing on
    /// screen is claiming to have looked.
    private func findInPage() {
        switch activeInternalAddress {
        case .history:
            pageSearchRequests += 1
        case .downloads, .chat, .settings:
            break
        case nil:
            finder.open(seededWith: nil)
        }
    }

    func runFind(forwards: Bool) {
        guard let tab = snapshot.activeTab else { return }
        finder.find(in: engine.webView(for: tab), forwards: forwards) { _ in }
    }

    func closeFind() {
        guard let tab = snapshot.activeTab else { return }
        engine.webView(for: tab)?.evaluateJavaScript("window.getSelection().removeAllRanges();")
        finder.close()
    }

    func setFindQuery(_ value: String) {
        finder.setQuery(value)
        runFind(forwards: true)
    }

    private func adjustZoom(by delta: Double) {
        guard let tab = activeTab else { return }
        send(.setTabZoom(tab: tab.id, factor: tab.zoomFactor + delta))
    }

    // MARK: - Preferences

    public var preferences: Preferences { core.preferences() }

    /// Read, change, write. Every setting goes through here so nothing is
    /// changed on the shell side and forgotten on the core side.
    public func updatePreferences(_ change: (inout Preferences) -> Void) {
        var next = core.preferences()
        change(&next)
        core.setPreferences(preferences: next)
        save()
        // Unconditional rather than gated on "did a blocking setting change".
        // This is the one door every preference goes through, and a gate here
        // is a list of fields somebody has to remember to extend. It costs
        // nothing when nothing changed: the rule list's identifier is a hash of
        // its own content, so an unchanged list never reaches the store.
        applyBlockingChange()
        applyEnginePolicy()
    }

    /// Hand the engine the settings a person is allowed to change
    /// (ADR-0074, ADR-0075).
    ///
    /// Beside `applyBlockingChange` and for the same reason: this is the one
    /// door every preference goes through, so there is no list of fields to
    /// remember. `EngineHost` ignores a change that changed nothing.
    func applyEnginePolicy() {
        let prefs = core.preferences()
        engine.policy = EnginePolicy.Choices(
            blockAudibleAutoplay: prefs.blockAudibleAutoplay,
            blockUnpromptedWindows: prefs.blockUnpromptedWindows
        )
    }

    /// The colour scheme to force, or nil to follow the system.
    ///
    /// The preference was being written to disk and applied to nothing, which
    /// is worse than not offering the setting at all.
    public var colorScheme: ColorScheme? {
        switch preferences.theme {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    public var searchEngines: [SearchEngine] { core.searchEngines() }
    public var searchTemplate: String { core.searchTemplate() }
    public var currentSearchEngineName: String? { core.currentSearchEngine() }

    public func setSearchTemplate(_ template: String) {
        core.setSearchTemplate(template: template)
        save()
    }

    public var archiveAfterMs: UInt64 { core.archiveAfterMs() }

    public func setArchiveAfter(_ ms: UInt64) {
        core.setArchiveAfterMs(ms: ms)
        save()
    }

    public func setBlocking(host: String, blocking: Bool) {
        core.setBlocking(host: host, blocking: blocking)
        save()
        applyBlockingChange()
    }

    /// The site the current page is on, as the core names it for an exception.
    ///
    /// Asked rather than worked out here. A shell that reached for
    /// `URL(string:)?.host` would agree with the core almost always, and the
    /// menu item would name a host the exception was not filed under in exactly
    /// the cases that matter.
    public var blockingHost: String? {
        guard let url = activeTab?.url else { return nil }
        return core.blockingHostFor(url: url)
    }

    /// Whether blocking currently applies to the page in front of you.
    public var blocksCurrentPage: Bool {
        guard let url = activeTab?.url else { return false }
        return core.blocks(url: url)
    }

    /// What the interface may say about blocking. No per-page count, because
    /// WebKit publishes none (ADR-0018, ADR-0058).
    public var blockingSummary: BlockingSummary { core.blockingSummary() }

    /// How many hosts the shipped list covers.
    public var blockedHostCount: UInt32 { core.blockedHostCount() }

    /// What the menu item says, which is a sentence about the page in front of
    /// you rather than a switch label.
    ///
    /// It names the host and the direction, so nobody has to open the item to
    /// find out which way it goes. `www.` is dropped because nobody says it out
    /// loud — the same thing the navigation error screen does — but the
    /// exception is still filed against the full host the core gave us, and the
    /// two are deliberately not the same string.
    public var blockingMenuTitle: String {
        guard let host = blockingHost else { return UiCommand.toggleBlockingHere.title }
        let shown = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return blocksCurrentPage
            ? "Turn Off Blocking on \(shown)"
            : "Turn On Blocking on \(shown)"
    }

    /// The inspector did not open, and the person deserves to know where it
    /// went.
    ///
    /// Only reachable on a WebKit that has dropped `_WKInspector`, which is the
    /// price ADR-0067 agreed to pay. It is worth an alert rather than a beep
    /// because the answer is actionable, and it names only the route that is
    /// public API and therefore still works on the very machine showing this:
    /// every page is `isInspectable`, so Safari can attach to it. The page's own
    /// Inspect Element item is deliberately not promised here — it comes from
    /// the same private preference that may well have gone with the class.
    private func reportInspectorUnavailable() {
        let alert = NSAlert()
        alert.messageText = "This version of WebKit cannot open the Web Inspector."
        alert.informativeText = """
            The page can still be inspected from Safari: turn on the Develop menu in \
            Safari's settings, and this window will be listed under this Mac.
            """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// ⇧⌘K, and the menu item beside it: turn blocking off for this site, or
    /// back on.
    ///
    /// The reload is the point, not a flourish. A content rule list only
    /// applies to loads that start after it is attached, so a toggle without
    /// one leaves the person looking at the page they were already looking at
    /// and concluding it did nothing. Reloading is also the feedback — this
    /// takes single-digit milliseconds and a spinner would be a flash.
    func toggleBlockingOnCurrentSite() {
        guard let host = blockingHost else {
            // No host to file an exception against: a blank tab, a `data:`
            // URL, an error page that never committed. Refusing is the honest
            // answer; recording an exception against nothing would put a row
            // in Settings that exempts no page at all.
            NSSound.beep()
            return
        }
        core.setBlocking(host: host, blocking: !blocksCurrentPage)
        save()
        applyBlockingChange { [weak self] in
            guard let self, let tab = self.snapshot.activeTab else { return }
            self.send(.reload(tab: tab, fromOrigin: false))
        }
    }

    /// Recompile and reattach after anything that changes the rules.
    ///
    /// Cheap when nothing actually changed: the identifier carries a hash of
    /// the rules, so an unchanged list never reaches the store.
    func applyBlockingChange(then: (@MainActor () -> Void)? = nil) {
        blocking.refresh(from: core) { then?() }
    }

    /// Most recently visited first.
    public func recentHistory(limit: Int = 200) -> [HistoryEntry] {
        core.recentHistory(limit: UInt32(max(0, limit)))
    }

    /// History ranked for what was typed, best first; the whole list, newest
    /// first, for an empty query.
    ///
    /// The ranking is the command bar's, in the core. A second one written here
    /// would be this shell having an opinion about which page answers "gh"
    /// better than the bar does, and the two would part company the first time
    /// either grew a tie-break (ADR-0015).
    public func searchHistory(_ query: String, limit: Int = 500) -> [HistoryEntry] {
        core.searchHistory(query: query, limit: UInt32(max(0, limit)))
    }

    public func forgetHistory(url: String) {
        core.forgetHistory(url: url)
        save()
    }

    /// Forget a span of it. `.everything` is a span like the others, so there
    /// is one way history is cleared rather than two that have to agree.
    ///
    /// The clock is read here and handed down: the core has none, and a browser
    /// whose idea of "the last hour" came from anywhere but the system clock
    /// would delete the wrong hour.
    public func clearHistory(_ range: HistoryRange) {
        core.clearHistory(range: range, nowMs: UInt64(Date().timeIntervalSince1970 * 1000))
        save()
    }

    // MARK: - Keymap

    /// Every binding, for building menus.
    public var keymap: [ShortcutBinding] {
        core.keymap()
    }

    /// What to print next to a menu item.
    public func chord(for command: UiCommand) -> Chord? {
        core.chordForCommand(command: command)
    }

    /// Add a chord, leaving any the command already had.
    public func bind(_ chord: Chord, to command: UiCommand) {
        core.bindShortcut(chord: chord, command: command)
    }

    /// Make this the command's only chord, which is what changing a shortcut
    /// in settings means.
    public func rebind(_ command: UiCommand, to chord: Chord) {
        core.rebindShortcut(command: command, chord: chord)
    }

    public func resetKeymap() {
        core.resetKeymap()
    }

    // MARK: - Extensions

    func loadInstalledExtensions() {
        installedExtensions = core.installedExtensions()
        pinnedExtensions = core.pinnedExtensions()
        for installed in installedExtensions {
            Task { await syncExtension(installed) }
        }
    }

    /// An action's icon, title or badge moved. Nothing is stored; this only
    /// tells the views there is something new to read.
    func extensionActionsChanged() {
        extensionActionRevision &+= 1
    }

    /// An extension asked for its popup, so the button drawing it should open
    /// one.
    ///
    /// Carried as state rather than handed to a view directly, because the ask
    /// arrives from WebKit and the answer to *where does it come from* belongs
    /// to whatever is drawing the button right now — the sidebar, or the window
    /// strip when the sidebar is away. The revision is what makes a second ask
    /// for the same extension a second event rather than a no-op.
    func requestExtensionPopup(_ id: String) {
        popupRequest = PopupRequest(extensionId: id, revision: popupRequest.map { $0.revision &+ 1 } ?? 0)
    }

    /// Which extension wants its popup on screen, if any.
    struct PopupRequest: Equatable {
        let extensionId: String
        let revision: Int
    }

    private(set) var popupRequest: PopupRequest?

    /// Taken by whichever button opened it, so a popover that has already been
    /// put on screen is not put there again on the next redraw.
    func clearExtensionPopupRequest() {
        popupRequest = nil
    }

    /// Show or hide an extension's button.
    ///
    /// Right-clicking a button and choosing Hide lands here, and so does the
    /// switch in Settings. One path, so the two cannot drift.
    func setExtensionPinned(_ id: String, _ pinned: Bool) {
        core.setExtensionPinned(id: id, pinned: pinned)
        pinnedExtensions = core.pinnedExtensions()
        scheduleSave()
    }

    func extensionIsPinned(_ id: String) -> Bool {
        core.extensionIsPinned(id: id)
    }

    /// ⇧⌘1..⇧⌘9. Silently does nothing past the end of the row, because the row
    /// is on screen and visibly has fewer buttons in it than the number that
    /// was pressed — there is no failure here to report.
    ///
    /// 1-based, as printed on the keyboard.
    func runPinnedExtension(_ index: UInt8) {
        guard index >= 1, Int(index) <= pinnedExtensions.count else { return }
        extensions?.performAction(
            for: pinnedExtensions[Int(index) - 1].id,
            tab: snapshot.activeTab
        )
    }

    /// Bring one extension's running state in line with what it was allowed.
    ///
    /// Three outcomes, and each is a state the interface has a sentence for:
    /// never asked, so it does not run; asked and granted nothing, so it does
    /// not run; asked and granted something, so it runs holding that and
    /// nothing else.
    private func syncExtension(_ installed: InstalledExtension) async {
        guard let extensions else { return }
        guard let decision = core.extensionConsent(id: installed.id),
              !consentDecisionGrantsNothing(decision: decision)
        else {
            extensions.unload(installed.id)
            return
        }

        // It runs, so it gets somewhere to be clicked — unless somebody has
        // already said otherwise, which `adoptExtensionPin` is what enforces.
        //
        // Default on, and that is the decision rather than an oversight. An
        // extension that installs with nowhere to click it is a password
        // manager you cannot open, which is the defect this whole path exists
        // to fix; Chrome ships that defect and calls the fix "pinning". The
        // opt-out is a right-click.
        if installed.manifest.hasAction, core.adoptExtensionPin(id: installed.id) {
            scheduleSave()
        }
        pinnedExtensions = core.pinnedExtensions()

        do {
            let context = try await extensions.load(installed, granting: decision)
            // A pattern the core read and WebKit would not is not granted, so
            // the record stops saying it is. Without this the review screen
            // shows a site as approved when no engine anywhere is honouring
            // it, which is the shape of lie the dialog exists to end.
            let refused = extensions.apply(decision, to: context)
            guard !refused.isEmpty else { return }
            for pattern in refused {
                core.markExtensionPatternUnreadable(id: decision.extensionId, pattern: pattern)
            }
            scheduleSave()
        } catch {
            NSLog("[zer0] could not load \(installed.manifest.name): \(error)")
        }
    }

    /// Fetch and unpack an extension, and return what has to be decided.
    ///
    /// Nothing is granted and nothing runs until `applyConsent` is called with
    /// an answer. Downloading happens here rather than in Rust so URLSession's
    /// handling of the system proxy and certificate settings applies.
    public func installExtension(id: String) async throws -> ConsentRequest {
        let url = URL(string: core.extensionDownloadUrl(id: id))!

        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse,
           let refusal = ExtensionInstallError.refusal(
               toStoreResponse: data,
               status: http.statusCode,
               id: id,
               chromeVersion: core.extensionDownloadChromeVersion()
           ) {
            throw refusal
        }

        let installed = try core.installExtension(package: data)
        installedExtensions = core.installedExtensions()
        return core.extensionConsentRequest(extension: installed)
    }

    /// Record an answer and bring the extension into line with it.
    public func applyConsent(_ decision: ConsentDecision) async {
        core.recordExtensionConsent(decision: decision)
        scheduleSave()
        guard let installed = installedExtensions.first(where: { $0.id == decision.extensionId })
        else { return }
        await syncExtension(installed)
    }

    /// What the dialog should show for something already on disk.
    public func consentRequest(for installed: InstalledExtension) -> ConsentRequest {
        core.extensionConsentRequest(extension: installed)
    }

    // MARK: - Conversations

    /// One thread, as it stands right now.
    ///
    /// Read straight from the core on every draw rather than mirrored into a
    /// property, for the reason the core gives for keeping conversations out of
    /// `BrowserSnapshot`: a thread is large, it changes on every delta, and a
    /// second copy of one is a copy that goes stale mid-answer.
    ///
    /// **What makes a delta redraw the page** is that `send` reassigns
    /// `snapshot`, and `ChatPage` reads `snapshot` for the tab it is drawing.
    /// That is load-bearing and not obvious: a view that read only this
    /// function would show the first token of a reply and then sit still.
    public func conversation(_ id: ConversationId) -> Conversation? {
        core.conversation(id: id)
    }

    /// Every thread the browser is holding, oldest first.
    ///
    /// Not on the drawing path — `ChatPage` asks for the one it is showing.
    /// This is for the screens and the tests that need to say something about
    /// all of them at once.
    public var conversations: [Conversation] { core.conversations() }

    /// Every thread about the same page as this one, most recent first, this
    /// one among them.
    ///
    /// The order is the core's and is never re-sorted here: which thread is the
    /// most recent is the same question ⌘E answers, and a list that disagreed
    /// with the chord would be two answers to one question.
    public func conversations(about id: ConversationId) -> [Conversation] {
        core.conversationsAbout(conversation: id)
    }

    /// Whether a tab is showing the page this thread is about.
    ///
    /// Asked of the core rather than worked out from `snapshot`, because "the
    /// same page" is a normalisation the core owns — comparing URL strings here
    /// would be a second opinion about it, and the half that is wrong is always
    /// the half on screen.
    public func pageIsOpen(for id: ConversationId) -> Bool {
        core.conversationPageIsOpen(conversation: id)
    }

    /// What the page this thread is about calls itself, when anything can say.
    ///
    /// `nil` is a real answer and not a gap: nobody has ever told the browser
    /// what that page is called. The screen falls back to the site, which is a
    /// fact about the address — it does not dress the address up as a name
    /// (ADR-0018).
    ///
    /// Asked of the core for the reason `pageIsOpen(for:)` is: finding the tab
    /// showing a thread's page is the same normalisation ⌘E anchors with, and a
    /// second opinion about it here would be the half that is wrong being the
    /// half on screen.
    public func pageTitle(for id: ConversationId) -> String? {
        core.conversationPageTitle(conversation: id)
    }

    /// Everything the browser can honestly say about one tool, separated by who
    /// said it. `nil` for a tool no connected server publishes — which is what
    /// a consent card draws when it has nothing of its own to say.
    public func disclosure(server: String, tool: String) -> ToolDisclosure? {
        core.mcpToolDisclosure(server: server, tool: tool)
    }

    // MARK: - What a tool server may do

    /// What the configured MCP servers last said they can do.
    ///
    /// Read rather than cached: the list changes when a server connects, and a
    /// copy kept here would be a second answer to a question the core already
    /// answers.
    public var knownTools: [ToolDescriptor] { core.knownTools() }

    /// Where one tool server has got to, straight off the register.
    public func mcpServerState(_ server: String) -> McpServerState {
        core.mcpServerState(id: server)
    }

    /// Told whenever a tool server's state changes.
    ///
    /// Set by whatever is drawing connections, which is why the arrow points
    /// this way: a screen subscribes to the browser, and the browser has never
    /// heard of the screen. `@ObservationIgnored` because it is a wire and not
    /// a thing anybody draws.
    @ObservationIgnored
    public var connectionsChanged: (@MainActor (String, McpServerState) -> Void)?

    /// Every remembered answer about a tool, for the screen that reviews them.
    public var toolGrants: [ToolGrant] { core.toolGrants() }

    /// What this extension currently holds, or `nil` if nobody has decided yet.
    public func consent(for id: String) -> ConsentDecision? {
        core.extensionConsent(id: id)
    }

    /// Take one permission back, all the way down to the running context.
    public func revokeExtensionPermission(_ id: String, _ kind: PermissionKind, _ key: String) {
        guard core.revokeExtensionPermission(id: id, kind: kind, key: key) else { return }
        Task { await resyncExtension(id) }
    }

    /// Give one back, from the same screen that took it away.
    public func grantExtensionPermission(_ id: String, _ kind: PermissionKind, _ key: String) {
        guard core.grantExtensionPermission(id: id, kind: kind, key: key) else { return }
        Task { await resyncExtension(id) }
    }

    private func resyncExtension(_ id: String) async {
        scheduleSave()
        guard let installed = installedExtensions.first(where: { $0.id == id }) else { return }
        await syncExtension(installed)
    }

    func uninstallExtension(id: String) throws {
        extensions?.unload(id)
        try core.uninstallExtension(id: id)
        installedExtensions = core.installedExtensions()
        scheduleSave()
    }

    /// The extension a URL points at, if it is a Chrome Web Store listing.
    public func extensionId(inURL url: String) -> String? {
        core.extensionIdForUrl(url: url)
    }

    /// The extension the active tab's page is a listing for, installed or not.
    ///
    /// The question the banner and the injected button both need, now that
    /// either can be about something already here: *is this page about an
    /// extension at all*. What to offer about it is a second question, and its
    /// answer is `standing(of:)`.
    public var listingExtensionId: String? {
        guard let url = activeTab?.url else { return nil }
        return core.extensionIdForUrl(url: url)
    }

    /// The extension the active tab is showing in the Chrome Web Store, if it
    /// is showing one and it is not already installed.
    public var offeredExtensionId: String? {
        guard let id = listingExtensionId,
              !installedExtensions.contains(where: { $0.id == id })
        else { return nil }
        return id
    }

    // MARK: - The store's own install button

    /// What the injected script found, per tab. See `StoreInstall.swift`.
    private var storeControls: [TabId: StoreControlState] = [:]

    func storeControlChanged(tab: TabId, to state: StoreControlState) {
        storeControls[tab] = state
    }

    /// Whether the page in `tab` is carrying an install button of ours.
    ///
    /// `unknown` until the script speaks. It resolves to `absent` once the tab
    /// has finished loading and nothing has been said, because a page that
    /// finished arriving without the script reporting is a page where the
    /// script did not run — and that is precisely when the banner has to be
    /// there. A failed injection degrades to the offer that shipped before it,
    /// not to nothing.
    func storeControlState(inTab tab: TabId) -> StoreControlState {
        let state = storeControls[tab] ?? .unknown
        guard state == .unknown else { return state }
        let finished = snapshot.tabs.first { $0.id == tab }?.loadingComplete ?? false
        return finished ? .absent : .unknown
    }

    /// Tell the button in the page what it should say.
    func reportStoreInstall(_ outcome: StoreInstallHost.Outcome, tab: TabId) {
        guard let webView = engine.webView(for: tab) else { return }
        storeInstall?.report(outcome, to: webView)
    }

    // MARK: - Adding, deciding, removing

    /// What this browser holds for one extension: nothing, undecided, running,
    /// or decided and holding nothing.
    ///
    /// The core's answer, because it is the same question the row in Settings,
    /// the banner and the button injected into the store's own page all ask —
    /// and a button drawn inside somebody else's page must never be able to
    /// answer it from the page (ADR-0062).
    public func standing(of id: String) -> ExtensionStanding {
        core.extensionStanding(id: id)
    }

    /// An install or a review, from the press that started it to the decision
    /// that ends it.
    ///
    /// **Here rather than inside `InstallBanner`, and that is the whole fix.**
    /// The banner is mounted from the offer, and the offer stops existing
    /// halfway through: the moment the package lands on disk the extension is
    /// installed, so `offeredExtensionId` goes `nil`, so the view carrying the
    /// consent sheet is torn down before the sheet is ever presented. What was
    /// left was an extension on disk holding nothing, a Settings row reading
    /// *"You have not said what it may do yet"*, and a button in the page stuck
    /// on *Adding…* waiting for an outcome that could not arrive.
    ///
    /// A decision outlives the offer that led to it, so it cannot live in
    /// something the offer keeps alive.
    private(set) var extensionFlow: ExtensionFlow?

    struct ExtensionFlow: Identifiable, Equatable {
        let id: String
        /// The tab whose page started this, so the button there can be told how
        /// it went. `nil` when the offer was taken in the banner instead.
        let tab: TabId?
        /// Whether this flow is what put the package on disk.
        ///
        /// Backing out of the sheet removes what nobody agreed to have. It does
        /// not remove something that was already installed and is merely being
        /// reviewed — closing a window is not an instruction to uninstall.
        let arrivedNow: Bool
        var phase: Phase

        enum Phase: Equatable {
            case installing
            case deciding(ConsentRequest)
            case decided(name: String, running: Bool)
            case failed(message: String)
        }

        var request: ConsentRequest? {
            if case let .deciding(request) = phase { return request }
            return nil
        }

        /// Still going, so a second press must not start anything on top of it.
        var isUnfinished: Bool {
            switch phase {
            case .installing, .deciding: true
            case .decided, .failed: false
            }
        }
    }

    /// The flow that has to stay on screen wherever the person goes.
    ///
    /// Only an *unfinished* one. Something still downloading, or waiting on a
    /// sheet, has to keep its window whatever the tab does — the store is a
    /// single-page app and the listing that started it can be gone before the
    /// package has arrived. An outcome is different: it belongs to the listing
    /// it happened on, and a capsule reading "1Password is ready" following
    /// somebody onto every page afterwards is chrome that stopped paying for
    /// itself.
    var unfinishedExtensionFlowId: String? {
        guard let flow = extensionFlow, flow.isUnfinished else { return nil }
        return flow.id
    }

    /// Start adding this extension, or — if it is already here and undecided —
    /// go straight to the decision it is waiting on.
    ///
    /// One function, whether the press came from the button in the store's page
    /// or from the banner's own Add. There is no second install path, and
    /// therefore no path that reaches an extension without the sheet (ADR-0028).
    func beginExtensionFlow(id: String, from tab: TabId?) {
        // A second press while one is in flight is a second press, not a second
        // install.
        if let flow = extensionFlow, flow.id == id, flow.isUnfinished { return }

        // Already on disk with nobody having answered for it: there is nothing
        // to download, and offering to add what is already here would be the
        // page lying about the state of the browser.
        if let installed = installedExtensions.first(where: { $0.id == id }),
           consent(for: id) == nil {
            extensionFlow = ExtensionFlow(
                id: id,
                tab: tab,
                arrivedNow: false,
                phase: .deciding(consentRequest(for: installed))
            )
            return
        }

        extensionFlow = ExtensionFlow(id: id, tab: tab, arrivedNow: true, phase: .installing)
        reportFlow(.working)
        Task {
            do {
                // On disk and holding nothing. It does not run until the sheet
                // is answered.
                let request = try await installExtension(id: id)
                setFlowPhase(id, .deciding(request))
            } catch {
                setFlowPhase(id, .failed(message: error.localizedDescription))
                reportFlow(.failed)
            }
        }
    }

    /// The sheet was answered.
    ///
    /// Refusing everything is one of the outcomes, not a failure: the extension
    /// is added, it holds nothing and it does not run, and every surface says
    /// exactly that.
    func answerExtensionConsent(_ decision: ConsentDecision) {
        guard var flow = extensionFlow, let request = flow.request else { return }
        let running = !consentDecisionGrantsNothing(decision: decision)
        flow.phase = .decided(name: request.extensionName, running: running)
        extensionFlow = flow
        // What was decided, which is a different thing from whether it worked.
        reportFlow(.afterDeciding(running: running))
        Task { await applyConsent(decision) }
    }

    /// The sheet was closed without adding.
    ///
    /// Nobody agreed to have it, so a package this flow downloaded does not stay
    /// on disk — and the offer goes back, in the page and in the banner, because
    /// the browser is once again a browser without it.
    func cancelExtensionConsent() {
        guard let flow = extensionFlow, let request = flow.request else { return }
        guard flow.arrivedNow else {
            // A review of something that was already here. Closing changes
            // nothing, including what the button says.
            reportFlow(.undecided)
            extensionFlow = nil
            return
        }
        do {
            try uninstallExtension(id: request.extensionId)
            reportFlow(.offer)
            extensionFlow = nil
        } catch {
            setFlowPhase(flow.id, .failed(message: "\(request.extensionName) was not added, and "
                + "could not be removed from disk: \(error.localizedDescription)"))
            reportFlow(.failed)
        }
    }

    /// Take the outcome off the screen. The extension stays exactly as it is.
    func dismissExtensionFlow() {
        guard let flow = extensionFlow, !flow.isUnfinished else { return }
        extensionFlow = nil
    }

    /// A removal waiting to be confirmed.
    ///
    /// Removing takes the extension's own stored data with it and there is no
    /// undo, so it warns before rather than after — the same rule
    /// `DestructiveButton` encodes for every red button in the window.
    ///
    /// It has to be state rather than a `@State` inside a button, because the
    /// button that starts this one is drawn inside somebody else's page and
    /// cannot host a dialog. It also closes a race the page opens: the button
    /// reflects what the machine held when the page loaded, so a press could in
    /// principle arrive after that changed. Confirming means the worst such a
    /// race can do is show a question about something that is not there, which
    /// answers nothing and destroys nothing.
    private(set) var pendingExtensionRemoval: PendingExtensionRemoval?

    struct PendingExtensionRemoval: Identifiable, Equatable {
        let id: String
        let name: String
        /// The page that asked, so its button can be put back if the answer is
        /// no. `nil` when the ask came from a window of ours.
        let tab: TabId?
    }

    // MARK: - Starting a program outside the browser

    /// The program somebody is being asked about, if one is.
    ///
    /// Stored rather than read off the snapshot, unlike the three page-driven
    /// panels: the question does not belong to a page or to a tab, it belongs
    /// to a request that is being held open in `NativeMessagingHost` while the
    /// answer is found. The same shape, and the same reason, as
    /// `extensionFlow`.
    private(set) var pendingNativeHost: PendingNativeHost?

    /// One program, one extension, one question.
    struct PendingNativeHost: Identifiable, Equatable {
        let extensionId: String
        /// The extension's own resolved name, which is what is on its button.
        let extensionName: String
        let host: ResolvedHost

        /// Identity is what the decision is about. Two application ids that
        /// resolve to one program are one question, so they are one sheet.
        var id: String { "\(extensionId)\u{0}\(host.program)" }
    }

    private func askAboutNativeHost(extensionId: String, host: ResolvedHost) {
        pendingNativeHost = PendingNativeHost(
            extensionId: extensionId,
            extensionName: installedExtensions
                .first { $0.id == extensionId }?.manifest.name ?? "This extension",
            host: host
        )
    }

    /// Somebody answered. Written down before anything starts, so a relaunch
    /// does not ask again — and so a refusal stays a refusal (ADR-0028).
    func answerNativeHost(_ pending: PendingNativeHost, allowed: Bool) {
        pendingNativeHost = nil
        core.recordNativeHostDecision(decision: NativeHostDecision(
            extensionId: pending.extensionId,
            program: pending.host.program,
            allowed: allowed,
            decidedAtMs: UInt64(Date().timeIntervalSince1970 * 1000)
        ))
        scheduleSave()
        nativeMessaging?.answer(
            extensionId: pending.extensionId,
            program: pending.host.program,
            allowed: allowed
        )
    }

    /// The sheet went away without an answer.
    ///
    /// The request is refused and **nothing is written down**, so the next
    /// press asks again. That is the difference between "not now" and Don't
    /// Allow, and it is why Escape is bound at all: the request is being held
    /// open while the sheet is up, and a sheet that could be dismissed without
    /// answering would be an extension waiting for ever.
    func dismissNativeHostQuestion(_ pending: PendingNativeHost) {
        pendingNativeHost = nil
        nativeMessaging?.answer(
            extensionId: pending.extensionId,
            program: pending.host.program,
            allowed: false
        )
    }

    /// The programs an extension has been allowed to start, for the row that
    /// says what it holds.
    func allowedPrograms(of extensionId: String) -> [String] {
        core.allowedNativeHostPrograms(extensionId: extensionId)
    }

    // MARK: - A server asking who you are

    /// The password panel that is up, if one is.
    ///
    /// Read straight off the snapshot rather than kept here, for the reason
    /// `pendingSitePermission` is: one answer to "is something being asked", so
    /// a panel cannot outlive the challenge behind it.
    var pendingHttpAuth: PendingAuth? {
        snapshot.httpAuthPrompt.map(PendingAuth.init(prompt:))
    }

    /// Sign in, and keep it if that was asked for and allowed.
    ///
    /// **The credential goes to the engine and to the Keychain, and never to
    /// the core.** It is handed to the ledger first, then the core is told only
    /// that somebody answered — `AuthChoice` has no field a password fits in.
    /// That is ADR-0064's guarantee, held one layer up.
    func signInToServer(
        _ request: UInt64,
        username: String,
        password: String,
        remember: Bool
    ) {
        let prompt = snapshot.httpAuthPrompt
        engine.authChallenges.supply(
            URLCredential(user: username, password: password, persistence: .none),
            for: request
        )

        // Written down before the core is told, because telling the core drops
        // the prompt and the origin to key by is on it. Through the same store
        // saved logins use, so an HTTP-auth sign-in and a form login for one
        // origin are one account list rather than two (ADR-0064).
        if remember, let prompt, prompt.request == request,
           let origin = authKeychainOrigin(prompt: prompt), let host = passwords {
            try? host.save(
                SavedPassword(username: username, password: password),
                for: origin,
                tab: prompt.tab
            )
        }

        send(.decideHttpAuth(request: request, choice: .supply))
    }

    /// Nobody answered. The server is told so, and the page gets whatever it
    /// serves to strangers — which is a page, rather than a tab that never
    /// finishes loading.
    func cancelServerSignIn(_ request: UInt64) {
        send(.decideHttpAuth(request: request, choice: .cancel))
    }

    // MARK: - A certificate that did not check out

    /// What was wrong with the certificate that stopped the tab in front of
    /// you, when a certificate is what stopped it.
    var certificateReport: CertificateReport? { snapshot.certificateReport }

    /// Wave one certificate through, in this space, until the browser quits.
    ///
    /// Offered by the screen only when the core said it may be, which today is
    /// loopback and nowhere else. Nothing here decides that.
    func trustThisCertificate(tab: TabId, origin: String, fingerprint: String) {
        send(.trustThisCertificate(tab: tab, origin: origin, fingerprint: fingerprint))
    }

    /// Ask before removing. The words are here because they are the same words
    /// wherever the red button was pressed.
    func askToRemoveExtension(id: String, from tab: TabId?) {
        guard let installed = installedExtensions.first(where: { $0.id == id }) else { return }
        pendingExtensionRemoval = PendingExtensionRemoval(
            id: id,
            name: installed.manifest.name,
            tab: tab
        )
    }

    /// Backing out of the question. The button in the page goes back to what it
    /// was showing, because nothing about the machine changed.
    func cancelExtensionRemoval() {
        guard let asked = pendingExtensionRemoval else { return }
        pendingExtensionRemoval = nil
        guard let tab = asked.tab, let host = storeInstall else { return }
        reportStoreInstall(host.resting(standing(of: asked.id)), tab: tab)
    }

    /// Go through with it.
    func confirmExtensionRemoval() {
        guard let asked = pendingExtensionRemoval else { return }
        pendingExtensionRemoval = nil
        removeExtension(id: asked.id, from: asked.tab)
    }

    /// Remove an extension and put the offer back where it was.
    ///
    /// Private so that nothing reaches a removal without the question above it.
    private func removeExtension(id: String, from tab: TabId?) {
        tell(.removing, tab: tab)
        do {
            try uninstallExtension(id: id)
            extensionFlow = nil
            tell(.offer, tab: tab)
        } catch {
            extensionFlow = ExtensionFlow(
                id: id,
                tab: tab,
                arrivedNow: false,
                phase: .failed(message: "Could not remove it: \(error.localizedDescription)")
            )
            tell(.failed, tab: tab)
        }
    }

    /// Only ever moves the flow it was started for, so a result arriving late
    /// for an extension nobody is looking at any more changes nothing.
    private func setFlowPhase(_ id: String, _ phase: ExtensionFlow.Phase) {
        guard var flow = extensionFlow, flow.id == id else { return }
        flow.phase = phase
        extensionFlow = flow
    }

    private func reportFlow(_ outcome: StoreInstallHost.Outcome) {
        tell(outcome, tab: extensionFlow?.tab)
    }

    /// Nothing to report when the press came from the banner rather than from a
    /// page. Named apart from `reportStoreInstall` rather than overloading it:
    /// two functions differing only by an optional is a pair that resolves to
    /// itself the day somebody changes one of the types.
    private func tell(_ outcome: StoreInstallHost.Outcome, tab: TabId?) {
        guard let tab else { return }
        reportStoreInstall(outcome, tab: tab)
    }

    // MARK: - What a site was allowed to point at you

    /// The question a page is waiting on, or `nil`.
    ///
    /// Read off the snapshot rather than kept here, so there is exactly one
    /// answer to "is something being asked" and a sheet cannot outlive the
    /// request behind it. The core clears it the moment the engine is answered.
    var pendingSitePermission: PendingSitePermission? {
        snapshot.sitePermissionPrompt.map(PendingSitePermission.init(prompt:))
    }

    /// Every answer given to a site, for the pane that takes them back.
    ///
    /// Read straight from the core on every draw for the reason `toolGrants`
    /// is: a copy kept here would be a second answer to a question the core
    /// already answers, and this one is read by a pane that is usually shut.
    var siteGrants: [SiteGrant] { core.sitePermissions() }

    /// Answer the sheet.
    ///
    /// The clock is the shell's, because the core has none and the window this
    /// is measured against is half a second — far under the minute
    /// `Action.tick` moves the browser's clock by.
    func decideSitePermission(_ request: UInt64, _ choice: SiteChoice) {
        send(.decideSitePermission(
            request: request,
            choice: choice,
            decidedAtMs: UInt64(Date().timeIntervalSince1970 * 1000)
        ))
    }

    /// Change an answer from Settings. Reaches the engine: anything capturing
    /// under the old answer stops.
    func setSitePermission(_ grant: SiteGrant, allowed: Bool) {
        send(.setSitePermission(
            space: grant.space,
            origin: grant.origin,
            capability: grant.capability,
            allowed: allowed,
            decidedAtMs: UInt64(Date().timeIntervalSince1970 * 1000)
        ))
    }

    /// Take an answer back entirely, so the site is asked again next time.
    func forgetSitePermission(_ grant: SiteGrant) {
        send(.forgetSitePermission(
            space: grant.space,
            origin: grant.origin,
            capability: grant.capability
        ))
    }

    // MARK: - What a page said to you

    /// The question a page is waiting on, if it belongs to this window.
    ///
    /// Read off the snapshot for the same reason `pendingSitePermission` is,
    /// and filtered by window for a reason that one is not: a page dialog is
    /// raised by a tab, and a tab is in exactly one window. A panel drawn on
    /// every window would let a page in one take the keyboard in another.
    ///
    /// The file control is deliberately not here. Its panel is AppKit's and is
    /// put up in `refresh()`; returning it would draw a sheet over the picker.
    func pendingPageDialog(in window: WindowId?) -> PendingPageDialog? {
        guard let dialog = snapshot.pageDialogs.first(where: { $0.window == window }) else {
            return nil
        }
        switch dialog.kind {
        case .alert, .confirm, .prompt:
            return PendingPageDialog(dialog: dialog)
        case .chooseFiles:
            return nil
        }
    }

    /// Answer a page, and — if that is what was ticked — stop it asking again.
    ///
    /// The clock is the shell's, for the reason `decideSitePermission` takes
    /// one: the core has none, and the window this is measured against is half
    /// a second.
    func answerPageDialog(_ request: UInt64, _ answer: PageDialogAnswer, silence: Bool) {
        send(.answeredPageDialog(
            request: request,
            answer: answer,
            silence: silence,
            decidedAtMs: UInt64(Date().timeIntervalSince1970 * 1000)
        ))
    }

    // MARK: - Downloads

    /// Newest first.
    public var downloads: [Download] { snapshot.downloads }

    /// Anything still running, for the shelf and for the quit warning.
    public var downloadsInFlight: [Download] {
        snapshot.downloads.filter { $0.state == .inProgress }
    }

    /// Whether quitting right now would stop something.
    ///
    /// `WKDownload` dies with the process and there is no resuming it on the
    /// next launch, so the only honest thing to do is say so first.
    public var shouldWarnBeforeQuitting: Bool {
        !downloadsInFlight.isEmpty
    }

    public func cancelDownload(_ id: DownloadId) {
        send(.cancelDownload(id: id))
    }

    public func retryDownload(_ id: DownloadId) {
        send(.retryDownload(id: id))
    }

    /// Carry on from where it stopped, keeping what already arrived.
    ///
    /// Only ever offered for a download the core says is resumable, which it
    /// only says because the host is holding the blob right now.
    public func resumeDownload(_ id: DownloadId) {
        send(.resumeDownload(id: id))
    }

    public func removeDownload(_ id: DownloadId) {
        send(.removeDownload(id: id))
    }

    public func clearFinishedDownloads() {
        send(.clearFinishedDownloads)
    }

    /// Show it in Finder, selected. What people actually want more often than
    /// opening it: the next thing is usually to move it somewhere.
    public func revealDownload(_ download: Download) {
        guard !download.path.isEmpty else { return }
        DownloadHost.reveal(download.path)
    }

    public func openDownload(_ download: Download) {
        guard !download.path.isEmpty else { return }
        DownloadHost.open(download.path)
    }

    // MARK: - What an extension is answered

    /// Answer a `chrome.*` call an extension made. Every word of the answer,
    /// including every refusal, comes from the core (ADR-0103).
    func extensionApiCall(
        extensionId: String,
        method: String,
        body: String,
        host: HostFacts
    ) -> ExtensionApiAnswer {
        let answered = core.extensionApiCall(
            extensionId: extensionId, method: method, body: body, host: host
        )
        // Through `send`, so a cancel an extension asked for takes the same
        // road as the person pressing Stop: the reducer moves the row and the
        // engine stops the bytes. Reaching `WKDownload` directly would stop the
        // transfer and leave every screen saying it was still arriving.
        for action in answered.actions {
            send(action)
        }
        return answered
    }

    /// Start a download an extension asked for, answering with its id.
    func startDownloadForExtension(url: String, tab: TabId) -> DownloadId? {
        engine.startDownload(url, in: tab)
    }

    /// What that extension is told now the download exists.
    func extensionDownloadStarted(_ id: DownloadId) -> String {
        core.extensionApiDownloadStarted(id: id)
    }

    // MARK: - Air traffic

    func addRoute(_ pattern: RoutePattern, to space: SpaceId) {
        send(.addRoute(pattern: pattern, space: space))
    }

    func removeRoute(at index: Int) {
        send(.removeRoute(index: UInt32(index)))
    }

    func setRoute(at index: Int, enabled: Bool) {
        send(.setRouteEnabled(index: UInt32(index), enabled: enabled))
    }

    /// Where a URL would land, for showing the user before they follow a link.
    func routeDestination(for url: String) -> SpaceId? {
        core.routeFor(url: url)
    }
}
