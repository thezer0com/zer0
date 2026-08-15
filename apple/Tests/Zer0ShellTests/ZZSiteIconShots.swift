import AppKit
import SwiftUI
import Testing
import Zer0Core

@testable import Zer0Shell

/// The sidebar, the command bar and the history pane with **real** favicons in
/// them — fetched over the network by the shipping fetcher, filed by the
/// shipping reducer, and drawn by the shipping views.
///
/// A favicon feature verified only by assertions is not verified. The whole
/// claim is that a row reads faster with a picture on it than with a letter,
/// and no test can hold that opinion. So the boards come in pairs: the same
/// rows with icons and without, light and dark, side by side in a directory
/// somebody can open.
///
/// **Opt-in.** `ZER0_SHOT=1 swift test --filter ZZSiteIcon`. These reach the
/// network and pump the run loop for seconds, so `scripts/check.sh` verifies
/// every case here carries the gate.
///
/// **What is real and what is not.** Everything except WebKit. There is no web
/// view, so `IconsDeclared` is dispatched directly instead of arriving from a
/// page's DOM — which means the boards exercise the `/favicon.ico` fallback
/// rather than the declared-`<link>` path. Everything downstream of that is the
/// product: the reducer picks the URL, `IconFetcher` fetches it anonymously,
/// the bytes are validated and cached per cookie jar, and `SiteBadge` draws
/// whatever survived. A site that is unreachable draws its letter, which is the
/// fallback working and is worth seeing on the same board.
@Suite("ZZ site icon shots")
struct ZZSiteIconShots {
    /// Four levels up from this file is the repository root, where `design/`
    /// already holds the logo and palette boards.
    private static let output = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "design/icons")

    /// Sites chosen for variety rather than affection: a dark mark, a light
    /// one, a wordmark, a photograph-ish one, a shape with no fill. If the
    /// treatment only works on flat squares, this is where that shows.
    private static let sites: [(host: String, title: String)] = [
        ("github.com", "avelino/zer0-browser: a WebKit browser"),
        ("news.ycombinator.com", "Hacker News"),
        ("en.wikipedia.org", "Bauhaus — Wikipedia"),
        ("stackoverflow.com", "swift - NSHostingView renders blank"),
        ("www.rust-lang.org", "Rust Programming Language"),
        ("developer.mozilla.org", "WKWebView - Web APIs | MDN"),
        ("www.apple.com", "Apple"),
        ("avelino.run", "Thiago Avelino"),
    ]

    @Test(
        "render rows with real favicons, with the letters beside them",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    @MainActor
    func renderRealIcons() async throws {
        try FileManager.default.createDirectory(
            at: Self.output, withIntermediateDirectories: true
        )

        let model = BrowserModel(storagePath: nil)
        let tabs = seed(model)
        let fetched = await fetchIcons(model)

        // Said out loud in the run log, because a board full of letters is
        // indistinguishable from the feature not working, and "I looked at it"
        // has to mean something.
        print("icons: \(fetched) of \(Self.sites.count) sites answered with a usable icon")

        for dark in [false, true] {
            try shoot("01-sidebar", size: CGSize(width: 280, height: 460), dark: dark) {
                Sidebar().environment(model)
            }
            try shoot("02-rows-icons", size: CGSize(width: 320, height: 300), dark: dark) {
                RowStrip(model: model, tabs: tabs, icons: true)
            }
            // The same rows, same order, same titles, with the letters back.
            // The pair is the argument.
            try shoot("03-rows-letters", size: CGSize(width: 320, height: 300), dark: dark) {
                RowStrip(model: model, tabs: tabs, icons: false)
            }
            try shoot("04-history", size: CGSize(width: 640, height: 380), dark: dark) {
                HistoryStrip(model: model)
            }
        }

        #expect(
            fetched > 0,
            "no site answered — the boards are a picture of the fallback, not of the feature"
        )
    }

    // MARK: - Driving the real pipeline

    /// A tab per site, committed onto its page. No web view: the reducer only
    /// needs a tab that has landed somewhere.
    @MainActor
    private func seed(_ model: BrowserModel) -> [BrowserTab] {
        for site in Self.sites {
            model.send(.openTab(space: nil, url: nil, parent: nil))
            guard let tab = model.snapshot.activeTab else { continue }
            model.send(.navigationCommitted(tab: tab, url: "https://\(site.host)/"))
            model.send(.titleChanged(tab: tab, title: site.title))
            model.send(.navigationFinished(tab: tab))
        }
        return model.snapshot.tabs.filter { $0.url != nil }
    }

    /// Ask for every icon and wait for the answers.
    ///
    /// `model.send` runs the whole path: the reducer decides, `EngineHost`
    /// carries out `FetchIcon`, `IconFetcher` goes to the network, and the
    /// answer comes back in as another action.
    @MainActor
    private func fetchIcons(_ model: BrowserModel) async -> Int {
        for tab in model.snapshot.tabs where tab.url != nil {
            model.send(.iconsDeclared(tab: tab.id, candidates: []))
        }

        // Awaited rather than run-looped, and that is not a style choice: a
        // `Task` started on the main actor by `IconFetcher` is never serviced
        // by `RunLoop.run(until:)` in this process, so pumping the run loop
        // here waits fifteen seconds for a request that has not started.
        // Suspending is what lets it run.
        //
        // Up to fifteen seconds, checked twice a second, and stopping the
        // moment everything has landed.
        for _ in 0 ..< 30 {
            try? await Task.sleep(for: .milliseconds(500))
            if arrived(model) == Self.sites.count { break }
        }
        return arrived(model)
    }

    @MainActor
    private func arrived(_ model: BrowserModel) -> Int {
        model.snapshot.tabs.count { model.icon(forHost: $0.host, in: $0.space) != nil }
    }

    // MARK: - Rasterising

    /// `NSHostingView` + `cacheDisplay` rather than `ImageRenderer`, which does
    /// not draw materials — and the sidebar is one.
    @MainActor
    private func shoot(
        _ name: String,
        size: CGSize,
        dark: Bool,
        @ViewBuilder content: () -> some View
    ) throws {
        let root = content()
            .environment(\.controlActiveState, .key)
            .zer0Palette()
            .frame(width: size.width, height: size.height)
            .preferredColorScheme(dark ? .dark : .light)

        let host = NSHostingView(rootView: AnyView(root))
        host.frame = CGRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

        let window = testWindow(host.frame, styleMask: [.borderless])
        window.appearance = host.appearance
        window.contentView = host
        window.displayIfNeeded()

        for _ in 0 ..< 12 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            Issue.record("no bitmap rep for \(name)")
            return
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            Issue.record("no png for \(name)")
            return
        }
        try png.write(to: Self.output.appending(path: "\(name)-\(dark ? "dark" : "light").png"))
    }
}

// MARK: - Specimens

/// Sidebar rows on their own, at sidebar width, with the badge switchable.
///
/// Not the `Sidebar` itself, because the point of this board is the pair —
/// identical rows differing in one thing — and the sidebar would bring its
/// header, its spaces and its scroll along for the ride.
private struct RowStrip: View {
    let model: BrowserModel
    let tabs: [BrowserTab]
    let icons: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(icons ? "With icons" : "With letters")
                .sectionHeading()
                .foregroundStyle(.secondary)
                .padding(.horizontal, Design.Space.snug)
                .padding(.bottom, Design.Space.hair)

            ForEach(tabs, id: \.id) { tab in
                HStack(spacing: Design.Space.tight) {
                    SiteBadge(subject: icons
                        ? model.badge(for: tab)
                        : .site(host: tab.host, icon: nil))
                    Text(tab.displayTitle)
                        .font(Design.Text.row)
                        .lineLimit(1)
                    Spacer(minLength: Design.Space.hair)
                }
                .padding(.horizontal, Design.Space.tight)
                .padding(.vertical, Design.Space.hair)
            }
            Spacer()
        }
        .padding(Design.Space.snug)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .chromeSurface()
    }
}

/// A history pane's rows, which is the other list where a badge is the only
/// thing telling two long URLs apart at a glance.
private struct HistoryStrip: View {
    let model: BrowserModel

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.recentHistory(limit: 12).enumerated()), id: \.element.url) {
                index, entry in
                let host = URL(string: entry.url)?.host()

                HStack(spacing: Design.Space.snug) {
                    SiteBadge(subject: model.badge(forHost: host))
                    VStack(alignment: .leading, spacing: Design.Space.line) {
                        Text(entry.title ?? entry.url).lineLimit(1)
                        Text(entry.url)
                            .font(Design.Text.label)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: Design.Space.regular)
                }
                .padding(Design.Space.snug)

                if index < model.recentHistory(limit: 12).count - 1 {
                    Divider().padding(.leading, Design.Space.regular)
                }
            }
        }
        .background(
            Design.Surface.recessed,
            in: RoundedRectangle(cornerRadius: Design.Radius.medium)
        )
        .padding(Design.Space.loose)
    }
}
