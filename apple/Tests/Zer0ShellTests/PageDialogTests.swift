import AppKit
import Foundation
import Testing
import WebKit
import Zer0Core

@testable import Zer0Shell

/// What a page said, and what it heard back (ADR-0089).
///
/// **These ask the page, not the delegate.** A test that proves
/// `runJavaScriptConfirmPanelWithMessage` was called proves a method exists. It
/// says nothing about the thing that was broken, which is what `confirm()`
/// *evaluates to* — and before this, unimplemented, it evaluated to `false`
/// with nothing on screen. So each of the four is driven from inside a real
/// page over a real origin, and the answer is read out of JavaScript.
///
/// **Over http, not `file://`**, for the reason `PopupTests` gives: a `file://`
/// page has an opaque origin, and this whole change is about which origin gets
/// named.
///
/// **Serialized on purpose**, for the reason `PopupTests` and `EnginePolicyTests`
/// are: several models, page loads and windows on the main actor at once starve
/// the debounce `SessionPersistenceTests` waits on, and the failure lands on
/// that test rather than on this file.
///
/// **Every test here answers every dialog it raises before it ends**, and that
/// is not tidiness. WebKit's `CompletionHandlerCallChecker` raises
/// `NSInternalInconsistencyException` when a completion block is released
/// without having been called, and it takes the process down — so a test that
/// walks away from a question crashes the whole suite, in a stack that names
/// the release rather than the omission. The invariant this file is about
/// enforces itself, expensively.
@MainActor
@Suite(.serialized)
struct PageDialogTests {
    private func serve() async throws -> TinyHTTPServer {
        try await TinyHTTPServer(routes: [
            // Every call is made from a script the page runs, and the answer is
            // parked on `window` for the test to read. `evaluateJavaScript`
            // cannot be used to make the call itself and then read its result,
            // because these block the script that made them: the promise would
            // not resolve until the panel was answered, which is after the test
            // needs to be looking at it.
            "/talker": .html("""
            <html><body>
              <p id="here">here</p>
              <input id="file" type="file">
              <input id="files" type="file" multiple>
              <input id="folder" type="file" webkitdirectory>
              <script>
                window.said = 'nothing';
                window.ask = function (what) {
                  window.said = 'waiting';
                  if (what === 'alert') { alert('the site wrote this'); window.said = 'alerted'; }
                  if (what === 'confirm') { window.said = 'confirm:' + String(confirm('delete this?')); }
                  if (what === 'prompt') { window.said = 'prompt:' + String(prompt('your name?', 'ada')); }
                };
                window.picked = function (id) {
                  var input = document.getElementById(id);
                  return input.files.length + ':' +
                    Array.prototype.map.call(input.files, function (f) { return f.name; }).join(',');
                };
              </script>
            </body></html>
            """),
        ])
    }

    /// A model on a page that talks, in a real window.
    ///
    /// The window matters: a `WKWebView` with no window hosts a document WebKit
    /// reports as hidden, and a sheet has nowhere to be.
    private func talking(
        _ server: TinyHTTPServer,
        window: NSWindow
    ) async throws -> (model: BrowserModel, tab: TabId, view: WKWebView) {
        let model = BrowserModel(storagePath: nil)
        let tab = try #require(model.snapshot.activeTab)
        model.send(.navigateTo(tab: tab, input: "http://127.0.0.1:\(server.port)/talker"))
        #expect(await eventually { model.activeTab?.loadingComplete == true })
        let view = try #require(model.engine.webView(for: tab))
        let container = window.contentView ?? NSView(frame: window.contentLayoutRect)
        window.contentView = container
        view.frame = container.bounds
        container.addSubview(view)
        window.orderFront(nil)
        return (model, tab, view)
    }

    /// Start a call that is going to block, without waiting on it.
    ///
    /// `setTimeout` so the `evaluateJavaScript` that starts it returns: the
    /// call itself never returns until the panel is answered.
    private func ask(_ view: WKWebView, _ what: String) async {
        _ = try? await view.evaluateJavaScript(
            "setTimeout(function () { window.ask('\(what)'); }, 0); 'started'"
        )
    }

    /// Read a value out of the page, once it has been let go.
    ///
    /// **Never call this while a panel is up.** `alert()` blocks the script
    /// thread, and `evaluateJavaScript` is queued behind it — measured, an
    /// `await` on this while a `confirm()` was outstanding never returned and
    /// hung the whole suite. That the page is waiting is asserted off the
    /// core's snapshot instead, which is where the fact actually lives.
    private func said(_ view: WKWebView) async -> String? {
        try? await view.evaluateJavaScript("window.said") as? String
    }

    /// Wait for the page to report something, which it cannot do until the
    /// panel that is holding it has been answered.
    private func waitFor(_ view: WKWebView, _ expected: String) async -> String? {
        _ = await eventually { await said(view) == expected }
        return await said(view)
    }

    /// A stand-in for the system's file picker.
    ///
    /// **Not a convenience.** An `NSOpenPanel` put up from inside
    /// `WKUIDelegate.runOpenPanelWith` never comes back in this process:
    /// measured, the test hung indefinitely with the panel's modal session and
    /// WebKit's reply both wanting the main thread, in a process where nothing
    /// ever calls `NSApplication.run`. So what the browser *decided the panel
    /// is* is asserted here, and what AppKit draws from that is verified by
    /// running the browser and looking (ADR-0089).
    @MainActor
    final class Picker {
        var asked: [FilePanelRequest] = []
        var windows: [NSWindow?] = []
        private var answer: (@MainActor ([URL]?) -> Void)?

        /// Give the picker to a model, and get it back to drive.
        static func installed(on model: BrowserModel) -> Picker {
            let picker = Picker()
            model.filePanels = FilePanelPresenter { asked, window, answer in
                picker.asked.append(asked)
                picker.windows.append(window)
                picker.answer = answer
            }
            return picker
        }

        func cancel() { take()?(nil) }
        func choose(_ urls: [URL]) { take()?(urls) }

        private func take() -> (@MainActor ([URL]?) -> Void)? {
            let held = answer
            answer = nil
            return held
        }
    }

    // MARK: - The three that are drawn

    /// **The one that was dangerous.** Measured before this existed:
    /// `confirm('delete this?')` evaluated to `false` — a Cancel nobody
    /// pressed — with nothing drawn anywhere.
    @Test("a page that asks a question gets the answer somebody gave it")
    func confirmIsAnsweredByAPersonRatherThanByTheBrowser() async throws {
        let server = try await serve()
        defer { server.stop() }
        let window = testWindow(NSRect(x: 0, y: 0, width: 1280, height: 800))
        defer { window.close() }
        let (model, _, view) = try await talking(server, window: window)

        await ask(view, "confirm")
        _ = await eventually { !model.snapshot.pageDialogs.isEmpty }

        let dialog = try #require(model.snapshot.pageDialogs.first, """
            `confirm()` raised nothing. With no `webView(_:runJavaScriptConfirmPanel…)` the call
            returns false and the page has no way to know, so a page asking "delete this?" is
            silently told no — and the day one asks "keep my changes?" it is silently told the
            wrong thing (ADR-0089).
            """)
        #expect(dialog.message == "delete this?", "the page's own words have to reach the panel")

        // Past the settle window, which is the core's and applies here too.
        try? await Task.sleep(for: .milliseconds(Int(promptSettleMs()) + 200))
        model.answerPageDialog(dialog.request, .accepted, silence: false)

        #expect(await waitFor(view, "confirm:true") == "confirm:true", """
            the page was not told what somebody actually pressed. `confirm()` settles when the
            completion handler runs and never otherwise (ADR-0089).
            """)
        #expect(model.snapshot.pageDialogs.isEmpty)
    }

    /// Cancel is an answer, and the answer is the safe one.
    @Test("cancelling a question tells the page no rather than telling it nothing")
    func cancellingAnswersThePage() async throws {
        let server = try await serve()
        defer { server.stop() }
        let window = testWindow(NSRect(x: 0, y: 0, width: 1280, height: 800))
        defer { window.close() }
        let (model, _, view) = try await talking(server, window: window)

        await ask(view, "confirm")
        _ = await eventually { !model.snapshot.pageDialogs.isEmpty }
        let dialog = try #require(model.snapshot.pageDialogs.first)
        try? await Task.sleep(for: .milliseconds(Int(promptSettleMs()) + 200))

        model.answerPageDialog(dialog.request, .cancelled, silence: false)

        #expect(await waitFor(view, "confirm:false") == "confirm:false", """
            a cancelled question left the page waiting. A handler nobody calls is a tab frozen
            inside `confirm()` with nothing on screen (ADR-0089).
            """)
    }

    /// `prompt()` carries text home, and the page's suggestion arrives in the
    /// field rather than being thrown away.
    @Test("what somebody types into a prompt is what the page receives")
    func promptCarriesTheTypedTextHome() async throws {
        let server = try await serve()
        defer { server.stop() }
        let window = testWindow(NSRect(x: 0, y: 0, width: 1280, height: 800))
        defer { window.close() }
        let (model, _, view) = try await talking(server, window: window)

        await ask(view, "prompt")
        _ = await eventually { !model.snapshot.pageDialogs.isEmpty }
        let dialog = try #require(model.snapshot.pageDialogs.first, """
            `prompt()` raised nothing, so it returned null (ADR-0089).
            """)
        #expect(dialog.kind == .prompt(defaultText: "ada"), """
            the page's suggested answer was dropped, so the field opens empty and typing does
            not replace anything.
            """)
        try? await Task.sleep(for: .milliseconds(Int(promptSettleMs()) + 200))

        model.answerPageDialog(dialog.request, .typed(text: "grace"), silence: false)

        #expect(await waitFor(view, "prompt:grace") == "prompt:grace")
    }

    /// An alert has nothing to carry either way. What it has is a script that
    /// does not move until somebody has read it.
    @Test("an alert holds the page until somebody has read it, and then lets go")
    func alertBlocksAndThenReleases() async throws {
        let server = try await serve()
        defer { server.stop() }
        let window = testWindow(NSRect(x: 0, y: 0, width: 1280, height: 800))
        defer { window.close() }
        let (model, _, view) = try await talking(server, window: window)

        await ask(view, "alert")
        _ = await eventually { !model.snapshot.pageDialogs.isEmpty }
        let dialog = try #require(model.snapshot.pageDialogs.first, """
            `alert()` drew nothing at all — measured, the call returned in 94ms having shown
            nobody anything (ADR-0089).
            """)
        try? await Task.sleep(for: .milliseconds(Int(promptSettleMs()) + 200))

        model.answerPageDialog(dialog.request, .accepted, silence: false)

        #expect(
            await waitFor(view, "alerted") == "alerted",
            "the page never came back out of `alert()`"
        )
    }

    // MARK: - The one that is not drawn

    /// **Every file upload on the web.** Measured before this existed: clicking
    /// a file control opened nothing, fired no `change` event and left
    /// `files.length` at zero — on an ordinary page, not only inside an
    /// extension.
    @Test("a file control opens a picker on its own window, and cancelling answers")
    func aFileControlOpensAPickerAndCancellingAnswers() async throws {
        let server = try await serve()
        defer { server.stop() }
        let window = testWindow(NSRect(x: 0, y: 0, width: 1280, height: 800))
        defer { window.close() }
        let (model, _, view) = try await talking(server, window: window)
        let picker = Picker.installed(on: model)

        _ = try? await view.evaluateJavaScript("document.getElementById('file').click(); 'clicked'")
        _ = await eventually { !model.snapshot.pageDialogs.isEmpty }

        let dialog = try #require(model.snapshot.pageDialogs.first, """
            clicking `<input type="file">` did nothing at all. With no
            `webView(_:runOpenPanelWith:…)` there is no panel and no answer, so attaching a file
            is impossible on every site in this browser (ADR-0089).
            """)
        #expect(dialog.kind == .chooseFiles(multiple: false, directories: false))

        _ = await eventually { !picker.asked.isEmpty }
        let asked = try #require(picker.asked.first, """
            the core raised a file control and no picker was asked for, so the page is frozen on
            a panel that never opened (ADR-0089).
            """)
        #expect(asked == FilePanelRequest(
            // The host as the core spells it, port and all, because
            // `http://127.0.0.1:8080` and `http://127.0.0.1` are different
            // sites and a panel naming only the first would be naming the
            // wrong one.
            message: "Choose what 127.0.0.1:\(server.port) may upload.",
            multiple: false,
            directories: false
        ), "the panel does not name the site it is about to hand a file to")
        #expect(
            picker.windows.first ?? nil === window,
            "the picker was offered to a window other than the one holding the page"
        )
        #expect(picker.asked.count == 1, "one control, two panels")

        // **The line every upload button depends on.**
        picker.cancel()
        _ = await eventually { model.snapshot.pageDialogs.isEmpty }

        #expect(model.snapshot.pageDialogs.isEmpty)
        #expect(
            model.engine.pageDialogs.outstandingCount == 0,
            "a handler left holding is a page whose promise never settles"
        )
        let picked = try? await view.evaluateJavaScript("window.picked('file')") as? String
        #expect(picked == "0:", "cancelling put a file into the control")
    }

    @Test("multiple and directory controls carry their own two facts")
    func multipleAndDirectoryAreCarried() async throws {
        let server = try await serve()
        defer { server.stop() }
        let window = testWindow(NSRect(x: 0, y: 0, width: 1280, height: 800))
        defer { window.close() }
        let (model, _, view) = try await talking(server, window: window)
        let picker = Picker.installed(on: model)

        _ = try? await view.evaluateJavaScript("document.getElementById('files').click(); 'x'")
        _ = await eventually { !model.snapshot.pageDialogs.isEmpty }
        let many = try #require(model.snapshot.pageDialogs.first)
        #expect(many.kind == .chooseFiles(multiple: true, directories: false), """
            `<input multiple>` came through as a single-file panel, so a page asking for three
            attachments gets one and no way to say so.
            """)
        _ = await eventually { !picker.asked.isEmpty }
        #expect(picker.asked.last?.multiple == true)
        #expect(picker.asked.last?.directories == false)
        picker.cancel()
        _ = await eventually { model.snapshot.pageDialogs.isEmpty }

        _ = try? await view.evaluateJavaScript("document.getElementById('folder').click(); 'x'")
        _ = await eventually { !model.snapshot.pageDialogs.isEmpty }
        let folder = try #require(model.snapshot.pageDialogs.first)
        // `multiple: false` is measured, not assumed: `<input webkitdirectory>`
        // reports `allowsMultipleSelection` **false**, which is the opposite of
        // what a first reading of "a directory holds many files" suggests. One
        // directory is one selection.
        #expect(folder.kind == .chooseFiles(multiple: false, directories: true), """
            `<input webkitdirectory>` came through as an ordinary file panel, so the one control
            that needs a directory cannot be given one.
            """)
        _ = await eventually { picker.asked.count > 1 }
        #expect(picker.asked.last?.directories == true, """
            a control that asked for a directory was offered files instead, so the answer it
            gets back may not be a directory at all.
            """)
        picker.cancel()
        _ = await eventually { model.snapshot.pageDialogs.isEmpty }
    }

    /// The file a person picked reaches the control, which is the half of the
    /// upload the panel exists for.
    @Test("a file that was picked arrives in the control the page can read")
    func aPickedFileArrivesInTheControl() async throws {
        let server = try await serve()
        defer { server.stop() }
        let window = testWindow(NSRect(x: 0, y: 0, width: 1280, height: 800))
        defer { window.close() }
        let (model, _, view) = try await talking(server, window: window)
        let picker = Picker.installed(on: model)

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("zer0-upload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = scratch.appendingPathComponent("notes.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)

        _ = try? await view.evaluateJavaScript("document.getElementById('file').click(); 'x'")
        _ = await eventually { !picker.asked.isEmpty }

        picker.choose([file])

        func picked() async -> String? {
            try? await view.evaluateJavaScript("window.picked('file')") as? String
        }
        _ = await eventually { await picked() == "1:notes.txt" }
        #expect(await picked() == "1:notes.txt", """
            the file somebody chose never reached the page, so the upload button does nothing
            after a successful pick (ADR-0089).
            """)
        #expect(model.snapshot.pageDialogs.isEmpty)
    }

    /// Picking nothing is a cancel, not an empty selection: an empty list handed
    /// to a file control reads as "clear what was there".
    @Test("a picker that came back with nothing is a cancel")
    func anEmptyPickIsACancel() async throws {
        let server = try await serve()
        defer { server.stop() }
        let window = testWindow(NSRect(x: 0, y: 0, width: 1280, height: 800))
        defer { window.close() }
        let (model, _, view) = try await talking(server, window: window)
        let picker = Picker.installed(on: model)

        _ = try? await view.evaluateJavaScript("document.getElementById('file').click(); 'x'")
        _ = await eventually { !picker.asked.isEmpty }

        picker.choose([])
        _ = await eventually { model.snapshot.pageDialogs.isEmpty }

        #expect(model.engine.pageDialogs.outstandingCount == 0)
        let picked = try? await view.evaluateJavaScript("window.picked('file')") as? String
        #expect(picked == "0:")
    }

    // MARK: - Nothing is left waiting

    @Test("a tab that closes mid-question does not leave the page waiting forever")
    func aClosingTabStillAnswers() async throws {
        let server = try await serve()
        defer { server.stop() }
        let window = testWindow(NSRect(x: 0, y: 0, width: 1280, height: 800))
        defer { window.close() }
        let (model, tab, view) = try await talking(server, window: window)

        await ask(view, "confirm")
        _ = await eventually { !model.snapshot.pageDialogs.isEmpty }
        #expect(model.engine.pageDialogs.outstandingCount == 1)

        model.close(tab)

        #expect(
            model.engine.pageDialogs.outstandingCount == 0,
            "a handler dropped with the web view is a page that spins with no error"
        )
    }

    // MARK: - Whose panel is on whose window

    /// The panel belongs to the window its tab is in. Drawn on every window it
    /// would let a page in one take the keyboard in another.
    @Test("a panel is offered only to the window holding the tab that raised it")
    func aPanelIsOfferedOnlyToItsOwnWindow() async throws {
        let server = try await serve()
        defer { server.stop() }
        let window = testWindow(NSRect(x: 0, y: 0, width: 1280, height: 800))
        defer { window.close() }
        let (model, tab, view) = try await talking(server, window: window)
        let mine = try #require(model.snapshot.tabs.first { $0.id == tab }?.window)

        await ask(view, "alert")
        _ = await eventually { !model.snapshot.pageDialogs.isEmpty }
        let dialog = try #require(model.snapshot.pageDialogs.first)

        #expect(model.pendingPageDialog(in: mine) != nil)
        #expect(
            model.pendingPageDialog(in: mine &+ 1) == nil,
            "another window offered to answer a question asked in this one"
        )
        // And the file control never becomes a SwiftUI sheet, because the panel
        // for it is AppKit's and two of them over each other is one nobody can
        // reach.
        #expect(model.pendingPageDialog(in: nil) == nil)

        // **Answered before the model goes**, and that is not tidiness.
        // Measured: WebKit's `CompletionHandlerCallChecker` raises
        // `NSInternalInconsistencyException` when a completion block is
        // released without having been called, and it takes the process with
        // it — so a test that raises a dialog and walks away crashes the whole
        // suite, in a stack naming nothing useful. That is the invariant
        // enforcing itself.
        model.answerPageDialog(dialog.request, .cancelled, silence: false)
        #expect(model.engine.pageDialogs.outstandingCount == 0)
    }
}

// MARK: - The site's words stay the site's

/// Two rules on this sheet are **absences**, and an assertion cannot observe
/// something that is not there. `SourceRuleTests` established the answer for
/// that shape of rule — read the source and fail on it — and this is that
/// scanner pointed at the three panels a page gets to fill with its own text.
@Suite("a page cannot write in the browser's voice")
struct PageDialogSourceRuleTests {
    private var sheet: SourceScan.Source {
        get throws {
            let file = SourceScan.repoRoot
                .appending(path: "apple/Sources/Zer0Shell/PageDialogSheet.swift")
            return SourceScan.Source(file: file, text: try String(contentsOf: file, encoding: .utf8))
        }
    }

    /// `Text(_:)` on a `String` parses markdown, so a page writing
    /// `**Your password has expired**` would arrive bold, and a `[link](…)`
    /// would arrive as one. `Text(verbatim:)` does not, and `SiteWords` is the
    /// only place the page's own string is drawn.
    @Test("the page's own words are drawn verbatim and in one place")
    func theSitesWordsAreDrawnVerbatimAndInOnePlace() throws {
        let source = try sheet

        #expect(
            !SourceScan.occurrences(of: "Text(verbatim: dialog.message)", in: source.code).isEmpty,
            """

            \(source.path): the page's own string is no longer drawn with `Text(verbatim:)`.
              `Text(_:)` parses markdown at runtime, so a site could arrive in bold, as a link,
              or as a heading — in the browser's own type, on a panel the browser drew
              (ADR-0089).
            """
        )
        // `dialog.messageTruncated` contains the shorter name, so it is
        // subtracted rather than matched: a scan that counted it would be a
        // scan whose number nobody could check.
        let reads = SourceScan.occurrences(of: "dialog.message", in: source.code).count
            - SourceScan.occurrences(of: "dialog.messageTruncated", in: source.code).count
        #expect(
            reads == 2,
            """

            \(source.path): the page's own string is read \(reads) times, not twice.
              It has exactly one path to the screen — `SiteWords`, which asks whether it is
              empty and then draws it verbatim in a recessed block — and a second path is the
              one that ends up in a title (ADR-0089).
            """
        )
        #expect(
            SourceScan.occurrences(of: "Text(dialog.message", in: source.code).isEmpty,
            """

            \(source.path): the page's string reaches a `Text(_:)`.
              That initialiser parses markdown at runtime, so a site could arrive in bold, as a
              link, or as a heading — in the browser's own type, on a panel the browser drew
              (ADR-0089).
            """
        )
    }

    /// The identity line is what a spoof has to get past, so it is never
    /// composed here: the origin arrives canonical from the core, punycode and
    /// all, and a shell that built its own would be a second answer to which
    /// site is talking.
    @Test("the identity line is the core's spelling and not one built here")
    func theIdentityLineComesFromTheCore() throws {
        let source = try sheet

        for spelling in ["://", "components(separatedBy:", "replacingOccurrences"] {
            #expect(
                SourceScan.occurrences(of: spelling, in: source.code).isEmpty,
                """

                \(source.path): `\(spelling)` on the page-dialog sheet.
                  Splitting an origin here is a second implementation of `host_of`, and the day
                  the two disagree is the day a panel names a site that is not the one talking
                  (ADR-0089).
                """
            )
        }
    }

    /// **An extension's name never reaches the title.**
    ///
    /// The title is the browser talking — "example.com is asking", in the
    /// browser's type at the browser's weight. A host earns that slot because
    /// it is a fact the browser derived from an address it fetched. An
    /// extension's name is a string the package wrote about itself, and a
    /// package may call itself `google.com`; the day one is interpolated here,
    /// this browser prints a lie in its own voice with nothing on screen saying
    /// so. The name goes on the identity line, in `ExtensionName`, where it is
    /// visibly a quotation.
    ///
    /// A source scan because no assertion can watch a string *not* being
    /// interpolated: a run-time check would need a rendered sheet and a package
    /// named after a real site, and it would still only cover the one spelling
    /// somebody thought to write.
    @Test("an extension's own name never reaches the sheet's title")
    func theTitleNeverCarriesAnExtensionsOwnName() throws {
        let source = try sheet

        // The one place the name is allowed, and the scan is anchored to it so
        // that moving the drawing without moving the rule fails here.
        #expect(
            !SourceScan.occurrences(of: "Text(verbatim: truncated ?", in: source.code).isEmpty,
            """

            \(source.path): `ExtensionName` no longer draws the name with `Text(verbatim:)`.
              `Text(_:)` parses markdown at runtime, so a package named `**Trusted**` would
              arrive bold on the line that says who is responsible (ADR-0098).
            """
        )
        let title = title(of: source)
        for spelling in ["case let .extension(name", "case .extension(let name"] {
            #expect(
                SourceScan.occurrences(of: spelling, in: title).isEmpty,
                """

                \(source.path): the sheet's `title` binds an extension's own name.
                  The title is the browser's voice. A package calling itself `google.com` would
                  get "google.com is asking" in our type at our weight, which is the whole of
                  the spoof `SiteWords` and the identity line exist to prevent (ADR-0098).
                """
            )
        }
    }

    /// The body of `title`, which is the only part of this file the rule above
    /// is about. Read by slicing rather than by scanning the whole file,
    /// because `ExtensionName` legitimately binds the name a few lines away.
    private func title(of source: SourceScan.Source) -> [Character] {
        guard let start = SourceScan.occurrences(
            of: "private var title: String {", in: source.code
        ).first else { return [] }
        let rest = Array(source.code[start...])
        guard let end = SourceScan.occurrences(of: "\n    }", in: rest).first else { return rest }
        return Array(rest[..<end])
    }
}
