import Foundation
import WebKit
import Zer0Core

/// One `WKWebView` plus the plumbing that reports its state back to the core.
///
/// Everything WebKit tells us is forwarded as an `Action`. Nothing is decided
/// here: if the title changes, we say so and let the reducer decide what that
/// means.
@MainActor
final class HostedWebView: NSObject, WKNavigationDelegate {
    let tab: TabId
    /// A `PageView` rather than a `WKWebView`, and that is the guarantee rather
    /// than a rule: the context menu is reached through an `NSView` override
    /// (ADR-0091), so a plain `WKWebView` is one that silently has no menu of
    /// ours. This initialiser will not take one.
    let webView: PageView

    private let emit: @MainActor (Action) -> Void
    /// Report something to the core from an extension on this class.
    ///
    /// `emit` stays private — a view that could be made to say anything from
    /// anywhere is the seam this whole file exists to keep narrow — and this is
    /// the one door through it, for the delegate methods that live in files of
    /// their own. See `AuthChallengeHost.swift`.
    func emitAction(_ action: Action) { emit(action) }

    /// The completion handlers for servers asking who you are, and for
    /// certificates that did not check out.
    ///
    /// On the host rather than here, and handed in, because a tab can close
    /// while the core is still deciding and the engine is still owed exactly
    /// one answer. See `AuthChallengeHost.swift`.
    let authChallenges: AuthChallengeLedger
    /// The `WKUIDelegate`. Held here because `uiDelegate` is weak, and reported
    /// through rather than decided by: see `SitePermissionHost.swift`.
    private let sitePermissions: SitePermissionDelegate
    /// Hands a `WKDownload` to whoever tracks downloads. A closure rather than
    /// a reference so a hosted view still knows nothing beyond its own tab.
    private let adoptDownload: @MainActor (WKDownload, TabId) -> Void
    private var observations: [NSKeyValueObservation] = []
    private var isMuted = false
    /// The last back/forward pair this view has reported to the core.
    ///
    /// KVO re-fires for a flag that did not move — measured 2026-08-16,
    /// counting what one navigation dispatches: both observers deliver for
    /// one navigation, the changed flag and the unchanged one alike — and
    /// every report costs a full core dispatch and refresh. One pair per
    /// view rather than one flag per view, because the two flags are one
    /// answer: whichever observer fires first reads both, so a navigation
    /// lands as one report and the other fire finds nothing left to say.
    var lastReportedStack: (canGoBack: Bool, canGoForward: Bool)?

    /// The ordinary way in: this host builds the configuration and the view.
    ///
    /// A convenience rather than the designated initialiser, because there is a
    /// second way a view comes into being and it does **not** pass through
    /// here: a page that called `window.open` has already been handed a
    /// configuration by the engine, and a view built from any other one is a
    /// different browsing context (ADR-0075).
    convenience init(
        tab: TabId,
        dataStoreId: String,
        profile: SpaceProfile,
        policy: EnginePolicy.Choices,
        configure: (WKWebViewConfiguration) -> Void,
        adoptDownload: @escaping @MainActor (WKDownload, TabId) -> Void,
        permissions: SitePermissionLedger,
        dialogs: PageDialogLedger,
        authChallenges: AuthChallengeLedger,
        openWindow: @escaping PopupOpener,
        emit: @escaping @MainActor (Action) -> Void
    ) {
        let config = WKWebViewConfiguration()
        // First, and before anything a caller adds: the answers to what kind
        // of client this is. A `WKWebView`'s defaults are an embedded web
        // view's defaults, and accepting one is a decision made by omission
        // (ADR-0074).
        EnginePolicy.apply(to: config, choices: policy)
        config.websiteDataStore = Self.dataStore(id: dataStoreId, profile: profile)
        // Without this the UA ends at "(KHTML, like Gecko)" and sites that
        // sniff, Google's especially, decide we are an unsupported browser.
        config.applicationNameForUserAgent = Self.safariUserAgentToken
        // Attaching the extension controller has to happen before the view is
        // built; a view cannot join a controller afterwards.
        configure(config)
        // Both halves of "this page can be inspected", set before the view
        // exists rather than the first time somebody presses ⌥⌘I. Switching
        // either on afterwards does not reach a page that has already loaded,
        // which is why the old code reloaded — and a shortcut whose visible
        // effect is losing what you had typed is worse than one that does
        // nothing (ADR-0067).
        WebInspector.allowInspection(of: config)

        let view = PageView(frame: .zero, configuration: config)
        if let agent = profile.userAgent, !agent.isEmpty {
            view.customUserAgent = agent
        }

        self.init(
            tab: tab,
            webView: view,
            adoptDownload: adoptDownload,
            permissions: permissions,
            dialogs: dialogs,
            authChallenges: authChallenges,
            openWindow: openWindow,
            emit: emit
        )
    }

    /// A view that already exists, wired up.
    ///
    /// Designated, because the pop-up path arrives here with a view made from
    /// the engine's own configuration and nothing this host may substitute for
    /// it. Everything below the configuration is identical for both, which is
    /// the point of the split: a page a person opened and a page a page opened
    /// report the same things, get the same delegates and get inspected the
    /// same way.
    init(
        tab: TabId,
        webView: PageView,
        adoptDownload: @escaping @MainActor (WKDownload, TabId) -> Void,
        permissions: SitePermissionLedger,
        dialogs: PageDialogLedger,
        authChallenges: AuthChallengeLedger,
        openWindow: @escaping PopupOpener,
        emit: @escaping @MainActor (Action) -> Void
    ) {
        self.tab = tab
        self.webView = webView
        self.emit = emit
        self.authChallenges = authChallenges
        // The view carries the gesture; the core decides what the menu says and
        // what a row does. Set here rather than at each of the two places a
        // view is built, so neither can forget one (ADR-0091).
        webView.tab = tab
        webView.emit = emit
        self.adoptDownload = adoptDownload
        sitePermissions = SitePermissionDelegate(
            tab: tab,
            ledger: permissions,
            dialogs: dialogs,
            openWindow: openWindow,
            emit: emit
        )

        webView.allowsBackForwardNavigationGestures = true
        // The public half, and the one that survives Apple deleting the
        // private half: it is what lets Safari's Develop menu attach to our
        // pages.
        webView.isInspectable = true

        super.init()
        webView.navigationDelegate = self
        // Without this the answer to "may this page have your camera" is
        // `WKPermissionDecisionPrompt` — WebKit's own dialog, chosen by nobody,
        // recorded nowhere and revocable from no screen (ADR-0056). It is also
        // what makes `window.open` open anything at all (ADR-0075).
        webView.uiDelegate = sitePermissions
        // Here rather than on the configuration, so both ways a view comes into
        // being get it: a pop-up arrives with the engine's own configuration and
        // nothing this host may substitute, but the content controller inside it
        // is the same object either way. See `PagePrintScript` (ADR-0101).
        PagePrintChannel.attach(to: webView)

        observations = [
            webView.observe(\.title, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.emit(.titleChanged(tab: self.tab, title: view.title ?? ""))
                }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    guard let self, !view.isLoading else { return }
                    self.emit(.navigationFinished(tab: self.tab))
                }
            },
            // The engine's back/forward answer, watched rather than asked for.
            // One observation per flag and both flags in every report, so a
            // Back that flips the pair still lands as one settled answer
            // whoever fires first. Emitted through `reportNavigationStack`
            // rather than inline, because the restored-history path below says
            // the same thing from a place KVO does not reach — and a fire
            // that would repeat the last reported pair is dropped there, so
            // a navigation's two fires cost one dispatch.
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    self?.reportNavigationStack()
                }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    self?.reportNavigationStack()
                }
            },
        ]
    }

    /// The tail WebKit appends to its generated User-Agent.
    ///
    /// A `WKWebView` in a third-party app produces a UA with no browser token
    /// at all, and large sites read that as "unsupported". So we carry the
    /// Safari signature, which is what a sniffer looks for, and then say who
    /// we actually are.
    ///
    /// Composed by the core (ADR-0119): the order, the fallbacks and the fixed
    /// `Safari/605.1.15` suffix are behaviour two platforms could not disagree
    /// about, so this host supplies the local facts and applies the answer.
    /// Order still matters as much as ADR-0008 says it does — `zer0/` goes
    /// **after** `Safari/`, the way Edge appends `Edg/` — it is just no longer
    /// this file's to get wrong.
    static let safariUserAgentToken: String = userAgent(
        safariVersion: installedSafariVersion,
        ownVersion: appVersion,
        context: .browsing
    )

    /// The installed Safari's version, or `nil` where no Safari can be read.
    ///
    /// The one local input to the Safari signature: read from the installed
    /// copy so it ages with the system instead of freezing at whatever was
    /// current when this shipped. Everything the signature wraps around it —
    /// the `Version/` prefix, the fixed `Safari/605.1.15` suffix, the `"18.3"`
    /// fallback — is the core's to spell (ADR-0119).
    static let installedSafariVersion: String? = Bundle(path: "/Applications/Safari.app")?
        .infoDictionary?["CFBundleShortVersionString"] as? String

    /// This app's own version, or `nil` where the bundle names none.
    ///
    /// The other local input: the bundle in front of the core is the shell's,
    /// and a Linux host will read its own. The `zer0/` spelling and its
    /// fallback are the core's.
    static let appVersion: String? = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String

    /// The UA extension contexts announce (ADR-0106). Carries Chrome's token
    /// alongside Safari's so Chrome-marketplace extensions that gate on UA take
    /// the Chromium path; Safari's signature stays so extensions that *also*
    /// recognise Safari see both, the way Edge and Brave spell their UA. zer0's
    /// own token stays last for the same reason it does on pages (ADR-0008).
    ///
    /// Composed by the same core function the browsing UA comes from, one
    /// context apart (ADR-0119) — the split is one argument, not a second
    /// string this host could drift on.
    static let chromeCompatibleUserAgentToken: String = userAgent(
        safariVersion: installedSafariVersion,
        ownVersion: appVersion,
        context: .webExtension
    )

    /// An ephemeral space gets a store that never touches disk. A persistent
    /// one gets its own identified store, which is what keeps two spaces from
    /// sharing a login.
    private static func dataStore(id: String, profile: SpaceProfile) -> WKWebsiteDataStore {
        if profile.ephemeral {
            return .nonPersistent()
        }
        guard let uuid = UUID(uuidString: id) else {
            // Falling back to the shared store would silently merge cookies
            // across spaces, so isolate instead and lose persistence.
            return .nonPersistent()
        }
        return WKWebsiteDataStore(forIdentifier: uuid)
    }

    func load(_ url: String) {
        guard let target = URL(string: url) else {
            emit(.navigationFailed(
                tab: tab,
                kind: .unsupportedUrl,
                message: "not a usable URL: \(url)"
            ))
            return
        }
        // WebKit refuses file:// through a plain request; it needs explicit
        // read access to the containing directory.
        if target.isFileURL {
            webView.loadFileURL(target, allowingReadAccessTo: target.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: target))
        }
    }

    /// WebKit exposes no public API for muting page audio (only camera and
    /// microphone capture), so this reaches into the page. The flag is kept so
    /// it can be reapplied after every navigation, otherwise a mute would last
    /// only until the next page load.
    func setMuted(_ muted: Bool) {
        isMuted = muted
        applyMute()
    }

    private func applyMute() {
        webView.evaluateJavaScript(
            "document.querySelectorAll('video,audio').forEach(m => m.muted = \(isMuted));"
        )
    }

    // MARK: - WKNavigationDelegate

    /// A link carrying `download`, or one WebKit was told to fetch as a file.
    ///
    /// Without this, clicking `<a download href="...">` on a page whose type
    /// the engine *can* show — an image, a text file — navigates to it instead,
    /// and the page author's explicit "save this" is silently ignored.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        // Nothing a page does may reach one of the browser's own addresses.
        //
        // This is belt and braces, and both are deliberate. The scheme is never
        // registered with WebKit, so there is nothing here that could load a
        // `zer0:` URL even if this returned `.allow` — but "we forgot to give
        // WebKit the scheme" is an absence, and an absence is not a guarantee
        // (AGENTS.md). This is the sentence that says no on purpose, and it is
        // the one that keeps saying no if somebody ever registers a handler for
        // some other reason.
        //
        // It covers the main frame, every subframe and every redirect, because
        // all three arrive here. What it deliberately cannot cover is a
        // subresource load — `<img src="zer0://…">`, `fetch()` — which never
        // reaches a navigation delegate at all. That one is answered by the
        // scheme being unregistered, which is why the scheme being unregistered
        // is the real decision and this is the second lock on it (ADR-0054).
        if isInternal(navigationAction.request.url) {
            decisionHandler(.cancel)
            return
        }
        // A scheme the system owns — `mailto:`, `tel:`, `sms:` — is not the
        // engine's to load, and letting it try costs the person the page they
        // were reading: measured, WebKit fails it as `-1002`, which arrives
        // here as `.unsupportedUrl` and takes the whole screen (ADR-0016).
        //
        // After the check above and never before it, so our own scheme can
        // never be the thing handed to another application (ADR-0092).
        if ExternalScheme.takeOver(navigationAction) {
            decisionHandler(.cancel)
            return
        }
        // A page belonging to an extension may link to the web, and the view it
        // is in cannot go there.
        //
        // **Measured, in a view built from an extension's own configuration:**
        // this delegate is asked about `https://example.com/`, answers `.allow`,
        // and then nothing happens at all — no `didStartProvisionalNavigation`,
        // no failure, no commit. The tab stays on the extension's page and the
        // click reads as a broken button. That is the mirror of the rule
        // `WKWebExtensionContext.h` states in the other direction, it is not
        // documented, and because the engine reports nothing there is no failure
        // to wait for and nothing to retry.
        //
        // So the crossing is taken away from the engine here and made where
        // every other crossing is made — the core replaces the view and loads
        // the address (ADR-0104). This is the second way *into* that door and
        // not a second door: nothing about which view a tab gets is decided
        // here.
        //
        // Read off the page the view is showing rather than off what it was
        // built for, and both halves ask the core what an extension's address
        // is. A view built for an extension that has not loaded yet is showing
        // nothing of the extension's, so its first load is untouched — which is
        // what stops this cancelling the navigation that puts the page there.
        //
        // **Main frame only.** An extension's page embedding a web page in an
        // iframe is a subresource WebKit does load, and re-aiming the tab at one
        // would replace the page somebody is looking at with something meant for
        // a corner of it.
        if navigationAction.targetFrame?.isMainFrame == true,
           let showing = webView.url.flatMap({ extensionBaseHost(url: $0.absoluteString) }),
           let target = navigationAction.request.url?.absoluteString,
           extensionBaseHost(url: target) != showing
        {
            decisionHandler(.cancel)
            emit(.pageLeftExtension(tab: tab, url: target))
            return
        }
        decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
    }

    /// Whether a URL claims the browser's own scheme.
    ///
    /// Asks the core rather than comparing a string here, so the shell cannot
    /// drift into a different idea of what our scheme is than the reducer has.
    private func isInternal(_ url: URL?) -> Bool {
        guard let url, let scheme = url.scheme else { return false }
        return scheme.caseInsensitiveCompare(internalScheme()) == .orderedSame
    }

    /// A response the engine cannot display: a PDF served as an attachment, a
    /// zip, an installer.
    ///
    /// This is the case that made "the browser cannot download a file" true.
    /// Without it WebKit fails the navigation with `WebKitErrorDomain 100`,
    /// which the core reads as cancelled, and the click does nothing at all.
    func webView(
        _: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
    ) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(
        _: WKWebView, navigationAction _: WKNavigationAction, didBecome download: WKDownload
    ) {
        adoptDownload(download, tab)
    }

    func webView(
        _: WKWebView,
        navigationResponse _: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        adoptDownload(download, tab)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
        emit(.navigationStarted(tab: tab, url: webView.url?.absoluteString ?? ""))
    }

    func webView(_ webView: WKWebView, didCommit _: WKNavigation!) {
        emit(.navigationCommitted(tab: tab, url: webView.url?.absoluteString ?? ""))
        // Early, because the chrome takes its colour from here and a window
        // that stays neutral until the last image lands is a window that
        // changes colour after you have started reading. What the engine
        // painted is *not* asked for yet — at commit that is still the previous
        // page's canvas, and reporting it would tint the window in the site we
        // just left.
        reportPageColors(includingCanvas: false)
        // At the commit and not only at the finish, so where the tab has been
        // is never behind what the tab says it is showing: a page that commits
        // and then takes a minute would otherwise leave a session whose stored
        // history names the previous page while `Tab.url` names this one, and a
        // restore would put the tab back on the older of the two.
        reportNavigationState()
    }

    func webView(_: WKWebView, didFinish _: WKNavigation!) {
        if isMuted { applyMute() }
        emit(.navigationFinished(tab: tab))
        reportDeclaredIcons()
        reportPageColors(includingCanvas: true)
        // Again, now the page has settled: the archive carries scroll and form
        // state as well as the list, and this is the version worth keeping.
        reportNavigationState()
    }

    // MARK: - Site icons

    /// Tell the core what this page says its icon is.
    ///
    /// Reading the DOM, because there is nothing else to read. WebKit's modern
    /// surface has no favicon API at all — this was checked against the
    /// installed SDK rather than remembered: no `icon` on `WKWebView`, no
    /// delegate callback, no icon data type on `WKWebsiteDataStore`. The
    /// symbols exist in the binary and none of them are in a header. The only
    /// public way to a page's `<link rel="icon">` is to ask the page.
    ///
    /// Run for every page, including one in an ephemeral space: reading the
    /// DOM sends nothing anywhere. Whether that turns into a request is the
    /// core's call, and the core says no.
    ///
    /// An empty list is reported rather than nothing at all when the script
    /// fails — a PDF, a page with JavaScript off, a page that shadowed
    /// `querySelectorAll` — because empty is what makes the core fall back to
    /// `/favicon.ico`, which is exactly the right guess for a page we could
    /// not read.
    private func reportDeclaredIcons() {
        webView.evaluateJavaScript(Self.iconDiscovery) { [weak self] result, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.emit(.iconsDeclared(
                    tab: self.tab,
                    candidates: Self.candidates(in: result)
                ))
            }
        }
    }

    /// `href` rather than the raw attribute, so the DOM resolves the URL
    /// against the page's own base — the one part of this the page is better
    /// placed to do than we are.
    ///
    /// `apple-touch-icon` is included because on a great many sites it is the
    /// only large icon on offer, and a 180px source is what makes a 16pt badge
    /// sharp. Ranking is not decided here: the core picks.
    private static let iconDiscovery = """
    (function () {
      var out = [], seen = {};
      function add(link) {
        if (out.length >= 16) { return; }
        var href = link.href;
        if (!href || seen[href]) { return; }
        seen[href] = true;
        var largest = 0;
        (link.getAttribute('sizes') || '').toLowerCase().split(/\\s+/).forEach(function (s) {
          var m = /^(\\d+)x(\\d+)$/.exec(s);
          if (m) { largest = Math.max(largest, +m[1], +m[2]); }
        });
        out.push({ url: href, size: largest });
      }
      document.querySelectorAll('link[rel~="icon" i]').forEach(add);
      document.querySelectorAll(
        'link[rel~="apple-touch-icon" i], link[rel~="apple-touch-icon-precomposed" i]'
      ).forEach(add);
      return out;
    })()
    """

    /// Everything in here came out of a page, so none of it is trusted: the
    /// list is capped, a missing or unusable size becomes "unstated" rather
    /// than a number, and an absurd one is clamped. What survives is still
    /// only a *suggestion* — the core checks every URL before anything is
    /// fetched.
    static func candidates(in result: Any?) -> [IconCandidate] {
        guard let rows = result as? [[String: Any]] else { return [] }

        return rows.prefix(16).compactMap { row in
            guard let url = row["url"] as? String, !url.isEmpty else { return nil }
            let declared = (row["size"] as? NSNumber)?.intValue ?? 0
            return IconCandidate(
                url: url,
                sizePx: declared > 0 ? UInt32(min(declared, 4096)) : nil
            )
        }
    }

    // MARK: - Reading the page for a conversation

    /// Read this page so a conversation can be told what it is looking at.
    ///
    /// Run only because somebody asked about the page. Nothing here fires on
    /// navigation, on focus or on a timer: page text leaves the page when it
    /// was asked for and at no other moment.
    ///
    /// An answer is always reported, including when the script returned
    /// nothing — a PDF, a page with JavaScript off, a page that shadowed
    /// `innerText`. The core holds the question until this arrives, so a host
    /// that stayed quiet on failure would leave a thread waiting forever. A
    /// page nobody could read still has an address worth telling the model.
    func capturePageContext(conversation: ConversationId, maxChars: UInt32) {
        let url = webView.url?.absoluteString ?? ""
        let title = webView.title ?? ""

        webView.evaluateJavaScript(Self.textDiscovery(maxChars: maxChars)) { [weak self] result, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.emit(.pageContextCaptured(
                    conversation: conversation,
                    url: url,
                    title: title,
                    text: result as? String ?? ""
                ))
            }
        }
    }

    /// What a person would read off the page, cut where the core asked.
    ///
    /// `innerText` rather than the markup, because the markup is mostly script
    /// and styling — sending it would spend the model's context on things
    /// nobody can see. Written defensively (ADR-0024): a page may have no body
    /// yet, and it may have shadowed anything.
    private static func textDiscovery(maxChars: UInt32) -> String {
        """
        (function () {
          try {
            var body = document.body;
            if (!body) { return ""; }
            return String(body.innerText || "").slice(0, \(maxChars));
          } catch (e) { return ""; }
        })()
        """
    }

    // MARK: - The colour of the page

    /// Tell the core what colour this page is.
    ///
    /// Three sources, reported together and never merged here, because which
    /// one wins is the core's decision (ADR-0047). A host that flattened them
    /// into one list would be choosing the fallback order for itself, and the
    /// Linux host would be free to choose a different one.
    ///
    /// The `media` query on a `<meta name="theme-color">` is resolved *in the
    /// page*, which is the only place it can be: matching
    /// `(prefers-color-scheme: dark)` needs the view's own idea of the
    /// appearance it is drawn in. The page answers whether each declaration
    /// applies; the core picks which applying one to take.
    ///
    /// Sampled exactly twice per navigation and never on a timer. A page that
    /// animates its `theme-color` cannot make the window strobe, because we are
    /// not watching.
    private func reportPageColors(includingCanvas: Bool) {
        // Read before the async hop: by the time the script answers, a fast
        // second navigation could have moved the canvas on.
        let canvas = includingCanvas ? Self.cssColor(webView.underPageBackgroundColor) : nil

        webView.evaluateJavaScript(Self.colorDiscovery) { [weak self] result, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let page = result as? [String: Any]
                self.emit(.colorsDeclared(
                    tab: self.tab,
                    themeColors: Self.themeColors(in: page?["theme"]),
                    elementBackgrounds: Self.strings(in: page?["backgrounds"]),
                    canvasBackground: canvas
                ))
            }
        }
    }

    /// What the page says its colour is, read from the page because there is
    /// nowhere else to read it.
    ///
    /// Written defensively on purpose (ADR-0024): a page may have shadowed
    /// `getComputedStyle`, may have no `body` yet at commit, and may declare a
    /// `media` query that throws. Each of those costs one missing value rather
    /// than the whole answer, and a script that fails entirely returns nothing
    /// at all — which the core reads as "no colour", not as "black".
    private static let colorDiscovery = """
    (function () {
      var out = { theme: [], backgrounds: [] };
      try {
        var metas = document.querySelectorAll('meta[name="theme-color" i]');
        for (var i = 0; i < metas.length && out.theme.length < 8; i++) {
          var media = metas[i].getAttribute('media');
          var matches = true;
          try { matches = !media || window.matchMedia(media).matches; } catch (e) { matches = false; }
          out.theme.push({
            value: String(metas[i].getAttribute('content') || ''),
            matches: matches
          });
        }
      } catch (e) {}
      try {
        [document.documentElement, document.body].forEach(function (element) {
          if (!element) { return; }
          var painted = window.getComputedStyle(element).backgroundColor;
          if (painted) { out.backgrounds.push(String(painted)); }
        });
      } catch (e) {}
      return out;
    })()
    """

    /// The declarations, capped and with every field forced to the shape the
    /// core expects. Everything in here came out of a page.
    static func themeColors(in value: Any?) -> [DeclaredColor] {
        guard let rows = value as? [[String: Any]] else { return [] }

        return rows.prefix(8).compactMap { row in
            guard let content = row["value"] as? String, !content.isEmpty else { return nil }
            return DeclaredColor(
                value: content,
                // A declaration whose query we could not evaluate is not one we
                // can claim applies.
                matchesAppearance: row["matches"] as? Bool ?? false
            )
        }
    }

    static func strings(in value: Any?) -> [String] {
        guard let rows = value as? [String] else { return [] }
        return Array(rows.prefix(8))
    }

    /// A `WKWebView`'s idea of what sits behind the page, as CSS.
    ///
    /// This is the rung that answers for most of the web. A page that sets no
    /// background on `html` or `body` — which is most of them — computes to
    /// `rgba(0, 0, 0, 0)` twice over, and the only thing that knows the page is
    /// nevertheless white is the engine that painted it.
    ///
    /// Serialised rather than interpreted: whether this colour is usable, and
    /// what it means if it is, is decided in the core along with every other
    /// source.
    static func cssColor(_ color: NSColor?) -> String? {
        guard let srgb = color?.usingColorSpace(.sRGB) else { return nil }
        var (r, g, b, a) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
        srgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(
            format: "rgba(%.0f, %.0f, %.0f, %.4f)",
            r * 255, g * 255, b * 255, a
        )
    }

    func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) {
        emit(fail(with: error))
    }

    func webView(
        _: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error
    ) {
        emit(fail(with: error))
    }

    private func fail(with error: Error) -> Action {
        .navigationFailed(
            tab: tab,
            kind: Self.kind(of: error),
            message: error.localizedDescription
        )
    }

    /// Translate WebKit's error into the core's category.
    ///
    /// This is the only place that knows what `NSURLErrorDomain` is, which is
    /// the point: the domain and code are exact and unreadable, and a Linux
    /// host will have entirely different numbers meaning the same things. What
    /// the categories *mean* is decided in the core; picking one from a
    /// platform error is the host's job.
    private static func kind(of error: Error) -> NavigationErrorKind {
        let error = error as NSError

        switch error.domain {
        case NSURLErrorDomain:
            return urlErrorKind(error.code)
        case "WebKitErrorDomain":
            return webKitErrorKind(error.code)
        default:
            return .unknown
        }
    }

    private static func urlErrorKind(_ code: Int) -> NavigationErrorKind {
        switch code {
        case NSURLErrorNotConnectedToInternet,
             NSURLErrorDataNotAllowed,
             NSURLErrorInternationalRoamingOff:
            .offline

        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            .hostNotFound

        case NSURLErrorTimedOut:
            .timeout

        case NSURLErrorCannotConnectToHost,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorResourceUnavailable,
             NSURLErrorBadServerResponse,
             NSURLErrorCannotLoadFromNetwork:
            .connectionFailed

        // Every TLS failure is one category on purpose: the difference between
        // an expired certificate and an unknown root is not a difference the
        // person reading the screen can act on.
        case NSURLErrorSecureConnectionFailed,
             NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid,
             NSURLErrorClientCertificateRejected,
             NSURLErrorClientCertificateRequired:
            .certificateInvalid

        case NSURLErrorUnsupportedURL,
             NSURLErrorBadURL,
             NSURLErrorFileDoesNotExist,
             NSURLErrorFileIsDirectory:
            .unsupportedUrl

        case NSURLErrorCancelled:
            .cancelled

        default:
            .unknown
        }
    }

    /// WebKit's own domain ships no public constants, so the codes are spelled
    /// out. They are stable and documented in `WebKitErrors.h`.
    private static func webKitErrorKind(_ code: Int) -> NavigationErrorKind {
        switch code {
        // 100 (cannot show MIME type) and 102 (frame load interrupted by a
        // policy change) are what a download looks like from here, and what a
        // link handed to another app looks like. Both leave a page that is
        // working; neither is a failure to report.
        case 100, 102:
            .cancelled
        case 101:
            .unsupportedUrl
        default:
            .unknown
        }
    }
}

/// Carries out `EngineCommand`s and owns the live web views.
///
/// This is the seam the whole architecture rests on: swapping WebKit for
/// another engine means writing another one of these, not touching the core.
@MainActor
final class EngineHost {
    private var hosted: [TabId: HostedWebView] = [:]

    /// The views the engine has built and nobody owns yet, oldest first.
    ///
    /// It exists for the length of a single synchronous dispatch and no longer:
    /// `adopt` puts one here, sends the action, and the `AdoptWebView` the
    /// reducer answers with picks it up on the way back through `perform`. A
    /// field rather than a parameter because the core is between the two halves
    /// and the core does not carry `WKWebViewConfiguration`s.
    ///
    /// A queue rather than one slot, because the delegate must answer
    /// synchronously and nothing on our side of the FFI controls whether
    /// WebKit ever asks for a second view while the first is still being
    /// adopted. Measured on this SDK it does not — each `createWebViewWith`
    /// runs to completion before the next arrives — but that is an engine's
    /// behaviour, not a promise, and the cost of relying on it was answering a
    /// second approved `window.open` with `nil`, which is the page's spelling
    /// of a pop-up blocker nobody configured. Order is the pairing: actions
    /// and their commands cross the core one dispatch at a time, so the oldest
    /// pending configuration is always the one the oldest `AdoptWebView` is
    /// for.
    private var pendingPopups: [PendingPopup] = []

    /// A `WKWebViewConfiguration` the engine handed over, and the view built
    /// from it once the core has said what tab it is.
    ///
    /// A class rather than a struct so `perform` can fill in `adopted` and
    /// `adopt` can read it back without either of them holding the other.
    private final class PendingPopup {
        let configuration: WKWebViewConfiguration
        /// The opener's, copied because it lives on the **view** and not on the
        /// configuration: a space with a user agent of its own would otherwise
        /// have pop-ups that report a different browser than every other page
        /// in it.
        let userAgent: String?
        var adopted: WKWebView?

        init(configuration: WKWebViewConfiguration, userAgent: String?) {
            self.configuration = configuration
            self.userAgent = userAgent
        }
    }

    /// A page asked for a view of its own. Hand back one, or refuse.
    ///
    /// **The configuration is the engine's and is used as given.** Measured on
    /// this SDK, it carries the opener's `websiteDataStore`, its
    /// `userContentController` and its `WKPreferences` as the *same objects* —
    /// so the pop-up inherits the space's cookie jar, its block list, its
    /// injected scripts and every answer on `EnginePolicy`'s sheet, and it
    /// inherits them structurally rather than by being reconfigured to match.
    /// A view built from a configuration of our own would be a different
    /// browsing context: no `window.opener`, no `postMessage` home, no
    /// `window.close()`, which is every OAuth flow half-working (ADR-0075).
    ///
    /// Returning `nil` is what a pop-up blocker looks like from the page's
    /// side: `window.open` evaluates to `null` and nothing happens. So it is
    /// only ever done when the core refused, never to paper over a state this
    /// host got into.
    func adopt(
        configuration: WKWebViewConfiguration,
        openedBy opener: TabId,
        request: WindowRequest
    ) -> WKWebView? {
        let pending = PendingPopup(
            configuration: configuration,
            userAgent: hosted[opener]?.webView.customUserAgent
        )
        pendingPopups.append(pending)
        // Ours alone to take back: the core may answer this open with no
        // `AdoptWebView` at all — the opener's tab is gone — and a pending
        // nobody claims would otherwise sit at the front of the queue and be
        // handed to the next adoption, which is somebody signing in as the
        // wrong person.
        defer { pendingPopups.removeAll { $0 === pending } }

        // Synchronous all the way down: this reaches `BrowserModel.send`, which
        // dispatches into the core and performs what comes back before it
        // returns. That is what lets a delegate method with a return value ask
        // the core a question at all.
        emit?(.pageOpenedWindow(opener: opener, request: request))
        return pending.adopted
    }

    /// Everything coming down. Lives here rather than per web view: a download
    /// outlives the tab that started it, and closing that tab must not take
    /// the file with it.
    let downloads = DownloadHost()

    /// The decision handlers the engine has given us for questions a page
    /// asked. On the host rather than on a web view, because a tab can close
    /// while the core is still deciding and the page is still owed an answer.
    let sitePermissions = SitePermissionLedger()

    /// The completion handlers for servers asking who you are, and for
    /// certificates that did not check out.
    ///
    /// Here rather than on a web view, for a sharper version of the reason
    /// `sitePermissions` is here: a tab can close while a password panel is on
    /// screen, and a challenge left unanswered is a navigation that — measured
    /// — never finishes and never fails. See `AuthChallengeHost.swift`.
    let authChallenges = AuthChallengeLedger()

    /// The same, for the questions a page asks in its own words: `alert()`,
    /// `confirm()`, `prompt()` and the file control. A second ledger rather
    /// than one, because the two hold different kinds of handler and a map that
    /// held either would need a discriminant anyway (ADR-0089).
    let pageDialogs = PageDialogLedger()

    /// Site icons, fetched outside every web view on purpose. See `SiteIcons`.
    let icons = IconFetcher()

    /// Set by the model so engine events can travel back into the reducer.
    var emit: (@MainActor (Action) -> Void)? {
        didSet {
            downloads.emit = emit
            icons.emit = emit
        }
    }

    /// The engine settings a person can change (ADR-0074).
    ///
    /// A stored value with a shipped default rather than a closure the host
    /// reads through: a host nobody configured still blocks, which is the safe
    /// direction.
    ///
    /// The two settings here make two different promises, because the engine
    /// gives them two different reaches and saying otherwise would be a lie in
    /// a Settings row (ADR-0018).
    ///
    /// Autoplay lives on the configuration, and `WKWebView.configuration` is a
    /// copy — measured, a write to it after the view exists is dropped and the
    /// property keeps its old value. So that one reaches views built from now
    /// on and nothing else.
    ///
    /// The pop-up blocker lives on `WKPreferences`, which the copy still shares,
    /// so it can be pushed at every open page and lands on that page's next
    /// load. That is what the loop below is for, and it is why the two rows in
    /// Settings do not read the same.
    var policy = EnginePolicy.Choices() {
        didSet {
            guard policy != oldValue else { return }
            for view in hosted.values {
                EnginePolicy.reapply(
                    to: view.webView.configuration.preferences,
                    choices: policy
                )
            }
        }
    }

    /// Set by the model to attach the extension controller to new views.
    var configureExtensions: ((WKWebViewConfiguration) -> Void)?

    /// Asked for the one configuration a page belonging to an extension may be
    /// shown in. `nil` for a host no loaded extension answers to.
    ///
    /// A closure rather than a reference to `ExtensionHost`, for the reason
    /// every other seam here is one: this host performs and does not decide.
    /// Which extensions are loaded, and which uuid each one was given, is not a
    /// web view's business — and asking through a closure keeps this file from
    /// knowing that `WKWebExtensionContext` exists.
    var extensionPageConfiguration: ((String) -> WKWebViewConfiguration?)?

    /// Set by the model to put the compiled block list on new views.
    ///
    /// Separate from `configureExtensions`, and it runs **after** it, because
    /// that one may install a `WKUserContentController` of its own — the
    /// extension controller. A rule list added to the controller that was
    /// replaced a moment later is attached to nothing.
    var configureBlocking: ((WKWebViewConfiguration) -> Void)?

    /// Set by the model to inject the Chrome Web Store install script.
    ///
    /// Takes the tab because the script's channel answers for one view, and the
    /// tab is known here, where the view is made. A handler that has to look up
    /// which tab it belongs to is a handler that can answer for the wrong one.
    var configureStoreInstall: ((WKWebViewConfiguration, TabId) -> Void)?

    /// Set by the model to inject the login-form script (ADR-0064).
    ///
    /// Takes the tab for a sharper version of the reason `configureStoreInstall`
    /// does: the tab names the Space, a Space is an identity, and a handler that
    /// answered for the wrong tab would offer the wrong person's password.
    var configurePasswords: ((WKWebViewConfiguration, TabId) -> Void)?

    /// Bring up the window one of the browser's own addresses resolves to.
    ///
    /// A closure rather than a reference to the model, for the reason every
    /// other seam here is one: this host performs and does not decide. Which
    /// window `zer0://history` means is the core's answer, and where a window
    /// comes from is the model's business (ADR-0054).
    var raiseWindow: (@MainActor (UiCommand) -> Void)?

    /// What Settings calls the configured search engine, asked of the core each
    /// time rather than remembered: the row in a context menu has to name the
    /// engine somebody chose a minute ago, not the one this host was built with
    /// (ADR-0091). `nil` is a template nobody has a name for.
    var searchEngineName: (@MainActor () -> String?)?

    /// Put a browser window on screen, and take one off it. Closures for the
    /// same reason `raiseWindow` is one: which windows exist is the core's
    /// answer and materialising a scene is the app's, and neither is a web
    /// view's business.
    var openBrowserWindow: (@MainActor (WindowId) -> Void)?
    var closeBrowserWindow: (@MainActor (WindowId) -> Void)?

    /// Whatever answers a question. Set by the model once configuration has
    /// been read; until then every request lands on `UnconfiguredChatHost`,
    /// which says so rather than swallowing it.
    var chat: ChatHost?

    func webView(for tab: TabId) -> WKWebView? {
        hosted[tab]?.webView
    }

    /// The content controller of every live web view.
    ///
    /// Read off `webView.configuration` rather than remembered from creation:
    /// `WKWebView` copies the configuration it is given, so the object a view
    /// actually consults is the one to reach for when a rule list changes under
    /// an open tab.
    var contentControllers: [WKUserContentController] {
        hosted.values.map { $0.webView.configuration.userContentController }
    }

    func perform(_ commands: [EngineCommand]) {
        for command in commands {
            perform(command)
        }
    }

    /// A page of the web, in the cookie jar of the space its tab is in.
    private func ordinaryPage(
        tab: TabId, dataStoreId: String, profile: SpaceProfile
    ) -> HostedWebView {
        HostedWebView(
            tab: tab,
            dataStoreId: dataStoreId,
            profile: profile,
            policy: policy,
            configure: { [weak self] config in
                self?.configureExtensions?(config)
                self?.configureStoreInstall?(config, tab)
                self?.configurePasswords?(config, tab)
                // Last, so it lands on whichever controller the three above
                // left in place rather than on one that has been replaced.
                self?.configureBlocking?(config)
            },
            adoptDownload: { [weak self] download, tab in
                self?.downloads.adopt(download, tab: tab)
            },
            permissions: sitePermissions,
            dialogs: pageDialogs,
            authChallenges: authChallenges,
            openWindow: { [weak self] configuration, opener, request in
                self?.adopt(configuration: configuration, openedBy: opener, request: request)
            }
        ) { [weak self] action in
            self?.emit?(action)
        }
    }

    /// A page belonging to an extension: its options screen, its onboarding,
    /// anything it opens for itself.
    ///
    /// **Built from the extension's own configuration and from no other.**
    /// `WKWebExtensionContext.h` says a navigation to an extension's address is
    /// *cancelled* in a view built from anything else, and measured — same
    /// address, same run — an ordinary page configuration leaves the view at
    /// `about:blank` while this one loads and reports its title.
    ///
    /// Nothing is put on it on the way through, and each omission is doing a
    /// job rather than being a gap:
    ///
    /// - **No `EnginePolicy.apply`.** This is the engine's object, already
    ///   carrying the controller, its content controller and the User-Agent
    ///   `ExtensionHost.configuration` set on it. Writing over it would be this
    ///   host deciding an extension's own screen is a different kind of client
    ///   from every other page (ADR-0075's rule, one door along).
    /// - **No data store.** It arrives with WebKit's shared, persistent one and
    ///   will not take another: measured, assigning a space's identified store
    ///   or a non-persistent one leaves `WKWebView.init` **never returning**,
    ///   while the same assignments on an ordinary configuration build a view
    ///   and load a page. That is why the core refuses one of these in a space
    ///   that records nothing rather than trying to make it ephemeral.
    ///
    /// `nil` refuses, out loud. A base host nothing loaded is an address to no
    /// extension — most plausibly one restored from a session written before
    /// this launch, since WebKit mints the host per context — and a view built
    /// for it would cancel the load and leave a blank tab explaining nothing.
    private func extensionPage(tab: TabId, baseHost: String) -> HostedWebView? {
        guard let configuration = extensionPageConfiguration?(baseHost) else {
            emit?(.navigationFailed(
                tab: tab,
                kind: .unsupportedUrl,
                message: ExtensionPageError.noSuchExtension.localizedDescription
            ))
            return nil
        }
        // Before the view exists, the same as every other page: switching it on
        // afterwards does not reach a page that has already loaded (ADR-0067).
        WebInspector.allowInspection(of: configuration)

        return HostedWebView(
            tab: tab,
            webView: PageView(frame: .zero, configuration: configuration),
            adoptDownload: { [weak self] download, tab in
                self?.downloads.adopt(download, tab: tab)
            },
            permissions: sitePermissions,
            dialogs: pageDialogs,
            authChallenges: authChallenges,
            openWindow: { [weak self] configuration, opener, request in
                self?.adopt(configuration: configuration, openedBy: opener, request: request)
            }
        ) { [weak self] action in
            self?.emit?(action)
        }
    }

    private func perform(_ command: EngineCommand) {
        switch command {
        case let .createWebView(tab, configuration, navigationState):
            let built: HostedWebView?
            switch configuration {
            case let .space(dataStoreId, profile):
                built = ordinaryPage(
                    tab: tab, dataStoreId: dataStoreId, profile: profile
                )
            case let .extension(baseHost):
                built = extensionPage(tab: tab, baseHost: baseHost)
            }
            guard let created = built else { return }
            created.webView.searchEngineName = { [weak self] in self?.searchEngineName?() }
            hosted[tab] = created
            // After `hosted[tab]`, so a view that is refused its history is
            // already reachable by the `LoadUrl` the core answers with. The
            // engine is the only thing that can say whether these bytes were a
            // back/forward list, and it says so on the next line — so the
            // refusal is reported rather than guessed at, and the core decides
            // what a tab with no history is owed.
            if let navigationState {
                if created.restore(navigationState: navigationState) {
                    // The list is whole the moment the engine takes the
                    // archive, and the core should not wait for the commit
                    // that loads the page on top of it to learn that Back
                    // works here — a relaunch would otherwise open with every
                    // tab answering "nothing behind me" until each page
                    // finishes loading.
                    created.reportNavigationStack()
                } else {
                    emit?(.navigationStateRefused(tab: tab))
                }
            }

        case let .adoptWebView(tab):
            // Only ever in answer to `adopt` above, which is the only thing
            // that fills this, and the oldest one first — the order actions
            // and commands crossed the core in. Nothing to fall back on if it
            // is empty: a view built here from a configuration of our own
            // would satisfy the command and break the opener relationship
            // silently, which is exactly the repair that guesses (AGENTS.md).
            guard let pending = pendingPopups.popFirst() else { return }

            let view = PageView(frame: .zero, configuration: pending.configuration)
            if let agent = pending.userAgent, !agent.isEmpty {
                view.customUserAgent = agent
            }
            let adopted = HostedWebView(
                tab: tab,
                webView: view,
                adoptDownload: { [weak self] download, tab in
                    self?.downloads.adopt(download, tab: tab)
                },
                permissions: sitePermissions,
                dialogs: pageDialogs,
                authChallenges: authChallenges,
                openWindow: { [weak self] configuration, opener, request in
                    self?.adopt(configuration: configuration, openedBy: opener, request: request)
                }
            ) { [weak self] action in
                self?.emit?(action)
            }
            adopted.webView.searchEngineName = { [weak self] in self?.searchEngineName?() }
            hosted[tab] = adopted
            pending.adopted = view

        case let .destroyWebView(tab):
            hosted[tab]?.webView.stopLoading()
            hosted.removeValue(forKey: tab)

        case let .loadUrl(tab, url):
            hosted[tab]?.load(url)

        case let .reload(tab, fromOrigin):
            guard let view = hosted[tab]?.webView else { return }
            _ = fromOrigin ? view.reloadFromOrigin() : view.reload()

        case let .goBack(tab):
            hosted[tab]?.webView.goBack()

        case let .goForward(tab):
            hosted[tab]?.webView.goForward()

        case let .setMuted(tab, muted):
            hosted[tab]?.setMuted(muted)

        case let .setZoom(tab, factor):
            hosted[tab]?.webView.pageZoom = factor

        case let .deleteDataStore(dataStoreId):
            guard let uuid = UUID(uuidString: dataStoreId) else { return }
            // The space is gone; leaving its cookies on disk would be a
            // privacy leak with no way to reach them from the UI.
            WKWebsiteDataStore.remove(forIdentifier: uuid) { _ in }

        case let .acceptDownload(id, path):
            downloads.accept(id: id, path: path)

        case let .askDownloadDestination(id, directory, filename):
            downloads.ask(id: id, directory: directory, filename: filename)

        case let .cancelDownload(id):
            downloads.cancel(id: id)

        case let .startDownload(tab, url):
            startDownload(url, in: tab)

        case let .resumeDownload(tab, id):
            // The view is handed over even when it is gone: unlike a start, the
            // core has already put this row back to arriving, so a silent return
            // would leave it saying so forever. `resume` refuses out loud.
            downloads.resume(id: id, in: hosted[tab]?.webView, tab: tab)

        case let .printPage(tab):
            printPage(tab)

        case let .fetchIcon(dataStoreId, host, url, maxBytes):
            icons.fetch(
                dataStoreId: dataStoreId,
                host: host,
                url: url,
                maxBytes: maxBytes
            )

        case let .startChatReply(conversation, message, transcript, tools):
            chat?.startReply(
                conversation: conversation,
                message: message,
                transcript: transcript,
                tools: tools
            )

        case let .cancelChatReply(message):
            chat?.cancelReply(message: message)

        case let .runToolCall(conversation, invocation):
            chat?.runToolCall(conversation: conversation, invocation: invocation)

        case let .cancelToolCall(call):
            chat?.cancelToolCall(call: call)

        case let .listTools(server):
            chat?.listTools(server: server)

        case let .raiseWindow(command):
            // No tab changes and no web view is touched. Going to
            // `zer0://settings` puts Settings in front of the page you were
            // reading and leaves you on it (ADR-0054).
            raiseWindow?(command)

        // A browser window is a scene, not a web view. This host owns views and
        // knows nothing about where they are drawn, so both are handed straight
        // on to whoever does (ADR-0065).
        case let .openBrowserWindow(window):
            openBrowserWindow?(window)

        case let .closeBrowserWindow(window):
            closeBrowserWindow?(window)

        case let .capturePageContext(conversation, tab, maxChars):
            guard let hosted = hosted[tab] else {
                // The tab went away between the question and the read. The
                // conversation is holding its question on this answer, so an
                // empty one still has to arrive.
                emit?(.pageContextCaptured(
                    conversation: conversation,
                    url: "",
                    title: "",
                    text: ""
                ))
                return
            }
            hosted.capturePageContext(conversation: conversation, maxChars: maxChars)

        case let .answerHttpAuth(request, decision):
            // The one call that lets the navigation move. Exactly one of these
            // arrives per challenge, including for the ones the core refused
            // without asking anybody — a handler nobody calls is a tab that
            // holds a white rectangle for as long as the browser is open.
            authChallenges.answer(request, decision)

        case let .answerServerTrust(request, decision):
            authChallenges.answer(request, decision)

        case let .answerSitePermission(request, decision):
            // The one call that settles the page's promise. Exactly one of
            // these arrives per request, including for the ones the core
            // refused without asking anybody.
            sitePermissions.answer(request, decision)

        case let .stopCapture(tab, capability):
            hosted[tab]?.stopCapture(capability)

        case let .answerPageDialog(request, answer):
            // The call that lets the script carry on. Exactly one of these
            // arrives per request, including for the ones the core cancelled
            // without anybody being shown anything — a page waiting inside
            // `alert()` is frozen until this runs (ADR-0089).
            pageDialogs.answer(request, answer)

        case .focusWebView:
            // The view hierarchy follows the core's active tab, so SwiftUI
            // already handles this by re-rendering. Kept explicit so the
            // command is not silently dropped.
            break
        }
    }
}

private extension Array {
    /// The front of the queue, or nothing.
    ///
    /// Spelled out because `removeFirst` traps on an empty array, and a trap
    /// in the adoption path is a browser that dies because nobody asked for a
    /// view — the refusal is the answer, not a crash.
    mutating func popFirst() -> Element? {
        isEmpty ? nil : removeFirst()
    }
}
