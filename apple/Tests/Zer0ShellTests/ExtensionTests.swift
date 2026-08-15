import Testing
import WebKit
import Zer0Core

@testable import Zer0Shell

/// A real unpacked extension on disk, cleaned up when it goes out of scope.
@MainActor
final class ExtensionFixture {
    let installed: InstalledExtension
    private let directory: URL

    init(
        id: String = String(repeating: "a", count: 32),
        name: String = "Test Extension",
        permissions: [String] = ["storage", "tabs"],
        hostPermissions: [String] = ["https://*/*"],
        includeManifest: Bool = true,
        // Most fixtures want a button, because most extensions have one and
        // because it is what puts them on the row. The ones that do not are
        // testing exactly that.
        hasAction: Bool = true,
        // A background service worker, written verbatim. `nil` means the
        // manifest declares none at all, which is what most fixtures want:
        // WebKit then has nothing to start and nothing to fail at.
        backgroundScript: String? = nil,
        // The action's `default_popup`, written verbatim. `nil` is an action
        // with no popup, which is what an extension that only fires `onClicked`
        // has and what most fixtures want.
        popup: String? = nil,
        // Pages of the extension's own, by file name. An options screen, an
        // onboarding page — the things `webkit-extension://` addresses point
        // at. Empty is what most fixtures want: an extension with no page of
        // its own is the ordinary case.
        pages: [String: String] = [:],
        // Where to unpack it. `nil` is a directory of its own, which is what a
        // test loading it by hand wants; a profile's own `extensions` folder is
        // what a test going through `installedExtensions` wants, because that
        // is the only place the core looks.
        in extensionsDirectory: URL? = nil
    ) throws {
        directory = extensionsDirectory?.appendingPathComponent(id)
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("zer0-ext-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        if let backgroundScript {
            try backgroundScript.write(
                to: directory.appendingPathComponent("background.js"),
                atomically: true,
                encoding: .utf8
            )
        }

        if let popup {
            try popup.write(
                to: directory.appendingPathComponent("popup.html"),
                atomically: true,
                encoding: .utf8
            )
        }

        for (name, html) in pages {
            try html.write(
                to: directory.appendingPathComponent(name),
                atomically: true,
                encoding: .utf8
            )
        }

        if includeManifest {
            let quoted = permissions.map { "\"\($0)\"" }.joined(separator: ", ")
            let background = backgroundScript == nil
                ? ""
                : ",\n    \"background\": { \"service_worker\": \"background.js\" }"
            let action = popup == nil
                ? "{}"
                : "{ \"default_popup\": \"popup.html\" }"
            try """
            {
                "manifest_version": 3,
                "name": "\(name)",
                "version": "1.0.0",
                "permissions": [\(quoted)]\(hasAction ? ",\n    \"action\": \(action)" : "")\(background)
            }
            """.write(
                to: directory.appendingPathComponent("manifest.json"),
                atomically: true,
                encoding: .utf8
            )
        }

        installed = InstalledExtension(
            id: id,
            path: directory.path,
            manifest: ExtensionManifest(
                name: name,
                version: "1.0.0",
                description: nil,
                manifestVersion: 3,
                permissions: permissions,
                hostPermissions: hostPermissions,
                hasAction: hasAction,
                compat: nil
            )
        )
    }

    /// The decision someone would make by accepting the dialog as it opens:
    /// everything the browser can explain, and nothing it cannot.
    var everything: ConsentDecision {
        defaultConsentDecision(request: consentRequest, decidedAtMs: 1_000)
    }

    /// The decision someone would make by switching every row off.
    var nothing: ConsentDecision {
        var decision = everything
        for request in consentRequest.requests {
            decision = consentDecisionSetting(
                decision: decision,
                kind: request.kind,
                key: request.key,
                granted: false
            )
        }
        return decision
    }

    var consentRequest: ConsentRequest {
        consentRequestFor(installed)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Built through a throwaway core so the words and the ranking are the real
/// ones rather than a second copy written in the test.
@MainActor
private func consentRequestFor(_ installed: InstalledExtension) -> ConsentRequest {
    BrowserModel(storagePath: nil).consentRequest(for: installed)
}

@MainActor
private func newModel() -> BrowserModel {
    BrowserModel(storagePath: nil)
}

/// Loading extensions into a real `WKWebExtensionController`.
@MainActor
struct ExtensionHostTests {
    @Test("an unpacked extension loads into the controller")
    func extensionLoads() async throws {
        let m = newModel()
        let host = try #require(m.extensions)
        let fixture = try ExtensionFixture()

        let context = try await host.load(fixture.installed, granting: fixture.everything)

        #expect(host.loadedIds.contains(fixture.installed.id))
        #expect(context.webExtension.displayName == "Test Extension")
    }

    @Test("approved permissions are granted, not left pending")
    func permissionsAreGranted() async throws {
        let m = newModel()
        let host = try #require(m.extensions)
        let fixture = try ExtensionFixture(permissions: ["storage", "tabs"])

        let context = try await host.load(fixture.installed, granting: fixture.everything)

        // A permission left unrequested means the API silently does nothing,
        // which is the hardest kind of extension bug to diagnose.
        #expect(context.hasPermission(WKWebExtension.Permission("tabs")))
        #expect(context.hasPermission(WKWebExtension.Permission("storage")))
    }

    @Test("approved host permissions are granted for the sites they name")
    func hostPermissionsAreGranted() async throws {
        let m = newModel()
        let host = try #require(m.extensions)
        let fixture = try ExtensionFixture(hostPermissions: ["https://*/*"])

        let context = try await host.load(fixture.installed, granting: fixture.everything)

        let url = try #require(URL(string: "https://avelino.run/"))
        #expect(context.hasAccess(to: url))
    }

    @Test("loading the same extension twice does not load it twice")
    func loadingIsIdempotent() async throws {
        let m = newModel()
        let host = try #require(m.extensions)
        let fixture = try ExtensionFixture()

        _ = try await host.load(fixture.installed, granting: fixture.everything)
        _ = try await host.load(fixture.installed, granting: fixture.everything)

        #expect(host.loadedIds.count == 1)
    }

    @Test("unloading removes it from the controller")
    func extensionUnloads() async throws {
        let m = newModel()
        let host = try #require(m.extensions)
        let fixture = try ExtensionFixture()
        _ = try await host.load(fixture.installed, granting: fixture.everything)

        host.unload(fixture.installed.id)

        #expect(host.loadedIds.isEmpty)
    }

    @Test("a directory with no manifest fails instead of loading quietly")
    func aBrokenExtensionFailsLoudly() async throws {
        let m = newModel()
        let host = try #require(m.extensions)
        let broken = try ExtensionFixture(
            id: String(repeating: "b", count: 32),
            includeManifest: false
        )

        await #expect(throws: (any Error).self) {
            _ = try await host.load(broken.installed, granting: broken.everything)
        }
        #expect(host.loadedIds.isEmpty)
    }

    /// Loading is not running, and WebKit is the only one who knows.
    ///
    /// `controller.load` returns successfully for both of these. The difference
    /// shows up afterwards, in `WKWebExtensionContext.errors`, and nothing else
    /// in the browser is told. Both are in one test on purpose: the failing one
    /// alone would stay green against `backgroundContentFailed` hardcoded to
    /// `true`, which is exactly the shape of lock that defends nothing.
    @Test("only the extension whose background content died is called broken")
    func onlyADeadBackgroundIsCalledBroken() async throws {
        let m = newModel()
        let host = try #require(m.extensions)
        let dead = try ExtensionFixture(
            id: String(repeating: "c", count: 32),
            name: "Dead Background",
            backgroundScript: "throw new Error('this worker does not come up');"
        )
        let alive = try ExtensionFixture(
            id: String(repeating: "d", count: 32),
            name: "Live Background",
            backgroundScript: "self.zer0BackgroundRan = true;"
        )

        _ = try await host.load(dead.installed, granting: dead.everything)
        _ = try await host.load(alive.installed, granting: alive.everything)

        // Polled rather than slept on: WebKit fills the error list some time
        // after the load returns, and how long is not ours to guess.
        #expect(
            await eventually { host.backgroundContentFailed(dead.installed.id) },
            "WebKit never reported the broken worker"
        )
        // Read at the same instant the other one has already failed, so this
        // half needs no waiting of its own to be worth anything.
        #expect(!host.backgroundContentFailed(alive.installed.id))
    }

    @Test("an extension with no background content at all is not called broken")
    func noBackgroundIsNotABrokenBackground() async throws {
        let m = newModel()
        let host = try #require(m.extensions)
        // WebKit has a separate error for this — `noBackgroundContent` — and
        // reading "there is none" as "it failed" would mark every content-script
        // extension in the browser as broken.
        let fixture = try ExtensionFixture(id: String(repeating: "e", count: 32))

        _ = try await host.load(fixture.installed, granting: fixture.everything)

        #expect(!host.backgroundContentFailed(fixture.installed.id))
    }

    /// A permission nobody granted does not fail politely — it removes the API.
    ///
    /// WebKit installs a namespace into the background context only once the
    /// permission gating it is granted. Denied, `chrome.storage` is not a
    /// `storage` object whose calls report an error; it is `undefined`. So a
    /// worker that touches it on the way up throws, and WebKit reports exactly
    /// the same `backgroundContentFailedToLoad` it reports for an API it does
    /// not implement at all.
    ///
    /// That is why the Extensions screen may not blame the engine whenever this
    /// flag is set (ADR-0077): this browser can cause the state itself, out of a
    /// decision somebody made in its own consent sheet.
    @Test("a permission that was denied is enough to kill the background")
    func aDeniedPermissionIsEnoughToKillTheBackground() async throws {
        let m = newModel()
        let host = try #require(m.extensions)
        let fixture = try ExtensionFixture(
            id: String(repeating: "f", count: 32),
            name: "Denied Storage",
            permissions: ["storage"],
            hostPermissions: [],
            // The shape MV3 pushes everyone towards: touched while the worker
            // is starting, not inside a handler that may never run.
            backgroundScript: "chrome.storage.local.get(['k'], () => {});"
        )

        // Granting nothing, which is what switching every row off produces.
        _ = try await host.load(fixture.installed, granting: fixture.nothing)

        #expect(
            await eventually { host.backgroundContentFailed(fixture.installed.id) },
            "a denied permission left the background running, so the Extensions screen no longer needs to distinguish this"
        )
    }

    /// An extension's own contexts are pages too, and they were the only pages
    /// in this browser not told what browser they are in.
    ///
    /// `EngineHost` sets `applicationNameForUserAgent` on every configuration
    /// it builds a view from; a background service worker is not built from one
    /// of those, so its UA ended at `(KHTML, like Gecko)` and carried no product
    /// token at all. Bitwarden sniffs for one and dies on the way up. ADR-0081
    /// closed that gap by setting the **browsing** UA here; ADR-0106 widened
    /// this one knob to also name Chrome, because per-extension UA is not a
    /// lever WebKit gives and the cost of "tell extensions Safari" was paid
    /// twice (1Password, Bitwarden). The split — Chrome on workers, Safari-only
    /// on pages — is defended by `theExtensionContextNamesChromeButPagesDoNot`.
    ///
    /// Read out of the worker rather than off the configuration, because the
    /// configuration is a copy of a copy and asserting on it would prove that a
    /// property was set, not that anything reads it. The worker throwing is the
    /// only signal WebKit gives, which is exactly the signal ADR-0072 already
    /// established this host can see.
    ///
    /// **Both halves are the test.** The second fixture is the instrument
    /// check: it demands a token this browser still refuses everywhere
    /// (ADR-0073), so it must fail. Without it, the first `#expect` stays green
    /// against a `backgroundContentFailed` that never returns `true`.
    @Test("an extension's background worker is told which browser it is in")
    func theExtensionContextCarriesTheBrowsersUserAgent() async throws {
        let m = newModel()
        let host = try #require(m.extensions)

        let reads = try ExtensionFixture(
            id: String(repeating: "g", count: 32),
            name: "Reads Its User-Agent",
            backgroundScript: """
            if (!navigator.userAgent.includes("\(HostedWebView.chromeCompatibleUserAgentToken)")) {
                throw new Error("no browser token: " + navigator.userAgent);
            }
            """
        )
        // The same script asking for something this browser has promised never
        // to say. It has to die, or the half above means nothing. ADR-0106
        // moved this from `Chrome/` (which the worker now carries) to `Firefox/`
        // (which this browser still refuses everywhere — ADR-0073).
        let control = try ExtensionFixture(
            id: String(repeating: "h", count: 32),
            name: "Demands A Browser We Are Not",
            backgroundScript: """
            if (!navigator.userAgent.includes("Firefox/")) {
                throw new Error("no Firefox token: " + navigator.userAgent);
            }
            """
        )

        _ = try await host.load(reads.installed, granting: reads.everything)
        _ = try await host.load(control.installed, granting: control.everything)

        #expect(
            await eventually { host.backgroundContentFailed(control.installed.id) },
            "the instrument cannot see a worker refusing a User-Agent, so the other half proves nothing"
        )
        #expect(
            !host.backgroundContentFailed(reads.installed.id),
            "the worker did not find \(HostedWebView.chromeCompatibleUserAgentToken) in its own User-Agent"
        )
    }

    /// The split ADR-0106 made: extension contexts name Chrome, pages the
    /// person visits do not. Collapsing the two — by pointing the controller
    /// back at `safariUserAgentToken`, or by moving `chromeCompatibleUserAgentToken`
    /// onto `EngineHost`'s views — regresses ADR-0106 silently, and the only
    /// signal weeks later is "1Password stopped connecting" or "Bitwarden died".
    ///
    /// Both halves are read live: a background worker that throws if its UA
    /// lacks `Chrome/`, and `navigator.userAgent` out of a real browsing view.
    /// The split is the whole decision; this test is the only instrument that
    /// sees both sides of it at once.
    ///
    /// The control worker (demanding `Firefox/`) is the instrument check from
    /// `theExtensionContextCarriesTheBrowsersUserAgent`, repeated here because
    /// without it the worker-side `#expect` stays green against a
    /// `backgroundContentFailed` that never returns `true` — which is exactly
    /// the failure shape a reverted constant produces while the worker is still
    /// starting. Awaiting the control's failure is what gives the worker the
    /// window to fail in.
    @Test("extension contexts name Chrome; pages the person visits do not")
    func theExtensionContextNamesChromeButPagesDoNot() async throws {
        let m = newModel()
        let host = try #require(m.extensions)

        let worker = try ExtensionFixture(
            id: String(repeating: "k", count: 32),
            name: "Expects Chrome",
            backgroundScript: """
            if (!navigator.userAgent.includes("Chrome/")) {
                throw new Error("no Chrome token: " + navigator.userAgent);
            }
            """
        )
        // Instrument check: a worker that demands a token this browser still
        // refuses everywhere must fail — and waiting for that failure is what
        // gives the worker above the window to fail too, if its UA lacks Chrome/.
        let control = try ExtensionFixture(
            id: String(repeating: "l", count: 32),
            name: "Demands A Browser We Are Not",
            backgroundScript: """
            if (!navigator.userAgent.includes("Firefox/")) {
                throw new Error("no Firefox token: " + navigator.userAgent);
            }
            """
        )

        _ = try await host.load(worker.installed, granting: worker.everything)
        _ = try await host.load(control.installed, granting: control.everything)

        #expect(
            await eventually { host.backgroundContentFailed(control.installed.id) },
            "instrument check: a worker demanding Firefox/ never failed, so the worker half below proves nothing"
        )
        #expect(
            !host.backgroundContentFailed(worker.installed.id),
            "extension worker did not see Chrome/ in its UA — ADR-0106 regressed"
        )

        // The page side: a real browsing view, not an extension context.
        let tab = try #require(m.snapshot.activeTab)
        let webView = try #require(m.engine.webView(for: tab))
        let ua = try #require(
            try await webView.evaluateJavaScript("navigator.userAgent") as? String
        )

        #expect(!ua.contains("Chrome/"), "page UA now carries Chrome/ — ADR-0073 regressed: \(ua)")
        #expect(ua.contains("Safari/"), "page UA lost Safari/ — ADR-0008 regressed: \(ua)")
    }

    @Test("web views are built with the extension controller attached")
    func webViewsJoinTheController() async throws {
        let m = newModel()
        let tab = try #require(m.snapshot.activeTab)
        let webView = try #require(m.engine.webView(for: tab))

        // Without this a content script never runs: the page is simply outside
        // the controller's world.
        #expect(webView.configuration.webExtensionController != nil)
    }
}

/// What a fetch from the store is allowed to be turned into.
@MainActor
struct ExtensionDownloadRefusalTests {
    private func refusal(_ data: Data, _ status: Int) -> ExtensionInstallError? {
        ExtensionInstallError.refusal(
            toStoreResponse: data,
            status: status,
            id: "ddkjiahejlhfcafbddmgiahcphecmpfh",
            chromeVersion: "200.0.0.0"
        )
    }

    /// `204 No Content` is a success, so the status range waves it through and
    /// an empty buffer reaches the CRX parser, which says "not a CRX package"
    /// about a file the person never had. Measured on 2026-08-10, two of
    /// eighteen popular ids answer 204 at every version tried, so this is a
    /// state the browser has to be able to explain rather than one a better
    /// version number removes.
    @Test("a store answer carrying no package is refused, not parsed")
    func nothingFromTheStoreIsARefusal() throws {
        let error = try #require(refusal(Data(), 204))

        let sentence = try #require(error.errorDescription)
        // The id, because there is no other way to know which Add failed.
        #expect(sentence.contains("ddkjiahejlhfcafbddmgiahcphecmpfh"))
        // And the number that has to move, because a stale one is one of the
        // two reasons and the person reporting it is holding the evidence.
        #expect(sentence.contains("200.0.0.0"))
    }

    /// The half that stops the refusal from swallowing every install.
    @Test("a store answer carrying a package is not refused")
    func bytesFromTheStoreAreNotARefusal() {
        #expect(refusal(Data("Cr24".utf8), 200) == nil)
    }

    /// A status outside the success range keeps saying what it always said, so
    /// the new sentence never gets printed over an HTTP failure it cannot
    /// explain — a 404 is not the store answering with nothing.
    @Test("an unsuccessful status is still reported as its status")
    func aFailedRequestIsStillAFailedRequest() throws {
        let error = try #require(refusal(Data(), 404))

        guard case let .download(status) = error else {
            Issue.record("a 404 was reported as the store having nothing: \(error)")
            return
        }
        #expect(status == 404)
    }
}

/// The sentence the Extensions screen prints for one row.
@MainActor
struct ExtensionStatusTests {
    @Test("a background WebKit could not start outranks the core's word that it is running")
    func aBrokenBackgroundIsNotCalledRunning() {
        // The core's answer is unchanged and still correct on its own terms:
        // this extension was granted everything it asked for and its context
        // loaded. What the core cannot see is that the worker then died.
        let status = ExtensionStatus.of(
            standing: .running(held: 15, asked: 15, withheld: .nothing),
            backgroundFailed: true
        )

        #expect(!status.isRunning)
        #expect(
            status.summary == "Not running. WebKit could not start its background page.",
            "said instead: \(status.summary)"
        )
    }

    @Test("a background that failed while something was withheld does not blame the engine")
    func aWithheldPermissionIsNamedRatherThanBlamingTheEngine() {
        // Same platform fact as above, different standing: this one is holding
        // less than it asked for, and what it is missing is something this
        // browser could have given it — which is on its own enough to produce
        // the failure being reported.
        let status = ExtensionStatus.of(
            standing: .running(held: 13, asked: 15, withheld: .somethingProvidable),
            backgroundFailed: true
        )

        #expect(!status.isRunning)
        // Naming WebKit here would point at the engine for something this
        // browser may have done, and would send somebody to a bug report when
        // the fix is a toggle on the same screen.
        #expect(
            !status.summary.contains("WebKit"),
            "blamed the engine for a state a withheld permission explains: \(status.summary)"
        )
        // And the counts have to survive, because they are the only thing that
        // makes the sentence actionable.
        #expect(status.summary.contains("13"), "said instead: \(status.summary)")
        #expect(status.summary.contains("15"), "said instead: \(status.summary)")
    }

    @Test("a failure explained by nothing on this screen does not point at a switch")
    func nothingProvidableWithheldPointsAtNoSwitch() {
        // The state the owner was looking at: 1Password, seventeen things
        // asked for, two of them withheld — and both of those two are
        // permissions this engine does not implement, so granting them cannot
        // start anything. ADR-0077 read `held < asked` and sent them to a
        // toggle that could not have helped (ADR-0084).
        let status = ExtensionStatus.of(
            standing: .running(held: 15, asked: 17, withheld: .onlyTheUnprovidable),
            backgroundFailed: true
        )

        #expect(!status.isRunning)
        #expect(
            !status.summary.contains("switching one off"),
            "sent somebody to a switch that cannot change this: \(status.summary)"
        )
        // The counts survive, because they are the same numbers the running
        // state prints and the row a moment ago was one of them.
        #expect(status.summary.contains("15"), "said instead: \(status.summary)")
        #expect(status.summary.contains("17"), "said instead: \(status.summary)")
        // And it says why there is nothing to press.
        #expect(
            status.summary.contains("cannot provide"),
            "said instead: \(status.summary)"
        )
    }

    @Test("an extension whose background is fine still reads as running")
    func aWorkingExtensionStillReadsAsRunning() {
        // The other half, and the one that catches a correction applied to
        // every row rather than to the broken ones.
        let status = ExtensionStatus.of(
            standing: .running(held: 15, asked: 15, withheld: .nothing),
            backgroundFailed: false
        )

        #expect(status.isRunning)
        #expect(status.summary == "Running with all 15 permissions it asked for.")
    }

    @Test("a broken background does not overwrite a reason that is already true")
    func nothingGrantedStillSaysNothingGranted() {
        // An extension holding nothing is not loaded at all, so there is no
        // context to have failed. If this ever reports a failure the answer has
        // stopped being about this extension.
        let status = ExtensionStatus.of(standing: .grantedNothing, backgroundFailed: false)

        #expect(!status.isRunning)
        #expect(status.summary == "Not running. You granted it nothing.")
    }
}

/// What an extension sees when it asks the browser about tabs.
@MainActor
struct ExtensionTabTests {
    /// A loaded context, which the protocol methods all require.
    private func loadedContext(
        _ m: BrowserModel,
        _ fixture: ExtensionFixture
    ) async throws -> WKWebExtensionContext {
        let host = try #require(m.extensions)
        return try await host.load(fixture.installed, granting: fixture.everything)
    }

    @Test("a tab answers from the Rust state rather than a copy of its own")
    func tabReflectsCoreState() async throws {
        let m = newModel()
        let fixture = try ExtensionFixture()
        let context = try await loadedContext(m, fixture)
        let id = try #require(m.snapshot.activeTab)
        let window = ExtensionWindow(id: m.snapshot.keyWindow, model: m)
        let tab = try #require(window.extensionTab(for: id))

        m.send(.navigationCommitted(tab: id, url: "https://avelino.run/"))
        m.send(.titleChanged(tab: id, title: "Avelino"))

        #expect(tab.title(for: context) == "Avelino")
        #expect(tab.url(for: context)?.absoluteString == "https://avelino.run/")
        #expect(tab.isSelected(for: context))
    }

    @Test("pinning is visible to an extension the moment the core changes it")
    func pinningIsVisible() async throws {
        let m = newModel()
        let fixture = try ExtensionFixture()
        let context = try await loadedContext(m, fixture)
        let id = try #require(m.snapshot.activeTab)
        let window = ExtensionWindow(id: m.snapshot.keyWindow, model: m)
        let tab = try #require(window.extensionTab(for: id))

        #expect(!tab.isPinned(for: context))
        m.setKind(id, .pinned)
        #expect(tab.isPinned(for: context))
    }

    @Test("an extension closing a tab goes through the reducer")
    func closingFromAnExtensionUsesTheSamePath() async throws {
        let m = newModel()
        let fixture = try ExtensionFixture()
        let context = try await loadedContext(m, fixture)
        m.send(.openTab(space: nil, url: nil, parent: nil))
        let id = try #require(m.snapshot.activeTab)
        let window = ExtensionWindow(id: m.snapshot.keyWindow, model: m)
        let tab = try #require(window.extensionTab(for: id))
        let before = m.snapshot.tabs.count

        try await tab.close(for: context)

        #expect(m.snapshot.tabs.count == before - 1)
        #expect(m.engine.webView(for: id) == nil, "the view must go with the tab")
    }

    @Test("an extension navigating a tab goes through the reducer")
    func navigatingFromAnExtensionUsesTheSamePath() async throws {
        let m = newModel()
        let fixture = try ExtensionFixture()
        let context = try await loadedContext(m, fixture)
        let id = try #require(m.snapshot.activeTab)
        let window = ExtensionWindow(id: m.snapshot.keyWindow, model: m)
        let tab = try #require(window.extensionTab(for: id))

        try await tab.loadURL(URL(string: "https://avelino.run/")!, for: context)

        #expect(m.snapshot.tabs.first { $0.id == id }?.pendingUrl == "https://avelino.run/")
    }

    @Test("the same tab always yields the same adapter object")
    func adaptersAreStable() async throws {
        let m = newModel()
        let id = try #require(m.snapshot.activeTab)
        let window = ExtensionWindow(id: m.snapshot.keyWindow, model: m)

        let first = try #require(window.extensionTab(for: id))
        let second = try #require(window.extensionTab(for: id))

        // A new object for the same tab would read as a tab replacement.
        #expect(first === second)
    }

    @Test("a closed tab yields no adapter")
    func closedTabsDisappear() async throws {
        let m = newModel()
        let id = try #require(m.snapshot.activeTab)
        let window = ExtensionWindow(id: m.snapshot.keyWindow, model: m)
        _ = window.extensionTab(for: id)

        m.close(id)

        #expect(window.extensionTab(for: id) == nil)
    }

    @Test("an extension only sees tabs in the space it is looking at")
    func spacesAreNotVisibleToEachOther() async throws {
        let m = newModel()
        let fixture = try ExtensionFixture()
        let context = try await loadedContext(m, fixture)
        let personalTab = try #require(m.snapshot.activeTab)

        m.createSpace(named: "Work")
        let workTab = try #require(m.snapshot.activeTab)
        #expect(workTab != personalTab)

        let window = ExtensionWindow(id: m.snapshot.keyWindow, model: m)
        let visible = window.tabs(for: context).compactMap { ($0 as? ExtensionTab)?.id }

        // Crossing this line would leak one space's browsing into another's
        // cookie jar, which is the whole thing spaces exist to prevent.
        #expect(visible.contains(workTab))
        #expect(!visible.contains(personalTab))
    }

    @Test("an ephemeral space is reported to extensions as a private window")
    func ephemeralSpacesAreReportedPrivate() async throws {
        let m = newModel()
        let fixture = try ExtensionFixture()
        let context = try await loadedContext(m, fixture)
        let window = ExtensionWindow(id: m.snapshot.keyWindow, model: m)

        #expect(!window.isPrivate(for: context))

        m.setProfile(m.snapshot.activeSpace, SpaceProfile(userAgent: nil, ephemeral: true))

        #expect(
            window.isPrivate(for: context),
            "an extension must know not to persist anything from this space"
        )
    }
}

/// Consent: nothing runs on anything nobody approved.
///
/// Deliberately lopsided. There is one test here for the case where a
/// permission is granted and eight for the cases where it must not be,
/// because a consent dialog is only worth having if refusing works.
@MainActor
struct ExtensionConsentTests {
    /// A model backed by a real file, so a decision can be made in one launch
    /// and read in the next.
    private func persistentModel(at path: String) -> BrowserModel {
        BrowserModel(storagePath: path)
    }

    private func temporaryDatabase() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("zer0-consent-\(UUID().uuidString).sqlite")
            .path
    }

    @Test("nothing is granted when nothing was approved")
    func refusingEverythingGrantsNothing() async throws {
        let m = newModel()
        let host = try #require(m.extensions)
        let fixture = try ExtensionFixture(
            permissions: ["storage", "tabs"],
            hostPermissions: ["<all_urls>"]
        )

        let context = try await host.load(fixture.installed, granting: fixture.nothing)

        #expect(!context.hasPermission(WKWebExtension.Permission("tabs")))
        #expect(!context.hasPermission(WKWebExtension.Permission("storage")))
        let url = try #require(URL(string: "https://avelino.run/"))
        #expect(!context.hasAccess(to: url), "a refused site is a site it cannot reach")
    }

    @Test("a refused permission is explicitly denied, not merely left unmentioned")
    func refusalIsExplicit() async throws {
        let m = newModel()
        let host = try #require(m.extensions)
        let fixture = try ExtensionFixture(permissions: ["storage", "tabs"])
        var decision = fixture.everything
        decision = consentDecisionSetting(
            decision: decision,
            kind: .api,
            key: "tabs",
            granted: false
        )

        let context = try await host.load(fixture.installed, granting: decision)

        // "Unknown" is a status WebKit may resolve in the extension's favour
        // when it asks again. A refusal has to be a refusal.
        #expect(context.permissionStatus(for: WKWebExtension.Permission("tabs")) == .deniedExplicitly)
        #expect(context.hasPermission(WKWebExtension.Permission("storage")))
    }

    @Test("a partly approved extension runs holding only what was approved")
    func partialGrantsRunWithWhatTheyHold() async throws {
        let m = newModel()
        let host = try #require(m.extensions)
        let fixture = try ExtensionFixture(
            permissions: ["storage", "tabs"],
            hostPermissions: ["https://avelino.run/*", "https://example.com/*"]
        )
        var decision = fixture.everything
        decision = consentDecisionSetting(
            decision: decision,
            kind: .site,
            key: "https://example.com/*",
            granted: false
        )

        let context = try await host.load(fixture.installed, granting: decision)

        #expect(host.loadedIds.contains(fixture.installed.id), "refusing one is not refusing it all")
        #expect(context.hasAccess(to: try #require(URL(string: "https://avelino.run/"))))
        #expect(!context.hasAccess(to: try #require(URL(string: "https://example.com/"))))
    }

    @Test("revoking reaches the context and not just the row")
    func revokingReachesTheContext() async throws {
        let m = newModel()
        let host = try #require(m.extensions)
        let fixture = try ExtensionFixture(permissions: ["tabs"], hostPermissions: ["<all_urls>"])
        let context = try await host.load(fixture.installed, granting: fixture.everything)
        #expect(context.hasPermission(WKWebExtension.Permission("tabs")))

        var revoked = fixture.everything
        revoked = consentDecisionSetting(decision: revoked, kind: .api, key: "tabs", granted: false)
        revoked = consentDecisionSetting(
            decision: revoked,
            kind: .site,
            key: "<all_urls>",
            granted: false
        )
        _ = host.updateConsent(revoked)

        #expect(!context.hasPermission(WKWebExtension.Permission("tabs")))
        #expect(!context.hasAccess(to: try #require(URL(string: "https://avelino.run/"))))
    }

    @Test("a permission given back reaches the context too")
    func grantingBackReachesTheContext() async throws {
        let m = newModel()
        let host = try #require(m.extensions)
        let fixture = try ExtensionFixture(permissions: ["tabs"])
        let context = try await host.load(fixture.installed, granting: fixture.nothing)
        #expect(!context.hasPermission(WKWebExtension.Permission("tabs")))

        _ = host.updateConsent(fixture.everything)

        #expect(context.hasPermission(WKWebExtension.Permission("tabs")))
    }

    @Test("updating an extension that is not loaded says so instead of pretending")
    func updatingSomethingUnloadedReportsNothing() throws {
        let m = newModel()
        let host = try #require(m.extensions)
        let fixture = try ExtensionFixture()

        #expect(host.updateConsent(fixture.everything) == nil)
    }

    @Test("a pattern nobody could parse is never granted and is reported back")
    func unreadablePatternsAreReportedNotGranted() async throws {
        let m = newModel()
        let host = try #require(m.extensions)
        let fixture = try ExtensionFixture(hostPermissions: ["https://avelino.run/*"])

        // The core reads patterns itself; this is the case where it accepted
        // one the engine will not. Showing it as approved afterwards is the
        // exact lie the dialog exists to prevent.
        var decision = fixture.everything
        decision.grantedHosts.append("nonsense-that-webkit-will-refuse")
        let context = try await host.load(fixture.installed, granting: decision)

        let refused = host.apply(decision, to: context)
        #expect(refused == ["nonsense-that-webkit-will-refuse"])
    }

    @Test("an extension nobody was asked about does not run")
    func undecidedExtensionsDoNotRun() async throws {
        let m = newModel()
        let host = try #require(m.extensions)
        let fixture = try ExtensionFixture()

        // No decision recorded anywhere. `loadInstalledExtensions` walks the
        // same path at launch, which is what anything installed before this
        // browser started asking hits.
        #expect(m.consent(for: fixture.installed.id) == nil)
        #expect(!host.loadedIds.contains(fixture.installed.id))
    }

    @Test("a refusal survives a relaunch")
    func refusalsSurviveARelaunch() async throws {
        let path = temporaryDatabase()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let fixture = try ExtensionFixture(
            permissions: ["storage", "tabs"],
            hostPermissions: ["<all_urls>"]
        )

        let first = persistentModel(at: path)
        var decision = first.consentRequest(for: fixture.installed).requests.reduce(
            defaultConsentDecision(
                request: first.consentRequest(for: fixture.installed),
                decidedAtMs: 1_000
            )
        ) { partial, request in
            request.key == "storage"
                ? partial
                : consentDecisionSetting(
                    decision: partial,
                    kind: request.kind,
                    key: request.key,
                    granted: false
                )
        }
        decision.extensionId = fixture.installed.id
        await first.applyConsent(decision)
        first.saveNow(reason: .quitting)

        let second = persistentModel(at: path)
        let restored = try #require(second.consent(for: fixture.installed.id))

        // If a refusal evaporated on quit, the next launch would read it as
        // never asked and hand it back — which teaches people that reading the
        // dialog is a waste of time.
        #expect(!consentDecisionGrants(decision: restored, kind: .site, key: "<all_urls>"))
        #expect(!consentDecisionGrants(decision: restored, kind: .api, key: "tabs"))
        #expect(consentDecisionGrants(decision: restored, kind: .api, key: "storage"))
    }

    @Test("granting nothing is recorded, so nobody is asked twice")
    func grantingNothingIsStillADecision() async throws {
        let path = temporaryDatabase()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let fixture = try ExtensionFixture()

        let first = persistentModel(at: path)
        var nothing = fixture.nothing
        nothing.extensionId = fixture.installed.id
        await first.applyConsent(nothing)
        first.saveNow(reason: .quitting)

        let second = persistentModel(at: path)
        let restored = try #require(second.consent(for: fixture.installed.id))

        #expect(consentDecisionGrantsNothing(decision: restored))
    }
}

/// The consent sheet's scroll affordance: what it claims is out of view.
///
/// Appearance is not usually tested, but this is not appearance. The sheet caps
/// at 620pt and an ordinary manifest overruns it; whether the fade and the
/// chevron appear is the difference between a person seeing seven permissions
/// and a person seeing four and a half under a footer that says seven.
struct ExtensionConsentScrollTests {
    typealias Edges = ExtensionConsentSheet.ScrollEdges

    @Test("a list that fits claims nothing is out of view")
    func aShortListSaysNothingIsHidden() {
        let edges = Edges(offset: 0, visible: 620, total: 400)

        #expect(!edges.above)
        // A fade over a list that ends on screen is the sheet inventing a
        // permission that is not there.
        #expect(!edges.below)
    }

    @Test("a list taller than the sheet says so before anyone scrolls")
    func atRestALongListSaysThereIsMore() {
        let edges = Edges(offset: 0, visible: 620, total: 900)

        #expect(!edges.above)
        #expect(edges.below)
    }

    @Test("scrolled to the end, nothing below is claimed")
    func atTheEndTheClaimIsWithdrawn() {
        let edges = Edges(offset: 280, visible: 620, total: 900)

        #expect(edges.above)
        // The chevron has to go: a marker pointing at nothing is the same lie
        // as no marker over something.
        #expect(!edges.below)
    }

    @Test("a fractional resting offset is not read as scrolled")
    func aRoundingErrorIsNotAScrollPosition() {
        let edges = Edges(offset: 0.25, visible: 620, total: 900.3)

        #expect(!edges.above)
        #expect(edges.below)
    }
}

/// The row of extension buttons (ADR-0068).
///
/// What is on it, in what order, and whether that survives a quit are the
/// behaviours; where it is drawn is not tested here and is not meant to be.
///
/// Every test here goes through a **real profile directory**, because that is
/// the only place `installedExtensions` looks and the row is built from it. A
/// fixture unpacked somewhere else loads fine and is invisible to the row,
/// which is exactly the difference these are about.
@MainActor
struct ExtensionPinTests {
    /// A profile of its own per test, so two cannot fight over a database or
    /// see each other's extensions.
    private func profile() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zer0-pins-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func model(in profile: URL) -> BrowserModel {
        let m = BrowserModel(
            storagePath: profile.appendingPathComponent("session.sqlite").path
        )
        m.loadInstalledExtensions()
        return m
    }

    private func extensionsDirectory(in profile: URL) -> URL {
        let dir = profile.appendingPathComponent("extensions")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Consent, granted, so the extension is actually running — nothing gets a
    /// button until it does.
    private func run(_ fixture: ExtensionFixture, in model: BrowserModel) async {
        var decision = fixture.everything
        decision.extensionId = fixture.installed.id
        await model.applyConsent(decision)
    }

    /// The whole promise of pinning. A row rebuilt from nothing on every launch
    /// is the "consent that resets" failure ADR-0028 names, wearing a different
    /// hat.
    @Test("a hidden button is still hidden after a relaunch")
    func pinningSurvivesARelaunch() async throws {
        let profile = profile()
        defer { try? FileManager.default.removeItem(at: profile) }
        let fixture = try ExtensionFixture(in: extensionsDirectory(in: profile))

        let first = model(in: profile)
        await run(fixture, in: first)
        #expect(
            first.pinnedExtensions.contains { $0.id == fixture.installed.id },
            "an extension that runs and has a button arrives with somewhere to click it"
        )

        first.setExtensionPinned(fixture.installed.id, false)
        #expect(first.pinnedExtensions.isEmpty)
        first.saveNow(reason: .quitting)

        // The next launch adopts every running extension all over again, which
        // is where a refusal stored as an absence would quietly come undone.
        let second = model(in: profile)
        await run(fixture, in: second)

        #expect(!second.extensionIsPinned(fixture.installed.id))
        #expect(second.pinnedExtensions.isEmpty)
    }

    /// Plenty of extensions are a content script and a background page. A
    /// button drawn for one of those is a button that swallows the press, and
    /// the row must not have a gap where it would have been either — ⇧⌘2 counts
    /// through this same list.
    @Test("an extension with no action is not on the row and leaves no hole")
    func anExtensionWithNoActionIsNotOnTheRow() async throws {
        let profile = profile()
        defer { try? FileManager.default.removeItem(at: profile) }
        let dir = extensionsDirectory(in: profile)
        let withButton = try ExtensionFixture(id: String(repeating: "a", count: 32), in: dir)
        let without = try ExtensionFixture(
            id: String(repeating: "b", count: 32),
            hasAction: false,
            in: dir
        )

        let m = model(in: profile)
        await run(withButton, in: m)
        await run(without, in: m)

        #expect(m.installedExtensions.count == 2, "both are on disk and both run")
        #expect(m.pinnedExtensions.map(\.id) == [withButton.installed.id])
        #expect(!without.installed.manifest.hasAction)
        // Stopped one step earlier than the row, deliberately: something with
        // no button is never adopted in the first place, so the ledger carries
        // no decision about it at all. A row that only filtered at the last
        // moment would leave a record saying somebody had chosen to show a
        // button that cannot exist.
        #expect(!m.extensionIsPinned(without.installed.id))
    }

    /// An icon comes out of a package nobody vetted (ADR-0022), so every way it
    /// can fail has to end somewhere other than on screen. The button is still
    /// there, still pressable, still counted by the chords.
    @Test("an extension whose icon is unusable still gets a working button")
    func aMalformedIconDoesNotTakeTheRowDown() async throws {
        let profile = profile()
        defer { try? FileManager.default.removeItem(at: profile) }
        let fixture = try ExtensionFixture(in: extensionsDirectory(in: profile))

        // The manifest declares an action and names no icon at all, which
        // leaves `iconForSize:` with nothing to hand back — the same hole a
        // corrupt PNG leaves, reached without having to write a corrupt PNG.
        let m = model(in: profile)
        await run(fixture, in: m)

        #expect(m.pinnedExtensions.map(\.id) == [fixture.installed.id])

        let host = try #require(m.extensions)
        let action = try #require(
            host.action(for: fixture.installed.id, tab: m.snapshot.activeTab),
            "the action exists even when its picture does not"
        )
        #expect(
            action.icon(for: CGSize(width: 18, height: 18)) == nil
                || action.icon(for: CGSize(width: 18, height: 18))?.size.width ?? 0 > 0,
            "an icon is either absent or has a size — never a zero-sized image"
        )

        // Pressing it is not allowed to throw, and not allowed to take the row
        // down with it.
        host.performAction(for: fixture.installed.id, tab: m.snapshot.activeTab)
        #expect(m.pinnedExtensions.map(\.id) == [fixture.installed.id])
    }

    /// An action's icon, title and badge are per-tab and change as you browse.
    /// The button asks about the tab in front, so switching tabs asks a
    /// different question — a button that answered for the tab it was built on
    /// would be making a claim about the wrong page.
    @Test("the button reads the tab in front, not the tab it was built on")
    func perTabStateFollowsTheTab() async throws {
        let profile = profile()
        defer { try? FileManager.default.removeItem(at: profile) }
        let fixture = try ExtensionFixture(in: extensionsDirectory(in: profile))

        let m = model(in: profile)
        await run(fixture, in: m)
        let host = try #require(m.extensions)

        m.send(.openTab(space: nil, url: "https://example.com", parent: nil))
        let first = try #require(m.snapshot.activeTab)
        let onFirst = try #require(host.action(for: fixture.installed.id, tab: first))

        m.send(.openTab(space: nil, url: "https://example.org", parent: nil))
        let second = try #require(m.snapshot.activeTab)
        #expect(second != first)
        let onSecond = try #require(host.action(for: fixture.installed.id, tab: second))

        // Two tabs, two actions. One object answering for both would be the
        // cache ADR-0020 spends a paragraph refusing, and every per-tab badge
        // in the browser would be whichever tab asked last.
        #expect(onFirst !== onSecond)
        #expect(onFirst.associatedTab != nil)
        #expect(onSecond.associatedTab != nil)

        // Asking with no tab is the default action, which is a third thing
        // again rather than an alias for whichever tab is in front.
        let defaultAction = try #require(host.action(for: fixture.installed.id, tab: nil))
        #expect(defaultAction.associatedTab == nil)
    }
}

/// What an extension's own popup can say, and who it is said to be (ADR-0098).
///
/// **These drive the popup WebKit built, not one of ours.**
/// `WKWebExtensionAction.popupPopover` wraps a private
/// `_WKWebExtensionActionWebView` carrying a private
/// `_WKWebExtensionActionWebViewDelegate`, so a test that instantiated a
/// `WKWebView` here would prove nothing about the object that was broken.
/// Measured on that real view before any of this existed: `alert()` returned
/// having drawn nothing, `confirm()` returned **false**, `prompt()` returned
/// **null**.
///
/// **One test, four claims, and that is a measurement rather than laziness.**
/// Releasing a `BrowserModel` that has a live extension popup and then building
/// a second one takes the process down inside WebKit — reproducible on order,
/// `EXC_BREAKPOINT` in `WebProcessPool::~WebProcessPool` →
/// `IPC::MessageReceiverMap::invalidate()`, with nothing of ours on the stack
/// and no output at all. Split into four tests this file was a suite that
/// crashed the run; as one model driven four ways it is stable. Each claim
/// still fails on its own line with its own sentence, which is what a lock has
/// to do.
///
/// **Serialized on purpose**, for `PageDialogTests`' reason: several models,
/// extension loads and windows on the main actor at once starve the debounce
/// `SessionPersistenceTests` waits on, and the failure lands there.
@MainActor
@Suite(.serialized)
struct ExtensionPopupDialogTests {
    /// Everything this test built, held until the process ends. See the comment
    /// where it is appended.
    nonisolated(unsafe) static var kept: [(BrowserModel, ExtensionFixture)] = []

    /// Read a value out of a page, and give up rather than hang.
    ///
    /// `evaluateJavaScript` is queued behind whatever the script thread is
    /// doing, and these three calls **block that thread until they are
    /// answered** — so an unanswered one turns a read into a wait with no end.
    /// A `nil` here is a readable failure; the alternative is a suite that
    /// never finishes and says nothing about why.
    private func readBack(
        _ view: WKWebView,
        _ script: String,
        within: Duration = .seconds(10)
    ) async -> String? {
        // The read runs in a task of its own and parks its answer here, so what
        // this function waits on is a **synchronous** fact. `eventually`'s
        // deadline is between polls: give it a condition whose own `await`
        // hangs and it hangs with it, which is the failure this exists to turn
        // into a readable one.
        final class Answer { var read: String??; init() {} }
        let answer = Answer()
        Task { @MainActor in
            answer.read = .some(try? await view.evaluateJavaScript(script) as? String)
        }
        _ = await eventually(timeout: within) { answer.read != nil }
        return answer.read ?? nil
    }

    @Test("an extension's popup is answered, is named as an extension, and keeps the engine's own answers")
    func anExtensionPopupIsAnsweredAndNamed() async throws {
        let profile = FileManager.default.temporaryDirectory
            .appendingPathComponent("zer0-popup-dialogs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        // Not removed at the end: the model below outlives this test on purpose
        // and is still running an extension out of this directory. The name
        // carries a UUID, so nothing else can mean it.

        let extensions = profile.appendingPathComponent("extensions")
        try FileManager.default.createDirectory(at: extensions, withIntermediateDirectories: true)
        // **The name a package would choose to be mistaken for a site.** If an
        // extension's name ever reaches the panel where a host goes, this is
        // the string that makes it obvious.
        let fixture = try ExtensionFixture(
            name: "google.com",
            popup: "<html><body><script>window.said = 'nothing';</script></body></html>",
            in: extensions
        )
        let model = BrowserModel(
            storagePath: profile.appendingPathComponent("session.sqlite").path
        )
        // **Never released, and that is a measurement.** Letting a model that
        // has built an extension popup go takes the whole process down at the
        // next turn of the run loop — `EXC_BREAKPOINT` inside
        // `WebProcessPool::~WebProcessPool` → `IPC::MessageReceiverMap::invalidate()`,
        // with nothing of ours on the stack, no output, and 500 unrelated tests
        // lost. Established as this test's own by deleting it: the suite went
        // from a signal 5 to 602 green. It is WebKit tearing down a pool that
        // still has a receiver on it, it is not reachable from the browser —
        // which never destroys its extension controller — and one retained
        // object for the length of a test process is the cheap way round it.
        ExtensionPopupDialogTests.kept.append((model, fixture))
        model.loadInstalledExtensions()
        var decision = fixture.everything
        decision.extensionId = fixture.installed.id
        await model.applyConsent(decision)

        let host = try #require(model.extensions)
        let tab = try #require(model.snapshot.activeTab)
        let action = try #require(host.action(for: fixture.installed.id, tab: tab))
        #expect(action.presentsPopup)
        let view = try #require(action.popupWebView)

        // **In a window, and not as decoration.** A `WKWebView` with no window
        // hosts a document WebKit reports as hidden and does not drive; the
        // popup would never finish loading and every wait below would spend its
        // whole deadline. `PageDialogTests.talking` puts a page in one for the
        // same reason. In the browser this view is inside an `NSPopover`, which
        // has a window of its own.
        let window = testWindow(NSRect(x: 0, y: 0, width: 420, height: 320))
        defer { window.close() }
        let container = NSView(frame: window.contentLayoutRect)
        window.contentView = container
        view.frame = container.bounds
        container.addSubview(view)
        window.orderFront(nil)

        // Asked of the view rather than of the document: an
        // `evaluateJavaScript` against a page that never loads never returns,
        // and `eventually` cannot rescue that — its deadline is between polls.
        #expect(
            await eventually { !view.isLoading && view.url != nil },
            "the extension's popup never finished loading"
        )

        // MARK: the forwarding, which is what makes this an addition

        // `uiDelegate` is one property, and WebKit's own object answers three
        // things ours does not: the popup's file picker, a link in a popup
        // opening a tab, and `window.close()` closing the popover — which
        // Simplify Gmail's own popup calls. Replacing it outright takes all
        // three away and nothing on screen says so.
        let delegate = try #require(view.uiDelegate as? NSObject)
        #expect(delegate is ExtensionPopupDialogDelegate, """
            the popup's `uiDelegate` is not ours, so `alert()`, `confirm()` and `prompt()` are
            back to being answered by nobody (ADR-0098).
            """)
        // Read the way `WKWebView` reads them: it asks `respondsToSelector:`
        // once, when the delegate is assigned, and caches the answers. A
        // forwarding target the receiver does not admit to is a method WebKit
        // never calls.
        for selector in [
            "webView:runOpenPanelWithParameters:initiatedByFrame:completionHandler:",
            "webView:createWebViewWithConfiguration:forNavigationAction:windowFeatures:",
            "webViewDidClose:",
        ] {
            #expect(delegate.responds(to: NSSelectorFromString(selector)), """
                the popup's delegate no longer answers `\(selector)`.
                That one is WebKit's own and was measured to be implemented on the delegate it
                installs. Ours forwards everything it does not answer; without the forwarding a
                file control in a popup opens nothing, a link in one goes nowhere, and
                `window.close()` leaves the popover up (ADR-0098).
                """)
        }

        // Adopting again must not stack a delegate on a delegate: each round
        // would add another layer of forwarding, and the popup would grow a
        // chain as long as the number of times its button was drawn.
        _ = try #require(host.action(for: fixture.installed.id, tab: tab))
        #expect(view.uiDelegate === delegate, """
            a second pass over the same action replaced the popup's delegate.
            The web view is built once and reused, so adopting is idempotent or it is a chain
            (ADR-0098).
            """)

        // MARK: the question, and who it is said to come from

        // `setTimeout` so the `evaluateJavaScript` that starts it returns:
        // `confirm()` blocks the script until the panel is answered.
        _ = try? await view.evaluateJavaScript(
            "setTimeout(function () { window.said = 'confirm:' + String(confirm('delete this?')); }, 0); 'go'"
        )
        #expect(await eventually { !model.snapshot.pageDialogs.isEmpty })

        let dialog = try #require(model.snapshot.pageDialogs.first)
        #expect(dialog.kind == .confirm)
        #expect(dialog.message == "delete this?")
        #expect(dialog.speaker == .extension(name: "google.com", nameTruncated: false), """
            an extension popup was named as \(dialog.speaker).
            `PageDialogSpeaker.site` is a fact the browser derived from an address it fetched;
            a package's name is a string the package wrote about itself. Arriving as the first
            would put "google.com is asking" in the browser's own voice (ADR-0098).
            """)

        // Past the settle window. The core ignores an answer inside it — a page
        // picks the moment it interrupts, so the Return that lands first is the
        // one that was already on its way down (ADR-0056, ADR-0089) — and an
        // extension popup is on exactly the same seam.
        try? await Task.sleep(for: .milliseconds(Int(promptSettleMs()) + 200))
        model.answerPageDialog(dialog.request, .accepted, silence: false)

        // The handler was called, which is the fact the ledger holds. Waiting
        // on it first means the read below is of a script that has resumed.
        #expect(await eventually { model.engine.pageDialogs.outstandingCount == 0 })
        let said = await readBack(view, "window.said")
        #expect(said == "confirm:true", """
            an extension popup's `confirm()` did not carry the answer home.
            Unimplemented it evaluates to `false` — a Cancel nobody pressed, with nothing on
            screen saying so (ADR-0098). Got \(String(describing: said)).
            """)
    }
}
