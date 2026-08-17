import Foundation
import WebKit
import Zer0Core

/// Presents one of our tabs to an extension.
///
/// `WKWebExtensionTab` is how `chrome.tabs` sees the browser. Every answer here
/// is read from the Rust snapshot rather than from any state kept on this side,
/// so an extension and the sidebar can never disagree about what is open.
@MainActor
final class ExtensionTab: NSObject, WKWebExtensionTab {
    let id: TabId
    private weak var model: BrowserModel?
    private weak var window: ExtensionWindow?

    init(id: TabId, model: BrowserModel, window: ExtensionWindow) {
        self.id = id
        self.model = model
        self.window = window
    }

    private var tab: BrowserTab? {
        model?.snapshot.tabs.first { $0.id == id }
    }

    func window(for _: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        window
    }

    func indexInWindow(for _: WKWebExtensionContext) -> Int {
        guard let model, let tab else { return NSNotFound }
        return model.snapshot.tabs
            .filter { $0.space == tab.space }
            .firstIndex { $0.id == id } ?? NSNotFound
    }

    func parentTab(for _: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        guard let parent = tab?.parent else { return nil }
        return window?.extensionTab(for: parent)
    }

    func webView(for _: WKWebExtensionContext) -> WKWebView? {
        model?.engine.webView(for: id)
    }

    func title(for _: WKWebExtensionContext) -> String? {
        tab?.displayTitle
    }

    func url(for _: WKWebExtensionContext) -> URL? {
        tab?.url.flatMap(URL.init(string:))
    }

    func pendingURL(for _: WKWebExtensionContext) -> URL? {
        tab?.pendingUrl.flatMap(URL.init(string:))
    }

    func isLoadingComplete(for _: WKWebExtensionContext) -> Bool {
        tab?.loadingComplete ?? true
    }

    func isPinned(for _: WKWebExtensionContext) -> Bool {
        // Derived from the tab's kind in the core, never stored twice.
        guard let kind = tab?.kind else { return false }
        return kind == .favorite || kind == .pinned
    }

    func isSelected(for _: WKWebExtensionContext) -> Bool {
        model?.snapshot.activeTab == id
    }

    func isPlayingAudio(for _: WKWebExtensionContext) -> Bool {
        tab?.playingAudio ?? false
    }

    func isMuted(for _: WKWebExtensionContext) -> Bool {
        tab?.muted ?? false
    }

    func zoomFactor(for _: WKWebExtensionContext) -> Double {
        tab?.zoomFactor ?? 1.0
    }

    func size(for _: WKWebExtensionContext) -> CGSize {
        model?.engine.webView(for: id)?.bounds.size ?? .zero
    }

    // MARK: - Things an extension asks us to do

    // Each of these goes through the reducer. An extension gets exactly the
    // same path as a click in the sidebar, so it cannot reach a state the UI
    // could not.

    func setPinned(_ pinned: Bool, for _: WKWebExtensionContext) async throws {
        model?.setKind(id, pinned ? .pinned : .today)
    }

    func setMuted(_ muted: Bool, for _: WKWebExtensionContext) async throws {
        model?.send(.setTabMuted(tab: id, muted: muted))
    }

    func loadURL(_ url: URL, for _: WKWebExtensionContext) async throws {
        model?.send(.navigateTo(tab: id, input: url.absoluteString))
    }

    func reload(fromOrigin: Bool, for _: WKWebExtensionContext) async throws {
        model?.send(.reload(tab: id, fromOrigin: fromOrigin))
    }

    func goBack(for _: WKWebExtensionContext) async throws {
        model?.send(.goBack(tab: id))
    }

    func goForward(for _: WKWebExtensionContext) async throws {
        model?.send(.goForward(tab: id))
    }

    func activate(for _: WKWebExtensionContext) async throws {
        model?.activate(id)
    }

    func setSelected(_ selected: Bool, for _: WKWebExtensionContext) async throws {
        if selected { model?.activate(id) }
    }

    func close(for _: WKWebExtensionContext) async throws {
        model?.close(id)
    }

    func setParentTab(_: (any WKWebExtensionTab)?, for _: WKWebExtensionContext) async throws {
        // Reparenting from an extension is not wired up. Accepting it silently
        // would be worse than doing nothing, but throwing breaks callers that
        // set it as a hint, so this is a deliberate no-op.
    }
}

/// One browser window, as an extension sees it.
///
/// One of these per core window, not one per application (ADR-0065).
/// `WKWebExtensionWindow` exists precisely so an extension can tell windows
/// apart, and a single instance standing for all of them told every extension
/// that ⌘N had never happened — and that a private window was an ordinary one
/// whenever the space in front of *some other* window was not ephemeral.
@MainActor
final class ExtensionWindow: NSObject, WKWebExtensionWindow {
    let id: WindowId
    private weak var model: BrowserModel?
    private var tabs: [TabId: ExtensionTab] = [:]

    init(id: WindowId, model: BrowserModel) {
        self.id = id
        self.model = model
        super.init()
    }

    /// What this window is showing, or `nil` once the core has closed it.
    private var window: BrowserWindow? {
        model?.snapshot.windows.first { $0.id == id }
    }

    /// One adapter per tab, created on demand and reused.
    ///
    /// Identity matters to WebKit: handing out a new object for the same tab
    /// would make an extension think the tab was replaced.
    func extensionTab(for id: TabId) -> ExtensionTab? {
        guard let model, model.snapshot.tabs.contains(where: { $0.id == id }) else {
            tabs.removeValue(forKey: id)
            return nil
        }
        if let existing = tabs[id] { return existing }
        let adapter = ExtensionTab(id: id, model: model, window: self)
        tabs[id] = adapter
        return adapter
    }

    func forgetTab(_ id: TabId) {
        tabs.removeValue(forKey: id)
    }

    /// Whether this window already minted an adapter for a tab. The only way
    /// to address a notification about a tab the model has already dropped.
    func knows(_ id: TabId) -> Bool { tabs[id] != nil }

    func tabs(for _: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        guard let model, let window else { return [] }
        // This window's tabs, in the space this window is showing. Two filters
        // for two different lines: a tab in another space is in another cookie
        // jar, and a tab in another window is on another screen.
        return model.snapshot.tabs
            .filter { $0.window == id && $0.space == window.activeSpace }
            .compactMap { extensionTab(for: $0.id) }
    }

    func activeTab(for _: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        guard let active = window?.activeTab else { return nil }
        return extensionTab(for: active)
    }

    func windowType(for _: WKWebExtensionContext) -> WKWebExtension.WindowType {
        .normal
    }

    func windowState(for _: WKWebExtensionContext) -> WKWebExtension.WindowState {
        .normal
    }

    func isPrivate(for _: WKWebExtensionContext) -> Bool {
        // An ephemeral space is private browsing by another name, and
        // extensions must be told so they can honour it.
        //
        // Read off *this* window rather than off the browser, because ⇧⌘N is a
        // window onto an ephemeral space beside windows that are not: one
        // answer for the whole application would call an ordinary window
        // private, or worse, an actual private one ordinary.
        guard let model, let space = window?.activeSpace else { return false }
        return model.snapshot.spaces.first { $0.id == space }?.profile.ephemeral ?? false
    }

    func frame(for _: WKWebExtensionContext) -> CGRect {
        #if canImport(AppKit)
        BrowserWindows.window(for: id)?.frame ?? .zero
        #else
        // iOS has no per-window geometry to report — extensions live in the
        // one scene — and `.zero` is the same "no frame" answer the macOS
        // branch gives for a window that is not on screen.
        .zero
        #endif
    }

    func screenFrame(for _: WKWebExtensionContext) -> CGRect {
        #if canImport(AppKit)
        NSScreen.main?.frame ?? .zero
        #else
        // See `frame` above: one scene, no screen split to describe.
        .zero
        #endif
    }
}

/// Loads extensions and keeps WebKit's view of the browser in sync with ours.
@MainActor
final class ExtensionHost: NSObject, WKWebExtensionControllerDelegate {
    private let controller: WKWebExtensionController
    /// One adapter per core window, created on demand and reused.
    ///
    /// Identity matters to WebKit the same way it does for a tab: handing out
    /// a new object for the same window would make an extension think every
    /// window had been replaced.
    private var windows: [WindowId: ExtensionWindow] = [:]
    private weak var model: BrowserModel?

    private(set) var contexts: [String: WKWebExtensionContext] = [:]

    /// One popup dialog delegate per extension, held because
    /// `WKWebView.uiDelegate` is **weak** — an unheld one is deallocated
    /// immediately and the popup goes straight back to being answered by
    /// nobody, which looks exactly like the defect ADR-0098 fixes.
    private var popupDialogDelegates: [String: ExtensionPopupDialogDelegate] = [:]

    /// Watches WebKit's own error list. Held so it goes when this host does.
    private var errorWatch: NotificationWatch?

    /// Answers the `chrome.*` calls WebKit does not implement and zer0 does.
    ///
    /// Held here because a `WKURLSchemeHandler` is retained by the
    /// configuration it is registered on, and that configuration is a *copy*
    /// (see `configuration()`), so nothing else in this process would be
    /// keeping it alive.
    private var api: ExtensionApiHost?

    init(model: BrowserModel) {
        self.model = model
        let api = ExtensionApiHost(model: model)
        controller = WKWebExtensionController(configuration: Self.configuration(answeredBy: api))
        super.init()
        self.api = api
        api.extensions = self
        controller.delegate = self

        // An extension whose background content dies says so *here* and
        // nowhere else — there is no delegate callback for it, and
        // `controller.load` has already returned successfully by the time it
        // happens. Without this the row and the Extensions screen are drawn
        // once, before WebKit has found out, and never asked again: they go on
        // saying "Running with all 15 permissions it asked for" about an
        // extension that never started (ADR-0072).
        errorWatch = NotificationWatch(
            WKWebExtensionContext.errorsDidUpdateNotification
        ) { [weak self] in
            // Same bump as an icon changing, for the same reason: nothing is
            // cached, so all a view needs is a reason to read again.
            self?.model?.extensionActionsChanged()
        }
    }

    deinit {
        // Contexts this host loaded do not die with it: they live in WebKit's
        // process-wide extension machinery, background service workers
        // included. In the app a host dies only at shutdown, so this is moot
        // there; under `swift test` a model is dropped at the end of every
        // test, and measured, a context abandoned still-loaded — with its
        // package then deleted from disk by the fixture — wedges that
        // machinery for the rest of the process: every load every other suite
        // attempts, in any store, hangs past its deadline. Unloading here is
        // the one door every abandonment passes through, so no test has to
        // remember it. A task rather than a direct call because deinit is
        // nonisolated and the controller is main-actor state.
        guard !contexts.isEmpty else { return }
        let controller = self.controller
        let contexts = Array(contexts.values)
        Task { @MainActor in
            for context in contexts {
                try? controller.unload(context)
            }
        }
    }

    /// The controller's configuration, carrying the same User-Agent every page
    /// in this browser carries.
    ///
    /// `.default()` on its own hands an extension's contexts — the background
    /// service worker, the popup, the options page — a bare `WKWebView`'s
    /// User-Agent, which ends at `(KHTML, like Gecko)` and names no browser at
    /// all. That is the same defect ADR-0008 exists for, arriving through a
    /// door `EngineHost` does not sit at: `applicationNameForUserAgent` is set
    /// on the configuration of every view this browser builds, and a worker is
    /// not one of those.
    ///
    /// What that costs, measured on the untouched store package: Bitwarden
    /// 2026.7.0 asks its own UA for ` Chrome/`, ` Safari/`, ` Firefox/`,
    /// ` Edg/`, ` OPR/`, ` Vivaldi/` and ` Gecko/`, finds none of them, and
    /// throws in `this.device.toString` while the worker is starting — which
    /// MV3 makes fatal (ADR-0077). The extension does not load.
    ///
    /// It reads `HostedWebView.chromeCompatibleUserAgentToken` rather than
    /// composing anything. ADR-0081 made this the same string as the browsing
    /// UA; ADR-0106 split them, because per-extension UA is not a lever WebKit
    /// gives us and the cost of "tell extensions Safari" was paid twice
    /// (1Password, Bitwarden). The browsing UA stays Safari-only — defended by
    /// `theUserAgentNamesNoOtherBrowser` and mirrored by
    /// `theExtensionContextNamesChromeButPagesDoNot`.
    ///
    /// The read-modify-write is not ceremony. `webViewConfiguration` is
    /// declared `copy` in `WKWebExtensionControllerConfiguration.h`, so
    /// mutating what the getter returns is mutating a copy and setting it back
    /// is the only assignment WebKit is obliged to see.
    ///
    /// It is also where `ExtensionApiHost` is registered, and the same
    /// read-modify-write is what makes that stick. Measured: a `fetch` from a
    /// background service worker to a scheme registered here reaches the
    /// handler, which is the only road into this process a worker has that does
    /// not need `nativeMessaging` (ADR-0103).
    private static func configuration(
        answeredBy api: ExtensionApiHost
    ) -> WKWebExtensionController.Configuration {
        let configuration = WKWebExtensionController.Configuration.default()
        // Optional the whole way through, and deliberately not resolved with a
        // `WKWebViewConfiguration()` of our own: this file is not the door that
        // builds one, and a second builder is a browsing context that missed
        // `EnginePolicy.apply` (ADR-0074, and the source scan in
        // `EnginePolicyTests` counts them). `null_resettable` says the getter
        // never answers nil; if it ever did, writing nil back is what resets the
        // property to WebKit's default, which is exactly where this started.
        let webViewConfiguration = configuration.webViewConfiguration
        // ADR-0106: extension contexts name Chrome so Chrome-marketplace
        // extensions take the Chromium path (`connectNative`,
        // `sendNativeMessage`). Sites the person visits keep Safari-only UA —
        // `theExtensionContextNamesChromeButPagesDoNot` defends the split, and
        // `theUserAgentNamesNoOtherBrowser` still refuses Chrome on real pages.
        webViewConfiguration?.applicationNameForUserAgent = HostedWebView.chromeCompatibleUserAgentToken
        webViewConfiguration?.setURLSchemeHandler(api, forURLScheme: ExtensionApiHost.scheme)
        configuration.webViewConfiguration = webViewConfiguration
        return configuration
    }

    /// Which extension a `webkit-extension://<uuid>` origin belongs to.
    ///
    /// The uuid is WebKit's, minted per context and not the id this browser
    /// installed under, so the two have to be matched rather than assumed
    /// equal. Answering `nil` for an origin nothing loaded is the point: a
    /// request from a context this host does not know is a request from
    /// nobody, and it is refused rather than attributed to whatever was loaded
    /// last.
    func extensionId(withBaseHost host: String) -> String? {
        contexts.first { $0.value.baseURL.host == host }?.key
    }

    /// The adapter for a window the core still has, or `nil` for one it does
    /// not. Asking for a window that is gone forgets the adapter rather than
    /// minting one for it.
    private func window(_ id: WindowId) -> ExtensionWindow? {
        guard let model, model.snapshot.windows.contains(where: { $0.id == id }) else {
            windows.removeValue(forKey: id)
            return nil
        }
        if let existing = windows[id] { return existing }
        let adapter = ExtensionWindow(id: id, model: model)
        windows[id] = adapter
        return adapter
    }

    /// The window a tab is in, which is where every per-tab notification below
    /// has to be addressed.
    private func window(holding tab: TabId) -> ExtensionWindow? {
        guard let id = model?.snapshot.tabs.first(where: { $0.id == tab })?.window else {
            // The tab is already gone from the model. Whichever adapter knows
            // it is the one that has to be told, and only one ever can.
            return windows.values.first { $0.knows(tab) }
        }
        return window(id)
    }

    /// Attach the controller so pages in this view can be reached by content
    /// scripts. Must happen before the view loads anything.
    func attach(to configuration: WKWebViewConfiguration) {
        configuration.webExtensionController = controller
    }

    /// The one configuration a page belonging to this extension may be shown
    /// in, or `nil` for a host no loaded context answers to.
    ///
    /// `WKWebExtensionContext.h` is explicit: *"navigations will be canceled if
    /// a web view not configured with this configuration attempts to navigate
    /// to a URL that does originate from this extension's base URL"*, and *"the
    /// app must also swap web views in tabs when navigating to and from web
    /// extension URLs"*. Measured, one run, same address and same instant: in
    /// an ordinary page configuration the view is left at `about:blank`; in
    /// this one it loads and reports `title = 1Password`.
    ///
    /// **Handed back untouched, and that is the whole of the rule.** Not
    /// through `EnginePolicy.apply`, and above all not with a store of our own
    /// on it: the configuration arrives carrying
    /// `WKWebsiteDataStore.default()`, and measured, assigning a space's
    /// identified store or a non-persistent one leaves `WKWebView.init` never
    /// returning — while the same two assignments on an ordinary configuration
    /// build a view and load a page. It is the same rule the pop-up path lives
    /// by for the same reason (ADR-0075): the configuration is the engine's,
    /// and a view built from a different one is a different browsing context.
    ///
    /// `nil` is a refusal and never a repair. A host nothing loaded is a
    /// request from nobody — the same answer `extensionId(withBaseHost:)`
    /// gives — and attributing it to whichever extension happens to be at hand
    /// would let one extension's page be opened out of another's address.
    func pageConfiguration(forBaseHost host: String) -> WKWebViewConfiguration? {
        contexts.values
            .first { $0.baseURL.host == host }?
            .webViewConfiguration
    }

    /// Load an unpacked extension, holding exactly what was approved.
    ///
    /// The decision is a parameter and not a lookup on purpose: there is no
    /// call here that loads an extension without one, so no future caller can
    /// reach the old behaviour of granting whatever the manifest asked for by
    /// forgetting a step.
    @discardableResult
    func load(
        _ installed: InstalledExtension,
        granting decision: ConsentDecision
    ) async throws -> WKWebExtensionContext {
        if let existing = contexts[installed.id] {
            apply(decision, to: existing)
            return existing
        }
        let base = URL(fileURLWithPath: installed.path, isDirectory: true)
        let ext = try await WKWebExtension(resourceBaseURL: base)
        let context = WKWebExtensionContext(for: ext)

        // Harness-only hook for the identity probe (ZZExtensionIdentityProbe).
        // The shell ships without ever setting baseURL or uniqueIdentifier —
        // they get WebKit's defaults, which mint a fresh uuid per launch. This
        // block lets the probe point them at a stable scheme/id of its choosing
        // so ADR-0104 §"When to revisit" can be measured rather than reasoned
        // about. Both gates are needed: #if DEBUG keeps it out of release
        // builds physically, and ZER0_SHOT keeps it inert in any debug run that
        // is not the probe. The setter is only valid pre-load, hence the
        // placement between context creation and controller.load.
        #if DEBUG
        if ProcessInfo.processInfo.environment["ZER0_SHOT"] != nil {
            if let raw = ProcessInfo.processInfo.environment["ZER0_PROBE_BASE_URL"],
               let url = URL(string: raw) {
                // A custom scheme must be registered with WKWebExtensionMatchPattern
                // before it can be used as a baseURL, or setBaseURL: throws
                // "not a registered custom scheme". Measured. webkit-extension is
                // already registered by WebKit; only our own scheme needs this.
                if let scheme = url.scheme?.lowercased(),
                   scheme != "webkit-extension" {
                    WKWebExtension.MatchPattern.registerCustomURLScheme(scheme)
                }
                context.baseURL = url
            }
            if let uniqueId = ProcessInfo.processInfo.environment["ZER0_PROBE_UNIQUE_ID"] {
                context.uniqueIdentifier = uniqueId
            }
        }
        #endif

        apply(decision, to: context)

        try controller.load(context)
        contexts[installed.id] = context
        return context
    }

    /// Push a decision into a context: grant what was allowed, explicitly deny
    /// the rest.
    ///
    /// Denials are set rather than left alone, because "unknown" is a state
    /// WebKit is free to resolve in the extension's favour when it asks again.
    /// A refusal has to be a refusal.
    ///
    /// Returns the host patterns WebKit would not parse. Those were not
    /// granted, whatever the record says, and the caller has to go correct the
    /// record — an approval nobody could apply must never keep reading as an
    /// approval.
    @discardableResult
    func apply(_ decision: ConsentDecision, to context: WKWebExtensionContext) -> [String] {
        for permission in decision.grantedPermissions {
            context.setPermissionStatus(.grantedExplicitly, for: WKWebExtension.Permission(permission))
        }
        for permission in decision.deniedPermissions {
            context.setPermissionStatus(.deniedExplicitly, for: WKWebExtension.Permission(permission))
        }

        var refused: [String] = []
        for pattern in decision.grantedHosts {
            guard let match = Self.matchPattern(pattern) else {
                refused.append(pattern)
                continue
            }
            context.setPermissionStatus(.grantedExplicitly, for: match)
        }
        for pattern in decision.deniedHosts {
            // A pattern nobody can parse cannot be denied either, and does not
            // need to be: nothing granted it.
            guard let match = Self.matchPattern(pattern) else { continue }
            context.setPermissionStatus(.deniedExplicitly, for: match)
        }
        return refused
    }

    /// Re-apply a decision to an extension that is already running.
    ///
    /// This is what makes the Revoke button reach WebKit rather than only
    /// repaint a row. Returns `nil` when the extension is not loaded, which
    /// the caller reads as "nothing to update", not as "it worked".
    func updateConsent(_ decision: ConsentDecision) -> [String]? {
        guard let context = contexts[decision.extensionId] else { return nil }
        return apply(decision, to: context)
    }

    /// WebKit's reader, with one fallback.
    ///
    /// `<all_urls>` has a dedicated constructor in the framework, and relying
    /// on the string initialiser to accept the literal would make the single
    /// most consequential permission in the browser depend on an undocumented
    /// spelling.
    private static func matchPattern(_ raw: String) -> WKWebExtension.MatchPattern? {
        if let match = try? WKWebExtension.MatchPattern(string: raw) {
            return match
        }
        return raw == "<all_urls>" ? WKWebExtension.MatchPattern.allURLs() : nil
    }

    func unload(_ id: String) {
        // The popup web view goes with the context, and a delegate held for one
        // that no longer exists is an extension this browser keeps a name for
        // after it has been removed.
        popupDialogDelegates.removeValue(forKey: id)
        guard let context = contexts.removeValue(forKey: id) else { return }
        try? controller.unload(context)
    }

    var loadedIds: [String] {
        Array(contexts.keys)
    }

    /// Whether WebKit could not start this extension's background content.
    ///
    /// **Loaded is not running, and this is the difference.** `controller.load`
    /// succeeds, the button appears, the icon is right — and the service worker
    /// threw on the way up, so nothing behind the button will ever answer. The
    /// measured case is 1Password, whose worker dies reaching for
    /// `chrome.notifications`, an API `WKWebExtension` does not implement; the
    /// popup then waits on a background that is not there, forever, with no
    /// error of its own (ADR-0072).
    ///
    /// Asked of WebKit every time rather than remembered, for the reason
    /// nothing else about an extension is cached: the list is WebKit's and it
    /// changes without us.
    ///
    /// **The one door.** Two screens need this answer and neither may work it
    /// out for itself, because the version that goes wrong is always the one on
    /// screen.
    func backgroundContentFailed(_ id: String) -> Bool {
        guard let context = contexts[id] else { return false }
        // Matched on WebKit's named case rather than on the sentence it prints.
        // The sentence is display text and is free to be reworded in a point
        // release; the case is API.
        return context.errors.contains { error in
            (error as? WKWebExtensionContext.Error)?.code == .backgroundContentFailedToLoad
        }
    }

    // MARK: - The button an extension puts on screen

    /// What this extension's button looks like *on this tab*.
    ///
    /// An action's icon, title and badge are per-tab and change as you browse:
    /// a password manager lights up on a site it has a login for, a blocker
    /// counts what it stopped on the page you are on. `action(for:)` is asked
    /// for the tab rather than for the default action precisely so the answer is
    /// about the page in front of the person.
    ///
    /// `nil` for an extension that is not running — which is a real state, not
    /// an error: an extension that was granted nothing is installed and
    /// deliberately not loaded (ADR-0028), so it has no context to ask.
    func action(for extensionId: String, tab: TabId?) -> WKWebExtension.Action? {
        guard let context = contexts[extensionId] else { return nil }
        let adapter = tab.flatMap { window(holding: $0)?.extensionTab(for: $0) }
        guard let action = context.action(for: adapter) else { return nil }
        adoptPopupDialogs(of: action, for: extensionId)
        return action
    }

    /// Give this action's popup the browser's answer to `alert()`, `confirm()`
    /// and `prompt()` (ADR-0098).
    ///
    /// **Here because this is the one place the shell ever gets an action.**
    /// Every road to a popup — a click on the row, ⇧⌘1..9, an extension opening
    /// its own — reaches `popupPopover` through an action from this method, so a
    /// popup that has not been through here does not exist. Putting it at the
    /// places that *show* a popup instead would be the same rule at N call
    /// sites, which is N−1 popups asking questions nobody hears (AGENTS.md).
    ///
    /// Idempotent, because this runs on every draw of every button. The web
    /// view is built lazily by WebKit and reused, so the second call finds our
    /// delegate already on it and does nothing.
    private func adoptPopupDialogs(of action: WKWebExtension.Action, for extensionId: String) {
        guard action.presentsPopup, let view = action.popupWebView else { return }
        if view.uiDelegate is ExtensionPopupDialogDelegate { return }
        guard let model else { return }

        let delegate = ExtensionPopupDialogDelegate(
            // The core's resolved name, which is the one on the button. Not
            // `WKWebExtension.displayName`: two spellings of what an extension
            // is called is two answers, and this one has already been through
            // `_locales`.
            name: model.installedExtensions
                .first { $0.id == extensionId }?.manifest.name ?? "",
            currentTab: { [weak model] in model?.snapshot.activeTab },
            dialogs: model.engine.pageDialogs,
            engines: view.uiDelegate,
            emit: { [weak model] action in model?.send(action) }
        )
        popupDialogDelegates[extensionId] = delegate
        view.uiDelegate = delegate
    }

    /// Somebody pressed the button.
    ///
    /// Goes through `performAction(for:)` rather than reaching for `popupWebView`
    /// directly, because that is what marks the tab as having had a user
    /// gesture — which is the whole of what `activeTab` means, and an extension
    /// that is told nobody clicked cannot read the page it was clicked on.
    ///
    /// What happens next is the extension's to decide: it either fires its
    /// `onClicked` event or asks for its popup, and the popup arrives back
    /// through the delegate below.
    func performAction(for extensionId: String, tab: TabId?) {
        guard let context = contexts[extensionId] else { return }
        let adapter = tab.flatMap { window(holding: $0)?.extensionTab(for: $0) }
        context.performAction(for: adapter)
    }

    // MARK: - Telling extensions what changed

    // Without these an extension's view of the browser silently goes stale:
    // chrome.tabs.query would keep returning tabs that closed minutes ago.

    func tabOpened(_ id: TabId) {
        guard let window = window(holding: id), let tab = window.extensionTab(for: id) else { return }
        controller.didOpenTab(tab)
    }

    /// `closingWindow` is the window this tab went down with, if it did.
    ///
    /// `windowIsClosing` was hardcoded `false` while there was one window and
    /// closing it meant quitting. With ⇧⌘W it is a real distinction: an
    /// extension that is told ten tabs closed one by one runs its
    /// `onRemoved` bookkeeping ten times over a window that no longer exists.
    func tabClosed(_ id: TabId, closingWindow: WindowId? = nil) {
        guard let window = window(holding: id), let tab = window.extensionTab(for: id) else { return }
        controller.didCloseTab(tab, windowIsClosing: closingWindow == window.id)
        window.forgetTab(id)
    }

    func tabActivated(_ id: TabId, previous: TabId?) {
        guard let window = window(holding: id), let tab = window.extensionTab(for: id) else { return }
        controller.didActivateTab(
            tab, previousActiveTab: previous.flatMap { window.extensionTab(for: $0) }
        )
    }

    func tabChanged(_ id: TabId, _ properties: WKWebExtension.TabChangedProperties) {
        guard let window = window(holding: id), let tab = window.extensionTab(for: id) else { return }
        controller.didChangeTabProperties(properties, for: tab)
    }

    /// A window arrived, or went. Both are things `WKWebExtensionWindow` exists
    /// to let an extension hear about.
    func windowOpened(_ id: WindowId) {
        guard let window = window(id) else { return }
        controller.didOpenWindow(window)
    }

    func windowClosed(_ id: WindowId) {
        guard let window = windows[id] else { return }
        controller.didCloseWindow(window)
        windows.removeValue(forKey: id)
    }

    func windowFocused(_ id: WindowId) {
        // `nil` is a legitimate answer here and means "none of ours is in
        // front", which is exactly the truth while Settings is key.
        controller.didFocusWindow(window(id))
    }

    // MARK: - WKWebExtensionControllerDelegate

    func webExtensionController(
        _: WKWebExtensionController,
        openWindowsFor _: WKWebExtensionContext
    ) -> [any WKWebExtensionWindow] {
        guard let model else { return [] }
        return model.snapshot.windows.compactMap { window($0.id) }
    }

    func webExtensionController(
        _: WKWebExtensionController,
        focusedWindowFor _: WKWebExtensionContext
    ) -> (any WKWebExtensionWindow)? {
        guard let model else { return nil }
        return window(model.snapshot.keyWindow)
    }

    /// An extension asked for a tab.
    ///
    /// The address is the core's to act on, with one thing settled here first
    /// because only this side can: **an extension may open its own pages and
    /// nobody else's.** The uuid in an extension address is WebKit's, minted
    /// per context, so an address naming a *different* context is one extension
    /// reaching into another's — the page it would open is drawn from that
    /// other extension's configuration and carries its storage and its origin.
    /// Refused out loud rather than opened, and refused rather than repaired
    /// into this extension's own base URL (AGENTS.md).
    ///
    /// An ordinary web address is untouched: `context` bounds which *extension*
    /// pages this call may reach, not which sites.
    func webExtensionController(
        _: WKWebExtensionController,
        openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void
    ) {
        guard let model else {
            completionHandler(nil, nil)
            return
        }
        // Asked of the core rather than compared here, so the shell cannot
        // drift into a different idea of what an extension's address is than
        // the reducer has.
        if let asked = configuration.url.map({ extensionBaseHost(url: $0.absoluteString) }),
           let asked,
           asked != context.baseURL.host
        {
            completionHandler(nil, ExtensionPageError.notThisExtensionsPage)
            return
        }
        model.send(.openTab(
            space: nil,
            url: configuration.url?.absoluteString,
            parent: nil
        ))
        guard let opened = model.snapshot.activeTab else {
            completionHandler(nil, nil)
            return
        }
        completionHandler(window(holding: opened)?.extensionTab(for: opened), nil)
    }

    /// An extension wants a lasting conversation with a program on this Mac.
    ///
    /// `chrome.runtime.connectNative`. The port is WebKit's end of it and is
    /// held for as long as the conversation is — `WKWebExtensionMessagePort.h`
    /// is explicit that releasing it disconnects — which `MessagePortPeer`
    /// does by holding it and `NativeMessagingHost` does by holding that.
    ///
    /// **Nothing is decided here.** Which program, whether this extension may
    /// reach it and whether anybody has said so are one call into the core, and
    /// the completion handler is answered whenever that finishes: immediately
    /// for a refusal or an approval already on file, and after a sheet for a
    /// program nobody has been asked about.
    func webExtensionController(
        _: WKWebExtensionController,
        connectUsing port: WKWebExtension.MessagePort,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let native = model?.nativeMessaging,
              let extensionId = contexts.first(where: { $0.value === context })?.key,
              let applicationId = port.applicationIdentifier
        else {
            completionHandler(NativeMessagingRefusal.notAvailable)
            return
        }

        native.connect(
            extensionId: extensionId,
            applicationId: applicationId,
            peer: MessagePortPeer(port: port)
        ) { failure in
            completionHandler(failure.map(NativeMessagingRefusal.said))
        }
    }

    /// An extension wants one answer from a program on this Mac.
    ///
    /// `chrome.runtime.sendNativeMessage`. Implemented rather than left out,
    /// even though the extension this was built for uses the port form: the
    /// one-shot form is what an extension reaches for when it wants a single
    /// fact, and an unimplemented delegate is a promise that never settles
    /// rather than a refusal anyone can read.
    func webExtensionController(
        _: WKWebExtensionController,
        sendMessage message: Any,
        toApplicationWithIdentifier applicationIdentifier: String?,
        for context: WKWebExtensionContext,
        replyHandler: @escaping (Any?, (any Error)?) -> Void
    ) {
        guard let native = model?.nativeMessaging,
              let extensionId = contexts.first(where: { $0.value === context })?.key,
              let applicationId = applicationIdentifier,
              let json = MessagePortPeer.json(from: message)
        else {
            replyHandler(nil, NativeMessagingRefusal.notAvailable)
            return
        }

        native.send(
            extensionId: extensionId,
            applicationId: applicationId,
            message: json
        ) { answer, failure in
            guard let answer, let value = MessagePortPeer.value(from: answer) else {
                replyHandler(nil, NativeMessagingRefusal.said(failure ?? "No answer came back."))
                return
            }
            replyHandler(value, nil)
        }
    }

    /// An action's icon, title or badge changed.
    ///
    /// Without this the row is drawn once and then lies: a blocker's count
    /// stops moving, and a password manager that has just noticed it has a
    /// login for this site never says so. WebKit has no way to tell us other
    /// than this call, and there is no polling that would be honest instead.
    func webExtensionController(
        _: WKWebExtensionController,
        didUpdate _: WKWebExtension.Action,
        forExtensionContext _: WKWebExtensionContext
    ) {
        // Deliberately not "update the icon for this action": the views read
        // everything fresh, so all that is needed is a reason to read again.
        // Carrying the action here would be the first half of a cache.
        model?.extensionActionsChanged()
    }

    /// The extension wants its popup on screen.
    ///
    /// Called both for a press — `performAction(for:)` routes through here
    /// rather than opening anything itself — and for an extension opening its
    /// own popup with nobody having clicked. Not implementing it means a popup
    /// action does nothing at all, which is the shape of "the extension loads,
    /// its icon appears, and the one feature the person installed it for quietly
    /// does nothing" that ADR-0020 names as reading like our bug.
    ///
    /// The popup is asked for here and shown by whichever button is drawing this
    /// extension, rather than opened from here onto a rectangle of its own. A
    /// popover that comes out of the thing you pressed says where it came from;
    /// one placed in a corner is a panel that appeared.
    ///
    /// **The answer given back is one that can be proved.** Not "a view will
    /// probably handle this" — the check is that the extension is on the row at
    /// all, which is a fact the core owns and this side only reads (ADR-0018).
    /// An extension that is unpinned has no button anywhere, and saying the
    /// popup was shown would be a lie told to the extension, which then believes
    /// its interface is on screen.
    func webExtensionController(
        _: WKWebExtensionController,
        presentActionPopup _: WKWebExtension.Action,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        // The action itself is deliberately not carried across. The button
        // reads its own, fresh, against the tab in front — holding on to this
        // one would be the cache the whole row exists without.
        guard let model,
              let id = contexts.first(where: { $0.value === context })?.key,
              model.pinnedExtensions.contains(where: { $0.id == id })
        else {
            completionHandler(ExtensionPopupError.nowhereToShowIt)
            return
        }
        model.requestExtensionPopup(id)
        completionHandler(nil)
    }
}

/// A block-based notification observer that unregisters when it is released.
///
/// The token has to be handed back to `NotificationCenter` or the observer
/// outlives whatever registered it — the block-based API has never
/// auto-removed. Doing that from the owner's own `deinit` does not compile: a
/// `@MainActor` type's `deinit` is nonisolated and may not read a non-`Sendable`
/// stored property, and the token is one.
///
/// So the token gets an owner of its own that is not actor-isolated, and the
/// removal becomes a consequence of ARC rather than a line somebody has to
/// remember to write. Anything holding one of these gets the teardown by
/// holding it.
final class NotificationWatch {
    private let token: any NSObjectProtocol

    /// `queue: .main` and `MainActor.assumeIsolated` are the pair: the first
    /// is what makes the second true rather than a hope.
    init(_ name: Notification.Name, onPost: @escaping @MainActor () -> Void) {
        token = NotificationCenter.default.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { onPost() }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(token)
    }
}

/// A `WKWebExtension.MessagePort`, as native messaging sees it.
///
/// An adapter rather than the port itself everywhere, so the whole of
/// `NativeMessagingHost` can be driven by a test that never loads an extension
/// — and so the one place a message becomes text, in either direction, is here.
///
/// **It holds the port.** `WKWebExtensionMessagePort.h`: *"You should retain
/// the port object for as long as the connection remains active. Releasing the
/// port will disconnect it."*
@MainActor
final class MessagePortPeer: NSObject, NativeMessagingPeer {
    var onMessage: (@MainActor (String) -> Void)?
    var onHangUp: (@MainActor () -> Void)?

    private let port: WKWebExtension.MessagePort

    init(port: WKWebExtension.MessagePort) {
        self.port = port
        super.init()

        port.messageHandler = { [weak self] message, _ in
            guard let self, let message, let json = Self.json(from: message) else { return }
            self.onMessage?(json)
        }
        port.disconnectHandler = { [weak self] _ in
            self?.onHangUp?()
        }
    }

    func deliver(_ json: String) {
        guard let value = Self.value(from: json) else { return }
        port.sendMessage(value, completionHandler: nil)
    }

    func end(reason: String?) {
        guard !port.isDisconnected else { return }
        guard let reason else {
            port.disconnect()
            return
        }
        port.disconnect(throwing: NativeMessagingRefusal.said(reason))
    }

    /// What an extension sent, as the JSON the core frames.
    ///
    /// `.fragmentsAllowed` because `port.postMessage("hello")` is a string and
    /// is a whole message; refusing one would be this browser having an opinion
    /// about a conversation it is only carrying.
    static func json(from message: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(message) || message is NSString
            || message is NSNumber,
            let data = try? JSONSerialization.data(
                withJSONObject: message,
                options: [.fragmentsAllowed]
            )
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The other direction, for what a program sent back.
    static func value(from json: String) -> Any? {
        try? JSONSerialization.jsonObject(
            with: Data(json.utf8),
            options: [.fragmentsAllowed]
        )
    }
}

/// Why nothing was said to a program outside the browser.
///
/// One case carrying the core's sentence, and one for the shape that has no
/// sentence because nothing was asked. Every refusal a person could act on is
/// written in the core (ADR-0105); this type only carries them.
enum NativeMessagingRefusal: LocalizedError {
    case said(String)
    case notAvailable

    var errorDescription: String? {
        switch self {
        case let .said(sentence): sentence
        case .notAvailable: "zer0 could not tell which extension is asking."
        }
    }
}

/// Why a page belonging to an extension was not opened.
enum ExtensionPageError: LocalizedError {
    /// The address named a different extension's context. One extension does
    /// not get to open another's screens.
    case notThisExtensionsPage
    /// The address named a context nothing loaded. Refused rather than shown in
    /// a view that would cancel it and leave a blank tab.
    case noSuchExtension

    var errorDescription: String? {
        switch self {
        case .notThisExtensionsPage:
            "An extension may only open its own pages."
        case .noSuchExtension:
            "That address does not belong to any extension this browser has."
        }
    }
}

/// Why a popup did not appear. One case, because there is one reason.
enum ExtensionPopupError: LocalizedError {
    /// Nothing is drawing this extension's button, so there is nothing to
    /// anchor a popover to. Reachable when an extension opens its own popup
    /// while it is unpinned, or while no browser window is in front.
    case nowhereToShowIt

    var errorDescription: String? {
        switch self {
        case .nowhereToShowIt:
            "There is nowhere on screen to show this extension's popup."
        }
    }
}
