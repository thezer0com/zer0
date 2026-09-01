import Testing
import Zer0Core

@testable import Zer0Shell

/// What the Space Lens can honestly say, asked through the same bridge the
/// sidebar draws from.
///
/// Which rows exist and in what order is the core's decision and is tested
/// there (`crates/zer0-core/src/ffi_tests.rs`). What is left for this side is
/// the half the shell owns: that the bridge carries exactly what the core
/// said — no filtering, no reordering — and that acting on a row lands where
/// the row promised.
@MainActor
struct SpaceLensTests {
    private func model() -> BrowserModel {
        BrowserModel(storagePath: nil)
    }

    /// A tab that commits a page and then loses its process.
    @discardableResult
    private func killActiveTab(of m: BrowserModel, at url: String) -> TabId {
        let tab = m.snapshot.activeTab!
        m.send(.navigationCommitted(tab: tab, url: url))
        m.send(.pageProcessEnded(tab: tab))
        return tab
    }

    // MARK: - What the lens is offered

    /// Only a page whose process ended is offered back. A page that failed
    /// another way — offline, host not found — is not "interrupted work", and
    /// a page that is still running is not anything's concern.
    ///
    /// The distinction is the core's and this test only carries it across the
    /// bridge: were the shell to filter here too, this stays green either way
    /// and the Rust suite is what goes red — which is the arrangement working,
    /// not a gap in it.
    @Test("only pages whose process ended are offered back")
    func onlyPagesWhoseProcessEndedAreOffered() {
        let m = model()
        let space = m.snapshot.activeSpace

        let dead = killActiveTab(of: m, at: "https://work.example/first")

        m.send(.openTab(space: nil, url: nil, parent: nil))
        let running = m.snapshot.activeTab!
        m.send(.navigationCommitted(tab: running, url: "https://work.example/running"))

        m.send(.openTab(space: nil, url: nil, parent: nil))
        let offline = m.snapshot.activeTab!
        m.send(.navigationFailed(tab: offline, kind: .offline, message: "offline"))

        let summary = m.spaceResumeSummary(space: space)
        #expect(summary.tabs.map(\.id) == [dead])
        #expect(summary.tabs.first?.url == "https://work.example/first")
        // Nobody ever told the core a title, so it says none — and the row the
        // lens draws falls back to the address rather than inventing one.
        #expect(summary.tabs.first?.title == nil)
    }

    /// The order the rows are offered in is the core's tab order, so the lens
    /// and the tab list above it name the same pages in the same sequence.
    /// Re-sorted here, the two lists would disagree about what is "first".
    @Test("rows arrive in the core's order")
    func rowsArriveInTheCoresOrder() {
        let m = model()
        let space = m.snapshot.activeSpace

        let first = killActiveTab(of: m, at: "https://work.example/first")
        m.send(.openTab(space: nil, url: nil, parent: nil))
        let second = killActiveTab(of: m, at: "https://work.example/second")

        #expect(m.spaceResumeSummary(space: space).tabs.map(\.id) == [first, second])

        // A reorder through the core is the core changing its own answer.
        m.send(.moveTab(tab: second, space: space, index: 0))
        #expect(m.spaceResumeSummary(space: space).tabs.map(\.id) == [second, first])
    }

    /// A space offers its own interruptions and nobody else's: the whole point
    /// of the lens is that it is about the space you are in, and a dead page in
    /// another jar is not waiting on you here.
    @Test("another space's interruptions stay there")
    func anotherSpacesInterruptionsStayThere() {
        let m = model()
        let mine = m.snapshot.activeSpace

        m.send(.createSpace(name: "Work", dataStoreId: "ds-work", ephemeral: false))
        let work = m.snapshot.activeSpace
        m.send(.openTab(space: work, url: nil, parent: nil))
        let dead = m.snapshot.activeTab!
        m.send(.navigationCommitted(tab: dead, url: "https://work.example/doc"))
        m.send(.pageProcessEnded(tab: dead))

        #expect(m.spaceResumeSummary(space: mine).tabs.isEmpty)
        #expect(m.spaceResumeSummary(space: work).tabs.map(\.id) == [dead])
    }

    /// A space that does not exist holds nothing. The core refuses the name
    /// with an empty summary rather than repairing it to "the one in front",
    /// and this asserts the bridge carries that refusal — a shell that
    /// substituted the active space here would be guessing.
    @Test("a space nobody has holds nothing")
    func aSpaceNobodyHasHoldsNothing() {
        let m = model()
        let summary = m.spaceResumeSummary(space: SpaceId.max)
        #expect(summary.tabs.isEmpty)
        #expect(summary.conversations.isEmpty)
    }

    // MARK: - Threads stopped on a tool

    /// A thread stopped on a tool nobody answered is offered with the question
    /// that started it — the one line the person wrote on purpose, and the only
    /// honest name for what they were doing.
    ///
    /// Staged the way it really happens: the server is adopted through the
    /// wiring a real connection reports with, the tool is listed, and the call
    /// arrives as the action a host reports. Anything less would be building
    /// the state by hand and then asserting the core can read back its own
    /// handwriting.
    @Test("a thread waiting on a tool is offered with the question that started it")
    func aThreadWaitingOnAToolIsOffered() throws {
        let m = model()
        let space = m.snapshot.activeSpace
        let page = m.snapshot.activeTab!
        m.send(.navigationCommitted(tab: page, url: "https://work.example/notes"))

        // The register only knows servers the host reported, and a listing for
        // one it does not is dropped on purpose. Reporting through the host's
        // own closure is the same road a real connection takes.
        let chat = try #require(m.engine.chat as? ConfiguredChatHost)
        let reported = try #require(chat.serverStateChanged)
        reported(
            "files",
            .ready(protocolVersion: "2025-06-18", serverName: "files", serverVersion: "1")
        )
        m.send(.toolsListed(server: "files", tools: [
            ReportedTool(
                name: "write_file",
                description: "Write a file.",
                inputSchemaJson: "{}",
                readOnlyHint: false,
                destructiveHint: true,
                openWorldHint: false
            ),
        ]))

        m.send(.openChat(about: .page(tab: page), ask: nil))
        // The page's tab goes, the way it does in a real session — and with it
        // the reason to hold the question for a capture nobody asked for.
        m.send(.closeTab(tab: page))
        let thread = m.conversations.last!.id

        m.send(.sendChatMessage(conversation: thread, text: "tidy the notes"))
        let reply = m.conversation(thread)!.messages.last!.id
        m.send(.chatReplyStarted(message: reply, model: "qwen3-coder:30b"))
        m.send(.chatToolCallRequested(
            message: reply,
            invocation: ToolInvocation(
                id: ToolCallId("call_1"),
                server: "files",
                tool: "write_file",
                arguments: "{}"
            )
        ))
        m.send(.chatReplyFinished(message: reply, stop: .toolCalls))

        let summary = m.spaceResumeSummary(space: space)
        #expect(summary.conversations.map(\.id) == [thread])
        #expect(summary.conversations.first?.openingQuestion == "tidy the notes")
        #expect(summary.conversations.first?.page == "https://work.example/notes")
    }

    /// A thread nobody is waiting on is not offered. The lens is for work that
    /// stopped mid-sentence; a plain exchange is a conversation somebody
    /// finished having.
    @Test("a thread nobody is waiting on is not offered")
    func aThreadNobodyIsWaitingOnIsNotOffered() {
        let m = model()
        let space = m.snapshot.activeSpace

        m.send(.openChat(about: .nothing, ask: nil))
        let thread = m.conversations.last!.id
        m.send(.sendChatMessage(conversation: thread, text: "hello"))
        let reply = m.conversation(thread)!.messages.last!.id
        m.send(.chatReplyStarted(message: reply, model: "qwen3-coder:30b"))
        m.send(.chatReplyDelta(message: reply, text: "hi"))
        m.send(.chatReplyFinished(message: reply, stop: .endOfTurn))

        #expect(m.spaceResumeSummary(space: space).conversations.isEmpty)
    }

    // MARK: - What acting on a row does

    /// A page row goes back to the tab it named — and nothing else, because
    /// reloading a page that died as it loads would be a loop the person never
    /// asked for (the offer is on the page it lands on, not made here).
    @Test("acting on a page row activates that tab")
    func actingOnAPageRowActivatesThatTab() {
        let m = model()
        let space = m.snapshot.activeSpace
        let dead = killActiveTab(of: m, at: "https://work.example/first")

        m.send(.openTab(space: nil, url: nil, parent: nil))
        #expect(m.snapshot.activeTab != dead)

        m.activate(dead)
        #expect(m.snapshot.activeTab == dead)
        // Still offered: going back to look is not the page coming back.
        #expect(m.spaceResumeSummary(space: space).tabs.map(\.id) == [dead])
    }

    /// A thread row puts that thread on screen, the same action the list of a
    /// page's conversations dispatches — so there is one way to open a thread,
    /// not one per surface that names one.
    @Test("acting on a thread row shows that thread")
    func actingOnAThreadRowShowsThatThread() {
        let m = model()

        m.send(.openChat(about: .nothing, ask: nil))
        let thread = m.conversations.last!.id
        m.send(.sendChatMessage(conversation: thread, text: "hello"))
        let reply = m.conversation(thread)!.messages.last!.id
        m.send(.chatReplyStarted(message: reply, model: "qwen3-coder:30b"))
        m.send(.chatReplyDelta(message: reply, text: "hi"))
        m.send(.chatReplyFinished(message: reply, stop: .endOfTurn))

        m.send(.openTab(space: nil, url: nil, parent: nil))
        m.send(.showConversation(conversation: thread))

        let shown = m.conversation(thread)
        #expect(shown != nil)
        // The tab in front addresses the thread, parsed by the core's own
        // fold rather than compared as a string: the lens row did what its
        // label said, and how the address is spelled is the core's sentence.
        let active = m.snapshot.activeTab!
        let address = m.snapshot.tabs
            .first { $0.id == active }?
            .url
            .flatMap { internalAddress(url: $0) }
        #expect(address == .chat(conversation: thread))
    }

    @Test("return dock names and separates its two kinds of loose end")
    func returnDockNamesAndSeparatesLooseEnds() throws {
        let m = model()
        let space = m.snapshot.activeSpace
        _ = killActiveTab(of: m, at: "https://work.example/first")

        m.send(.openTab(space: nil, url: nil, parent: nil))
        let page = try #require(m.snapshot.activeTab)
        m.send(.navigationCommitted(tab: page, url: "https://work.example/notes"))

        let chat = try #require(m.engine.chat as? ConfiguredChatHost)
        let reported = try #require(chat.serverStateChanged)
        reported(
            "files",
            .ready(protocolVersion: "2025-06-18", serverName: "files", serverVersion: "1")
        )
        m.send(.toolsListed(server: "files", tools: [
            ReportedTool(
                name: "write_file",
                description: "Write a file.",
                inputSchemaJson: "{}",
                readOnlyHint: false,
                destructiveHint: true,
                openWorldHint: false
            ),
        ]))

        m.send(.openChat(about: .page(tab: page), ask: nil))
        m.send(.closeTab(tab: page))
        let thread = try #require(m.conversations.last?.id)
        m.send(.sendChatMessage(conversation: thread, text: "finish the notes"))
        let reply = try #require(m.conversation(thread)?.messages.last?.id)
        m.send(.chatReplyStarted(message: reply, model: "qwen3-coder:30b"))
        m.send(.chatToolCallRequested(
            message: reply,
            invocation: ToolInvocation(
                id: ToolCallId("call_1"),
                server: "files",
                tool: "write_file",
                arguments: "{}"
            )
        ))
        m.send(.chatReplyFinished(message: reply, stop: .toolCalls))

        let groups = spaceLensGroups(for: m.spaceResumeSummary(space: space))

        #expect(spaceLensTitle == "BACK TO WORK")
        #expect(spaceLensCountLabel(total: 2) == "2 loose ends")
        #expect(groups == [.pages(count: 1), .requests(count: 1)])
    }
}
