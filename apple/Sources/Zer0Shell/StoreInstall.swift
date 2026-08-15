import Foundation
import WebKit
import Zer0Core

/// Replaces the Chrome Web Store's own install button with one that installs
/// into `zer0`.
///
/// On a listing the store draws a button greyed out for anything that is not
/// Chrome, under a banner reading *"Switch to Chrome to install extensions and
/// themes"*. Everything beneath that button already works here — the package is
/// fetched, checked, unpacked and asked about (ADR-0021, ADR-0022, ADR-0028) —
/// so the only thing missing was the gesture people actually make.
/// `InstallBanner` offered one at the foot of the window; this puts the offer
/// where the hand already is.
///
/// **The script is a platform mechanism, so it lives in the shell.** What may
/// be installed and from where stays in the core, and is asked for twice: once
/// for where this script may run at all, and once for whether a page may be
/// offered anything. See ADR-0062.
///
/// Three things make injecting into somebody else's page safe to have at all:
///
/// - **It runs on the store's hosts and nowhere else.** The rule is
///   `Zer0.extensionStoreHosts()`, the same one `extensionIdForUrl` applies.
/// - **It runs in a content world of its own**, so the message channel is not
///   reachable from anything the page loads: `window.webkit.messageHandlers`
///   in the page world does not have it.
/// - **The page never names the extension, and never decides it may offer
///   one.** The script asks; the core answers from the frame's committed URL.
enum StoreInstallScript {
    /// The world the script and its channel live in.
    ///
    /// Not the page world. `window.webkit.messageHandlers` is visible to every
    /// script on the page and the store loads plenty of them; in a named world
    /// the DOM is shared and the globals are not, which is exactly the split
    /// this needs.
    @MainActor
    static var world: WKContentWorld { WKContentWorld.world(name: "zer0.store-install") }

    /// The name the script posts to, and the name Swift listens on.
    static let channel = "zer0StoreInstall"

    /// The global the shell calls back into.
    static let entryPoint = "__zer0StoreInstall"

    /// A JavaScript expression for "is this host the store", built from the
    /// core's list.
    ///
    /// Kept separate from `source` so a test can evaluate exactly this and hold
    /// it to the same answer `extensionIdForUrl` gives for the same host. The
    /// matching is two lines in either language; what must never drift is the
    /// data, and the data has one home.
    static func hostGuard(_ hosts: StoreHosts) -> String {
        """
        (host => {
          const name = String(host || "").toLowerCase();
          return \(jsonArray(hosts.exact)).includes(name)
            || \(jsonArray(hosts.suffixes)).some(tail => name.endsWith(tail));
        })
        """
    }

    /// The whole script, gated by `hosts`.
    ///
    /// `accent` is passed in rather than spelled here because it is the shell's
    /// business and has one home: the button drawn in the page is the same
    /// colour as the buttons drawn in the window.
    static func source(hosts: StoreHosts, accent: Accent = .fromPalette) -> String {
        """
        (() => {
          "use strict";

          const isStoreHost = \(hostGuard(hosts));

          // Nothing below this line runs anywhere else. A script that edits the
          // DOM of an origin nobody authorised is a far worse defect than a
          // greyed-out button, so the guard is the first statement, and it is
          // the reason this file is allowed to exist at all.
          if (location.protocol !== "https:" || !isStoreHost(location.hostname)) return;

          const channel = (window.webkit && window.webkit.messageHandlers)
            ? window.webkit.messageHandlers.\(channel)
            : null;
          if (!channel) return;

          const MARK = "data-zer0-install";
          const STYLE_ID = "zer0-install-style";

          let ours = null;
          let candidate = null;
          let said = null;

          const post = body => { try { channel.postMessage(body); } catch (e) { /* gone */ } };

          const say = kind => {
            if (said === kind) return;
            said = kind;
            post({ kind });
          };

          // The store's own install control.
          //
          // Found by the one property that survives translation: it is the
          // page's only disabled button. Measured rather than guessed — the
          // label reads "Add to Chrome" in en-US and "Usar no Chrome" in pt-BR,
          // and in both there is exactly one disabled button on a listing.
          // Matching the label would work in one language and fail in the
          // other, which is the worse failure because it looks fixed.
          //
          // None means the store changed. Two or more means we cannot tell
          // which. Both answer null, and null is what leaves InstallBanner
          // doing the job it does today: refusing beats rewriting the wrong
          // button.
          const findCandidate = () => {
            let found = null;
            for (const button of document.querySelectorAll("button")) {
              if (button.hasAttribute(MARK)) continue;
              if (!button.disabled && button.getAttribute("aria-disabled") !== "true") continue;
              const box = button.getBoundingClientRect();
              // A control nobody can see is not the one being pointed at.
              if (box.width < 1 || box.height < 1) continue;
              if (found) return null;
              found = button;
            }
            return found;
          };

          const style = () => {
            if (document.getElementById(STYLE_ID)) return;
            const sheet = document.createElement("style");
            sheet.id = STYLE_ID;
            sheet.textContent = `
              button[${MARK}] {
                all: unset;
                box-sizing: border-box;
                display: inline-flex;
                align-items: center;
                justify-content: center;
                min-height: 40px;
                padding: 0 22px;
                border-radius: 20px;
                font: 500 14px/1 "Google Sans", Roboto, system-ui, sans-serif;
                letter-spacing: 0.2px;
                cursor: pointer;
                background: \(accent.light);
                color: \(accent.onLight);
                transition: background 140ms ease;
              }
              button[${MARK}]:hover { background: \(accent.lightHover); }
              button[${MARK}]:active { background: \(accent.lightPressed); }
              button[${MARK}][disabled] { opacity: 0.7; cursor: default; }
              @media (prefers-color-scheme: dark) {
                button[${MARK}] { background: \(accent.dark); color: \(accent.onDark); }
                button[${MARK}]:hover { background: \(accent.darkHover); }
                button[${MARK}]:active { background: \(accent.darkPressed); }
              }
            `;
            (document.head || document.documentElement).appendChild(sheet);
          };

          // What the button says, per state. The vocabulary is Swift's
          // (`StoreInstallHost.Outcome`); this is the drawing of it.
          //
          // Two kinds of state are in here and the difference is the whole
          // design. `present` and `undecided` are what this machine *has*,
          // decided when the page loads — seeing "Add to zer0" on something
          // installed yesterday is the page lying about your own browser.
          // `added` and `refused` are what you just *did*, and they are
          // disabled, because the pointer is still on the button and a second
          // click landing on "Remove" would undo the first.
          const LABELS = {
            working: "Adding\u{2026}",
            removing: "Removing\u{2026}",
            added: "Added to zer0",
            refused: "Added, not running",
            failed: "Could not add",
            present: "Remove from zer0",
            undecided: "Finish setting up",
          };
          const label = state => LABELS[state] || "Add to zer0";
          const SETTLED = { added: 1, refused: 1, working: 1, removing: 1 };

          // Called by the shell, and only ever after the core has agreed this
          // page is a listing. The script decides where a button goes; it does
          // not decide that there is one to offer.
          const adopt = state => {
            if (ours && ours.isConnected) return;
            if (!candidate || !candidate.isConnected) {
              say("absent");
              return;
            }
            style();
            const button = document.createElement("button");
            button.setAttribute(MARK, "");
            button.type = "button";
            candidate.style.display = "none";
            candidate.insertAdjacentElement("afterend", button);
            ours = button;
            // The state the shell worked out from what this machine holds. Set
            // before the listener so a button can never be pressed while it is
            // still showing the wrong offer.
            setState(state);
            button.addEventListener("click", event => {
              event.preventDefault();
              event.stopPropagation();
              // No id travels with this, and neither does what the button was
              // showing. The page reports that somebody pressed it; what a
              // press *means* is read out of the core's answer about this
              // frame's URL, which is the only reading of it a page cannot
              // influence.
              post({ kind: "press" });
            });
            say("adopted");
          };

          const setState = state => {
            if (!ours) return;
            ours.textContent = label(state);
            ours.disabled = state in SETTLED;
          };

          const sync = () => {
            if (ours && ours.isConnected) return;
            ours = null;
            candidate = findCandidate();
            if (candidate) {
              said = null;
              post({ kind: "candidate" });
              return;
            }
            // Silence until the page has stopped arriving. Saying "there is
            // nothing here" while the store is still drawing would put the
            // fallback banner on screen and then take it away again, which is
            // worse than either answer on its own.
            if (document.readyState === "complete") say("absent");
          };

          window.\(entryPoint) = { adopt, setState };

          sync();
          window.addEventListener("load", sync);

          // The store is a single-page app: moving between listings swaps the
          // button without loading a document, so a one-shot injection is right
          // exactly once. Watching is the price, rate-limited to one pass per
          // frame rather than one per mutation.
          let queued = false;
          new MutationObserver(() => {
            if (queued) return;
            queued = true;
            requestAnimationFrame(() => { queued = false; sync(); });
          }).observe(document.documentElement, { childList: true, subtree: true });
        })();
        """
    }

    /// The accent the injected button wears, from the palette, so the button in
    /// the page and the buttons in the window are one colour.
    struct Accent {
        let light: String
        let lightHover: String
        let lightPressed: String
        let onLight: String
        let dark: String
        let darkHover: String
        let darkPressed: String
        let onDark: String

        static let fromPalette = Accent(
            light: Design.Palette.light.accent.hex,
            lightHover: Design.Palette.light.accentHover.hex,
            lightPressed: Design.Palette.light.accentPressed.hex,
            onLight: Design.Palette.light.onAccent.hex,
            dark: Design.Palette.dark.accent.hex,
            darkHover: Design.Palette.dark.accentHover.hex,
            darkPressed: Design.Palette.dark.accentPressed.hex,
            onDark: Design.Palette.dark.onAccent.hex
        )
    }

    /// A JSON array literal, so a host carrying a quote cannot close the string
    /// it is written into.
    private static func jsonArray(_ values: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: values),
              let text = String(data: data, encoding: .utf8)
        else { return "[]" }
        return text
    }
}

/// What the script in the page said.
enum StoreInstallMessage {
    /// There is one control here we could take over. Whether we may is not the
    /// page's call.
    case candidate
    /// There is nothing here we recognise, and the page has stopped arriving.
    case absent
    /// The control is ours now.
    case adopted
    /// Somebody pressed it. Deliberately not "install": what a press means
    /// depends on what this machine already holds, and that is not the page's
    /// to say.
    case pressed
}

/// Whether the page a tab is showing offers its own install button.
///
/// `unknown` is a real third answer and not a synonym for `absent`: before the
/// script has spoken, nobody knows, and `InstallBanner` treats the two
/// differently — see `BrowserModel.storeControlState(inTab:)`.
enum StoreControlState {
    case unknown
    case adopted
    case absent
}

/// The Swift half of the channel, one per web view.
///
/// One per view rather than one shared object with a lookup table, because the
/// tab is known where the view is built. A handler that knows its tab
/// structurally cannot answer for the wrong one.
@MainActor
final class StoreInstallChannel: NSObject, WKScriptMessageHandler {
    private let tab: TabId
    private let deliver: @MainActor (StoreInstallMessage, TabId, WKWebView) -> Void

    init(
        tab: TabId,
        deliver: @escaping @MainActor (StoreInstallMessage, TabId, WKWebView) -> Void
    ) {
        self.tab = tab
        self.deliver = deliver
    }

    /// What a message has to be before it is one.
    ///
    /// Deliberately exhaustive over what the script sends and deliberately
    /// silent about everything else: this is a boundary, and an unrecognised
    /// message is not a message.
    static func message(named kind: String) -> StoreInstallMessage? {
        switch kind {
        case "candidate": .candidate
        case "absent": .absent
        case "adopted": .adopted
        case "press": .pressed
        default: nil
        }
    }

    nonisolated func userContentController(
        _: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        MainActor.assumeIsolated {
            // A subframe is not the listing. The store embeds third-party
            // frames, and one of those posting here would be a page inside a
            // page asking to install something.
            guard message.frameInfo.isMainFrame,
                  let webView = message.webView,
                  let body = message.body as? [String: Any],
                  let kind = body["kind"] as? String,
                  let named = Self.message(named: kind)
            else { return }

            deliver(named, tab, webView)
        }
    }
}

/// Injects the script into every web view and routes what comes back.
///
/// Owned by `BrowserModel` the way `ExtensionHost` is, and holding it weakly:
/// a content controller retains its message handlers for the life of the view.
@MainActor
final class StoreInstallHost {
    private let hosts: StoreHosts
    private weak var model: BrowserModel?

    init(model: BrowserModel, hosts: StoreHosts) {
        self.model = model
        self.hosts = hosts
    }

    /// Attach to a new view. Has to happen before it loads anything.
    func attach(to configuration: WKWebViewConfiguration, tab: TabId) {
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(
            source: StoreInstallScript.source(hosts: hosts),
            // At document end, because the control it looks for is drawn by the
            // store's own scripts. The observer covers everything after.
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true,
            in: StoreInstallScript.world
        ))
        controller.add(
            StoreInstallChannel(tab: tab) { [weak self] message, tab, webView in
                self?.handle(message, tab: tab, webView: webView)
            },
            contentWorld: StoreInstallScript.world,
            name: StoreInstallScript.channel
        )
    }

    /// The extension a message from a frame is about.
    ///
    /// **The only reading of it there is.** It is the core's answer about the
    /// frame's committed URL, and the message body is not consulted, because a
    /// channel where the page names the extension is a page that can install
    /// anything. Named and separate so a test can ask it directly.
    func subject(ofFrameAt url: String?) -> String? {
        guard let url, let model else { return nil }
        return model.extensionId(inURL: url)
    }

    /// What the button should be showing for an extension, given what this
    /// machine holds right now.
    ///
    /// The core answers; nothing here counts anything. Note what is *not* in
    /// here: nothing about the last click. A button that remembered what you
    /// last pressed would go on offering to add something you removed in
    /// another window.
    func resting(_ standing: ExtensionStanding) -> Outcome {
        switch standing {
        case .notInstalled: .offer
        // On disk with nobody having answered for it. Offering to add what is
        // already here would be the page lying; the only useful thing left is
        // the decision it is waiting on.
        case .undecided: .undecided
        case .grantedNothing, .running: .present
        }
    }

    private func handle(_ message: StoreInstallMessage, tab: TabId, webView: WKWebView) {
        guard let model else { return }
        switch message {
        case .candidate:
            // The one gate that matters for drawing: the core decides whether
            // this page is a listing at all. A page that finds a disabled
            // button on some other store screen is told nothing and gets
            // nothing.
            guard let id = subject(ofFrameAt: webView.url?.absoluteString) else {
                model.storeControlChanged(tab: tab, to: .absent)
                return
            }
            // Optimistic, so the fallback banner does not appear for the one
            // frame between asking and being answered. `adopt` says `absent` if
            // the control went away in between, which puts it back.
            model.storeControlChanged(tab: tab, to: .adopted)
            call("adopt(\"\(resting(model.standing(of: id)).rawValue)\")", in: webView)

        case .adopted:
            model.storeControlChanged(tab: tab, to: .adopted)

        case .absent:
            model.storeControlChanged(tab: tab, to: .absent)

        case .pressed:
            // The id is read out of the frame's committed URL and nowhere else.
            // A page that posts this can only ever act on the extension it is
            // itself showing, only if the core agrees the URL is a listing.
            guard let id = subject(ofFrameAt: webView.url?.absoluteString) else {
                report(.failed, to: webView)
                return
            }
            // And what the press *does* is read from the core's answer about
            // that id, not from the label the page happened to be drawing.
            switch model.standing(of: id) {
            case .notInstalled, .undecided:
                model.beginExtensionFlow(id: id, from: tab)
            case .grantedNothing, .running:
                model.askToRemoveExtension(id: id, from: tab)
            }
        }
    }

    /// Tell the button in the page what it should say.
    func report(_ outcome: Outcome, to webView: WKWebView) {
        call("setState(\"\(outcome.rawValue)\")", in: webView)
    }

    private func call(_ expression: String, in webView: WKWebView) {
        webView.evaluateJavaScript(
            "window.\(StoreInstallScript.entryPoint)?.\(expression)",
            in: nil,
            in: StoreInstallScript.world
        ) { _ in }
    }

    /// Everything the button in the page can say.
    ///
    /// Four of these are what the machine holds, read when the page loads and
    /// again after anything changes it; the rest are what is happening or what
    /// just happened. `refused` is a state of its own because refusing is a
    /// legitimate answer with a real outcome — the extension *was* added and it
    /// does not run — and reporting that as `failed` would be the browser
    /// calling somebody's decision an error.
    enum Outcome: String, CaseIterable {
        /// Not here. Add it.
        case offer
        /// Here, and nobody has said what it may do.
        case undecided
        /// Here and decided. The offer is to take it away.
        case present
        case working
        case removing
        /// Just added, holding something.
        case added
        /// Just added, holding nothing, because that is what was chosen.
        case refused
        case failed

        /// What the sheet being answered leaves on the button.
        ///
        /// Refusing everything is **not** `failed`. The extension was added, it
        /// holds nothing and it does not run — all three of which someone chose
        /// on purpose. Reporting a decision as an error is the browser telling
        /// somebody their answer did not work.
        static func afterDeciding(running: Bool) -> Outcome {
            running ? .added : .refused
        }
    }
}
