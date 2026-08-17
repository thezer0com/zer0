import Foundation
import Network
import Testing
import WebKit
import Zer0Core

@testable import Zer0Shell

/// Blocking, against the real compiler and a real page.
///
/// The core's tests prove the rules are anchored correctly under regex
/// semantics. They cannot prove WebKit *accepts* those rules, and they
/// certainly cannot prove a request is actually stopped — WebKit's `url-filter`
/// grammar is a restricted subset that refuses alternation, bounded repeats and
/// lookahead, so "it is a valid regex" and "it compiles here" are two different
/// claims. These make the second one, and one of them makes the third.
@MainActor
struct ContentBlockingTests {
    /// A store directory of this run's own.
    ///
    /// `WKContentRuleListStore.default()` is shared with anything else on this
    /// machine using WebKit's content blocking, and it is keyed by identifier —
    /// so a test writing into it would evict a real compile, and a real compile
    /// would answer a test's lookup.
    private func scratchStore(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zer0-crl-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func core() -> Zer0 {
        // In memory: these must not read or write the real session.
        Zer0.inMemory(
            firstSpaceName: "Test",
            dataStoreId: UUID().uuidString,
            capabilities: HostCapabilities(extensionRuntime: false, pagePrinting: false)
        )
    }

    // MARK: - The real compiler accepts what the core emits

    /// The claim the core's own tests cannot make.
    ///
    /// Every assertion in `blocking.rs` about WebKit's grammar — no `|`, no
    /// `{2,4}`, no `(?=`, lowercase only — is a fact about an engine the core
    /// never talks to. This is the one test that hands the actual list to the
    /// actual compiler.
    @Test("WebKit compiles the list the core emits")
    func webKitCompilesWhatTheCoreEmits() async throws {
        let core = core()
        core.setBlocking(host: "github.com", blocking: false)

        let json = try #require(core.contentRuleListJson())
        let identifier = try #require(core.contentRuleListIdentifier())
        let store = try #require(WKContentRuleListStore(url: try scratchStore("compiles")))

        let list = try await store.compileContentRuleList(
            forIdentifier: identifier,
            encodedContentRuleList: json
        )

        #expect(list?.identifier == identifier)
    }

    /// The identifier is the cache key, and the shell prunes by its prefix. A
    /// prefix that drifted from the core's would make every launch recompile
    /// and would leave the old lists on disk forever.
    @Test("the identifier carries the prefix the shell prunes by")
    func theIdentifierCarriesThePrefixTheShellPrunesBy() throws {
        let identifier = try #require(core().contentRuleListIdentifier())
        #expect(identifier.hasPrefix(ContentBlocking.identifierPrefix))
    }

    /// An empty list is a compile error in WebKit, not an empty list. The core
    /// answers `nil` for that case and this is what says so from the outside.
    @Test("blocking switched off asks for nothing to be compiled")
    func blockingSwitchedOffAsksForNothing() async throws {
        let core = core()
        var preferences = core.preferences()
        preferences.blockContent = false
        core.setPreferences(preferences: preferences)

        #expect(core.contentRuleListJson() == nil)
        #expect(core.contentRuleListIdentifier() == nil)

        let blocking = ContentBlocking(storeDirectory: try scratchStore("off"))
        await withCheckedContinuation { continuation in
            blocking.refresh(from: core) { continuation.resume() }
        }
        #expect(blocking.state == .off)
    }

    // MARK: - A malformed rule refuses to compile, and does not take us with it

    /// The failure mode this has to survive is not a crash — it is a browser
    /// that reports success and filters nothing.
    @Test("a malformed rule list is refused and reported, and the browser lives")
    func aMalformedRuleListIsRefusedAndReported() async throws {
        let store = try #require(WKContentRuleListStore(url: try scratchStore("malformed")))

        // Every one of these is a shape the emitter must never produce, and
        // each was confirmed against the installed engine to be refused.
        let bad = [
            "this is not json",
            "[]",
            #"[{"trigger":{"url-filter":"^https?://(a|b)\.com[:/]"},"action":{"type":"block"}}]"#,
            #"[{"trigger":{"url-filter":"a{2,4}"},"action":{"type":"block"}}]"#,
            #"[{"trigger":{"url-filter":"x"},"action":{"type":"detonate"}}]"#,
            #"[{"trigger":{"url-filter":"x","if-domain":["EXAMPLE.com"]},"action":{"type":"block"}}]"#,
        ]

        for (index, json) in bad.enumerated() {
            var caught: (any Error)?
            var produced: WKContentRuleList?
            do {
                produced = try await store.compileContentRuleList(
                    forIdentifier: "zer0-block-test-bad-\(index)",
                    encodedContentRuleList: json
                )
            } catch {
                caught = error
            }

            #expect(produced == nil, "WebKit accepted a rule list it should refuse: \(json)")
            let error = try #require(caught as NSError?, "no error for: \(json)")
            #expect(error.domain == WKErrorDomain)
            #expect(error.code == WKError.Code.contentRuleListStoreCompileFailed.rawValue)
            // And the failure is something a person could be shown, rather
            // than an empty string standing in for an explanation.
            #expect(!ContentBlocking.explain(error).isEmpty)
        }
    }

    /// The state a failed compile leaves behind is the one that matters: the
    /// Settings switch is still on, so the pane has to say the switch is not
    /// being honoured. Silence there is the lie ADR-0018 forbids.
    @Test("a compile that fails is a visible state, not a silent one")
    func aFailedCompileIsVisible() throws {
        let failure = ContentBlocking.State.failed(reason: "Empty extension.")

        #expect(failure.isFailure)
        #expect(failure.summary.contains("Empty extension."))
        #expect(failure.summary.contains("Not running"))
        // The three healthy states must not read as a problem, or the warning
        // that draws off `isFailure` means nothing.
        #expect(!ContentBlocking.State.off.isFailure)
        #expect(!ContentBlocking.State.compiling.isFailure)
        #expect(!ContentBlocking.State.active(hosts: 76).isFailure)
    }

    /// Nothing the pane can say may imply a per-page count, because there is
    /// none to be had (ADR-0018, ADR-0058). This is what goes red when somebody
    /// wires up the SPI and starts printing a number.
    @Test("nothing claims to know how many things were blocked on a page")
    func nothingClaimsAPerPageCount() {
        let states: [ContentBlocking.State] = [
            .off, .compiling, .active(hosts: 76), .failed(reason: "Empty extension."),
        ]
        // Phrases that could only be true of a page, which is the claim WebKit
        // gives us no way to make.
        let aboutThePage = ["blocked", "this page", "requests", "on this site"]
        for state in states {
            let said = state.summary.lowercased()
            for phrase in aboutThePage {
                #expect(!said.contains(phrase), "\"\(said)\" claims \"\(phrase)\"")
            }
        }
        // What it does say is a fact about the *list*, which is a different
        // claim and a true one.
        #expect(
            ContentBlocking.State.active(hosts: 76).summary
                .contains("76 tracking and advertising hosts")
        )
    }

    // MARK: - What the person actually does

    /// ⇧⌘K on a page, through the real model.
    ///
    /// The behaviour under test is the one somebody performs on a broken site:
    /// press once and blocking is off *here*, press again and it is back. Both
    /// halves matter — a toggle that only turns things off is a trapdoor.
    @Test("toggling on a page excepts that host, and toggling again undoes it")
    func togglingOnAPageExceptsThatHost() {
        let model = BrowserModel(storagePath: nil)
        let tab = model.snapshot.activeTab
        model.send(.navigationCommitted(tab: tab ?? 0, url: "https://github.com/avelino"))

        #expect(model.blockingHost == "github.com")
        #expect(model.blocksCurrentPage)

        model.perform(.toggleBlockingHere)

        #expect(!model.blocksCurrentPage)
        #expect(model.preferences.blockingExceptions == ["github.com"])

        model.perform(.toggleBlockingHere)

        #expect(model.blocksCurrentPage)
        #expect(
            model.preferences.blockingExceptions.isEmpty,
            "toggling back has to remove the exception, not stack a second one"
        )
    }

    /// The menu item is a sentence about the page, so it has to name the page
    /// and say which way it is about to go. A label that does not track the
    /// state is a small lie told every time the menu opens (ADR-0018).
    @Test("the menu item names the site and says which way it goes")
    func theMenuItemNamesTheSiteAndSaysWhichWayItGoes() {
        let model = BrowserModel(storagePath: nil)
        let tab = model.snapshot.activeTab
        model.send(.navigationCommitted(tab: tab ?? 0, url: "https://www.github.com/avelino"))

        #expect(model.blockingMenuTitle == "Turn Off Blocking on github.com")
        model.perform(.toggleBlockingHere)
        #expect(model.blockingMenuTitle == "Turn On Blocking on github.com")

        // `www.` is dropped from what is *shown* and kept in what is
        // *recorded*: the exception has to be the host the page was on.
        #expect(model.preferences.blockingExceptions == ["www.github.com"])
    }

    /// A page with no host cannot carry an exception, so the command refuses
    /// rather than recording one against nothing — and the menu item is
    /// disabled rather than accepting a click that does nothing.
    @Test("a page with no host records no exception")
    func aPageWithNoHostRecordsNoException() {
        let model = BrowserModel(storagePath: nil)

        #expect(model.blockingHost == nil)
        model.perform(.toggleBlockingHere)
        #expect(model.preferences.blockingExceptions.isEmpty)
        #expect(model.blockingMenuTitle == UiCommand.toggleBlockingHere.title)
    }

    /// The list reaches a live web view, and it is the controller the view
    /// actually consults rather than the one the configuration was handed.
    @Test("a web view the model built is carrying the compiled list")
    func aWebViewTheModelBuiltIsCarryingTheList() async {
        let model = BrowserModel(storagePath: nil)
        // `.off` is also the state before the first lookup answers, so waiting
        // for "not compiling" would pass instantly and prove nothing. The wait
        // is for the state that means the engine has it.
        let cameUp = await eventually {
            if case .active = model.blocking.state { return true }
            return false
        }
        #expect(cameUp, "blocking never came up: \(model.blocking.state)")

        // The engine has to expose the live controllers: that is the path every
        // later change — every exception somebody adds — travels down.
        #expect(!model.engine.contentControllers.isEmpty)

        if case let .active(hosts) = model.blocking.state {
            #expect(hosts == Int(model.blockedHostCount))
            // With no exceptions there is one rule per host, so the two counts
            // agree here — and this is what catches them drifting apart.
            #expect(hosts == Int(model.blockingSummary.rules))
        }
    }

    // MARK: - End to end, through a real page

    /// A rule really stops a real subresource, and an exception really lets it
    /// through.
    ///
    /// Everything else here is about shapes and errors. This is the only test
    /// that answers "is anything actually blocked", and the answer is read from
    /// the page rather than from the server: a blocked request fails the
    /// `fetch`, which is exactly the observable a broken site presents.
    ///
    /// **What this deliberately does not cover, and why:** the lookalike-host
    /// case is proven in the core against the emitted pattern, not here. Doing
    /// it here would need two hostnames resolving to a local server, and macOS
    /// does not bring up `127.0.0.11` without `ifconfig`. So the split is: the
    /// core proves the pattern is anchored, this proves the mechanism is wired.
    @Test("a rule stops a real request and an exception lets it through")
    func aRuleStopsARealRequestAndAnExceptionLetsItThrough() async throws {
        let server = try await TinyHTTPServer(routes: [
            "/page": .html("<html><body>hello</body></html>"),
            "/tracker.js": .html("window.tracked = true;"),
        ])
        defer { server.stop() }

        let origin = "http://127.0.0.1:\(server.port)"
        let store = try #require(WKContentRuleListStore(url: try scratchStore("e2e")))

        // Blocks the tracker path, with no exception.
        let blocking = """
        [{"trigger":{"url-filter":"^http://127\\\\.0\\\\.0\\\\.1:\(server.port)/tracker"},\
        "action":{"type":"block"}}]
        """
        // The same, with the page's own host excepted last — the shape
        // `blocking.rs` emits.
        let excepted = """
        [{"trigger":{"url-filter":"^http://127\\\\.0\\\\.0\\\\.1:\(server.port)/tracker"},\
        "action":{"type":"block"}},\
        {"trigger":{"url-filter":".*","if-top-url":["^http://127\\\\.0\\\\.0\\\\.1[:/]"]},\
        "action":{"type":"ignore-previous-rules"}}]
        """

        let blockList = try #require(try await store.compileContentRuleList(
            forIdentifier: "zer0-block-test-e2e-block", encodedContentRuleList: blocking
        ))
        let exceptList = try #require(try await store.compileContentRuleList(
            forIdentifier: "zer0-block-test-e2e-except", encodedContentRuleList: excepted
        ))

        #expect(
            try await fetchResult(from: origin, list: nil) == "loaded",
            "with no rules attached the request has to succeed, or this test proves nothing"
        )
        #expect(try await fetchResult(from: origin, list: blockList) == "blocked")
        #expect(
            try await fetchResult(from: origin, list: exceptList) == "loaded",
            "ignore-previous-rules with if-top-url has to undo the block on this site"
        )
    }

    /// Load `/page` with `list` attached and ask the page whether it could
    /// fetch `/tracker.js`.
    private func fetchResult(from origin: String, list: WKContentRuleList?) async throws -> String {
        let configuration = WKWebViewConfiguration()
        // Never the shared store: a test must not write cookies or cache into
        // anything the real browser reads.
        configuration.websiteDataStore = .nonPersistent()
        if let list {
            configuration.userContentController.add(list)
        }

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.load(URLRequest(url: try #require(URL(string: "\(origin)/page"))))
        #expect(await eventually { !webView.isLoading && webView.url != nil })

        // The body of an async function, which is what `callAsyncJavaScript`
        // takes. An IIFE here returns a Promise object rather than its value,
        // and the answer comes back `nil` for every case — including the
        // control, which is how this was caught rather than believed.
        let script = """
        try {
          const r = await fetch("\(origin)/tracker.js", { cache: "no-store" });
          return r.ok ? "loaded" : "http-" + r.status;
        } catch (e) { return "blocked"; }
        """
        let result = try await webView.callAsyncJavaScript(
            script, arguments: [:], in: nil, contentWorld: .page
        )
        return result as? String ?? "no-answer"
    }
}

extension TinyResponse {
    /// A body served as HTML or JavaScript, whichever the page asked for. The
    /// type does not matter to `fetch`; what matters is that it arrives.
    static func html(_ body: String) -> TinyResponse {
        let data = Data(body.utf8)
        return TinyResponse(
            head: Data("""
            HTTP/1.1 200 OK\r
            Content-Type: text/html; charset=utf-8\r
            Content-Length: \(data.count)\r
            Access-Control-Allow-Origin: *\r
            Connection: close\r
            \r

            """.utf8),
            chunks: [data],
            gap: 0
        )
    }
}
