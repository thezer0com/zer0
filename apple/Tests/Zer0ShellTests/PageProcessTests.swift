import AppKit
import Foundation
import Testing
import WebKit
import Zer0Core

@testable import Zer0Shell

/// A page whose process dies, and a tab that has to survive it.
///
/// **The crash is real.** `SIGKILL` to the web content process is what a crash
/// is, and it is used here rather than WebKit's own
/// `_killWebContentProcess` because that one was measured doing nothing at all
/// from a test: the selector exists, the call returns, the process keeps its
/// pid and `webViewWebContentProcessDidTerminate` never fires. An instrument
/// that cannot see the working case cannot be trusted on the broken one
/// (AGENTS.md), so every test here waits for that callback before it asserts
/// anything, and the wait failing is the test failing.
@MainActor
struct PageProcessTests {
    /// A local page, so nothing here depends on a network.
    private func page(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zer0-crash-\(UUID().uuidString)-\(label)")
            .appendingPathExtension("html")
        try "<html><head><title>\(label)</title></head><body>\(label)</body></html>"
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// The web content process drawing this view, or `nil` once it is gone.
    private func webProcess(of view: WKWebView) -> pid_t? {
        let value = (view.value(forKey: "_webProcessIdentifier") as? Int) ?? 0
        return value > 0 ? pid_t(value) : nil
    }

    /// Kill the process rendering this tab's page, and wait until the engine
    /// has noticed.
    ///
    /// Returns once the tab is carrying the failure, which is the core's proof
    /// that the callback arrived — not the test's own bookkeeping.
    private func crashPage(of model: BrowserModel, tab: TabId) async throws {
        let view = try #require(model.engine.webView(for: tab))
        let process = try #require(webProcess(of: view), "no live web process to kill")
        #expect(kill(process, SIGKILL) == 0)
        #expect(
            await eventually { model.snapshot.tabs.first { $0.id == tab }?.lastError != nil },
            "the crash never reached the core"
        )
    }

    private func navigate(_ model: BrowserModel, tab: TabId, to url: URL) async -> Bool {
        model.send(.navigateTo(tab: tab, input: url.absoluteString))
        return await eventually {
            model.snapshot.tabs.first { $0.id == tab }?.url?.hasSuffix(url.lastPathComponent)
                == true
        }
    }

    /// The core's copy of the engine's back answer, read the way the UI reads
    /// it: off the snapshot, never off the engine. A test reading
    /// `WKWebView.canGoBack` directly would prove the engine's own
    /// bookkeeping and say nothing about what the browser's state says ⌘[
    /// should do.
    private func canGoBack(_ model: BrowserModel, tab: TabId) -> Bool {
        model.snapshot.tabs.first { $0.id == tab }?.canGoBack == true
    }

    @Test("a crashed page becomes a screen that says so and keeps its address")
    func aDeadPageIsAState() async throws {
        let m = BrowserModel(storagePath: nil)
        let tab = try #require(m.snapshot.activeTab)
        let first = try page("one")
        #expect(await navigate(m, tab: tab, to: first))

        try await crashPage(of: m, tab: tab)

        let error = try #require(m.snapshot.tabs.first { $0.id == tab }?.lastError)
        #expect(error.kind == .pageProcessEnded)
        #expect(error.url?.hasSuffix(first.lastPathComponent) == true)
        #expect(m.snapshot.tabs.contains { $0.id == tab }, "the tab must survive its page")
    }

    @Test("the tab is not reloaded on its own, because a page can die on load")
    func nothingReloadsItself() async throws {
        let m = BrowserModel(storagePath: nil)
        let tab = try #require(m.snapshot.activeTab)
        #expect(await navigate(m, tab: tab, to: try page("one")))

        try await crashPage(of: m, tab: tab)

        // Long enough for a reload to have been issued, committed and reported.
        try await Task.sleep(for: .seconds(1))
        #expect(
            m.snapshot.tabs.first { $0.id == tab }?.lastError != nil,
            "a browser that reloads a crashed page by itself loops forever on one that dies on load"
        )
    }

    @Test("reloading a crashed tab brings the page back into the same view")
    func retryRecoversTheSameView() async throws {
        let m = BrowserModel(storagePath: nil)
        let tab = try #require(m.snapshot.activeTab)
        let first = try page("one")
        #expect(await navigate(m, tab: tab, to: first))
        let before = try #require(m.engine.webView(for: tab))

        try await crashPage(of: m, tab: tab)
        m.send(.reload(tab: tab, fromOrigin: false))

        #expect(
            await eventually { m.snapshot.tabs.first { $0.id == tab }?.lastError == nil },
            "Try Again has to actually try"
        )
        let after = try #require(m.engine.webView(for: tab))
        // The measurement this whole design rests on: an ordinary load into the
        // view whose process died recovers it. Nothing is replaced, so the
        // tab keeps its scroll, its zoom and its place in the hierarchy.
        #expect(before === after, "the view is recovered rather than swapped")
        #expect(await eventually { self.webProcess(of: after) != nil }, "a live process again")
        #expect(after.url?.lastPathComponent == first.lastPathComponent)
    }

    @Test("back and forward survive the crash")
    func historySurvivesTheCrash() async throws {
        let m = BrowserModel(storagePath: nil)
        let tab = try #require(m.snapshot.activeTab)
        #expect(await navigate(m, tab: tab, to: try page("one")))
        let second = try page("two")
        #expect(await navigate(m, tab: tab, to: second))
        #expect(canGoBack(m, tab: tab))

        try await crashPage(of: m, tab: tab)

        #expect(
            canGoBack(m, tab: tab),
            "the back list lives in the UI process and has no business dying with the page"
        )
    }
}

/// Where a tab has been, across a quit.
@MainActor
struct NavigationStateTests {
    private func page(_ label: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("\(label).html")
        try "<html><head><title>\(label)</title></head><body>\(label)</body></html>"
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func navigate(_ model: BrowserModel, tab: TabId, to url: URL) async -> Bool {
        model.send(.navigateTo(tab: tab, input: url.absoluteString))
        return await eventually {
            model.snapshot.tabs.first { $0.id == tab }?.url?.hasSuffix(url.lastPathComponent)
                == true
        }
    }

    /// The core's copy of the engine's back answer, read the way the UI reads
    /// it: off the snapshot, never off the engine. A test reading
    /// `WKWebView.canGoBack` directly would prove the engine's own
    /// bookkeeping and say nothing about what the browser's state says ⌘[
    /// should do.
    private func canGoBack(_ model: BrowserModel, tab: TabId) -> Bool {
        model.snapshot.tabs.first { $0.id == tab }?.canGoBack == true
    }

    /// The whole of it, end to end: browse three pages, quit, come back, and
    /// press Back.
    @Test("a restored tab can still go back to where it had been")
    func backAndForwardSurviveARelaunch() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zer0-navstate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("session.sqlite").path

        let first = try page("one", in: dir)
        let second = try page("two", in: dir)

        do {
            let before = BrowserModel(storagePath: path)
            let tab = try #require(before.snapshot.activeTab)
            #expect(await navigate(before, tab: tab, to: first))
            #expect(await navigate(before, tab: tab, to: second))
            #expect(canGoBack(before, tab: tab))
            // The state is reported off the navigation, so give the second one
            // a moment to have been carried into the core before the save.
            #expect(await eventually { canGoBack(before, tab: tab) })
            before.save()
        }

        let after = BrowserModel(storagePath: path)
        let tab = try #require(after.snapshot.tabs.first?.id)
        #expect(
            await eventually { canGoBack(after, tab: tab) },
            "a tab that comes back with an empty back list has lost everything you did to reach it"
        )

        after.send(.goBack(tab: tab))
        #expect(
            await eventually {
                after.engine.webView(for: tab)?.url?.lastPathComponent == first.lastPathComponent
            },
            "Back has to land on the page it says it will"
        )
    }

    /// The corrupt-file case, driven through the real command path rather than
    /// through a `WKWebView` on its own: the bytes are opaque, so the engine
    /// refusing them is the only signal there is, and what the core does about
    /// it is the thing worth locking.
    @Test("a history the engine will not take costs the history and not the tab")
    func aRefusedStateStillOpensTheTab() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zer0-navstate-bad-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let page = try page("only", in: dir)

        let m = BrowserModel(storagePath: nil)
        let tab = try #require(m.snapshot.activeTab)
        #expect(await navigate(m, tab: tab, to: page))

        // Exactly what a truncated or hand-edited row looks like coming out of
        // the file. Measured: WebKit takes it without complaint and keeps no
        // history at all, so `currentItem` is the only thing that can tell.
        let garbage = Data((0 ..< 900).map { _ in UInt8.random(in: 0 ... 255) })
        m.engine.perform([
            .destroyWebView(tab: tab),
            .createWebView(
                tab: tab,
                configuration: .space(
                    dataStoreId: UUID().uuidString,
                    profile: SpaceProfile(userAgent: nil, ephemeral: false)
                ),
                navigationState: garbage
            ),
        ])

        #expect(
            await eventually {
                m.engine.webView(for: tab)?.url?.lastPathComponent == page.lastPathComponent
            },
            "a corrupt state must cost the back list, not the tab"
        )
        #expect(canGoBack(m, tab: tab) == false)
    }

    @Test("a tab handed its history is not also told to load")
    func aRestoredTabIsLoadedOnce() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zer0-navstate-once-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("session.sqlite").path
        let first = try page("one", in: dir)
        let second = try page("two", in: dir)

        do {
            let before = BrowserModel(storagePath: path)
            let tab = try #require(before.snapshot.activeTab)
            #expect(await navigate(before, tab: tab, to: first))
            #expect(await navigate(before, tab: tab, to: second))
            before.save()
        }

        // A second load on top of the restored state appends a second entry for
        // the same address, and the person's first Back press then lands on the
        // page they are already reading (ADR-0018).
        let after = BrowserModel(storagePath: path)
        let tab = try #require(after.snapshot.tabs.first?.id)
        let view = try #require(after.engine.webView(for: tab))
        #expect(
            await eventually {
                view.url?.lastPathComponent == second.lastPathComponent && !view.isLoading
            },
            "the tab has to come back on the page it was on"
        )
        // A second's grace, and it is what this test is: the failure being
        // watched for is a load that must *not* arrive, so quiescence is not
        // proof on its own. Written as a wait rather than a poll for the same
        // reason — there is no condition that becomes true when nothing
        // happens.
        //
        // This is not a timing assertion in disguise. WebKit appends the entry
        // itself, off no callback of ours, so a sleep that resumes late under
        // a loaded suite has given the load *more* wall clock to appear in,
        // not less. Measured: with the load put back, the second entry is
        // there well inside this.
        try await Task.sleep(for: .seconds(1))
        #expect(
            view.backForwardList.backList.count == 1,
            """
            expected one page behind and found \
            \(view.backForwardList.backList.map(\.url.lastPathComponent))
            """
        )
    }

    @Test("a private space's back list is never written down")
    func anEphemeralSpaceKeepsItsHistoryOffDisk() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zer0-navstate-private-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("session.sqlite").path
        let first = try page("one", in: dir)
        let second = try page("two", in: dir)

        do {
            let before = BrowserModel(storagePath: path)
            before.setProfile(
                before.snapshot.activeSpace,
                SpaceProfile(userAgent: nil, ephemeral: true)
            )
            let tab = try #require(before.snapshot.activeTab)
            #expect(await navigate(before, tab: tab, to: first))
            #expect(await navigate(before, tab: tab, to: second))
            before.save()
        }

        // Read as bytes, because the promise is about what is in the file and
        // not about what an API hands back.
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(
            bytes.range(of: Data(first.lastPathComponent.utf8)) == nil,
            "a private space's page is in the session file"
        )
    }
}
