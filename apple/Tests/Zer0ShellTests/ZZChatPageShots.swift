import AppKit
import SwiftUI
import Testing
import Zer0Core

@testable import Zer0Shell

/// Looking at the chat page.
///
/// A harness, not a test of behaviour, and opt-in behind `ZER0_SHOT=1` like
/// every other `ZZ*` file — these pump the run loop and would starve the timing
/// suites (`scripts/check.sh` refuses an ungated case).
///
/// **An offscreen render is not the running application.** It is drawn into a
/// window that never reaches a display, it cannot become key, and every accent
/// and prominent button therefore paints grey unless the environment is forced.
/// It catches layout, hierarchy and spacing; it does not settle whether the
/// screen is beautiful in the app.
@MainActor
@Suite("chat page shots")
struct ZZChatPageShots {
    private func model() -> BrowserModel {
        BrowserModel(storagePath: nil)
    }

    /// A model whose chat host does nothing at all.
    ///
    /// The real one resolves configuration, finds none, and reports
    /// `NoProviderConfigured` from a `Task` — so a transcript staged by sending
    /// actions grows an error notice at whatever moment the run loop happens to
    /// be pumped. That is a flaky screenshot and, worse, one where a real defect
    /// would look like the harness misbehaving again. With the host silent the
    /// page shows exactly the messages that were fed to it.
    private final class SilentChatHost: ChatHost {
        func startReply(
            conversation _: ConversationId,
            message _: MessageId,
            transcript _: [Message],
            tools _: [ToolDescriptor]
        ) {}
        func cancelReply(message _: MessageId) {}
        func runToolCall(conversation _: ConversationId, invocation _: ToolInvocation) {}
        func cancelToolCall(call _: ToolCallId) {}
        func listTools(server _: String?) {}
    }

    private func staged() -> BrowserModel {
        let browser = model()
        browser.engine.chat = SilentChatHost()
        return browser
    }

    /// A thread with a real exchange in it, built the way one really is built:
    /// the question goes through the core, and the reply arrives as the actions
    /// a host reports.
    private func exchange(
        _ browser: BrowserModel,
        _ turns: [(ask: String, reply: String)],
        stop: ReplyStop = .endOfTurn
    ) -> (tab: TabId, thread: ConversationId) {
        browser.perform(.openChat)
        let tab = browser.snapshot.activeTab!
        let thread = browser.conversations.last!.id

        for turn in turns {
            browser.send(.sendChatMessage(conversation: thread, text: turn.ask))
            let reply = browser.conversation(thread)!.messages.last!.id
            browser.send(.chatReplyStarted(message: reply, model: "qwen3-coder:30b"))
            browser.send(.chatReplyDelta(message: reply, text: turn.reply))
            browser.send(.chatReplyFinished(message: reply, stop: stop))
        }
        return (tab, thread)
    }

    /// The windows this suite photographs the page in, and there are two of them
    /// on purpose.
    ///
    /// **The screen this replaced photographed beautifully and was ugly in the
    /// app**, and the reason was here: every shot was taken at nine hundred by
    /// six hundred and twenty, which is about twice the width of the text column
    /// and near enough to it that nothing looked stranded. The author runs a
    /// window around sixteen hundred by two thousand. At that size the same page
    /// had roughly fifteen hundred points of nothing between the newest reply
    /// and the field below it, and a rule three times the width of the row it
    /// was separating. Neither is visible at 900×620. **A view photographed at
    /// its own width is not a screen that has been looked at.**
    ///
    /// So: the size the author actually uses, and the smallest one the app will
    /// open at, because a page that is only good at one of them is not done.
    /// Both are the *detail* area rather than the whole window — the sidebar
    /// takes about 260 points off the width and the title bar a little height.
    private static let wide = CGSize(width: 1340, height: 1960)
    private static let narrow = CGSize(width: 600, height: 520)

    /// Every scenario is looked at in both, and the file name says which.
    private static let windows: [(name: String, size: CGSize)] = [
        ("wide", wide), ("narrow", narrow),
    ]

    /// The one the motion and geometry probes use, where the defect lived.
    private static let window = wide

    /// How long to let the page settle before photographing it.
    ///
    /// **Not padding, and not politeness to the run loop.** The composer travels
    /// on `Curve.entrance` when a transcript appears, and a shot taken at t=0
    /// catches that transition running: every wide transcript shot in this suite
    /// carried a second, half-faded composer at the top of the window — the
    /// outgoing half of the crossfade — which reads exactly like a real layout
    /// defect and is not one. `theComposerTravels` already advanced for its own
    /// reasons and so never showed it.
    ///
    /// A person looks at a screen that has arrived. So does this. 0.4 is over
    /// the curve's own response of 0.34.
    private static let settled: Double = 0.4

    /// The page, at a fixed size.
    ///
    /// **The size is not decoration.** `NSHostingView` grows to whatever its
    /// content asks for, and this page asks for nothing in particular, so
    /// without a frame it renders at its natural height — which made a 620pt
    /// window produce a 1074pt image, and made the composer's distance from the
    /// bottom edge the same in both states. The first version of
    /// `theComposerTravels` reported "it did not travel" for exactly that
    /// reason, and it was the instrument, not the animation.
    private func chatPage(
        _ browser: BrowserModel,
        _ thread: ConversationId?,
        _ tab: TabId,
        dark: Bool,
        size: CGSize = ZZChatPageShots.window
    ) -> some View {
        ChatPage(tab: tab, addressed: thread)
            .frame(width: size.width, height: size.height)
            .environment(browser)
            .zer0Palette()
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.controlActiveState, .key)
    }

    @Test(
        "the empty state, light and dark",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    func theEmptyState() {
        let browser = model()
        let tab = browser.snapshot.activeTab!

        for window in ZZChatPageShots.windows {
            for dark in [false, true] {
                let shot = Shot(size: window.size) {
                    chatPage(browser, nil, tab, dark: dark, size: window.size)
                }
                shot.advance(ZZChatPageShots.settled)
                shot.write("chat-empty-\(window.name)-\(dark ? "dark" : "light")")
            }
        }
    }

    /// **The screen almost everybody meets first**, and the one nothing in this
    /// suite had ever photographed.
    ///
    /// `theEmptyState` stages a browser with nothing committed, so its thread is
    /// about no page — which is the *rarer* of the two empty states, reached
    /// only by typing a question into the command bar. The ordinary one is ⌘E on
    /// a page you are reading, and everything that makes this screen worth
    /// opening lives there: the page named by its icon, its title and its site,
    /// and the questions offered about it. Photographing only the other one is
    /// the same mistake ADR-0076 found in `pageContext` — a view looked at only
    /// by reading its source.
    ///
    /// The title comes from a real `TitleChanged`, because that is where it
    /// comes from in the app, and a staged thread with no title would photograph
    /// the fallback rather than the case.
    @Test(
        "an empty conversation about the page in front of you",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    func anEmptyConversationAboutThePage() {
        // The real listing, percent-encoding and all: it is the address that
        // produced three wrapped lines of body copy, and the only way to see
        // that it does not any more is to hand the screen the same one.
        let listing = "https://chromewebstore.google.com/detail/"
            + "1password-%E2%80%93-password-mana/aeblfdkhhhdcdjpifhhbdiojplfjncoa"

        for window in ZZChatPageShots.windows {
            for dark in [false, true] {
                let browser = staged()
                let page = browser.snapshot.activeTab!
                browser.send(.navigationCommitted(tab: page, url: listing))
                browser.send(
                    .titleChanged(tab: page, title: "1Password – Password Manager")
                )
                browser.perform(.openChat)
                let tab = browser.snapshot.activeTab!
                let thread = browser.conversations.last!.id

                let shot = Shot(size: window.size) {
                    chatPage(browser, thread, tab, dark: dark, size: window.size)
                }
                shot.advance(ZZChatPageShots.settled)
                shot.write("chat-empty-anchored-\(window.name)-\(dark ? "dark" : "light")")
            }
        }
    }

    /// The same screen for a thread whose page is closed, which is what a
    /// conversation revisited a week later opens on.
    ///
    /// Nothing will be read for the next question, the screen says so, and the
    /// starting points are gone — because offering "Summarise this page" two
    /// lines under that sentence is one screen contradicting itself, and this is
    /// where you can see whether it does.
    @Test(
        "an empty conversation whose page is not open",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    func anEmptyConversationWhosePageIsNotOpen() {
        for window in ZZChatPageShots.windows {
            for dark in [false, true] {
                let browser = staged()
                let page = browser.snapshot.activeTab!
                browser.send(
                    .navigationCommitted(tab: page, url: "https://avelino.run/writing/nix")
                )
                browser.send(.titleChanged(tab: page, title: "Nix, a year in"))
                browser.perform(.openChat)
                let tab = browser.snapshot.activeTab!
                let thread = browser.conversations.last!.id
                browser.send(.closeTab(tab: page))

                let shot = Shot(size: window.size) {
                    chatPage(browser, thread, tab, dark: dark, size: window.size)
                }
                shot.advance(ZZChatPageShots.settled)
                shot.write("chat-empty-closed-\(window.name)-\(dark ? "dark" : "light")")
            }
        }
    }

    /// Two questions and two answers: the screen the redesign is judged on,
    /// because it is where "a question wears a shape and an answer wears none"
    /// either reads at a glance or does not.
    @Test(
        "a short exchange, light and dark",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    func aShortExchange() {
        for window in ZZChatPageShots.windows {
            for dark in [false, true] {
            let browser = staged()
            let staging = exchange(browser, [
                (
                    ask: "what does WAL mode actually buy us here",
                    reply: "Readers stop blocking on the writer. With the rollback journal "
                        + "every read takes a shared lock the writer has to wait for; with "
                        + "WAL the writer appends to a separate file and readers carry on "
                        + "against the last committed snapshot."
                ),
                (
                    ask: "and the cost?",
                    reply: "A second file to keep beside the database, and a checkpoint that "
                        + "has to happen somewhere."
                ),
            ])
            let shot = Shot(size: window.size) {
                chatPage(browser, staging.thread, staging.tab, dark: dark, size: window.size)
            }
            shot.advance(ZZChatPageShots.settled)
            shot.write("chat-exchange-\(window.name)-\(dark ? "dark" : "light")")
            }
        }
    }

    /// One long reply, which is what the column measure is actually for. 680
    /// points was a hundred and twenty-one characters of the type this is set
    /// in; this is the shot that says whether 450 reads.
    @Test(
        "a long reply, light and dark",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    func aLongReply() {
        let reply = """
        The reducer is pure, so every question about what the browser did next \
        has one answer and it is in a function you can call from a test. Nothing \
        in it knows what a WKWebView is.

        That has a cost worth naming. A command that needs the engine cannot \
        simply reach for it: it becomes an effect the shell performs and an \
        action the shell sends back, which is two more moving parts than calling \
        a method would have been. What it buys is that the whole of the browser's \
        behaviour can be replayed without a window, and that a second platform is \
        a new host rather than a second opinion.

        The place this is felt most is navigation. The core decides that a URL \
        belongs to a space, that opening it in another one reopens it where it \
        lives rather than moving it, and that a tab closed by accident comes back \
        with its history intact — none of which the engine has an opinion about.
        """
        for window in ZZChatPageShots.windows {
            for dark in [false, true] {
                let browser = staged()
                let staging = exchange(browser, [
                    (ask: "why is the core a pure reducer", reply: reply),
                ])
                let shot = Shot(size: window.size) {
                    chatPage(browser, staging.thread, staging.tab, dark: dark, size: window.size)
                }
                shot.advance(ZZChatPageShots.settled)
                shot.write("chat-long-reply-\(window.name)-\(dark ? "dark" : "light")")
            }
        }
    }

    /// A reply that asked to run something, in the page rather than on its own.
    ///
    /// What matters here is that the call, the notice under it and the result
    /// card still read as belonging to the answer above them now that none of
    /// them has a rail — the gutter used to be what tied them together, and
    /// what does it now is the gap: `Space.loose` inside the exchange against
    /// `Space.section` before the next question.
    @Test(
        "a reply with a tool call, light and dark",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    func aReplyWithAToolCall() {
        for window in ZZChatPageShots.windows {
            for dark in [false, true] {
            let browser = staged()
            // **This does not produce a consent card, and the render is what
            // said so.** The core refuses a tool nobody *configured* without
            // asking anybody (ADR-0049), and reporting one is not configuring
            // one — configuration is a file, and a harness that wrote to it
            // would be writing to somebody's real `~/.config`. So what this
            // photographs is the refusal path: the call, the "was not run"
            // notice, and the result card saying why. That is the state most
            // people will actually meet, and the consent card it is not is
            // photographed on its own by `aToolCallWaiting`.
            browser.send(.toolsListed(server: "files", tools: [
                ReportedTool(
                    name: "write_file",
                    description: "Write a file to disk.",
                    inputSchemaJson: "{}",
                    readOnlyHint: false,
                    destructiveHint: true,
                    openWorldHint: false
                ),
            ]))
            browser.perform(.openChat)
            let tab = browser.snapshot.activeTab!
            let thread = browser.conversations.last!.id
            browser.send(.sendChatMessage(conversation: thread, text: "write the notes up"))
            let reply = browser.conversation(thread)!.messages.last!.id
            browser.send(.chatReplyStarted(message: reply, model: "qwen3-coder:30b"))
            browser.send(.chatReplyDelta(
                message: reply,
                text: "I can put that in a file for you."
            ))
            browser.send(.chatToolCallRequested(
                message: reply,
                invocation: ToolInvocation(
                    id: ToolCallId("call_1"),
                    server: "files",
                    tool: "write_file",
                    arguments: """
                    {
                      "path": "~/Documents/notes/quarterly.md",
                      "contents": "# Quarterly\\n\\nRevenue is up."
                    }
                    """
                )
            ))
            browser.send(.chatReplyFinished(message: reply, stop: .toolCalls))

            let shot = Shot(size: window.size) {
                chatPage(browser, thread, tab, dark: dark, size: window.size)
            }
            shot.advance(ZZChatPageShots.settled)
            shot.write("chat-tool-call-\(window.name)-\(dark ? "dark" : "light")")
            }
        }
    }

    /// A thread anchored to a page, with the page really attached to a question.
    ///
    /// **Nothing else in this suite renders a `pageContext` message**, which is
    /// how that row spent a day as the heaviest object on the screen without
    /// anybody seeing it: `exchange(_:_:)` builds threads about no page, and
    /// `theThreadsAboutOnePage` never gets past the greeting. So the row was
    /// only ever looked at by reading its source. This stages the real path —
    /// the core asks for the page, the host answers, the question goes out —
    /// and photographs what a person actually meets.
    @Test(
        "a thread anchored to a page",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    func aThreadAnchoredToAPage() {
        for window in ZZChatPageShots.windows {
            for dark in [false, true] {
                let browser = staged()
                let page = browser.snapshot.activeTab!
                browser.send(
                    .navigationCommitted(
                        tab: page,
                        url: "https://github.com/avelino/zer0/pull/412/files"
                    )
                )
                browser.perform(.openChat)
                let tab = browser.snapshot.activeTab!
                let thread = browser.conversations.last!.id

                browser.send(
                    .sendChatMessage(
                        conversation: thread,
                        text: "does the migration in here roll back cleanly"
                    )
                )
                // The core holds the question until the browser answers with the
                // page, so this is not decoration — without it the transcript
                // never gets a reply to draw.
                browser.send(.pageContextCaptured(
                    conversation: thread,
                    url: "https://github.com/avelino/zer0/pull/412/files",
                    title: "Move the store behind a trait by avelino · Pull Request #412",
                    text: "the words on the page"
                ))
                let reply = browser.conversation(thread)!.messages.last!.id
                browser.send(.chatReplyStarted(message: reply, model: "qwen3-coder:30b"))
                browser.send(.chatReplyDelta(
                    message: reply,
                    text: "It does, and the down migration is the reason. Every step in "
                        + "this one is additive — a new table, a new column with a default "
                        + "— so nothing that already exists is rewritten, and rolling back "
                        + "drops what was added rather than trying to reconstruct what was "
                        + "replaced.\n\nThe one to watch is the backfill, which is a "
                        + "separate task rather than part of the migration. Rolling the "
                        + "schema back does not undo it."
                ))
                browser.send(.chatReplyFinished(message: reply, stop: .endOfTurn))

                let shot = Shot(size: window.size) {
                    chatPage(browser, thread, tab, dark: dark, size: window.size)
                }
                shot.advance(ZZChatPageShots.settled)
                shot.write("chat-anchored-\(window.name)-\(dark ? "dark" : "light")")
            }
        }
    }

    /// The four things a message can say about itself, side by side.
    ///
    /// Staged as values rather than driven through the model, because
    /// `interrupted` only ever arrives from a session restored after a crash and
    /// there is no way to produce one here. These four are the reason an answer
    /// that stopped does not read as an answer that finished, so they are worth
    /// looking at even where the route to them is synthetic.
    @Test(
        "what a message says about itself",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    func whatAMessageSaysAboutItself() {
        let browser = model()
        let states: [(MessageState, String)] = [
            (.cancelled, "You stopped this one part of the way through."),
            (.failed, "The connection dropped while this was arriving."),
            (.interrupted, "zer0 was quit while this was still coming in."),
            (.truncated, "This one ran past what the thread will hold, and"),
        ]

        for dark in [false, true] {
            let size = CGSize(width: 720, height: 420)
            let shot = Shot(size: size) {
                VStack(alignment: .leading, spacing: Design.Space.section) {
                    ForEach(Array(states.enumerated()), id: \.offset) { index, each in
                        MessageRow(
                            message: Message(
                                id: MessageId(UInt64(index)),
                                role: .assistant,
                                text: each.1,
                                page: nil,
                                state: each.0,
                                toolCalls: [],
                                answers: nil,
                                model: nil,
                                createdAtMs: 0
                            ),
                            conversation: ConversationId(1)
                        )
                    }
                    Spacer()
                }
                .padding(Design.Space.loose)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .background(.background)
                .environment(browser)
                .zer0Palette()
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.controlActiveState, .key)
            }
            shot.advance(ZZChatPageShots.settled)
            shot.write("chat-notices-\(dark ? "dark" : "light")")
        }
    }

    /// Does the composer actually travel from the middle of the canvas to the
    /// bottom, or does it cut?
    ///
    /// Measured the way `ZZMotionShots` established works: this is a **layout**
    /// change, which pixels can see — a transform would be invisible to both a
    /// bitmap and `onGeometryChange`, and reading "it did not move" off one of
    /// those would say nothing at all. The number is the lowest row of ink in a
    /// narrow column down the middle of the window, which below the composer is
    /// background in both states, so it is the card's bottom edge and nothing
    /// else.
    @Test(
        "the composer travels to the bottom rather than cutting there",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    func theComposerTravels() {
        let browser = staged()
        browser.perform(.openChat)
        let tab = browser.snapshot.activeTab!
        let thread = browser.conversations.last!.id

        let size = ZZChatPageShots.window
        let shot = Shot(size: size) {
            chatPage(browser, thread, tab, dark: false)
        }
        shot.advance(0.4)
        shot.write("chat-composer-centred")

        let background = shot.frame().colour(x: 12, y: Int(size.height * 2) - 12)
        // A strip eight points wide down the middle of the window, in points.
        //
        // **Only the strip is rasterised**, because sampling the whole window
        // sixty times costs more wall clock than the animation lasts, and the
        // travel then reads as two positions — which is what a cut reads as.
        // See `Shot.frame(in:)`. The middle rather than the right-hand edge: the
        // column is 450 points centred, so at this width the old strip at
        // `width - 12` was inside it only by arithmetic that stops being true
        // the moment either number changes.
        //
        // Below the composer this strip is background in both states, so the
        // lowest ink in it is the card's bottom edge and nothing else.
        let strip = CGRect(x: size.width / 2 - 4, y: 0, width: 8, height: size.height)

        func bottomEdge() -> CGFloat? {
            let rep = shot.frame(in: strip)
            let whole = CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)
            return rep.ink(in: whole, unlike: background, tolerance: 0.10)?.maxY
        }

        let before = bottomEdge()
        browser.send(.sendChatMessage(conversation: thread, text: "does this move"))

        var seen: [CGFloat] = []
        for _ in 0 ..< 60 {
            shot.advance(0.006)
            if let edge = bottomEdge(), seen.last != edge { seen.append(edge) }
        }
        shot.write("chat-composer-settled")

        print("composer bottom edge, before: \(before.map { Int($0) } as Any)")
        print("composer bottom edge per distinct frame: \(seen.map { Int($0) })")
        #expect(
            seen.count >= 3,
            "the composer was at \(seen.count) position(s): it did not travel, it cut"
        )
    }

    @Test(
        "every error the conversation can end on",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    func everyError() {
        let browser = model()
        let kinds: [ChatErrorKind] = [
            .noProviderConfigured, .notAuthorised, .rateLimited, .offline,
            .connectionFailed, .timeout, .contextTooLong, .malformedResponse,
            .providerRefused, .toolUnavailable, .toolFailed, .toolLoop, .unknown,
        ]

        for dark in [false, true] {
            let shot = Shot(size: CGSize(width: 720, height: 1500)) {
                ScrollView {
                    VStack(alignment: .leading, spacing: Design.Space.regular) {
                        ForEach(Array(kinds.enumerated()), id: \.offset) { _, kind in
                            ChatErrorNotice(
                                error: ChatError(kind: kind, detail: "the host said something"),
                                conversation: ConversationId(1)
                            )
                        }
                    }
                    .padding(Design.Space.loose)
                }
                .environment(browser)
                .zer0Palette()
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.controlActiveState, .key)
            }
            shot.advance(ZZChatPageShots.settled)
            shot.write("chat-errors-\(dark ? "dark" : "light")")
        }
    }

    /// A page that has been talked to more than once, which is the screen
    /// anchoring is judged on: it is where somebody chooses between three
    /// conversations they had with one page and has to be able to tell them
    /// apart at a glance.
    @Test(
        "the threads about one page",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    func theThreadsAboutOnePage() {
        let browser = model()
        let page = browser.snapshot.activeTab!
        browser.send(
            .navigationCommitted(
                tab: page,
                url: "https://github.com/avelino/zer0/pull/412"
            )
        )
        browser.perform(.openChat)
        let first = browser.conversations.last!.id
        browser.send(.sendChatMessage(conversation: first, text: "what changed in this pull request"))
        browser.send(.startAnotherConversation(like: first))
        let second = browser.conversations.last!.id
        browser.send(
            .sendChatMessage(
                conversation: second,
                text: "is the migration in here reversible, and what happens if it fails halfway"
            )
        )
        browser.send(.startAnotherConversation(like: first))

        let chatTab = browser.snapshot.activeTab!
        let showing = browser.conversations.last!.id

        for window in ZZChatPageShots.windows {
            for dark in [false, true] {
                let shot = Shot(size: window.size) {
                    chatPage(browser, showing, chatTab, dark: dark, size: window.size)
                }
                shot.advance(ZZChatPageShots.settled)
                shot.write("chat-threads-\(window.name)-\(dark ? "dark" : "light")")
            }
        }

        for dark in [false, true] {
            let list = Shot(size: ZZChatPageShots.wide) {
                ThreadList(
                    current: showing,
                    threads: browser.conversations(about: showing),
                    page: "https://github.com/avelino/zer0/pull/412",
                    open: { _ in },
                    start: {},
                    dismiss: {}
                )
                .background(.background)
                .environment(browser)
                .zer0Palette()
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.controlActiveState, .key)
            }
            list.write("chat-thread-list-\(dark ? "dark" : "light")")
        }
    }

    /// A thread whose page is not open, which is what a conversation revisited
    /// a week later looks like. The screen has to say so rather than promising
    /// to read a page that is not there.
    @Test(
        "a thread whose page is not open",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    func aThreadWhosePageIsNotOpen() {
        let browser = model()
        let page = browser.snapshot.activeTab!
        browser.send(.navigationCommitted(tab: page, url: "https://avelino.run/writing/nix"))
        browser.perform(.openChat)
        let thread = browser.conversations.last!.id
        browser.send(.sendChatMessage(conversation: thread, text: "summarise this"))
        let chatTab = browser.snapshot.activeTab!
        browser.send(.closeTab(tab: page))

        for window in ZZChatPageShots.windows {
            for dark in [false, true] {
                let shot = Shot(size: window.size) {
                    chatPage(browser, thread, chatTab, dark: dark, size: window.size)
                }
                shot.advance(ZZChatPageShots.settled)
                shot.write("chat-page-gone-\(window.name)-\(dark ? "dark" : "light")")
            }
        }
    }

    /// The consent card, which is the screen this feature is judged on: it is
    /// where somebody decides whether a model may act on their machine.
    @Test(
        "a tool call waiting on somebody",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    func aToolCallWaiting() {
        let browser = model()
        let call = ToolCall(
            invocation: ToolInvocation(
                id: ToolCallId("call_1"),
                server: "files",
                tool: "write_file",
                arguments: """
                {
                  "path": "~/Documents/notes/quarterly.md",
                  "contents": "# Quarterly\\n\\nRevenue is up."
                }
                """
            ),
            state: .awaitingConsent,
            result: "",
            requestedAtMs: 0
        )

        for dark in [false, true] {
            let shot = Shot(size: CGSize(width: 720, height: 460)) {
                VStack {
                    ToolCallRow(call: call, conversation: ConversationId(1))
                    Spacer()
                }
                .padding(Design.Space.loose)
                .environment(browser)
                .zer0Palette()
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.controlActiveState, .key)
            }
            shot.advance(ZZChatPageShots.settled)
            shot.write("chat-consent-\(dark ? "dark" : "light")")
        }
    }
}
