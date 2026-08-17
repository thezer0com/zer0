import AppKit
import Foundation
import SwiftUI
import Testing
import WebKit
import Zer0Core

@testable import Zer0Shell

/// The engine is configured for a browser rather than for an embedded web view
/// (ADR-0074).
///
/// Two of these ask the page rather than the configuration, and that is the
/// point. A test that reads `preferences.isElementFullscreenEnabled` back out
/// of the object it was just written to proves that a setter works; it says
/// nothing about whether a page got anything. Both of the settings that were
/// actually broken — no Fullscreen API, and audible autoplay — are observable
/// from inside the page, so they are asked there.
///
/// One thing to know before adding to this file: **`evaluateJavaScript` carries
/// a user gesture.** Measured — a `requestFullscreen()` issued through it gets
/// past WebKit's activation check and fails on document visibility instead. So
/// anything about "may a page do this on its own" has to be started by the
/// page, in a `<script>` at load, and read back afterwards. Driving it from
/// the test would answer a different question and answer it green.
///
/// **Serialized on purpose.** Five of these at once put three `BrowserModel`s,
/// three page loads and a window on the main actor together, and that was
/// enough to starve the two-second debounce
/// `SessionPersistenceTests/aStructuralChangeIsWrittenWithoutWaitingForTheTimer`
/// waits fifteen seconds for — measured at 0 failures in 3 runs without this
/// file and 2 in 3 with it. The failure landed on *that* test, which is the
/// shape `scripts/check.sh` warns about for the screenshot harnesses: it reads
/// as flakiness in code that is correct. One at a time costs this suite a few
/// seconds and costs the run nothing, because it is not the long pole.
@MainActor
@Suite(.serialized)
struct EnginePolicyTests {
    /// In-memory only. A test must never touch the real session on disk.
    private func model() -> BrowserModel {
        BrowserModel(storagePath: nil)
    }

    /// A page on disk, with a UUID in the name because swift-testing runs
    /// these in parallel.
    private func makePage(body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zer0-engine-policy-\(UUID().uuidString)")
            .appendingPathExtension("html")
        try "<html><head><title>policy</title></head><body>\(body)</body></html>"
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Half a second of silence as a `data:` URI, so the media in the autoplay
    /// test is real without a fixture on disk or a byte off the network.
    private var silentWav: String {
        let rate = 8000
        let samples = rate / 2
        var data = Data()
        func le32(_ value: Int) {
            var little = UInt32(value).littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        func le16(_ value: Int) {
            var little = UInt16(value).littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        le32(36 + samples * 2)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        le32(16)
        le16(1)
        le16(1)
        le32(rate)
        le32(rate * 2)
        le16(2)
        le16(16)
        data.append(contentsOf: Array("data".utf8))
        le32(samples * 2)
        data.append(Data(count: samples * 2))
        return "data:audio/wav;base64,\(data.base64EncodedString())"
    }

    /// Load a page through the core and wait for the engine to say it is done.
    private func load(_ page: URL, in m: BrowserModel) async throws -> WKWebView {
        let tab = try #require(m.snapshot.activeTab)
        m.send(.navigateTo(tab: tab, input: page.absoluteString))
        #expect(await eventually { m.activeTab?.loadingComplete == true })
        return try #require(m.engine.webView(for: tab))
    }

    /// **This is the one that was broken.** `elementFullscreenEnabled` defaults
    /// to `NO`, and `NO` does not mean "refuses politely" — measured, it means
    /// `Element.prototype.requestFullscreen` is `undefined` and
    /// `document.fullscreenEnabled` is not there at all. A video player feature
    /// detects that and hides its own fullscreen button, so the symptom is a
    /// missing control rather than a broken one and nobody reports it.
    ///
    /// Asked of the page, because the page is the only place the difference
    /// shows.
    @Test("a page gets the Fullscreen API")
    func aPageGetsTheFullscreenApi() async throws {
        let m = model()
        let webView = try await load(makePage(body: "<div id=box></div>"), in: m)

        let kind = try await webView
            .evaluateJavaScript("typeof document.getElementById('box').requestFullscreen") as? String
        #expect(kind == "function", """
            the page has no Fullscreen API. `WKPreferences.elementFullscreenEnabled` defaults to
            NO — the embedded-web-view answer — and with it off the method is not merely refused,
            it is absent, so every player's fullscreen button disappears rather than failing
            (ADR-0074). Set it in EnginePolicy, before the view is built.
            """)

        let enabled = try await webView.evaluateJavaScript("document.fullscreenEnabled") as? Bool
        #expect(enabled == true)
    }

    /// Autoplay, asked the only way it can honestly be asked: the page starts
    /// the media itself, at load, with nobody having touched anything.
    ///
    /// **What this does not catch, established by breaking it.** Swinging to
    /// `.all` leaves this test green: measured, muted *audio* plays under
    /// `.all` too, because the only thing `.all` adds is blocking silent
    /// **video**, and a `<video>` with a real source is not something this file
    /// can produce without a fixture or a byte off the network. The `.all`
    /// direction is caught by the value assertions instead — in
    /// `everyPageIsBuiltForABrowserRatherThanForAnEmbeddedView` and in
    /// `turningAPageSettingOffReachesTheEngine`, both of which name `.audio`
    /// exactly. Saying so here rather than leaving the gap for somebody to
    /// find at the wrong moment.
    @Test("audible media waits for a person and muted media does not")
    func audibleMediaWaitsForAPersonAndMutedMediaDoesNot() async throws {
        let m = model()
        let page = try makePage(body: """
        <audio id="loud" src="\(silentWav)"></audio>
        <audio id="quiet" src="\(silentWav)" muted></audio>
        <script>
          window.outcome = { loud: 'pending', quiet: 'pending' };
          function attempt(name, element) {
            var playing = element.play();
            if (!playing || !playing.then) { window.outcome[name] = 'no promise'; return; }
            playing.then(function () { window.outcome[name] = 'played'; },
                         function (e) { window.outcome[name] = 'blocked'; });
          }
          attempt('loud', document.getElementById('loud'));
          attempt('quiet', document.getElementById('quiet'));
        </script>
        """)
        let webView = try await load(page, in: m)

        // **The view has to be in a window, and that is load-bearing.** A
        // `WKWebView` with no window hosts a document WebKit reports as hidden,
        // and a muted element's `play()` promise there never resolves at all —
        // so the muted half of this test read "pending" forever and said
        // nothing about the setting. `WebInspectorTests` needs a window for a
        // different reason and this is the same fix.
        let window = testWindow(NSRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = NSHostingView(rootView: WebViewContainer(webView: webView))
        window.orderFront(nil)
        defer { window.close() }

        func outcome(_ name: String) async -> String? {
            try? await webView.evaluateJavaScript("window.outcome.\(name)") as? String
        }

        // Both settle from `pending` to a word the page wrote down, and that
        // word stays true however late anybody reads it. So there is nothing
        // to race — only a hang to turn into a readable failure, which is what
        // `eventually` is for. This was a hand-rolled twenty second deadline,
        // on the grounds that `eventually` could not await the page; it can
        // now, and twenty seconds was under the load this suite measures.
        _ = await eventually {
            // Two `await`s and not one expression: `&&` takes its right side as
            // an autoclosure, which cannot be `async`, so the short-circuit
            // spelling does not compile.
            let loud = await outcome("loud")
            let quiet = await outcome("quiet")
            return loud != "pending" && quiet != "pending"
        }
        let loud = await outcome("loud")
        let quiet = await outcome("quiet")

        #expect(loud == "blocked", """
            a page started playing audible media with nobody having touched anything.
            `mediaTypesRequiringUserActionForPlayback` defaults to none, which is the
            embedded-web-view answer; a browser that does this is one people learn to distrust
            within a day. EnginePolicy sets `.audio` (ADR-0074).
            """)
        #expect(quiet == "played", """
            muted media was blocked too. That is `.all`, not `.audio`, and it breaks every muted
            autoplaying video on the web — which is the majority of video on the web. The gate is
            on sound, not on media (ADR-0074).
            """)
    }

    /// Everything else on the sheet, read off a web view the model really
    /// built.
    ///
    /// These are property assertions and they are the weaker kind of lock,
    /// deliberately: the alternatives are a 20-second wait for a suspended
    /// timer and a network round trip for the HTTPS upgrade. The pop-up line
    /// used to be on that list because nothing in this shell could open a
    /// window; `PopupTests` asks it of a real page now (ADR-0075), and this is
    /// the value assertion beside it. What this does cover is the failure
    /// that actually happens — somebody tidies a line out of `EnginePolicy`,
    /// or adds a second place that builds a configuration and forgets the
    /// call.
    @Test("every page is built for a browser rather than for an embedded view")
    func everyPageIsBuiltForABrowserRatherThanForAnEmbeddedView() throws {
        let m = model()
        let tab = try #require(m.snapshot.activeTab)
        let webView = try #require(m.engine.webView(for: tab))
        let config = webView.configuration
        let preferences = config.preferences

        #expect(preferences.inactiveSchedulingPolicy == .throttle, """
            a tab that is not the front one is suspended rather than throttled. `zer0` shows one
            tab at a time, so this is every background tab: measured, a suspended page ran its
            100ms interval four times in twenty seconds and only ticked again when something
            touched it — a chat tab with no new messages until you click it (ADR-0074).
            """)

        #expect(!preferences.javaScriptCanOpenWindowsAutomatically, """
            a page may open a window with nobody having touched anything. This is the pop-up
            blocker, and WebKit's macOS default is the embedded-view answer (ADR-0074).
            """)

        // `.audio` exactly, not merely "something non-empty". This is the
        // assertion that catches `.all`, which the behavioural test above
        // cannot: muted audio plays under `.all` as well, and the only thing
        // `.all` adds is blocking silent video.
        #expect(config.mediaTypesRequiringUserActionForPlayback == .audio, """
            autoplay is gated on something other than `.audio`. `[]` lets any page start making
            sound on its own; `.all` blocks silent video, which is the muted hero video on a
            large share of the web. `.audio` is the only reading of "block autoplay" that
            matches what Safari and Chrome do (ADR-0074).
            """)

        #expect(preferences.isFraudulentWebsiteWarningEnabled)
        #expect(preferences.isSiteSpecificQuirksModeEnabled)
        #expect(config.upgradeKnownHostsToHTTPS)
        #expect(config.allowsAirPlayForMediaPlayback)
        #expect(config.allowsInlinePredictions)
        #expect(config.supportsAdaptiveImageGlyph)
        #expect(config.writingToolsBehavior == .complete)

        #expect(
            config.defaultWebpagePreferences.preferredHTTPSNavigationPolicy
                == .automaticFallbackToHTTP,
            """
            a typed http:// address is not upgraded. Measured on this SDK:
            `.automaticFallbackToHTTP` takes `http://info.cern.ch` to https and still loads
            `http://httpforever.com`, which has no https at all, over http (ADR-0074).
            """
        )

        // Not set, and each one is a decision. `suppressesIncrementalRendering`
        // is a blank window until the last byte lands;
        // `limitsNavigationsToAppBoundDomains` confines a browser to a list in
        // a plist; `textInteractionEnabled` off is a page whose text cannot be
        // selected. All three default the right way, and this is what notices
        // if a default moves.
        #expect(!config.suppressesIncrementalRendering)
        #expect(!config.limitsNavigationsToAppBoundDomains)
        #expect(preferences.isTextInteractionEnabled)
        #expect(preferences.minimumFontSize == 0)
    }

    /// The Settings switch reaches the engine.
    ///
    /// This is the half of ADR-0074 that is a promise to a person rather than a
    /// value in a struct, and the failure it exists for has happened in this
    /// repository before: a preference written to disk and applied to nothing.
    ///
    /// It reaches a view built afterwards and no view already open, and that is
    /// the honest shape rather than a shortfall.
    /// `mediaTypesRequiringUserActionForPlayback` lives on the configuration,
    /// and `WKWebView.configuration` is a **copy** — measured, a write to it
    /// after the view exists is dropped and the property keeps its old value.
    /// The Settings row promises exactly this and no more.
    @Test("turning a page setting off reaches the engine")
    func turningAPageSettingOffReachesTheEngine() throws {
        let m = model()
        let first = try #require(m.snapshot.activeTab)
        let opened = try #require(m.engine.webView(for: first))

        #expect(m.preferences.blockAudibleAutoplay, "ships on")
        #expect(opened.configuration.mediaTypesRequiringUserActionForPlayback == .audio)

        m.updatePreferences { $0.blockAudibleAutoplay = false }

        m.send(.openTab(space: nil, url: nil, parent: nil))
        let second = try #require(m.snapshot.activeTab)
        let fresh = try #require(m.engine.webView(for: second))
        #expect(fresh.configuration.mediaTypesRequiringUserActionForPlayback == [], """
            a tab opened after the setting changed still blocks autoplay, so the switch does
            nothing at all. The choice has to reach `HostedWebView.init`, which is where the
            configuration is built and the only moment this property can be set — and
            `applyEnginePolicy` has to run on the one door every preference goes through
            (ADR-0074).
            """)

        // And the tab that was already open kept what it was born with, which
        // is the sentence the Settings row makes. Asserted rather than assumed:
        // if this ever starts changing, the copy is the thing that became a lie.
        #expect(opened.configuration.mediaTypesRequiringUserActionForPlayback == .audio)
    }

    /// The other half of the sheet: behaviour the core decides, not a person.
    ///
    /// Background throttling and HTTPS-first were constants here until
    /// ADR-0120, which is the regression this exists to catch — a shell that
    /// spells them itself again stays green on every value assertion above,
    /// because the defaults agree. Only a core that says "off" and a view born
    /// afterwards can tell a derived value from a hardcoded one.
    ///
    /// Born afterwards, like the autoplay switch above and for the same
    /// measured reason: the scheduling policy is readable off a live view's
    /// `WKPreferences` but only ever written at birth, and the HTTPS policy
    /// lives on the configuration, which is a copy.
    @Test("engine behaviour the core decides reaches views born after it")
    func engineBehaviourTheCoreDecidesReachesViewsBornAfterIt() throws {
        let m = model()

        #expect(m.preferences.backgroundThrottling, "ships on")
        #expect(m.preferences.httpsFirst, "ships on")

        m.updatePreferences {
            $0.backgroundThrottling = false
            $0.httpsFirst = false
        }

        m.send(.openTab(space: nil, url: nil, parent: nil))
        let tab = try #require(m.snapshot.activeTab)
        let fresh = try #require(m.engine.webView(for: tab))

        #expect(fresh.configuration.preferences.inactiveSchedulingPolicy == .none, """
            a tab born after the core stopped throttling is still throttled. The core owns this
            answer (ADR-0120); if it stopped reaching the view, `applyEnginePolicy` is spelling a
            constant the core already decided.
            """)

        #expect(
            fresh.configuration.defaultWebpagePreferences.preferredHTTPSNavigationPolicy
                == .keepAsRequested,
            """
            a tab born after the core turned HTTPS-first off still upgrades typed http addresses.
            The core owns navigation policy (ADR-0120); the silent fallback is part of the
            semantics, and `.keepAsRequested` — not the mediated interstitial — is what "off"
            means.
            """
        )
    }

    /// One door.
    ///
    /// The sheet above is only true of pages built through `HostedWebView`. A
    /// second place that says `WKWebViewConfiguration()` would make a page with
    /// none of it, and every test in this file would stay green, because they
    /// all ask the model for the tab it made. So the door is counted rather
    /// than trusted.
    @Test("the engine policy is applied where the only configuration is built")
    func theEnginePolicyIsAppliedWhereTheOnlyConfigurationIsBuilt() throws {
        var builders: [String] = []
        var appliers: [String] = []

        for source in try SourceScan.shellSources() {
            if !SourceScan.occurrences(of: "WKWebViewConfiguration()", in: source.code).isEmpty {
                builders.append(source.name)
            }
            if !SourceScan.occurrences(of: "EnginePolicy.apply", in: source.code).isEmpty {
                appliers.append(source.name)
            }
        }

        #expect(builders == ["EngineHost.swift"], """
            a `WKWebViewConfiguration` is built somewhere other than EngineHost.swift: \(builders).
            A rule enforced at N call sites has N−1 bugs waiting, and the missing one here is a
            page with no Fullscreen API and unrestricted autoplay. Build it at the one door, or
            move the door (ADR-0074).
            """)
        #expect(appliers == ["EngineHost.swift"], """
            EngineHost.swift no longer calls `EnginePolicy.apply`, so every page is back on
            WKWebView's embedded-view defaults while every property assertion in this file still
            reads whatever the last caller left behind (ADR-0074). Found in: \(appliers).
            """)
    }
}
