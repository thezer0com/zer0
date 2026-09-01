import AppKit
import SwiftUI
import Testing
import Zer0Core

@testable import Zer0Shell

/// The Return Dock as it actually draws: dead pages and waiting threads under
/// the tab list, beside the space bar.
///
/// `SpaceLensTests` proves which rows exist and what acting on them does.
/// Nothing an assertion can say proves the section *reads* — that the heading
/// sits quietly under the list, that a lens row and a shelf row agree, that
/// the two detail lines tell the two kinds of loose end apart at a glance.
/// These boards are where that is looked at, in both themes, at the column's
/// ideal width.
///
/// **Opt-in.** `ZER0_SHOT=1 swift test --filter ZZSpaceLens`.
@MainActor
@Suite("ZZ return dock shots")
struct ZZSpaceLensShots {
    /// A chat host that does nothing, for the same reason `ZZChatPageShots`
    /// has one: the real host resolves configuration, finds none, and reports
    /// `NoProviderConfigured` from a `Task` at whatever moment the run loop
    /// happens to be pumped — which is every moment a board is settling. With
    /// the host silent the lens shows exactly the state staged below.
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

    @Test(
        "the return dock under a list of live tabs, light and dark",
        .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)
    )
    func theLensUnderLiveTabs() throws {
        let model = try staged()

        for dark in [false, true] {
            let shot = Shot(size: CGSize(width: Sidebar.Metrics.idealWidth, height: 620)) {
                Sidebar()
                    .environment(model)
                    .zer0Palette()
                    .preferredColorScheme(dark ? .dark : .light)
            }
            shot.hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            shot.settle()
            shot.write("return-dock-\(dark ? "dark" : "light")")
        }
    }

    /// A named space holding the work the lens exists for, built the way the
    /// browser really builds it: pages arrive as reported navigations, one
    /// dies, and a question stops on a tool nobody answered.
    private func staged() throws -> BrowserModel {
        let model = BrowserModel(storagePath: nil)
        model.createSpace(named: "Work")

        let news = try page(model, host: "news.ycombinator.com", title: "Hacker News")
        model.setKind(news, .favorite)
        _ = try page(
            model,
            host: "developer.mozilla.org",
            title: "WKWebView - Web APIs | MDN"
        )

        let dead = try page(
            model,
            host: "github.com",
            title: "avelino/zer0-browser: a WebKit browser with a Rust core"
        )
        model.send(.pageProcessEnded(tab: dead))

        // A server that is up and offers a tool, adopted through the same
        // wiring a real connection reports with — the register only knows
        // servers the host reported, and a listing for one it does not is
        // dropped on purpose.
        let chat = try #require(model.engine.chat as? ConfiguredChatHost)
        let reported = try #require(chat.serverStateChanged)
        reported(
            "files",
            .ready(protocolVersion: "2025-06-18", serverName: "files", serverVersion: "1")
        )
        model.send(.toolsListed(server: "files", tools: [
            ReportedTool(
                name: "write_file",
                description: "Write a file to disk.",
                inputSchemaJson: "{}",
                readOnlyHint: false,
                destructiveHint: true,
                openWorldHint: false
            ),
        ]))
        // From here the reply is staged by hand, so the host it would really
        // arrive through goes quiet rather than reporting a failure nobody
        // asked for onto the board.
        model.engine.chat = SilentChatHost()

        let anchor = try page(
            model,
            host: "figma.com",
            title: "zer0 — design system — Figma"
        )
        model.send(.openChat(about: .page(tab: anchor), ask: nil))
        // The page's tab goes, the way it does in a real session — and with it
        // the reason to hold the question for a capture nobody asked for.
        model.send(.closeTab(tab: anchor))
        let thread = try #require(model.conversations.last?.id)

        model.send(.sendChatMessage(
            conversation: thread,
            text: "audit the token spacing before Thursday's review"
        ))
        let reply = try #require(model.conversation(thread)?.messages.last?.id)
        model.send(.chatReplyStarted(message: reply, model: "qwen3-coder:30b"))
        model.send(.chatReplyDelta(
            message: reply,
            text: "I can write that up once I've looked at the file."
        ))
        model.send(.chatToolCallRequested(
            message: reply,
            invocation: ToolInvocation(
                id: ToolCallId("call_1"),
                server: "files",
                tool: "write_file",
                arguments: "{}"
            )
        ))
        model.send(.chatReplyFinished(message: reply, stop: .toolCalls))

        return model
    }

    /// One ordinary page: opened, committed, titled, finished.
    @discardableResult
    private func page(_ model: BrowserModel, host: String, title: String) throws -> TabId {
        model.send(.openTab(space: nil, url: nil, parent: nil))
        let tab = try #require(model.snapshot.activeTab)
        model.send(.navigationCommitted(tab: tab, url: "https://\(host)/"))
        model.send(.titleChanged(tab: tab, title: title))
        model.send(.navigationFinished(tab: tab))
        return tab
    }
}
