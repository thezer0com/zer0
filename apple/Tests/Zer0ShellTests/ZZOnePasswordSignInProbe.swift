import AppKit
import Foundation
import Testing
import WebKit
import Zer0Core

@testable import Zer0Shell

/// Throwaway probe: press 1Password's "Sign in" on its own welcome page, in a
/// real `BrowserModel`, and record what the press *calls* rather than what it
/// looks like it should call.
///
/// Not a lock. Nothing in CI may depend on 1Password being installed, and this
/// downloads the real package from the store.
/// Records every navigation decision WebKit asks about, so "the delegate said
/// no" and "WebKit never asked" can be told apart.
@MainActor
final class LeaveWatcher: NSObject, WKNavigationDelegate {
    var log: [String] = []

    func webView(
        _: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        log.append("asked about \(navigationAction.request.url?.absoluteString ?? "<nil>") "
            + "(type \(navigationAction.navigationType.rawValue)) -> allow")
        decisionHandler(.allow)
    }

    func webView(_: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
        log.append("started")
    }

    func webView(
        _: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: any Error
    ) {
        log.append("failed provisional: \(error)")
    }

    func webView(_: WKWebView, didFail _: WKNavigation!, withError error: any Error) {
        log.append("failed: \(error)")
    }

    func webView(_ webView: WKWebView, didCommit _: WKNavigation!) {
        log.append("committed \(webView.url?.absoluteString ?? "<nil>")")
    }
}

/// Exercises 1Password's welcome flow as far as the "Sign in" control.
///
/// Discovered 2026-08-11: 1Password's "Sign in" button opens a web tab at
/// my.1password.com/signin?auth-only=1 — it does not call `connectNative`.
/// This probe never exercises native messaging; use `ZZNativeMessagingProbe`
/// for that. What this probe does cover: extension load, UA detection as
/// Chrome, welcome page drive ("Continue" → reveal "Sign in"), and the
/// runtime state of the extension (`desktopAppState`, `accounts`).
@MainActor
struct OnePasswordSignInProbe {
    static var out: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["ZER0_PROBE_DIR"]
            ?? NSTemporaryDirectory())
    }

    /// Wraps every way this page could leave itself, before the page's own
    /// scripts run. Records the call, its arguments, where it was called from,
    /// and — for `runtime.sendMessage` — what came back, because the answer to
    /// `app-ready` is where the state that decides the branch lives.
    static let instrument = """
    (function () {
      if (window.__z) { return; }
      window.__z = { calls: [], errors: [], took: {} };
      var rec = function (what, arg) {
        var text;
        try { text = JSON.stringify(arg); } catch (e) { text = String(arg); }
        window.__z.calls.push(what + ' ' + (text || '').slice(0, 600) + ' @ ' +
          ((new Error()).stack || '').split('\\n').slice(1, 4).join(' | '));
      };
      ['chrome', 'browser'].forEach(function (ns) {
        var api = window[ns];
        if (!api) { return; }
        if (api.tabs && api.tabs.create) {
          var create = api.tabs.create.bind(api.tabs);
          try {
            api.tabs.create = function (o) { rec(ns + '.tabs.create', o); return create(o); };
          } catch (e) {}
          window.__z.took[ns + '.tabs.create'] =
            String(api.tabs.create).indexOf('rec(') !== -1;
        }
        if (api.tabs && api.tabs.update) {
          var update = api.tabs.update.bind(api.tabs);
          try {
            api.tabs.update = function () {
              rec(ns + '.tabs.update', Array.from(arguments));
              return update.apply(null, arguments);
            };
          } catch (e) {}
        }
        if (!api.runtime) { return; }
        ['sendMessage', 'connect', 'connectNative', 'sendNativeMessage'].forEach(function (name) {
          if (typeof api.runtime[name] !== 'function') { return; }
          var original = api.runtime[name].bind(api.runtime);
          try {
            api.runtime[name] = function () {
              var args = Array.from(arguments);
              rec(ns + '.runtime.' + name, args);
              var answer = original.apply(null, args);
              var about = (args[0] && args[0].name) || '?';
              if (answer && typeof answer.then === 'function') {
                answer.then(
                  function (v) {
                    rec(ns + '.runtime.' + name + '(' + about + ') -> ok',
                      v === undefined ? '<undefined>' : v);
                  },
                  function (e) {
                    rec(ns + '.runtime.' + name + '(' + about + ') -> threw', String(e));
                  }
                );
              }
              return answer;
            };
          } catch (e) {}
          window.__z.took[ns + '.runtime.' + name] =
            String(api.runtime[name]).indexOf('rec(') !== -1;
        });
      });
      var open = window.open;
      window.open = function () {
        rec('window.open', Array.from(arguments));
        return open.apply(window, arguments);
      };
      window.__z.took['window.open'] = String(window.open).indexOf('rec(') !== -1;
      var close = window.close;
      window.close = function () { rec('window.close', null); return close.apply(window); };
      window.__z.took['window.close'] = String(window.close).indexOf('rec(') !== -1;
      window.addEventListener('error', function (e) {
        window.__z.errors.push('error: ' + (e.message || '') + ' @ ' + (e.filename || ''));
      });
      window.addEventListener('unhandledrejection', function (e) {
        window.__z.errors.push('rejection: ' + String(e.reason) +
          ' @ ' + ((e.reason && e.reason.stack) || '').split('\\n').slice(0, 3).join(' | '));
      });
      window.addEventListener('beforeunload', function () {
        window.__z.calls.push('beforeunload from ' + location.href);
      });
    })();
    """

    static func say(_ line: String) {
        print("[probe] \(line)")
        let file = out.appendingPathComponent("signin.log")
        let text = line + "\n"
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    private func js(_ view: WKWebView, _ source: String) async -> String {
        do {
            let value = try await view.evaluateJavaScript(source)
            if let value = value as? String { return value }
            if let value { return String(describing: value) }
            return "<nil>"
        } catch {
            return "<threw: \(error)>"
        }
    }

    /// Everything the page can say about itself, in one place.
    private func snapshot(_ model: BrowserModel, _ label: String) {
        Self.say("--- \(label) ---")
        for tab in model.snapshot.tabs {
            let url = tab.url ?? tab.pendingUrl ?? "<none>"
            Self.say("  tab \(tab.id): url=\(url) title=\(tab.title ?? "<nil>") "
                + "error=\(String(describing: tab.lastError?.kind))")
        }
        Self.say("  pendingNativeHost=\(String(describing: model.pendingNativeHost?.host.program))")
    }

    /// The instrument beneath the one below: does an extension's own page get an
    /// answer from its own background worker in this browser at all?
    ///
    /// 1Password's app asks its worker three questions while it boots and draws
    /// nothing until they come back, so "the page is blank" and "the worker
    /// never answers" have to be told apart before anything else is believed.
    @Test(
        "an extension page gets an answer from its own worker",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    func pageTalksToItsWorker() async throws {
        let model = BrowserModel(storagePath: nil)
        let host = try #require(model.extensions)
        let fixture = try ExtensionFixture(
            id: String(repeating: "e", count: 32),
            backgroundScript: """
            chrome.storage.local.set({ workerRan: 'yes' });
            chrome.runtime.onMessage.addListener((message, sender, reply) => {
              chrome.storage.local.set({ workerHeard: message.name });
              if (message.name === 'async') {
                setTimeout(() => reply({ heard: message.name }), 10);
                return true;
              }
              reply({ heard: message.name });
            });
            chrome.runtime.onConnect.addListener((port) => {
              chrome.storage.local.set({ workerConnected: port.name });
              port.onMessage.addListener((m) => port.postMessage({ heard: m.name }));
            });
            """,
            pages: [
                "page.html": """
                <!doctype html><html><body><div id="out">{}</div>
                <script src="page.js"></script></body></html>
                """,
                // An extension page's default CSP is `script-src 'self'`, so an
                // inline script is blocked and the page sits at its initial
                // markup — which is exactly the reading a broken worker gives.
                // The first draft of this probe made that mistake.
                "page.js": """
                const out = {};
                const show = () => {
                  document.getElementById('out').textContent = JSON.stringify(out);
                };
                const note = (k, v) => { out[k] = v; show(); };
                window.onerror = (m, f, l) => note('pageError', m + ' @ ' + l);
                note('apis', typeof chrome + '/' +
                  (chrome && chrome.storage ? 'storage' : 'no storage') + '/' +
                  (chrome && chrome.runtime ? 'runtime' : 'no runtime'));

                chrome.storage.local.get('workerRan').then(
                  v => note('storage', JSON.stringify(v)),
                  e => note('storage', 'threw ' + e));

                chrome.runtime.sendMessage({ name: 'sync' }).then(
                  a => note('promise-sync', JSON.stringify(a) || 'undefined'),
                  e => note('promise-sync', 'threw ' + e));

                chrome.runtime.sendMessage({ name: 'async' }).then(
                  a => note('promise-async', JSON.stringify(a) || 'undefined'),
                  e => note('promise-async', 'threw ' + e));

                chrome.runtime.sendMessage({ name: 'callback' }, a => {
                  note('callback', JSON.stringify(a) || ('undefined, lastError=' +
                    (chrome.runtime.lastError ? chrome.runtime.lastError.message : 'none')));
                });

                try {
                  const port = chrome.runtime.connect({ name: 'probe' });
                  port.onMessage.addListener(m => note('port', JSON.stringify(m)));
                  port.onDisconnect.addListener(() => note('port', 'disconnected'));
                  port.postMessage({ name: 'ping' });
                } catch (e) { note('port', 'threw ' + e); }

                setTimeout(() => {
                  chrome.storage.local.get(['workerRan', 'workerHeard', 'workerConnected']).then(
                    v => note('worker-side', JSON.stringify(v)),
                    e => note('worker-side', 'threw ' + e));
                }, 4000);
                """,
            ]
        )
        let context = try await host.load(fixture.installed, granting: fixture.everything)
        let page = try #require(URL(string: context.baseURL.absoluteString + "page.html"))

        // The control first, and the order is load-bearing. An earlier draft
        // opened zer0's tab immediately after `load` returned, before the worker
        // had finished starting — and read "the worker never answered" off a
        // page that had asked before there was anybody to ask. Everything below
        // therefore waits for the worker to be provably warm first.
        let bare = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 600, height: 400),
            configuration: try #require(context.webViewConfiguration)
        )
        bare.load(URLRequest(url: page))
        _ = await eventually(timeout: .seconds(30)) {
            await js(bare, "document.getElementById('out').textContent").contains("worker-side")
        }
        Self.say("bare view: \(await js(bare, "document.getElementById('out').textContent"))")

        model.send(.openTab(
            space: nil,
            url: context.baseURL.absoluteString + "page.html",
            parent: nil
        ))
        let tab = try #require(model.snapshot.activeTab)
        let view = try #require(model.engine.webView(for: tab))
        _ = await eventually(timeout: .seconds(30)) {
            await js(view, "document.getElementById('out').textContent").contains("worker-side")
        }
        Self.say("zer0 tab: \(await js(view, "document.getElementById('out').textContent"))")

        Self.say("windows the core has: \(model.snapshot.windows.map(\.id))")
        Self.say("tab \(tab) is in window "
            + "\(String(describing: model.snapshot.tabs.first { $0.id == tab }?.window))")

        for error in context.errors {
            Self.say("context error: \((error as NSError).localizedDescription) "
                + "\((error as NSError).userInfo)")
        }
        withExtendedLifetime(fixture) {}
    }

    /// The other arm of the branch: an extension's own page sending *itself* to
    /// the web, which is what `window.location.href = …` does.
    ///
    /// ADR-0104 replaces the view at `start_navigation`, and a navigation the
    /// page starts never goes through it.
    @Test(
        "an extension page can send itself to the web",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    func extensionPageLeavesForTheWeb() async throws {
        let model = BrowserModel(storagePath: nil)
        let host = try #require(model.extensions)
        let fixture = try ExtensionFixture(
            id: String(repeating: "f", count: 32),
            pages: [
                "leave.html": """
                <!doctype html><html><body><div id="out">here</div>
                <script src="leave.js"></script></body></html>
                """,
                "leave.js": """
                document.getElementById('out').textContent = 'loaded';
                setTimeout(() => { window.location.href = 'https://example.com/'; }, 500);
                """,
            ]
        )
        let context = try await host.load(fixture.installed, granting: fixture.everything)
        model.send(.openTab(
            space: nil,
            url: context.baseURL.absoluteString + "leave.html",
            parent: nil
        ))
        let tab = try #require(model.snapshot.activeTab)

        // Re-read the view every time: a crossing replaces it, so a reference
        // taken before the click is a photograph of the view that went.
        _ = await eventually(timeout: .seconds(20)) {
            (model.engine.webView(for: tab)?.url?.absoluteString ?? "")
                .hasPrefix("https://example.com")
        }
        let now = model.engine.webView(for: tab)
        Self.say("after location.href: engine url = \(now?.url?.absoluteString ?? "<nil>")")
        Self.say("after location.href: core says "
            + "\(model.snapshot.tabs.first { $0.id == tab }?.url ?? "<nil>") "
            + "pending=\(model.snapshot.tabs.first { $0.id == tab }?.pendingUrl ?? "<nil>") "
            + "error=\(String(describing: model.snapshot.tabs.first { $0.id == tab }?.lastError))")
        // The security half. Every zer0 view carries the extension controller so
        // content scripts run, so that says nothing; the store is what tells the
        // extension's shared jar from the space's own (ADR-0007, ADR-0104).
        Self.say("it landed in WebKit's shared jar: "
            + "\(now?.configuration.websiteDataStore === WKWebsiteDataStore.default())")

        // Is the policy delegate even consulted for a navigation *out* of an
        // extension page? A fix that cancels and re-aims at the core can only
        // sit somewhere this is `true`.
        let watcher = LeaveWatcher()
        let bare = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 600, height: 400),
            configuration: try #require(context.webViewConfiguration)
        )
        bare.navigationDelegate = watcher
        bare.load(URLRequest(url: try #require(
            URL(string: context.baseURL.absoluteString + "leave.html")
        )))
        _ = await eventually(timeout: .seconds(20)) {
            (bare.url?.absoluteString ?? "").hasPrefix("https://example.com")
        }
        Self.say("bare view landed at \(bare.url?.absoluteString ?? "<nil>")")
        for line in watcher.log { Self.say("  delegate: \(line)") }
        withExtendedLifetime(fixture) {}
    }

    @Test(
        "what 1Password's Sign in actually calls",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    func signIn() async throws {
        let id = "aeblfdkhhhdcdjpifhhbdiojplfjncoa"
        let model = BrowserModel(storagePath: ProcessInfo.processInfo.environment["ZER0_PROBE_DB"])
        let host = try #require(model.extensions)

        Self.say("installing \(id) through the real install path")
        let request = try await model.installExtension(id: id)
        let installed = try #require(model.installedExtensions.first { $0.id == id })
        let decision = defaultConsentDecision(request: request, decidedAtMs: 1000)

        // Persist consent into the core ledger before loading. Before this,
        // the probe only applied the decision to the WKWebExtensionContext,
        // so `core.native_host` refused with `.PermissionNotGranted`, the
        // consent sheet never fired, and the extension's `connectNative`
        // closed with `Error: None` — masking that the rest of the flow
        // works. Mirrors `ExtensionsView.swift:70` and `ExtensionApiTests:97`.
        await model.applyConsent(decision)

        let context = try await host.load(installed, granting: decision)
        _ = host.apply(decision, to: context)
        Self.say("loaded \(installed.manifest.name) \(installed.manifest.version)")
        Self.say("baseURL=\(context.baseURL.absoluteString)")

        // Answer the native-host sheet the moment one appears, the way a person
        // would. Which arm of 1Password's branch runs turns on whether the port
        // came up, so a probe that leaves the sheet unanswered measures only the
        // refusal.
        let approveNativeHost = ProcessInfo.processInfo.environment["ZER0_PROBE_APPROVE"] != nil
        var answered: [String] = []
        let watcher = Task { @MainActor in
            while !Task.isCancelled {
                if let pending = model.pendingNativeHost {
                    answered.append(pending.host.program)
                    Self.say("native host sheet: \(pending.host.program) "
                        + "(registrar \(pending.host.registrar)) -> "
                        + (approveNativeHost ? "allow" : "refuse"))
                    model.answerNativeHost(pending, allowed: approveNativeHost)
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        defer { watcher.cancel() }

        // Wait for the worker to be provably answering before the page asks it
        // anything, rather than for a number of seconds. Measured: a message
        // sent from an extension page while the worker is still starting is
        // dropped in silence — `sendMessage` resolves `undefined` with no
        // `lastError` — so a page opened too early reads exactly like a page
        // whose worker is broken. This probe made that mistake twice.
        let warmUp = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 300),
            configuration: try #require(context.webViewConfiguration)
        )
        warmUp.load(URLRequest(url: try #require(
            URL(string: context.baseURL.absoluteString + "app/app.html")
        )))
        // Polled with plain `evaluateJavaScript` over a value the page parks on
        // `window`, rather than by awaiting inside the page: measured, an
        // `await`ing `callAsyncJavaScript` against a page whose worker never
        // answers does not come back at all, and an earlier draft of this probe
        // hung there for ten minutes with nothing to show.
        _ = await eventually(timeout: .seconds(30)) { warmUp.url != nil && !warmUp.isLoading }
        var warm = "never"
        let isWarm = await eventually(timeout: .seconds(45), polling: .seconds(1)) {
            _ = await js(warmUp, """
            if (window.__warm === undefined && typeof browser !== 'undefined') {
              window.__warm = 'pending';
              browser.runtime.sendMessage({ name: 'get-desktop-app-status' }).then(
                function (a) { window.__warm = a === undefined ? 'undefined' : JSON.stringify(a); },
                function (e) { window.__warm = 'threw ' + e; });
            }
            'asked'
            """)
            warm = await js(warmUp, "String(window.__warm)")
            return warm != "pending" && warm != "undefined" && warm != "<nil>"
        }
        Self.say("worker warm = \(isWarm): get-desktop-app-status -> \(warm)")

        let page = context.baseURL.absoluteString + "app/app.html#/page/welcome"
        model.send(.openTab(space: nil, url: page, parent: nil))
        let tab = try #require(model.snapshot.activeTab)
        let view = try #require(model.engine.webView(for: tab))
        Self.say("opened tab \(tab) at \(page)")

        // The instrument goes in at document start and the page is loaded
        // again, so the whole boot conversation is recorded rather than
        // whatever is left of it by the time a wrapper could be pasted in.
        view.configuration.userContentController.addUserScript(WKUserScript(
            source: Self.instrument,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        view.reload()

        #expect(await eventually(timeout: .seconds(60)) {
            await js(view, "document.body ? document.body.innerText.length : 0") != "0"
        }, "the welcome page never rendered")
        _ = await eventually(timeout: .seconds(20)) {
            await js(view, """
            JSON.stringify(Array.from(document.querySelectorAll('button')).length)
            """) != "0"
        }
        Self.say("boot = \(await js(view, "JSON.stringify(window.__z ? window.__z.calls : 'no instrument')"))")
        Self.say("boot errors = \(await js(view, "JSON.stringify(window.__z ? window.__z.errors : [])"))")
        Self.say("html length = \(await js(view, "document.documentElement.outerHTML.length"))")
        Self.say("body html = \(await js(view, "document.body.innerHTML.slice(0, 3000)"))")
        Self.say("context.errors = \(context.errors.map { "\($0)" })")
        Self.say("context.isLoaded = \(context.isLoaded)")

        // Ask the background directly, so "the page never rendered" and "the
        // worker never answers" are told apart.
        _ = await js(view, """
        window.__ask = {};
        ['get-settings-configuration', 'get-desktop-app-status', 'app-ready'].forEach(function (n) {
          window.__ask[n] = 'pending';
          browser.runtime.sendMessage({ name: n }).then(
            function (a) { window.__ask[n] = a === undefined ? 'undefined' : JSON.stringify(a); },
            function (e) { window.__ask[n] = 'threw ' + e; });
        });
        'asked'
        """)
        _ = await eventually(timeout: .seconds(10)) {
            !(await js(view, "JSON.stringify(window.__ask)")).contains("pending")
        }
        Self.say("direct ask = \(await js(view, "JSON.stringify(window.__ask)"))")


        Self.say("url=\(await js(view, "location.href"))")
        Self.say("title=\(await js(view, "document.title"))")
        Self.say("text=\n\(await js(view, "document.body.innerText"))")
        Self.say("apis: \(await js(view, """
        JSON.stringify({
          chrome: typeof chrome, browser: typeof browser,
          tabsCreate: (typeof browser !== 'undefined' && browser.tabs)
            ? typeof browser.tabs.create : 'none',
          connectNative: (typeof browser !== 'undefined' && browser.runtime)
            ? typeof browser.runtime.connectNative : 'none',
          userAgent: navigator.userAgent
        })
        """))")
        Self.say("controls=\(await js(view, """
        JSON.stringify(Array.from(document.querySelectorAll('button, a, [role=button]'))
          .map(function (e) { return {
            tag: e.tagName, text: (e.innerText || '').slice(0, 80), href: e.href || ''
          }; }))
        """))")

        Self.say("wrappers took: \(await js(view, "JSON.stringify(window.__z.took)"))")

        // Establish the instrument before believing anything it says: a real
        // `tabs.create` from this page has to be recorded *and* has to reach the
        // browser. Without this, "nothing was called" and "the wrapper never
        // took" are the same reading.
        let tabsBefore = model.snapshot.tabs.count
        Self.say("control: \(await js(view, """
        (function () {
          try { browser.tabs.create({ url: 'https://example.com/zer0-probe-control' }); return 'asked'; }
          catch (e) { return 'threw: ' + e; }
        })()
        """))")
        let sawControl = await eventually(timeout: .seconds(10)) {
            model.snapshot.tabs.count > tabsBefore
        }
        Self.say("control: browser reached = \(sawControl)")
        Self.say("control: recorded = \(await js(view, "JSON.stringify(window.__z.calls)"))")
        snapshot(model, "after the control")
        #expect(sawControl, "the instrument cannot see a working tabs.create from this page")

        _ = await js(view, "window.__z.calls = []")

        // MARK: Drive the welcome page

        // 1Password's welcome page renders a single "Get Started" button whose
        // `innerText` is empty (it carries an SVG only), so the earlier
        // `/sign in/i` filter found nothing and the page never advanced.
        // Drive the welcome page by clicking whatever button is there, wait
        // for the hash to change (the app is a hash router), and only then
        // look for a Sign in control on the next screen.

        let pendingBefore = model.pendingNativeHost?.host.program
        let answeredBefore = answered.count
        let callsBefore = await js(view, "JSON.stringify(window.__z.calls)")
        let desktopBefore = await js(view, """
        (function () {
          try {
            var v = window.__ask && window.__ask['get-desktop-app-status'];
            return v || 'none';
          } catch (e) { return 'err ' + e; }
        })()
        """)

        Self.say("welcome controls=\(await js(view, """
        JSON.stringify(Array.from(document.querySelectorAll('button, a[href], [role=button]')).map(function (e) {
          return {
            tag: e.tagName,
            text: (e.innerText || e.textContent || '').trim().slice(0, 120),
            ariaLabel: e.getAttribute('aria-label') || '',
            href: e.getAttribute('href') || '',
            type: e.getAttribute('type') || '',
            classes: (e.className || '').toString().slice(0, 160)
          };
        }))
        """))")

        let welcomeHashBefore = await js(view, "location.hash || '(none)'")
        Self.say("welcome hash before=\(welcomeHashBefore)")

        // Click the first button on the welcome page. Measured: the page has
        // exactly one `<button>` and it carries no text — `/sign in/i` could
        // never match it. The SVG inside is the "Get Started" arrow.
        Self.say("welcome click: \(await js(view, """
        (function () {
          var btn = document.querySelector('button');
          if (!btn) { return 'no <button>'; }
          var label = btn.getAttribute('aria-label')
            || (btn.innerText || btn.textContent || '').trim()
            || '<unlabelled>';
          btn.click();
          return 'clicked <button>: ' + label;
        })()
        """))")

        // Wait for the hash router to leave `#/page/welcome`. The app moves
        // through `#/page/signin` (or similar) on the way to the screen whose
        // button actually calls `connectNative`.
        let hashChanged = await eventually(timeout: .seconds(15), polling: .milliseconds(250)) {
            let h = await js(view, "location.hash || ''")
            return !h.isEmpty && h != welcomeHashBefore
        }
        Self.say("welcome hash changed=\(hashChanged) "
            + "now=\(await js(view, "location.hash || '(none)'")) "
            + "href=\(await js(view, "location.href"))")

        // Give the next screen a moment to render before reading it. A hash
        // change does not imply the new view has painted its controls.
        _ = await eventually(timeout: .seconds(15)) {
            await js(view, """
            (document.body && document.body.innerText ? document.body.innerText.length : 0)
            """) != "0"
        }
        _ = await eventually(timeout: .seconds(10)) {
            await js(view, "document.querySelectorAll('button, a, [role=button]').length") != "0"
        }

        Self.say("post-welcome controls=\(await js(view, """
        JSON.stringify(Array.from(document.querySelectorAll('button, a[href], [role=button]')).map(function (e) {
          return {
            tag: e.tagName,
            text: (e.innerText || e.textContent || '').trim().slice(0, 160),
            ariaLabel: e.getAttribute('aria-label') || '',
            href: e.getAttribute('href') || '',
            classes: (e.className || '').toString().slice(0, 160)
          };
        }))
        """))")

        Self.say("post-welcome text=\n\(await js(view, "document.body.innerText.slice(0, 4000)"))")

        // MARK: The press

        // Match "Sign in" across every spelling: innerText, textContent,
        // aria-label, and the joined "signin" form. The welcome page's button
        // had empty text, so do not trust any one field.
        let urlBefore = view.url?.absoluteString ?? ""
        let countBefore = model.snapshot.tabs.count
        Self.say("pressing: \(await js(view, """
        (function () {
          var nodes = Array.from(document.querySelectorAll('button, a, [role=button]'));
          var match = nodes.find(function (e) {
            var t = ((e.innerText || '') + ' ' + (e.textContent || '')).toLowerCase();
            var al = (e.getAttribute('aria-label') || '').toLowerCase();
            return /sign[\\s_-]*in/.test(t) || /sign[\\s_-]*in/.test(al)
              || t.indexOf('signin') !== -1 || al.indexOf('signin') !== -1
              || t.indexOf('log in') !== -1 || al.indexOf('log in') !== -1;
          });
          if (!match) { return 'no sign-in control found'; }
          var label = (match.innerText || match.textContent || '').trim()
            || match.getAttribute('aria-label') || '<unlabelled>';
          match.click();
          return 'clicked: ' + label + ' <' + match.tagName + '>';
        })()
        """))")

        // The press is done when either a native-host sheet appears, the port
        // wrapper records a `connectNative` call, or the URL/hash moves again.
        // Sheet arrival is what unlocks the rest, so do not stop on navigation
        // alone.
        _ = await eventually(timeout: .seconds(20), polling: .milliseconds(100)) {
            let calls = await js(view, "JSON.stringify(window.__z.calls || [])")
            return model.pendingNativeHost != nil
                || answered.count > answeredBefore
                || calls.contains("connectNative")
        }
        // A little more, so anything the press started has a chance to be
        // observed even if none of the above tripped.
        _ = await eventually(timeout: .seconds(8)) {
            model.snapshot.tabs.count > countBefore
                || (view.url?.absoluteString ?? "") != urlBefore
                || answered.count > answeredBefore
        }
        _ = await eventually(timeout: .seconds(5)) { false }

        Self.say("recorded = \(await js(view, "JSON.stringify(window.__z.calls)"))")
        Self.say("errors = \(await js(view, "JSON.stringify(window.__z.errors)"))")
        Self.say("the page's own url before=\(urlBefore) after=\(view.url?.absoluteString ?? "<nil>")")
        Self.say("native host sheets answered: \(answered)")
        Self.say("wrappers took: \(await js(view, "JSON.stringify(window.__z.took)"))")

        // Final comparison snapshot. `desktopAppState` is read through the
        // same `get-desktop-app-status` channel the app uses, so it reflects
        // what 1Password's own UI believes after the press.
        let desktopAfter = await js(view, """
        (function () {
          try { return window.__ask && window.__ask['get-desktop-app-status'] || 'none'; }
          catch (e) { return 'err ' + e; }
        })()
        """)
        Self.say("--- before vs after ---")
        Self.say("  pendingNativeHost: before=\(pendingBefore ?? "<nil>") "
            + "after=\(model.pendingNativeHost?.host.program ?? "<nil>")")
        Self.say("  sheets answered: before=\(answeredBefore) after=\(answered.count) "
            + "programs=\(answered)")
        Self.say("  desktopAppState: before=\(desktopBefore) after=\(desktopAfter)")
        Self.say("  calls before=\(callsBefore)")
        Self.say("  calls after=\(await js(view, "JSON.stringify(window.__z.calls)"))")
        snapshot(model, "after the press")

        watcher.cancel()
    }
}
