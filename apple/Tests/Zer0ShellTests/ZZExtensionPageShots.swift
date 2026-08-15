import AppKit
import Testing
import WebKit
import Zer0Core

@testable import Zer0Shell

/// Opens a real installed extension's own page through the whole browser and
/// photographs it.
///
/// Not a lock, and it cannot be one: nothing in CI may depend on any particular
/// extension existing. It installs through the browser's own path into this
/// model's own storage — never the author's profile — and the locks that run
/// every time live in `ExtensionPageTests`.
///
///     ZER0_SHOT=1 ZER0_EXT_ID=<store id> ZER0_PROBE_DIR=/tmp/out \
///       swift test --filter ZZExtensionPageShots
@MainActor
struct ZZExtensionPageShots {
    static func say(_ line: String) {
        print("[shot] \(line)")
    }

    @Test(
        "an installed extension's own page, opened the way a person would",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    func anInstalledExtensionsPage() async throws {
        let id = try #require(
            ProcessInfo.processInfo.environment["ZER0_EXT_ID"],
            "set ZER0_EXT_ID to a store id, e.g. 1Password's"
        )
        let out = URL(fileURLWithPath:
            ProcessInfo.processInfo.environment["ZER0_PROBE_DIR"] ?? NSTemporaryDirectory())
        let page = ProcessInfo.processInfo.environment["ZER0_EXT_PAGE"]
            ?? "app/app.html#/page/welcome"

        // Installed through the browser's own path, into this model's own
        // storage and never the author's profile. That is also what puts
        // ADR-0100's compatibility file in place, so the worker comes up the
        // way it does for a person.
        let m = BrowserModel(storagePath: nil)
        let host = try #require(m.extensions)
        let request = try await m.installExtension(id: id)
        let installed = try #require(m.installedExtensions.first { $0.id == id })
        let manifest = installed.manifest
        let context = try await host.load(
            installed,
            granting: defaultConsentDecision(request: request, decidedAtMs: 1_000)
        )
        Self.say("loaded \(manifest.name) \(manifest.version), base = \(context.baseURL)")

        let address = context.baseURL.absoluteString + page
        m.send(.openTab(space: nil, url: address, parent: nil))
        let tab = try #require(m.snapshot.activeTab)

        // A window, because a view that is never in one is a view WebKit is
        // free to leave unpainted — and this harness exists to be looked at.
        let window = testWindow(CGRect(x: 0, y: 0, width: 1100, height: 860))
        let view = try #require(m.engine.webView(for: tab), """
            no view was built for the tab. Either the address did not survive the core, or the
            base host resolved to no loaded extension.
            """)
        view.frame = CGRect(x: 0, y: 0, width: 1100, height: 860)
        window.contentView?.addSubview(view)

        _ = await eventually(timeout: .seconds(60)) {
            await Self.text(view).count > 20
        }
        Self.say("url = \(view.url?.absoluteString ?? "<nil>")")
        Self.say("title = \(view.title ?? "<nil>")")
        Self.say("text = \(await Self.text(view).prefix(400))")
        Self.say("controls = \(await Self.controls(view).prefix(600))")
        Self.say("context.errors = \(context.errors.map { "\($0)" })")
        Self.say("dom = \(await Self.dom(view).prefix(1200))")

        if let image = try? await view.takeSnapshot(configuration: nil),
           let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:])
        {
            let path = out.appendingPathComponent("extension-page.png")
            try? png.write(to: path)
            Self.say("wrote \(path.path)")
        }
        view.removeFromSuperview()
    }

    private static func text(_ view: WKWebView) async -> String {
        let value = try? await view.evaluateJavaScript("""
        (function () {
          function walk(root, out) {
            root.querySelectorAll('*').forEach(function (e) {
              if (e.shadowRoot) { walk(e.shadowRoot, out); }
            });
            out.push(root.textContent || '');
          }
          var out = [];
          try { walk(document, out); } catch (e) { return ''; }
          return out.join(' ').replace(/\\s+/g, ' ').trim();
        })()
        """)
        return (value as? String) ?? ""
    }

    /// Enough of the document to tell "nothing loaded" from "loaded and drew
    /// nothing", which look identical in a photograph.
    private static func dom(_ view: WKWebView) async -> String {
        let value = try? await view.evaluateJavaScript("""
        JSON.stringify({
          href: location.href,
          readyState: document.readyState,
          htmlLength: document.documentElement.outerHTML.length,
          bodyChildren: document.body ? document.body.children.length : -1,
          bodyHTML: document.body ? document.body.innerHTML.slice(0, 500) : '',
          scripts: Array.from(document.scripts).map(function (s) { return s.src || '<inline>'; }),
          // Whether the page is inside the extension's world at all. If any of
          // these is missing, the view was built wrong and it is ours; if they
          // are all there, whatever failed happened inside the extension.
          chrome: typeof chrome,
          runtimeId: (typeof chrome !== 'undefined' && chrome.runtime) ? chrome.runtime.id : null,
          sendMessage: (typeof chrome !== 'undefined' && chrome.runtime)
            ? typeof chrome.runtime.sendMessage : 'no runtime',
          storage: (typeof chrome !== 'undefined') ? typeof chrome.storage : 'no chrome',
          i18n: (typeof chrome !== 'undefined' && chrome.i18n)
            ? chrome.i18n.getMessage('extName') : null
        })
        """)
        return (value as? String) ?? "<nil>"
    }

    private static func controls(_ view: WKWebView) async -> String {
        let value = try? await view.evaluateJavaScript("""
        JSON.stringify(Array.from(document.querySelectorAll('button, a, [role=button]'))
          .map(function (e) { return (e.innerText || '').trim(); })
          .filter(function (t) { return t.length > 0; }))
        """)
        return (value as? String) ?? ""
    }
}
