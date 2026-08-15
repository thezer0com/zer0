import AppKit
import Foundation
import Testing
import WebKit
import Zer0Core

@testable import Zer0Shell

/// Throwaway probe: drive 1Password's own interface and find out what it offers
/// a browser with no native host.
///
/// Not a lock. Nothing in CI may depend on 1Password being installed.
@MainActor
final class OPProbeDelegate: NSObject, WKWebExtensionControllerDelegate {
    var nativeSends = 0
    var nativeConnects = 0
    var log: [String] = []
    var windows: [any WKWebExtensionWindow] = []

    func webExtensionController(
        _: WKWebExtensionController,
        openWindowsFor _: WKWebExtensionContext
    ) -> [any WKWebExtensionWindow] { windows }

    func webExtensionController(
        _: WKWebExtensionController,
        focusedWindowFor _: WKWebExtensionContext
    ) -> (any WKWebExtensionWindow)? { windows.first }

    func webExtensionController(
        _: WKWebExtensionController,
        sendMessage message: Any,
        toApplicationWithIdentifier applicationIdentifier: String?,
        for _: WKWebExtensionContext,
        replyHandler: @escaping (Any?, (any Error)?) -> Void
    ) {
        nativeSends += 1
        log.append("sendMessage -> \(applicationIdentifier ?? "<nil>") : \(message)")
        replyHandler(nil, NSError(
            domain: "zer0.probe", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "no native host"]
        ))
    }

    func webExtensionController(
        _: WKWebExtensionController,
        connectUsing port: WKWebExtension.MessagePort,
        for _: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        nativeConnects += 1
        log.append("connectUsingMessagePort -> \(port.applicationIdentifier ?? "<nil>")")
        completionHandler(NSError(
            domain: "zer0.probe", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "no native host"]
        ))
    }

    /// Actually open it, so a page the extension navigates to can be read.
    var openTab: ((URL?) -> OPProbeTab?)?

    func webExtensionController(
        _: WKWebExtensionController,
        openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for _: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void
    ) {
        log.append("openNewTab -> \(configuration.url?.absoluteString ?? "<nil>")")
        completionHandler(openTab?(configuration.url), nil)
    }

    func webExtensionController(
        _: WKWebExtensionController,
        presentActionPopup _: WKWebExtension.Action,
        for _: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        log.append("presentActionPopup")
        completionHandler(nil)
    }
}

/// One window with one tab, enough for `chrome.tabs.query({active: true})`.
@MainActor
final class OPProbeTab: NSObject, WKWebExtensionTab {
    let view: WKWebView
    weak var owner: OPProbeWindow?

    init(view: WKWebView) { self.view = view }

    func window(for _: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { owner }
    func webView(for _: WKWebExtensionContext) -> WKWebView? { view }
    func url(for _: WKWebExtensionContext) -> URL? { view.url }
    func title(for _: WKWebExtensionContext) -> String? { view.title }
    func isSelected(for _: WKWebExtensionContext) -> Bool { true }
    func isLoadingComplete(for _: WKWebExtensionContext) -> Bool { !view.isLoading }
    func indexInWindow(for _: WKWebExtensionContext) -> Int { 0 }
}

@MainActor
final class OPProbeWindow: NSObject, WKWebExtensionWindow {
    var tab: OPProbeTab?
    func tabs(for _: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        tab.map { [$0] } ?? []
    }

    func activeTab(for _: WKWebExtensionContext) -> (any WKWebExtensionTab)? { tab }
    func windowType(for _: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    func windowState(for _: WKWebExtensionContext) -> WKWebExtension.WindowState { .normal }
    func isPrivate(for _: WKWebExtensionContext) -> Bool { false }
    func frame(for _: WKWebExtensionContext) -> CGRect { CGRect(x: 0, y: 0, width: 1280, height: 800) }
    func screenFrame(for _: WKWebExtensionContext) -> CGRect {
        CGRect(x: 0, y: 0, width: 1280, height: 800)
    }
}

@MainActor
struct OnePasswordProbe {
    static var out: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["ZER0_PROBE_DIR"] ?? NSTemporaryDirectory())
    }

    static func say(_ line: String) {
        print("[probe] \(line)")
        let file = out.appendingPathComponent("probe.log")
        let text = line + "\n"
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    @Test(
        "drive 1Password's own screens",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    func drive() async throws {
        let id = "aeblfdkhhhdcdjpifhhbdiojplfjncoa"
        let model = BrowserModel(storagePath: nil)

        Self.say("downloading + installing \(id) through the real install path")
        let request = try await model.installExtension(id: id)
        let installed = try #require(model.installedExtensions.first { $0.id == id })
        Self.say("installed at \(installed.path)")
        Self.say("manifest name=\(installed.manifest.name) version=\(installed.manifest.version)")
        Self.say("compat=\(String(describing: installed.manifest.compat))")

        let decision = defaultConsentDecision(request: request, decidedAtMs: 1000)
        Self.say("granted: \(decision.grantedPermissions.sorted())")
        Self.say("denied: \(decision.deniedPermissions.sorted())")

        // A controller of our own, so native messaging attempts can be counted.
        let configuration = WKWebExtensionController.Configuration.default()
        let webViewConfiguration = configuration.webViewConfiguration
        webViewConfiguration?.applicationNameForUserAgent = HostedWebView.safariUserAgentToken
        configuration.webViewConfiguration = webViewConfiguration
        let controller = WKWebExtensionController(configuration: configuration)
        let delegate = OPProbeDelegate()
        controller.delegate = delegate

        // A page for the extension to look at.
        let pageConfiguration = WKWebViewConfiguration()
        pageConfiguration.webExtensionController = controller
        pageConfiguration.applicationNameForUserAgent = HostedWebView.safariUserAgentToken
        let page = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 1280, height: 800),
            configuration: pageConfiguration
        )
        let window = testWindow(CGRect(x: 0, y: 0, width: 1280, height: 900))
        window.contentView?.addSubview(page)
        let probeWindow = OPProbeWindow()
        let probeTab = OPProbeTab(view: page)
        probeTab.owner = probeWindow
        probeWindow.tab = probeTab
        delegate.windows = [probeWindow]

        // Every page the extension opens for itself, kept so it can be read.
        var opened: [OPProbeTab] = []
        delegate.openTab = { url in
            let view = WKWebView(
                frame: CGRect(x: 0, y: 0, width: 1000, height: 760),
                configuration: pageConfiguration
            )
            window.contentView?.addSubview(view)
            if let url { view.load(URLRequest(url: url)) }
            let tab = OPProbeTab(view: view)
            tab.owner = probeWindow
            opened.append(tab)
            return tab
        }

        page.load(URLRequest(url: URL(string: "https://example.com/")!))
        _ = await eventually(timeout: .seconds(20)) { !page.isLoading }

        let ext = try await WKWebExtension(resourceBaseURL: URL(fileURLWithPath: installed.path, isDirectory: true))
        let context = WKWebExtensionContext(for: ext)
        for permission in decision.grantedPermissions {
            context.setPermissionStatus(.grantedExplicitly, for: WKWebExtension.Permission(permission))
        }
        for pattern in decision.grantedHosts {
            if let match = try? WKWebExtension.MatchPattern(string: pattern) {
                context.setPermissionStatus(.grantedExplicitly, for: match)
            } else if pattern == "<all_urls>" {
                context.setPermissionStatus(.grantedExplicitly, for: WKWebExtension.MatchPattern.allURLs())
            }
        }
        try controller.load(context)
        Self.say("loaded. waiting for the worker.")

        // The one configuration an extension page is allowed to load in.
        // `WKWebExtensionContext.h`: "navigations will be canceled if a web
        // view not configured with this configuration attempts to navigate to
        // a URL that does originate from this extension's base URL."
        let extensionConfiguration = try #require(context.webViewConfiguration)
        delegate.openTab = { url in
            let view = WKWebView(
                frame: CGRect(x: 0, y: 0, width: 1000, height: 760),
                configuration: extensionConfiguration
            )
            window.contentView?.addSubview(view)
            if let url { view.load(URLRequest(url: url)) }
            let tab = OPProbeTab(view: view)
            tab.owner = probeWindow
            opened.append(tab)
            return tab
        }

        // Let the worker come up.
        _ = await eventually(timeout: .seconds(20)) { delegate.nativeConnects > 0 }
        Self.say("context.errors = \(context.errors.map { "\($0)" })")
        Self.say("after load: sends=\(delegate.nativeSends) connects=\(delegate.nativeConnects)")

        // 1. The press. This is what makes the extension reach for its host.
        let action = try #require(context.action(for: probeTab), "no action for the tab")
        Self.say("action label=\(action.label) presentsPopup=\(action.presentsPopup)")
        context.performAction(for: probeTab)
        if let popup = action.popupWebView {
            popup.frame = CGRect(x: 0, y: 0, width: 380, height: 600)
            window.contentView?.addSubview(popup)
            _ = await eventually(timeout: .seconds(45)) { delegate.nativeConnects > 0 }
            _ = await eventually(timeout: .seconds(90)) {
                let text = (try? await popup.evaluateJavaScript(
                    "document.body ? document.body.innerText : ''"
                )) as? String
                return ((text ?? "")?.count ?? 0) > 20
            }
            await dump(popup, label: "popup")
        } else {
            Self.say("no popup web view")
        }
        Self.say("after press: sends=\(delegate.nativeSends) connects=\(delegate.nativeConnects)")
        for line in delegate.log { Self.say("  delegate: \(line)") }

        // 2. The extension's own onboarding screen, which is where the sign-in
        //    offer lives if there is one. Loaded twice on purpose: once in the
        //    ordinary page configuration, which is what zer0's `openNewTab`
        //    hands an extension URL today, and once in the extension's.
        let base = context.baseURL
        for (label, configuration) in [
            ("plain", pageConfiguration), ("extension", extensionConfiguration),
        ] {
            guard let url = URL(string: base.absoluteString + "app/app.html#/page/welcome")
            else { continue }
            let view = WKWebView(
                frame: CGRect(x: 0, y: 0, width: 1000, height: 900),
                configuration: configuration
            )
            window.contentView?.addSubview(view)
            view.load(URLRequest(url: url))
            _ = await eventually(timeout: .seconds(30)) { !view.isLoading }
            _ = await eventually(timeout: .seconds(90)) {
                let text = (try? await view.evaluateJavaScript(
                    "document.body ? document.body.innerText : ''"
                )) as? String
                return (text ?? "").count > 40
            }
            await dump(view, label: "welcome-\(label)")
            view.removeFromSuperview()
        }

        // 3. Whatever the extension opened for itself.
        Self.say("the extension opened \(opened.count) page(s) of its own")
        for (index, tab) in opened.enumerated() {
            _ = await eventually(timeout: .seconds(20)) { !tab.view.isLoading }
            _ = await eventually(timeout: .seconds(60)) {
                let text = (try? await tab.view.evaluateJavaScript(
                    "document.body ? document.body.innerText : ''"
                )) as? String
                return (text ?? "").count > 40
            }
            await dump(tab.view, label: "opened-\(index)")
        }

        // 4. 1Password's own sign-in page, loaded through this controller so
        //    the extension's content scripts run on it. STOP at the first
        //    field: no credential is entered.
        let signIn = URL(string: "https://start.1password.com/signin/?auth-only=1")!
        let signInView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 1000, height: 900),
            configuration: pageConfiguration
        )
        window.contentView?.addSubview(signInView)
        signInView.load(URLRequest(url: signIn))
        _ = await eventually(timeout: .seconds(40)) { !signInView.isLoading }
        _ = await eventually(timeout: .seconds(120)) {
            let text = (try? await signInView.evaluateJavaScript(
                "document.body ? document.body.innerText : ''"
            )) as? String
            return (text ?? "").count > 40
        }
        await dump(signInView, label: "signin")

        // Did the extension's own content script reach this page? The manifest
        // declares `inline/injected/b5.js` for exactly these hosts, and it is
        // what turns a web session into an "account handler".
        //
        // `b5.js` sets `document.body.dataset.b5xBuildNumber` and dispatches
        // `B5OPXReady`. That attribute is the web app's own witness that the
        // extension is present, so it is the one to read.
        let reached = (try? await signInView.evaluateJavaScript("""
        JSON.stringify({
          b5xBuildNumber: document.body.dataset.b5xBuildNumber || null,
          onepasswordExtensionVersion: document.body.dataset.onepasswordExtensionVersion || null,
          bodyDataset: Object.keys(document.body.dataset)
        })
        """)) as? String
        Self.say("signin: extension traces = \(reached ?? "<nil>")")

        Self.say("FINAL native sends=\(delegate.nativeSends) connects=\(delegate.nativeConnects)")
        for line in delegate.log { Self.say("  delegate: \(line)") }

        window.contentView?.subviews.forEach { $0.removeFromSuperview() }
    }

    private func dump(_ view: WKWebView, label: String) async {
        let url = (try? await view.evaluateJavaScript("location.href")) as? String
        Self.say("\(label): url=\(url ?? "<nil>")")
        let title = (try? await view.evaluateJavaScript("document.title")) as? String
        Self.say("\(label): title=\(title ?? "<nil>")")
        let text = (try? await view.evaluateJavaScript(
            "document.body ? document.body.innerText : '<no body>'"
        )) as? String
        Self.say("\(label): text=\n\(text ?? "<nil>")")
        let controls = (try? await view.evaluateJavaScript("""
        JSON.stringify(Array.from(document.querySelectorAll(
          'button, a, input, [role=button], [role=link]'
        )).map(function (e) {
          return {
            tag: e.tagName, type: e.type || '', text: (e.innerText || e.value || '').slice(0, 120),
            href: e.href || '', label: e.getAttribute('aria-label') || '',
            placeholder: e.placeholder || ''
          };
        }))
        """)) as? String
        Self.say("\(label): controls=\(controls ?? "<nil>")")

        // And a photograph, because the interface is verified by looking.
        if let snapshot = try? await view.takeSnapshot(configuration: nil),
           let tiff = snapshot.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            try? png.write(to: Self.out.appendingPathComponent("\(label).png"))
            Self.say("\(label): wrote \(label).png")
        }
    }
}
