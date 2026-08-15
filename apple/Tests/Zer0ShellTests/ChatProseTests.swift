import Foundation
import Testing
import Zer0Core

@testable import Zer0Shell

/// What the shell decides about a model's reply.
///
/// The reading of the Markdown is the core's and is tested there
/// (`crates/zer0-core/src/prose_tests.rs`) — without a window, which is the
/// point of it being there. What is left on this side is what the shell decides:
/// where a click goes, and how often the reply is read.
///
/// Everything else `ChatProse` does is appearance — the type ladder, the
/// rhythm, the code panel, the rails — and appearance is checked by looking, in
/// `ZZChatProseShots`.
@MainActor
@Suite("a reply set as prose")
struct ChatProseTests {
    // MARK: A link goes to a tab, not to another browser

    @Test("a link in a reply opens in zer0")
    func aLinkOpensInZer0() {
        let browser = BrowserModel(storagePath: nil)
        let before = browser.snapshot.tabs.count

        ChatProse.open(URL(string: "https://avelino.run/writing/nix")!, in: browser)

        let tabs = browser.snapshot.tabs
        #expect(tabs.count == before + 1)
        // `pendingUrl` rather than `url`: the tab has been opened and the load
        // asked for, and `url` is what came back from a navigation that has
        // committed. Nothing here is committing one.
        #expect(
            tabs.contains { ($0.pendingUrl ?? $0.url)?.contains("avelino.run/writing/nix") == true },
            "the link did not become a tab: \(tabs.map { $0.pendingUrl ?? $0.url })"
        )
    }

    /// The core refuses to hand over anything that is not `http` or `https`, so
    /// the shell is never asked to open one. Asserted here as well as in Rust
    /// because this is the side that would do the opening, and a regression on
    /// either side is the same click.
    @Test("a reply cannot hand the browser a scheme that runs something")
    func aReplyCannotHandOverAScheme() {
        for refused in [
            "[go](javascript:alert(1))",
            "[read](file:///etc/passwd)",
            "[settings](zer0://settings)",
        ] {
            let runs = proseBlocks(text: refused).flatMap(\.runs)
            #expect(!runs.isEmpty, "\(refused) produced nothing at all")
            #expect(
                runs.allSatisfy { $0.link == nil },
                "\(refused) arrived with something to click"
            )
        }

        let allowed = proseBlocks(text: "[go](https://avelino.run)").flatMap(\.runs)
        #expect(allowed.contains { $0.link != nil })
    }

    // MARK: Reading the same reply twice

    /// The cost that mattered was never the reply that is arriving — it is the
    /// twenty that are not. A transcript re-evaluates every message's body when
    /// any one of them changes, so a `ChatProse` with no memo re-reads every
    /// settled reply across the FFI on every delta of the last one.
    @Test("a reply that has not changed is not read again")
    func aSettledReplyIsNotReadAgain() {
        let reading = ProseReading()
        let reply = "# A reply\n\nWith **weight** and a `value`.\n\n- one\n- two\n"

        let first = reading.blocks(of: reply)
        #expect(reading.reads == 1)

        for _ in 0 ..< 50 {
            #expect(reading.blocks(of: reply) == first)
        }
        #expect(reading.reads == 1, "the reply was read \(reading.reads) times for one text")

        // And a reply that really did change is read.
        _ = reading.blocks(of: reply + "three")
        #expect(reading.reads == 2)
    }

    /// A reply arriving one delta at a time is read once per delta and no more.
    /// Cheap is the requirement; free is not on offer.
    @Test("an arriving reply is read once per delta")
    func anArrivingReplyIsReadOncePerDelta() {
        let reading = ProseReading()
        let reply = "Here is the answer:\n\n```sh\nls -la\n```\n"

        var deltas = 0
        for end in 1 ... reply.count {
            deltas += 1
            _ = reading.blocks(of: String(reply.prefix(end)))
            // Views redraw for reasons that have nothing to do with the text.
            _ = reading.blocks(of: String(reply.prefix(end)))
            _ = reading.blocks(of: String(reply.prefix(end)))
        }
        #expect(reading.reads == deltas)
    }

    // MARK: What a partly arrived reply already looks like

    /// The anti-strobe decision, asserted from the side that draws it: for every
    /// prefix of a reply that has opened a fence, the shell is already being
    /// handed a code block. The Rust suite proves the same property about the
    /// parse; this proves it about what actually crosses the FFI, which is what
    /// the view switches on.
    @Test("an unterminated fence reaches the shell as a code block")
    func anUnterminatedFenceReachesTheShellAsCode() {
        let reply = "Try:\n\n```swift\nlet x = 1\n```\n"
        let opened = reply.distance(from: reply.startIndex, to: reply.range(of: "```")!.upperBound)

        for end in opened ... reply.count {
            let blocks = proseBlocks(text: String(reply.prefix(end)))
            let isCode: (ProseBlock) -> Bool = { block in
                if case .code = block.kind { return true }
                return false
            }
            #expect(
                blocks.contains(where: isCode),
                "at \(end) characters the fence was not a code block: \(blocks)"
            )
        }
    }
}

private extension ProseBlock {
    var runs: [ProseRun] {
        switch kind {
        case let .paragraph(runs): runs
        case let .heading(_, runs): runs
        case let .item(_, runs): runs
        case .code, .rule: []
        }
    }
}
