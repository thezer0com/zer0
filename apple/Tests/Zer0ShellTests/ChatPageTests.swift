import Testing
import Zer0Core

@testable import Zer0Shell

// MARK: - ADR-0070: the chat page is a canvas with a card on it

/// The three claims the chat page makes that are not appearance.
///
/// Everything else about this screen — that the composer floats, that a question
/// wears a pill and a reply wears nothing, that the greeting is a serif — is
/// look, and look is checked by rendering it and using your eyes
/// (`ZZChatPageShots`). These three are not look. Each is a sentence the
/// interface says out loud, and each has a way of becoming false that nobody
/// would see: a model name that no longer matches the request, a Stop button
/// that sends, a state that stops saying what happened.
@MainActor
struct ChatPageTests {
    private func provider(
        models: [String] = [],
        defaultModel: String? = nil
    ) -> ProviderConfig {
        ProviderConfig(
            id: "somewhere",
            name: "Somewhere",
            kind: .openAiCompatible,
            baseUrl: nil,
            credential: nil,
            models: models,
            defaultModel: defaultModel,
            enabled: true
        )
    }

    private func message(
        _ id: UInt64,
        _ role: MessageRole,
        state: MessageState = .complete,
        toolCalls: [ToolCall] = []
    ) -> Message {
        Message(
            id: MessageId(id),
            role: role,
            text: "…",
            page: nil,
            state: state,
            toolCalls: toolCalls,
            answers: nil,
            model: nil,
            createdAtMs: 0
        )
    }

    private func conversation(
        _ messages: [Message],
        awaitingPage: Bool = false
    ) -> Conversation {
        Conversation(
            id: ConversationId(1),
            scope: .space(space: SpaceId(1)),
            messages: messages,
            error: nil,
            awaitingPage: awaitingPage,
            createdAtMs: 0
        )
    }

    private func call(_ state: ToolCallState) -> ToolCall {
        ToolCall(
            invocation: ToolInvocation(
                id: ToolCallId("call_1"),
                server: "files",
                tool: "read_file",
                arguments: "{}"
            ),
            state: state,
            result: "",
            requestedAtMs: 0
        )
    }

    // MARK: - What the composer says will answer

    /// The composer's footer and the request are one sentence.
    ///
    /// `default_model` wins, and with none named the file's first entry does —
    /// which is what `ConfiguredChatHost` builds the request from, because it is
    /// this function. Reimplement either half and the footer starts naming a
    /// model the answer did not come from, which is a claim with nothing behind
    /// it and no symptom until somebody compares two outputs.
    @Test("the model named is the one the request will use")
    func theModelNamedIsTheOneTheRequestWillUse() {
        #expect(
            modelThatWillAnswer(provider(models: ["small", "large"], defaultModel: "large"))
                == "large"
        )
        #expect(modelThatWillAnswer(provider(models: ["small", "large"])) == "small")
    }

    /// Nothing configured names nothing, and a provider that lists no model at
    /// all names nothing either.
    ///
    /// The second is the one worth having: an entry exists, it is enabled, and
    /// it still cannot answer, because `resolved()` refuses rather than guessing
    /// a model id. A footer that filled that gap with the provider's own name
    /// would be printing something no request will ever carry.
    @Test("nothing set up names no model")
    func nothingSetUpNamesNoModel() {
        #expect(modelThatWillAnswer(nil) == nil)
        #expect(modelThatWillAnswer(provider()) == nil)
    }

    // MARK: - Which control is in the one slot

    /// Send and Stop share a slot, and `conversationIsBusy` is the whole of what
    /// picks between them.
    ///
    /// Three ways to be busy, because there are three ways for a question to be
    /// in flight and only one of them is text arriving. Drop the tool clause and
    /// the composer offers Send while a tool is still running; drop
    /// `awaitingPage` and it offers Send while the browser is still reading the
    /// page the question is about.
    @Test("the slot is Stop for every way an answer can be in flight")
    func theSlotIsStopForEveryWayAnAnswerCanBeInFlight() {
        #expect(conversationIsBusy(conversation([])) == false)
        #expect(
            conversationIsBusy(conversation([message(1, .user), message(2, .assistant)])) == false
        )

        #expect(conversationIsBusy(conversation([], awaitingPage: true)))
        #expect(conversationIsBusy(conversation([message(1, .assistant, state: .streaming)])))
        #expect(
            conversationIsBusy(
                conversation([message(1, .assistant, toolCalls: [call(.running)])])
            )
        )

        // A call waiting on a person is not the browser being busy — the person
        // is, and the composer stays usable while they decide.
        #expect(
            conversationIsBusy(
                conversation([message(1, .assistant, toolCalls: [call(.awaitingConsent)])])
            ) == false
        )
    }

    // MARK: - What a message says about itself

    /// The four states that are not "it finished" each keep a sentence, and the
    /// two ordinary ones stay silent.
    ///
    /// This is ADR-0018 at message scale. A cancelled answer, a failed one, one
    /// the process died in the middle of and one zer0 cut short all end the same
    /// way on screen — the text simply stops — so the notice is the only thing
    /// that separates four different facts from a model that finished early.
    /// Delete any branch and the screen goes on looking finished while meaning
    /// something else.
    @Test("every state that did not finish says so, and the ones that did stay quiet")
    func everyStateThatDidNotFinishSaysSo() {
        #expect(messageNotice(for: .complete) == nil)
        #expect(messageNotice(for: .streaming) == nil)

        for state: MessageState in [.cancelled, .failed, .interrupted, .truncated] {
            let notice = messageNotice(for: state)
            #expect(notice != nil, "\(state) has nothing to say about itself")
            #expect(notice?.text.isEmpty == false)
            #expect(notice?.symbol.isEmpty == false)
        }

        // Four different facts, so four different sentences. One reused across
        // two states would pass every check above and still tell somebody their
        // answer was stopped when the process died under it.
        let said = [MessageState.cancelled, .failed, .interrupted, .truncated]
            .compactMap { messageNotice(for: $0)?.text }
        #expect(Set(said).count == 4)
    }

    // MARK: - How the page is named

    /// Nobody is ever shown a percent-encoded address.
    ///
    /// The real one that started this: a Chrome Web Store listing whose path
    /// carries an en dash, printed as `%E2%80%93` inside a sentence somebody was
    /// meant to read, wrapped over three lines of the emptiest screen in the
    /// browser. The decode is display-only — the host is taken separately and is
    /// never decoded — and the exact address is a tooltip away.
    @Test("a shortened address is readable and never percent-encoded")
    func aShortenedAddressIsReadableAndNeverPercentEncoded() {
        let listing = "https://chromewebstore.google.com/detail/"
            + "1password-%E2%80%93-password-mana/aeblfdkhhhdcdjpifhhbdiojplfjncoa"

        // Asserted whole rather than by `contains`, and that is the point of
        // the test rather than a matter of style. **Decoding is not
        // prettifying.** The slug really is `1password-–-password-mana` —
        // hyphen, en dash, hyphen — and a shortener that tidied those hyphens
        // into spaces would put a string on screen that is not the address the
        // page has, which is the same ADR-0018 failure as `%E2%80%93` wearing
        // better clothes. Only the scheme and a `www.` may go; every other
        // character survives, and the truncation that does happen is the view's
        // `.middle`, where a person can see it happening.
        #expect(
            shortPage(listing) == "chromewebstore.google.com/detail/"
                + "1password-–-password-mana/aeblfdkhhhdcdjpifhhbdiojplfjncoa"
        )
        #expect(!shortPage(listing).contains("%"), "still percent-encoded")

        // The scheme and a `www.` go; nothing else about the address does.
        #expect(shortPage("https://www.rust-lang.org/learn") == "rust-lang.org/learn")
        #expect(shortPage("https://example.com/") == "example.com")
        #expect(shortPage("https://example.com/a?b=c%20d") == "example.com/a?b=c d")
    }

    /// The site, folded the same way the core folds it when it names a
    /// conversation after its page — so a thread's row in the sidebar and the
    /// screen it opens spell one site one way.
    @Test("a site is named without the www nobody reads")
    func aSiteIsNamedWithoutTheWwwNobodyReads() {
        #expect(siteName("https://www.rust-lang.org/learn") == "rust-lang.org")
        #expect(siteName("https://github.com/avelino/zer0") == "github.com")
        #expect(siteName("file:///Users/a/notes.md") == nil)
    }

    // MARK: - Somewhere to start

    /// The empty screen offers questions, and it offers none about a page
    /// nothing will be read from.
    ///
    /// Both halves matter. Without the first this screen is a blank field, which
    /// is the thing anybody can already get from a website. Without the second
    /// it invites somebody to press "Summarise this page" two lines under a
    /// sentence saying the page is not open and nothing will be read — the same
    /// screen contradicting itself, which is the ADR-0018 failure in its most
    /// embarrassing form.
    @Test("the empty screen offers a way in, and offers none for a page that will not be read")
    func theEmptyScreenOffersAWayIn() {
        let offered = startingPoints(pageWillBeRead: true)
        #expect(offered.count >= 2, "an empty field is not an offer")
        #expect(Set(offered).count == offered.count, "the same question twice")
        #expect(offered.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty })

        #expect(
            startingPoints(pageWillBeRead: false).isEmpty,
            "offered a question about a page nothing will be read from"
        )
    }
}
