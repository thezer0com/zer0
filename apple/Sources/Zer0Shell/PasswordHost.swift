import Foundation
import WebKit
import Zer0Core

/// The page half: finding the login fields, measuring them, and putting a
/// value into one.
///
/// # What the page can and cannot make happen
///
/// It can make zer0 **look**. `focusin` is what prompts the shell to ask which
/// logins match, and a page can call `field.focus()` itself, so the caret is not
/// a trusted gesture and is not treated as one.
///
/// It cannot make zer0 **fill**. What looking produces is a `PasswordPrompt` in
/// Swift state, which never goes back into the document; the page learns
/// nothing it did not already know. A value is only put into the page from
/// `fill(_:matching:tab:into:)`, and nothing on the message channel reaches it
/// — `PasswordChannel.message(named:)` has two verbs and both are reports.
///
/// `usable()` in the core is the second, independent condition on that moment,
/// checked against geometry measured here rather than a claim made in the page.
///
/// # Why an isolated world
///
/// The same reason `StoreInstallScript` uses one, and it matters more here.
/// `window.webkit.messageHandlers` is visible to every script the page loads;
/// in a named world the DOM is shared and the globals are not. A page that
/// could reach this channel could ask to be filled, and asking is the one thing
/// it must not be able to do.
enum PasswordScript {
    @MainActor
    static var world: WKContentWorld { WKContentWorld.world(name: "zer0.passwords") }

    /// The name the script posts to, and the name Swift listens on.
    static let channel = "zer0Passwords"

    /// The global the shell calls back into to measure and to fill.
    static let entryPoint = "__zer0Passwords"

    /// Measures a field the way `passwords.rs` expects to be handed it.
    ///
    /// Every number here is a measurement, never a judgement: the script does
    /// not decide whether a field is visible, it reports width, height, opacity,
    /// position and what is drawn on top, and the core decides what that means.
    /// A boolean computed here would put the decision inside the page's own
    /// document, which is the one place it must not be — and it would be
    /// untestable without a browser.
    static let source = """
    (() => {
      const measure = (el) => {
        const r = el.getBoundingClientRect();
        // Effective opacity: an ancestor at 0 hides a child at 1, and that is
        // the cheap way to draw an invisible form out of visible parts.
        let opacity = 1;
        for (let n = el; n && n.nodeType === 1; n = n.parentElement) {
          const v = parseFloat(getComputedStyle(n).opacity);
          if (!isNaN(v)) { opacity *= v; }
        }
        // Whatever is actually drawn at the field's centre. A field covered by
        // an overlay is the clickjacking shape: the person believes they are
        // typing somewhere else.
        const cx = r.left + r.width / 2;
        const cy = r.top + r.height / 2;
        const hit = document.elementFromPoint(cx, cy);
        return {
          width: r.width,
          height: r.height,
          opacity: opacity,
          x: r.left,
          y: r.top,
          viewportWidth: window.innerWidth,
          viewportHeight: window.innerHeight,
          disabled: !!el.disabled,
          readonly: !!el.readOnly,
          topmost: hit === el || (hit != null && el.contains(hit)),
        };
      };

      const passwordField = () =>
        document.querySelector('input[type="password"]:not([aria-hidden="true"])');

      // The username is whatever precedes the password field in the same form,
      // preferring what the page said it was. `autocomplete` is a declaration
      // by the site, so it is trusted for *which field*, never for whether to
      // fill one.
      const usernameFor = (pw) => {
        const scope = pw.form || document;
        const declared = scope.querySelector(
          'input[autocomplete="username"], input[autocomplete="email"]'
        );
        if (declared) { return declared; }
        const inputs = Array.from(scope.querySelectorAll("input"));
        const before = inputs.slice(0, inputs.indexOf(pw)).reverse();
        return before.find((i) => ["text", "email", "tel"].includes(i.type)) || null;
      };

      const report = (kind) => {
        const pw = passwordField();
        if (!pw) { return; }
        const user = usernameFor(pw);
        window.webkit.messageHandlers.\(channel).postMessage({
          kind: kind,
          password: measure(pw),
          username: user ? measure(user) : null,
        });
      };

      window.\(entryPoint) = {
        // Called by the shell, never by the page: this world's globals are not
        // reachable from the page world.
        fill(username, password) {
          const pw = passwordField();
          if (!pw) { return false; }
          const user = usernameFor(pw);
          const set = (el, value) => {
            // Through the native setter, so a framework that wraps `value`
            // still sees the change and the form does not submit empty.
            const proto = Object.getPrototypeOf(el);
            const desc = Object.getOwnPropertyDescriptor(proto, "value");
            desc && desc.set ? desc.set.call(el, value) : (el.value = value);
            el.dispatchEvent(new Event("input", { bubbles: true }));
            el.dispatchEvent(new Event("change", { bubbles: true }));
          };
          if (user && username) { set(user, username); }
          set(pw, password);
          return true;
        },
        // Read out what was typed, so the shell can offer to keep it.
        //
        // Only ever called *by* the shell, in response to a submit it was told
        // about — the page cannot invoke this, because this world's globals are
        // not reachable from the page world. That direction is what stops a
        // page inventing a submitted login to overwrite a real saved one.
        read() {
          const pw = passwordField();
          if (!pw) { return null; }
          const user = usernameFor(pw);
          return { username: user ? user.value : "", password: pw.value };
        },
      };

      // A caret landing in the password field is a gesture, and it is the only
      // page event that leads anywhere. It reports; it does not ask.
      document.addEventListener("focusin", (e) => {
        if (e.target && e.target.type === "password") { report("caret"); }
      }, true);

      // A submitted form is the moment there is something worth offering to
      // save. Reported, and answered by `save_verdict` in the core.
      document.addEventListener("submit", () => report("submitted"), true);
    })();
    """
}

/// What the script is allowed to have said.
enum PasswordMessage {
    /// A caret landed in a password field.
    case caret
    /// A form carrying a password was submitted.
    case submitted
}

/// The Swift half of the channel, one per web view.
///
/// One per view rather than one shared object with a lookup table, for the
/// reason `StoreInstallChannel` gives: the tab is known where the view is
/// built, and a handler that knows its tab structurally cannot answer for the
/// wrong one. Here that is not tidiness — answering for the wrong tab means
/// answering for the wrong Space, and a Space is an identity.
@MainActor
final class PasswordChannel: NSObject, WKScriptMessageHandler {
    private let tab: TabId
    private let deliver: @MainActor (PasswordMessage, ReportedForm, TabId, WKWebView) -> Void

    init(
        tab: TabId,
        deliver: @escaping @MainActor (PasswordMessage, ReportedForm, TabId, WKWebView) -> Void
    ) {
        self.tab = tab
        self.deliver = deliver
    }

    /// What a message has to be before it is one.
    ///
    /// Exhaustive over what the script sends and silent about everything else.
    /// There is deliberately no `fill` case: a page that could ask to be filled
    /// would defeat the whole design, so the verb does not exist on this
    /// channel in either direction.
    static func message(named kind: String) -> PasswordMessage? {
        switch kind {
        case "caret": .caret
        case "submitted": .submitted
        default: nil
        }
    }

    nonisolated func userContentController(
        _: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        MainActor.assumeIsolated {
            guard let webView = message.webView,
                  let body = message.body as? [String: Any],
                  let kind = body["kind"] as? String,
                  let named = Self.message(named: kind),
                  let form = Self.form(from: body, message: message)
            else { return }

            deliver(named, form, tab, webView)
        }
    }

    /// The message, as the shape the core decides on.
    ///
    /// Both origins are taken from WebKit — `frameInfo.securityOrigin` for the
    /// frame the message came from, and the web view's committed URL for the
    /// page — and neither is taken from the message body. A page that could
    /// name its own origin could name somebody else's, which is the whole of
    /// the attack.
    static func form(from body: [String: Any], message: WKScriptMessage) -> ReportedForm? {
        guard let password = field(from: body["password"]) else { return nil }
        let frame = message.frameInfo.securityOrigin
        guard let pageUrl = message.webView?.url,
              let pageHost = pageUrl.host
        else { return nil }

        return ReportedForm(
            page: ReportedOrigin(
                scheme: pageUrl.scheme ?? "",
                host: pageHost,
                port: UInt32(pageUrl.port ?? 0)
            ),
            form: ReportedOrigin(
                scheme: frame.protocol,
                host: frame.host,
                port: UInt32(frame.port)
            ),
            username: field(from: body["username"]),
            password: password
        )
    }

    /// Numbers out of a page, treated as numbers out of a page.
    ///
    /// Everything is coerced rather than cast, and a missing value becomes the
    /// one that refuses: a zero size and a non-topmost field both fail
    /// `usable()`, so a malformed report is a refusal instead of a fill.
    private static func field(from raw: Any?) -> ReportedField? {
        guard let d = raw as? [String: Any] else { return nil }
        let number = { (key: String) -> Double in (d[key] as? NSNumber)?.doubleValue ?? 0 }
        return ReportedField(
            width: number("width"),
            height: number("height"),
            opacity: number("opacity"),
            x: number("x"),
            y: number("y"),
            viewportWidth: number("viewportWidth"),
            viewportHeight: number("viewportHeight"),
            disabled: d["disabled"] as? Bool ?? true,
            readonly: d["readonly"] as? Bool ?? true,
            topmost: d["topmost"] as? Bool ?? false
        )
    }
}

/// What zer0 is offering to do about a login, if anything.
///
/// A separate type from the verdict because it is what a view draws, and
/// because "there is something to offer" and "the person has been asked" are
/// different states — ADR-0018: the interface says only what it can back up.
enum PasswordPrompt: Equatable {
    /// Saved logins exist for this page and may be filled.
    case offer(origin: String, logins: [SavedLogin])
    /// Something was typed that is not saved yet.
    case askToSave(origin: String, username: String)
}

/// Injects the script into every web view, and answers what comes back.
///
/// **This is the only object in the app that moves a password.** It reads one
/// from the Keychain and puts it into a web view, and it does that in one
/// function, on a path that starts with a person. Nothing else needs to, so
/// nothing else does.
@MainActor
final class PasswordHost {
    /// Readable so the settings pane can list what is saved without going
    /// through a second Keychain implementation — the mistake `SecretStore.swift`
    /// records, where two stores under different names meant a value written by
    /// one and never found by the other.
    let store: any PasswordStore
    private let scope: (TabId) -> String?
    private let saveVerdict: (TabId, ReportedForm) -> SaveVerdict

    /// What each tab was last told about, so a view can draw it without asking
    /// the Keychain on every redraw.
    private(set) var prompts: [TabId: PasswordPrompt] = [:]

    /// What was read out of a submitted form, waiting for somebody to say
    /// whether to keep it.
    ///
    /// Held for the length of one question and dropped the moment it is
    /// answered. This is the only place in the app a password sits still, and
    /// it is deliberately keyed by tab so closing the tab drops it.
    private var pending: [TabId: SavedPassword] = [:]

    init(
        store: any PasswordStore,
        scope: @escaping (TabId) -> String?,
        saveVerdict: @escaping (TabId, ReportedForm) -> SaveVerdict
    ) {
        self.store = store
        self.scope = scope
        self.saveVerdict = saveVerdict
    }

    func attach(to configuration: WKWebViewConfiguration, tab: TabId) {
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(
            source: PasswordScript.source,
            injectionTime: .atDocumentEnd,
            // Subframes too: a login form in an iframe still has to be
            // *measured*, so that `fill_verdict` can refuse it for being
            // cross-origin rather than never hearing about it.
            forMainFrameOnly: false,
            in: PasswordScript.world
        ))
        controller.add(
            PasswordChannel(tab: tab) { [weak self] message, form, tab, webView in
                self?.handle(message, form: form, tab: tab, webView: webView)
            },
            contentWorld: PasswordScript.world,
            name: PasswordScript.channel
        )
    }

    private func handle(
        _ message: PasswordMessage,
        form: ReportedForm,
        tab: TabId,
        webView: WKWebView
    ) {
        switch message {
        case .caret:
            prompts[tab] = offer(for: form, tab: tab)
        case .submitted:
            askToSave(for: form, tab: tab, in: webView)
        }
    }

    /// What may be offered on this page — the core's answer, not ours.
    func offer(for form: ReportedForm, tab: TabId) -> PasswordPrompt? {
        guard case let .fill(origin) = passwordFillVerdict(form: form),
              let scope = scope(tab)
        else { return nil }

        let saved = (try? store.logins(for: origin, scope: scope)) ?? []
        let offers = passwordsOfferable(pageOrigin: origin, candidates: saved)
        return offers.isEmpty ? nil : .offer(origin: origin, logins: offers)
    }

    /// Ask whether the login that was just submitted is worth keeping.
    ///
    /// **The values are pulled, never pushed.** The page's message says only
    /// *that* a form was submitted; the two values are then read out of the DOM
    /// by this side, through `callAsyncJavaScript` in the isolated world.
    ///
    /// That direction is the whole point. If the values rode in on the message,
    /// a page could post a `submitted` it invented, with an account name and a
    /// value of its choosing, and get zer0 to offer to overwrite a real saved
    /// login for its own origin. Pulling them means the only thing that can
    /// answer is the document, and the only thing the page controls is whether
    /// the question gets asked at all.
    ///
    /// Nothing is written here. This puts a question on screen; the write
    /// happens in `save`, after somebody says yes.
    private func askToSave(for form: ReportedForm, tab: TabId, in webView: WKWebView) {
        guard case let .save(origin) = saveVerdict(tab, form), let scope = scope(tab) else {
            prompts[tab] = nil
            return
        }

        webView.callAsyncJavaScript(
            "return window.\(PasswordScript.entryPoint)?.read() ?? null",
            arguments: [:],
            in: nil,
            in: PasswordScript.world
        ) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self,
                      case let .success(value) = result,
                      let read = value as? [String: Any],
                      let username = read["username"] as? String,
                      let password = read["password"] as? String,
                      // An empty password is a form that was submitted without
                      // one — a search box, a half-filled sign-up. Nothing to
                      // keep, and asking would train people to dismiss.
                      !password.isEmpty
                else {
                    self?.prompts[tab] = nil
                    return
                }

                // Already saved, unchanged, is not worth interrupting for.
                let known = (try? self.store.logins(for: origin, scope: scope)) ?? []
                let unchanged = known.contains { $0.username == username }
                    && (try? self.store.password(
                        for: origin, scope: scope, username: username
                    )) == password
                if unchanged {
                    self.prompts[tab] = nil
                    return
                }

                self.pending[tab] = SavedPassword(username: username, password: password)
                self.prompts[tab] = .askToSave(origin: origin, username: username)
            }
        }
    }

    /// Keep what was submitted, after somebody said to.
    func keepPending(for origin: String, tab: TabId) throws {
        guard let credential = pending.removeValue(forKey: tab) else { return }
        try save(credential, for: origin, tab: tab)
        prompts[tab] = nil
    }

    /// Throw away what was submitted, because somebody said not to keep it.
    func discardPending(tab: TabId) {
        pending.removeValue(forKey: tab)
        prompts[tab] = nil
    }

    /// Put a saved login into the page.
    ///
    /// The one function that moves a password, and every guard is re-asked
    /// here: the core is asked again for a verdict against the geometry as it
    /// is *now*, because the form may have changed since the caret landed in
    /// it — which is exactly what a page trying to swap a visible field for a
    /// hidden one would do.
    func fill(
        _ username: String,
        matching form: ReportedForm,
        tab: TabId,
        into webView: WKWebView
    ) {
        guard case let .fill(origin) = passwordFillVerdict(form: form),
              let scope = scope(tab),
              let password = try? store.password(for: origin, scope: scope, username: username)
        else { return }

        // Through `callAsyncJavaScript` with arguments rather than by building
        // a string: a password interpolated into JavaScript source would be a
        // password that has to be escaped correctly forever, and one that
        // shows up in any log that records what was evaluated.
        webView.callAsyncJavaScript(
            "return window.\(PasswordScript.entryPoint)?.fill(username, password) ?? false",
            arguments: ["username": username, "password": password],
            in: nil,
            in: PasswordScript.world
        ) { _ in }
    }

    /// Write down what somebody typed, after they said to.
    func save(_ credential: SavedPassword, for origin: String, tab: TabId) throws {
        guard let scope = scope(tab) else { return }
        try store.save(credential, for: origin, scope: scope)
    }
}
