import AppKit
import SwiftUI
import Testing
import WebKit
import Zer0Core

@testable import Zer0Shell

/// The strip, drawn over the page it took its colour from.
///
/// **Opt-in.** `ZER0_SHOT=1 swift test --filter ZZChromeTintShots`. A harness
/// pumps the run loop for tens of seconds and starves the timing tests when it
/// runs by default, so `scripts/check.sh` verifies every case here carries the
/// gate.
///
/// Nothing here is faked. Each board loads real HTML into the real `WKWebView`
/// the browser builds for a tab, lets the real navigation delegate report what
/// the page said, puts that through the real core, and renders the real
/// `WindowChrome` above the real rendered page. The seam between the strip and
/// the page is the whole subject, so a mock of either half would be a picture of
/// the wrong thing.
///
/// `NSHostingView` + `cacheDisplay` rather than `ImageRenderer`, because
/// `ImageRenderer` does not draw materials — and the untinted strip is one.
@Suite("ZZ chrome tint shots")
struct ZZChromeTintShots {
    private static let output = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "design/chrome-tint")

    private static let size = CGSize(width: 900, height: 420)

    @Test(
        "render the strip over the page it borrowed from",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    @MainActor
    func renderTheStripOverThePage() async throws {
        try FileManager.default.createDirectory(
            at: Self.output, withIntermediateDirectories: true
        )

        // Everything each board built is kept alive until the whole run is
        // over. A `BrowserModel` torn down while its web view is still in a
        // view hierarchy takes the process with it, and a harness that crashes
        // on board two is a harness nobody runs.
        var alive: [Any] = []
        for dark in [false, true] {
            for page in Fixture.all {
                alive.append(try await shoot(page, dark: dark))
            }
        }
        withExtendedLifetime(alive) {}
    }

    /// Navigating from one site to another must cross-fade, not cut.
    ///
    /// Pixels rather than an assertion about the source, because
    /// `.motion(.subtle, value:)` being *written* is not the same as a `Color`
    /// in a `.background` actually interpolating — that is SwiftUI's business,
    /// and the only honest way to know is to read the frames. The curve is
    /// slowed so a run loop sampled at video rate cannot miss it.
    @Test(
        "the colour crosses from one page to the next rather than cutting",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    @MainActor
    func theColourCrossFades() throws {
        let model = BrowserModel(storagePath: nil)
        model.sidebarVisible = false
        let tab = try #require(model.snapshot.activeTab)

        func declare(_ colour: String) {
            model.send(.colorsDeclared(
                tab: tab,
                themeColors: [DeclaredColor(value: colour, matchesAppearance: true)],
                elementBackgrounds: [],
                canvasBackground: nil
            ))
        }

        declare("#ffffff")

        let strip = Shot(size: CGSize(width: 600, height: WindowChrome.height)) {
            WindowChrome()
                .environment(model)
                .zer0Palette()
                // Twelvefold, so a curve lasting a fifth of a second produces
                // enough distinct frames to count. Stated here rather than
                // borrowed, so the shell's own curve is what is measured —
                // taking longer.
                .transaction { $0.animation = $0.animation?.speed(1.0 / 12) }
        }
        strip.settle()

        // Somewhere with nothing drawn on it, so what is sampled is the surface
        // and not a glyph.
        func surface() -> NSColor { strip.frame().colour(x: 480, y: 18) }

        let before = surface()
        declare("#0d0d12")

        var seen: [NSColor] = []
        for _ in 0..<40 {
            strip.advance(0.05)
            let sample = surface()
            if seen.last.map({ !$0.isNear(sample, tolerance: 0.01) }) ?? true {
                seen.append(sample)
            }
        }

        print("strip, \(seen.count) distinct colours from white to near-black")
        #expect(
            seen.count >= 3,
            "the strip went from white to near-black in \(seen.count) step(s), so it cut"
        )
        #expect(!before.isNear(seen.last ?? before, tolerance: 0.05), "it has to end up dark")
    }

    /// Load a page for real, then draw the window over it.
    @MainActor
    private func shoot(_ fixture: Fixture, dark: Bool) async throws -> Any {
        let model = BrowserModel(storagePath: nil)
        // The strip only exists when the sidebar is away, which is the whole
        // situation this is about.
        model.sidebarVisible = false

        guard let tab = model.snapshot.activeTab,
              let webView = model.engine.webView(for: tab)
        else {
            Issue.record("no web view for \(fixture.name)")
            return model
        }
        webView.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

        let root = VStack(spacing: 0) {
            WindowChrome()
            WebViewContainer(webView: webView)
        }
        .environment(model)
        .environment(\.controlActiveState, .key)
        .zer0Palette()
        .frame(width: Self.size.width, height: Self.size.height)
        .preferredColorScheme(dark ? .dark : .light)

        let host = NSHostingView(rootView: AnyView(root))
        host.frame = CGRect(origin: .zero, size: Self.size)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

        let window = testWindow(host.frame, styleMask: [.borderless])
        window.appearance = host.appearance
        window.contentView = host
        // Off every real display. A locked or headless Mac shows nothing; the
        // window exists so WebKit has somewhere to draw.
        window.setFrameOrigin(CGPoint(x: -10000, y: -10000))
        window.orderFrontRegardless()

        fixture.load(into: webView)

        // Awaited rather than run-looped. WebKit delivers its delegate calls on
        // the main actor, and a synchronous `RunLoop.run` from inside a
        // main-actor function holds that actor for the whole wait — the page
        // loads and not one callback ever arrives. Yielding is what lets the
        // browser be a browser.
        if fixture.loadsSomething {
            _ = await eventually(timeout: .seconds(fixture.isRemote ? 20 : 10)) {
                model.snapshot.tabs.first { $0.id == tab }?.tint != nil
            }
        }
        // A moment more, so the colour's cross-fade has finished rather than
        // being caught halfway, and so WebKit has painted.
        try? await Task.sleep(for: .milliseconds(600))

        let tint = model.snapshot.tabs.first { $0.id == tab }?.tint
        print(
            "\(fixture.name) (\(dark ? "dark" : "light")): "
                + (tint.map { String(format: "#%06x, dark ink: \($0.prefersDarkInk)", $0.rgb) }
                    ?? "no colour")
        )

        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            Issue.record("no bitmap rep for \(fixture.name)")
            return model
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            Issue.record("no png for \(fixture.name)")
            return model
        }
        try png.write(
            to: Self.output.appending(path: "\(fixture.name)-\(dark ? "dark" : "light").png")
        )
        window.orderOut(nil)
        return (model, window)
    }
}

// MARK: - The pages

extension ZZChromeTintShots {
    /// A page to point the browser at, and what it is meant to prove.
    struct Fixture {
        let name: String
        let html: String?
        /// Set for the one board that goes out to the network, which may not be
        /// there. It is allowed to come back with nothing; the others are not.
        var remote: URL?

        var isRemote: Bool { remote != nil }
        var loadsSomething: Bool { remote != nil || html != nil }

        @MainActor
        func load(into webView: WKWebView) {
            if let remote {
                webView.load(URLRequest(url: remote))
            } else if let html {
                webView.loadHTMLString(html, baseURL: URL(string: "https://example.test/"))
            }
        }

        static let all: [Fixture] = [
            nearBlack, plainWhite, brand, inTheBand, appearancePair, undeclared, remotePage,
            nothingLoaded,
        ]

        /// A dark site that states its colour. The case that made the white
        /// strip look welded on.
        static let nearBlack = Fixture(
            name: "01-near-black",
            html: page(
                theme: ##"<meta name="theme-color" content="#0d0d12">"##,
                style: "background: #0d0d12; color: #e8e8f0;"
            )
        )

        /// A light site that states white outright.
        static let plainWhite = Fixture(
            name: "02-white",
            html: page(
                theme: ##"<meta name="theme-color" content="#ffffff">"##,
                style: "background: #ffffff; color: #16171a;"
            )
        )

        /// A saturated brand colour, well clear of both extremes.
        static let brand = Fixture(
            name: "03-brand",
            html: page(
                theme: ##"<meta name="theme-color" content="#0b3d91">"##,
                style: "background: #f7f8fc; color: #16171a;"
            )
        )

        /// A colour on which neither ink can be read — the band ADR-0047
        /// moves a tint out of. Pure red is the everyday case, not a contrived
        /// one: it is a brand colour, and it sits almost exactly in the middle
        /// of the gap. The strip should still be plainly red.
        static let inTheBand = Fixture(
            name: "04-in-the-band",
            html: page(
                theme: ##"<meta name="theme-color" content="#ff0000">"##,
                style: "background: #ff0000; color: #ffffff;"
            )
        )

        /// Two declarations, one per appearance. The light board must take the
        /// first and the dark board the second.
        static let appearancePair = Fixture(
            name: "05-appearance-pair",
            html: page(
                theme: """
                <meta name="theme-color" content="#fff8e7" media="(prefers-color-scheme: light)">
                <meta name="theme-color" content="#12100c" media="(prefers-color-scheme: dark)">
                """,
                style: """
                background: #fff8e7; color: #2b2416;
                """,
                extra: """
                @media (prefers-color-scheme: dark) {
                  body { background: #12100c; color: #f0e7d6; }
                }
                """
            )
        )

        /// **The board that decides whether this ships.** No `theme-color`, no
        /// background on `html` or `body` — which is what most of the web looks
        /// like. The only thing that knows this page is white is the engine
        /// that painted it.
        static let undeclared = Fixture(
            name: "06-nothing-declared",
            html: page(theme: "", style: "color: #202020;")
        )

        /// No page at all: a tab that has committed nothing. The third rung of
        /// the chain, where the strip wears the app's own surface and keeps its
        /// line — the only board here that should have a seam, because it is
        /// the only one where there is a real boundary to show.
        static let nothingLoaded = Fixture(name: "08-no-page", html: nil)

        /// A page off the actual internet, if there is one to be had. The
        /// machine running this may have no network, and the board is allowed
        /// to come back untinted — what it must not do is come back *wrong*.
        static let remotePage = Fixture(
            name: "07-live",
            html: nil,
            remote: URL(string: "https://example.com/")
        )

        /// A page that looks like a page rather than a colour swatch: the strip
        /// has to be judged against real content, not against a rectangle.
        private static func page(theme: String, style: String, extra: String = "") -> String {
            """
            <!doctype html>
            <html><head><meta charset="utf-8">
            <title>A page, with words on it</title>
            \(theme)
            <style>
              * { box-sizing: border-box; }
              body {
                margin: 0; \(style)
                font: 16px/1.6 -apple-system, system-ui, sans-serif;
              }
              header { padding: 28px 48px 0; }
              h1 { font-size: 30px; margin: 0 0 6px; letter-spacing: -0.02em; }
              p { margin: 0 0 14px; opacity: 0.72; max-width: 60ch; }
              main { padding: 20px 48px 48px; }
              .row { display: flex; gap: 14px; margin-top: 22px; }
              .card {
                flex: 1; height: 92px; border-radius: 10px;
                background: currentColor; opacity: 0.08;
              }
              a { color: inherit; }
              \(extra)
            </style></head>
            <body>
              <header>
                <h1>A page, with words on it</h1>
                <p>Long enough to see how the strip above sits against real
                   content rather than against a swatch.</p>
              </header>
              <main>
                <p>Another line, and <a href="#">a link</a>, so the page has
                   more than one weight in it.</p>
                <div class="row"><div class="card"></div><div class="card"></div>
                  <div class="card"></div></div>
              </main>
            </body></html>
            """
        }
    }
}
