import SwiftUI
import Zer0Core

/// A column of prose, not the width of the window. A reply set across a
/// maximised browser is a line nobody can track back to the start of.
///
/// **Measured, not estimated.** This was 680 and the comment here claimed that
/// was "about ninety characters at the body size". It was not: the reply is set
/// in `Design.Text.detail`, which resolves to `.callout` — 12pt, whose average
/// advance over a paragraph of ordinary English measures 5.61pt. 680 is a
/// hundred and twenty-one characters, roughly double the measure prose is read
/// at, and the ninety would only have been true at `.title2`. That is the
/// correction; the decision it supports is new.
///
/// 450 is eighty characters of the type the reply is actually set in, and
/// seventy-five of `.body` if it ever moves there. Eighty rather than the
/// classical sixty-six because a reply carries fenced code and tables, and a
/// column that wraps every code line has traded one reading problem for
/// another.
///
/// Shared by the transcript and by the list of threads, because those are two
/// screens of one page: a different measure on each would read as the content
/// jumping sideways when you move between them.
private let chatColumn: CGFloat = 450

/// The site as a person says it out loud: the host, without the `www.` nobody
/// reads. `nil` for an address with no site to name — a `file://` page is
/// anchorable and has none.
///
/// The same fold the core makes when it names a conversation after its page
/// (`internal_url::conversation_title`), so a thread's row in the sidebar and
/// the page it is about spell one site one way.
func siteName(_ page: PageAnchor) -> String? {
    guard let host = URL(string: page)?.host() else { return nil }
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
}

/// The page as a person would say it: the site, and the path when there is one
/// worth reading. Only the scheme and a `www.` are dropped, so what is left is
/// still the address and not a description of it.
///
/// **The path is decoded.** It used to be printed as it travels, which put
/// `1password-%E2%80%93-password-mana` on screen in a sentence somebody was
/// meant to read — three lines of it, wrapped, on the emptiest screen in the
/// browser. `%E2%80%93` is an en dash and nobody should ever be shown the
/// spelling. Decoding is for display only and the exact address is a tooltip
/// away here and verbatim on `ThreadList`; this is a label about a page, never
/// an address bar, so the usual objection to showing a decoded address — that
/// it can be dressed up to look like somewhere else — has nothing to work with:
/// the host is taken separately and is never decoded.
///
/// One function rather than one per view, because the subject bar and the
/// per-question line inside the transcript are the same claim about the same
/// page, and two spellings of it would drift into two different-looking
/// addresses on one screen.
func shortPage(_ page: PageAnchor) -> String {
    guard let url = URL(string: page), let name = siteName(page) else { return page }
    let path = url.path(percentEncoded: false)
    let query = url.query(percentEncoded: false).map { "?\($0)" } ?? ""
    return name + (path == "/" ? "" : path) + query
}

/// A conversation, as a page.
///
/// The whole screen belongs to the thread: this is a tab, and a tab is the
/// browser giving something its full attention. There is no panel chrome, no
/// title repeating what the sidebar row already says, and nothing floating over
/// anything (ADR-0010, ADR-0054).
///
/// **The state machine is the core's and there is not a second one here.**
/// Every question this view could ask — is a reply arriving, is a tool waiting
/// on somebody, did it fail and how — is a field on `Conversation`. What is
/// decided here is order, weight, colour and where the cursor is.
struct ChatPage: View {
    @Environment(BrowserModel.self) private var model
    let tab: TabId
    /// The thread this tab's address names, when it names one.
    let addressed: ConversationId?

    /// What is in the composer. Local, because a half-typed question is not
    /// state any other window has an opinion about, and sending it to the core
    /// on every keystroke would put a transcript-sized value through the FFI
    /// per character.
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    /// Whether the tab is showing the thread or the list of threads about its
    /// page. Local, because it is which screen this window is on and nothing
    /// else in the browser has an opinion about that.
    @State private var listingThreads = false

    private enum Metrics {
        /// The composer's resting height, and the ceiling it grows to before it
        /// starts scrolling instead. Four lines: enough to see a question with
        /// a pasted sentence in it, short enough that the answer above stays on
        /// screen while it is typed.
        static let composerMin: CGFloat = 34
        static let composerMax: CGFloat = 96
        /// The one control in the composer's footer — Send, or Stop.
        static let action: CGFloat = 28
        /// The arrow inside it. Its own number rather than a type token: this
        /// glyph is the whole of the control and is sized to the disc it sits
        /// in, not to a line of text beside it.
        static let actionGlyph: CGFloat = 13
        /// The page's own mark on the empty screen.
        ///
        /// A step over the 16 a sidebar row wears, because here it is not a
        /// badge beside a title in a list — it is the picture that says which
        /// page this whole screen is about, and it is the only picture on it.
        /// Its own number for the reason `Design.Glyph` gives: a mark is a
        /// picture and does not grow with the text size.
        static let identityIcon: CGFloat = 18
        /// The extra between two lines of the transcript.
        ///
        /// Leading, not spacing, so it is not on the 4pt rhythm by
        /// construction — it lands there by arithmetic. Measured: the system's
        /// own line height for `.callout` is 15pt on a 12pt face, which is set
        /// for a label in a row rather than for a paragraph somebody reads to
        /// the end of. 19pt is 1.58, which is what prose is set at on a screen.
        static let leading: CGFloat = 4
    }

    var body: some View {
        Group {
            if listingThreads, let conversation {
                ThreadList(
                    current: conversation.id,
                    threads: siblings,
                    page: anchoredPage,
                    open: { open($0) },
                    start: startAnother,
                    dismiss: { listingThreads = false }
                )
            } else {
                // The composer is one view in both states, deliberately. It
                // begins in the middle of an empty canvas with the greeting
                // over it and travels to the bottom when there is a transcript
                // to make room for, and that travel is the screen explaining
                // where the bar at the bottom came from. Two composers — one
                // for each state — would be a cut, and would take the cursor
                // and the half-typed question with it.
                VStack(spacing: 0) {
                    subjectBar

                    if hasTranscript {
                        transcript
                    } else {
                        Spacer(minLength: 0)
                        greeting
                    }

                    composer

                    if !hasTranscript {
                        starters
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .background(.background)
        .motion(.entrance, value: listingThreads)
        .motion(.entrance, value: hasTranscript)
    }

    /// Whether there is anything to read yet, which is the one thing that
    /// decides where the composer lives.
    private var hasTranscript: Bool {
        guard let conversation else { return false }
        return !conversation.messages.isEmpty
    }

    /// The thread this page is showing.
    ///
    /// `conversationRevision` is read and thrown away, and it is the only reason
    /// this page redraws at all. `model.conversation(_:)` goes straight through
    /// to the core, so nothing on this path is observable — every question this
    /// view asks about the thread is a function call, and a function call is not
    /// something the observation system can invalidate. Without this line the
    /// page redrew only when whatever hosts it happened to redraw for its own
    /// reasons, which is the difference between a reply that arrives a word at a
    /// time and one that appears when something unrelated changes.
    ///
    /// Reading `snapshot` here instead looks like the tidier answer and was
    /// measured not to work; `BrowserModel.conversationRevision` carries the
    /// evidence.
    private var conversation: Conversation? {
        _ = model.conversationRevision
        return addressed.flatMap { model.conversation($0) }
    }

    /// Every thread about this page, most recent first. One element for a
    /// thread about no page in particular.
    private var siblings: [Conversation] {
        guard let conversation else { return [] }
        return model.conversations(about: conversation.id)
    }

    /// The address this thread is anchored to, when it is anchored to one.
    private var anchoredPage: PageAnchor? {
        switch conversation?.scope {
        case let .page(_, page): page
        case .space, nil: nil
        }
    }

    // MARK: - What this thread is about

    /// One line naming the page, and the way to every other thread about it.
    ///
    /// Only for a thread that is about a page: a question typed into the
    /// command bar is about nothing, and a bar saying so would be a row that
    /// spends its life repeating a blank.
    ///
    /// It earns the space three times over — it says which page a thread
    /// restored a week later belongs to, it says out loud when that page is not
    /// open (so nothing is read for the next question and the screen does not
    /// pretend otherwise), and it is the door to the other conversations.
    @ViewBuilder
    private var subjectBar: some View {
        if let conversation, let page = anchoredPage {
            HStack(spacing: Design.Space.tight) {
                // The page's own mark, the same one its row wears in the
                // sidebar and its entry wears in history — so a thread and the
                // page it is about are recognisably one thing. It replaced a
                // generic document glyph that also carried "the page is not
                // open"; that fact is not lost, because the line below says it
                // in words, and a badge doing it in a glyph was the screen
                // saying it twice while saying which site it was about not at
                // all.
                SiteBadge(subject: model.badge(for: conversation))

                VStack(alignment: .leading, spacing: 0) {
                    Text(shortPage(page))
                        .font(Design.Text.label)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if !pageIsOpen {
                        Text("Not open — nothing will be read for the next question.")
                            .font(Design.Text.micro)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: Design.Space.tight)

                threadsControl(for: conversation)
            }
            .padding(.vertical, Design.Space.tight)
            // The rule stops where the column stops, and that is the point of
            // it. Full-bleed it read as a header band, which is fine in a
            // nine-hundred-point window and is a stray line across an empty page
            // in a fourteen-hundred-point one — a rule three times the width of
            // everything it is separating. Stopped at the column it does the
            // one job left: saying where content scrolls away to, on the same
            // vertical as the transcript and the composer.
            .overlay(alignment: .bottom) { Divider().hairline() }
            // The column first and the padding outside it, which is the order
            // the transcript and the composer use. Written the other way round
            // this bar's contents sat sixteen points inside theirs, so the page
            // had two left margins a person could see but not name.
            .frame(maxWidth: chatColumn)
            .padding(.horizontal, Design.Space.loose)
            .frame(maxWidth: .infinity)
        }
    }

    /// The one control on the subject bar, and which one it is says whether the
    /// page has been discussed more than once.
    ///
    /// Two shapes rather than a disabled third: with one thread there is
    /// nothing to list, so the only useful move is starting a second — and with
    /// several, starting one belongs on the screen that shows what is already
    /// there.
    @ViewBuilder
    private func threadsControl(for conversation: Conversation) -> some View {
        let count = siblings.count
        if count > 1 {
            Button { listingThreads = true } label: {
                HStack(spacing: Design.Space.hair) {
                    Text("\(count) conversations")
                    Image(systemName: "chevron.right")
                }
                .font(Design.Text.label)
            }
            .buttonStyle(.borderless)
            .help("Every conversation about this page")
        } else {
            Button(action: startAnother) {
                Image(systemName: "plus")
                    .font(Design.Text.label)
            }
            .buttonStyle(.borderless)
            .help("Start a second conversation about this page")
        }
    }

    private var pageIsOpen: Bool {
        guard let conversation else { return false }
        return model.pageIsOpen(for: conversation.id)
    }

    private func open(_ id: ConversationId) {
        listingThreads = false
        model.send(.showConversation(conversation: id))
        composerFocused = true
    }

    private func startAnother() {
        guard let conversation else { return }
        listingThreads = false
        model.send(.startAnotherConversation(like: conversation.id))
        composerFocused = true
    }

    // MARK: - The transcript

    @ViewBuilder
    private var transcript: some View {
        if let conversation {
            ScrollViewReader { scroller in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(
                            Array(conversation.messages.enumerated()),
                            id: \.element.id
                        ) { position, message in
                            MessageRow(message: message, conversation: conversation.id)
                                .padding(.top, gap(before: message, at: position))
                                .id(message.id)
                        }

                        if let error = conversation.error {
                            ChatErrorNotice(error: error, conversation: conversation.id)
                                .padding(.top, Design.Space.loose)
                                .id(errorAnchor)
                        }
                    }
                    .lineSpacing(Metrics.leading)
                    .frame(maxWidth: chatColumn, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, Design.Space.loose)
                    .padding(.vertical, Design.Space.section)
                }
                // **A conversation stacks upward from the composer.** A scroll
                // view top-aligns content shorter than its viewport, which on a
                // tall window put the newest reply about fifteen hundred points
                // above the field somebody is about to type into, with the whole
                // of the void between them. The empty room belongs above the
                // first message, not below the last: that is both how a
                // conversation reads and the only arrangement where what you
                // just read is next to what you are answering it with.
                //
                // Measured, because the modifier has two jobs and only one of
                // them is this: `.bottom` also keeps a growing transcript pinned
                // while a reply streams, which is what the explicit `scrollTo`
                // below was doing alone. They agree, so neither fights the other.
                .defaultScrollAnchor(.bottom)
                // Follow the answer as it is written, and only then. Keyed on
                // the id of the last message rather than on its text: a reply
                // arrives in dozens of deltas, and scrolling on each one fights
                // anybody who has scrolled up to read something.
                .onChange(of: conversation.messages.last?.id) { _, last in
                    guard let last else { return }
                    scroller.scrollTo(last, anchor: .bottom)
                }
            }
        }
    }

    /// The space above a message, which is not one number.
    ///
    /// A question and the answer under it are one exchange, and the gap that
    /// separates two exchanges has to be bigger than the gap inside one or the
    /// transcript is an undifferentiated stack. So a question opens a new block
    /// and everything that answers it stays close. With one gap for everything
    /// this was a wall the eye had nothing to divide.
    private func gap(before message: Message, at position: Int) -> CGFloat {
        guard position > 0 else { return 0 }
        switch message.role {
        case .user: return Design.Space.section
        case .assistant, .pageContext, .toolResult: return Design.Space.loose
        }
    }

    /// Somewhere for the error notice to be scrolled to. A constant rather than
    /// a message id, because a failure before the first reply belongs to no
    /// message at all.
    private var errorAnchor: String { "error" }

    // MARK: - Nothing said yet

    /// The first thing anybody sees, and for most people on most days the only
    /// chat screen they will meet before they type something.
    ///
    /// **Not an `EmptyState`.** That component is a list saying it has no rows:
    /// a glyph, a headline, a sentence and a button, capped at 320pt and filling
    /// whatever it is dropped into. This screen is not a list with nothing in
    /// it, it is the front door of the feature with a live field on it — and the
    /// field has to be the same view before and after the first question, which
    /// it could not be from inside a component that owns the whole canvas.
    ///
    /// So: one line, set in the only serif in the browser, with the composer
    /// directly under it and the cursor already in it. The icon is gone
    /// deliberately — a picture of sparkles is decoration standing where the
    /// invitation should be.
    private var greeting: some View {
        VStack(spacing: Design.Space.regular) {
            pageIdentity

            VStack(spacing: Design.Space.snug) {
                Text(greetingLine)
                    .greetingType()
                    .multilineTextAlignment(.center)

                Text(emptyMessage)
                    .font(Design.Text.detail)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(Metrics.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: chatColumn)
        .padding(.horizontal, Design.Space.loose)
        .padding(.bottom, Design.Space.regular)
    }

    /// The page this thread is about, named the way a person recognises one.
    ///
    /// **A title, an icon and a site — never the address.** What stood here was
    /// the address inside the sentence below it, and on a real page that is
    /// `chromewebstore.google.com/detail/1password-%E2%80%93-password-mana/aeblfdkhhhdcdjpifhhbdiojplfjncoa`
    /// wrapped over three lines of body copy on the emptiest screen in the
    /// browser. Nobody reads a percent-encoded path, and nobody recognises a
    /// page by one either; what a person recognises is the picture, the name
    /// and the site, which is exactly what a browser already has.
    ///
    /// It is the answer to *why open this instead of another tab on somebody
    /// else's website*, and it is the first thing the screen says.
    ///
    /// The title is the page's own claim about itself and may not exist —
    /// nothing has ever told us what a page nobody has opened is called. Then
    /// the site stands alone, which is a fact about the address rather than an
    /// address dressed up as a name (ADR-0018). The exact address is on the
    /// tooltip and verbatim on `ThreadList`.
    @ViewBuilder
    private var pageIdentity: some View {
        if let conversation, let page = anchoredPage {
            let title = model.pageTitle(for: conversation.id)
            let site = siteName(page)

            HStack(spacing: Design.Space.tight) {
                SiteBadge(subject: model.badge(for: conversation), size: Metrics.identityIcon)

                // The name, then the site behind it. The site is dropped when
                // it is already what the name says, because a row that prints
                // one fact twice is a row that has nothing to say.
                Text(title ?? site ?? page)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if title != nil, let site {
                    Text(site)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .font(Design.Text.label)
            .padding(.horizontal, Design.Space.snug)
            .padding(.vertical, Design.Space.hair)
            .background(Design.Surface.recessed, in: Capsule())
            .help(page)
        }
    }

    /// The greeting itself, which already carries the one fact that changes what
    /// the next question will do.
    ///
    /// "About this page" is only said when there is a page and it is open,
    /// because those are the conditions under which anything gets read
    /// (ADR-0018). A thread whose page is closed gets the plain invitation, and
    /// the line under it says why.
    private var greetingLine: String {
        guard anchoredPage != nil, pageIsOpen else { return "Ask anything." }
        return "Ask about this page."
    }

    /// What the empty screen says under the greeting, which depends on what the
    /// thread is about and whether that page is in front of the browser right
    /// now.
    ///
    /// Three sentences and not one, because a thread anchored to a page nobody
    /// has open is a real state somebody will meet the morning after — and a
    /// screen that promised to read the page anyway would be promising
    /// something that is not going to happen (ADR-0018).
    ///
    /// Each is one sentence now rather than two. What the second sentence used
    /// to carry — that the question goes to the model you set up — is said by
    /// the composer naming that model, which is the stronger form of it: a name
    /// rather than a promise.
    ///
    /// **None of them names the page any more, and that is not a loss of
    /// meaning.** The page is named above, as a picture and a name and a site;
    /// these say what happens to it and when, which is the part ADR-0018 makes
    /// this sentence carry. Spelling the address here as well put a
    /// percent-encoded path in the middle of a sentence and said nothing the
    /// line above does not.
    private var emptyMessage: String {
        guard anchoredPage != nil else {
            return "Nothing is read from any page unless the thread is about one."
        }
        guard pageIsOpen else {
            return "It is not open, so nothing will be read until it is back."
        }
        return "zer0 reads it to answer, and at no other moment."
    }

    // MARK: - Somewhere to start

    @ViewBuilder
    private var starters: some View {
        let offered = startingPoints(pageWillBeRead: anchoredPage != nil && pageIsOpen)
        if !offered.isEmpty {
            Wrap(spacing: Design.Space.tight) {
                ForEach(offered, id: \.self) { question in
                    Button { ask(question) } label: {
                        Text(question)
                            .font(Design.Text.label)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, Design.Space.snug)
                            .padding(.vertical, Design.Space.tight)
                            .background(
                                Design.Palette.background,
                                in: Capsule()
                            )
                            .overlay {
                                Capsule().strokeBorder(
                                    Design.Palette.rule,
                                    lineWidth: Design.Stroke.hairline
                                )
                            }
                    }
                    .buttonStyle(.pressable)
                    .help("Ask this about the page")
                }
            }
            .frame(maxWidth: chatColumn)
            .padding(.horizontal, Design.Space.loose)
        }
    }

    // MARK: - The composer

    /// A card, not a bar.
    ///
    /// It used to be welded to the bottom edge — a full-bleed strip on the
    /// recessed fill with a rule along the top — which is the shape a chat
    /// window has when the transcript is the product and the field is the price
    /// of using it. Here it is the other way round: on the screen most people
    /// meet, the field *is* the product and there is nothing else on the canvas.
    /// So it floats, with room around it, and casts the one shadow the scale has
    /// for something that has only just left the surface.
    private var composer: some View {
        VStack(alignment: .leading, spacing: Design.Space.snug) {
            TextEditor(text: $draft)
                .font(Design.Text.detail)
                .scrollContentBackground(.hidden)
                // **The scroller was drawing itself.** A `TextEditor` is an
                // `NSTextView` in a scroll view, and on a four-line field with
                // two lines in it macOS still parked a grey bar down the right
                // edge — which is the single detail that made this card read as
                // a disabled form field rather than as somewhere to write.
                .scrollIndicators(.never)
                .frame(minHeight: Metrics.composerMin, maxHeight: Metrics.composerMax)
                .fixedSize(horizontal: false, vertical: true)
                .focused($composerFocused)
                .overlay(alignment: .topLeading) { placeholder }

            // Everything a person needs to know about the next question, on one
            // line inside the card: what will answer it, and the one control
            // that does something about it.
            HStack(alignment: .center, spacing: Design.Space.tight) {
                answering
                Spacer(minLength: Design.Space.tight)
                action
            }
        }
        .padding(Design.Space.regular)
        // **A surface, not a material.** `.regularMaterial` blurs what is
        // behind it, and behind this there is nothing but the canvas — so it
        // resolved to its own flat tint and the field a person is being invited
        // to write in was a grey slab in the middle of an empty page. The card
        // is the page's own surface, lifted off it by a hairline and a shadow,
        // which is what paper on a desk looks like and what a material here
        // never could. (The same argument `DesignSystem.VisualEffect` makes for
        // the command bar, arriving at the opposite answer because there really
        // is a page behind that one.)
        .background(
            Design.Palette.background,
            in: RoundedRectangle(cornerRadius: Design.Radius.large, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Design.Radius.large, style: .continuous)
                .strokeBorder(Design.Palette.rule, lineWidth: Design.Stroke.hairline)
        }
        .elevation(Design.Elevation.resting)
        .frame(maxWidth: chatColumn)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Design.Space.loose)
        .padding(.vertical, Design.Space.loose)
        // A page that opens with a field on it opens with the cursor in the
        // field. There is no second step here and no reason to make somebody
        // find one (AGENTS.md).
        .onAppear { composerFocused = true }
        // Enter sends; ⇧↩ is a new line, which is the arrangement every message
        // composer has and the only one that does not need explaining.
        .onKeyPress(.return, phases: .down) { press in
            guard !press.modifiers.contains(.shift) else { return .ignored }
            submit()
            return .handled
        }
        // Escape stops an answer, which the Stop button has always promised in
        // its tooltip and nothing implemented — the key reached the core, where
        // it means "stop loading this page". It is claimed here only while
        // there is an answer to stop; with nothing arriving it is passed on
        // rather than swallowed, so Escape still means what it means everywhere
        // else in the browser.
        .onKeyPress(.escape, phases: .down) { _ in
            guard isBusy else { return .ignored }
            cancel()
            return .handled
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if draft.isEmpty {
            Text(isBusy ? "Answering…" : "Ask a question")
                .font(Design.Text.detail)
                .foregroundStyle(.tertiary)
                .padding(.top, Design.Space.hair)
                .padding(.leading, Design.Space.hair)
                .allowsHitTesting(false)
        }
    }

    /// Which model the next question goes to, said out loud.
    ///
    /// Nothing on this screen used to say it, which left the most consequential
    /// fact about a conversation — who is answering — readable only from a
    /// settings pane two windows away.
    ///
    /// It is the configured provider's name for its own model and never a vendor
    /// this shell knows about: the core does not name one (ADR-0051), and a
    /// hard-coded "Claude" here would be wrong for everybody running a local
    /// model and would go on being wrong silently. When nothing is set up it
    /// says so rather than showing a blank, because a blank is a claim too — and
    /// it is the same sentence the failure would give after a wasted question.
    ///
    /// Both shapes go to Settings, because the only thing anybody wants from a
    /// model's name is to change it.
    ///
    /// **And it is drawn as the control it is.** It has been a bare word in the
    /// corner of the card through two rounds of this screen — first in ten-point
    /// monospace, which read as debug output, then as a plain label, which read
    /// as a caption. Neither said the thing that matters about it, which is that
    /// it can be pressed: the most consequential fact about a conversation was
    /// sitting next to the field looking like a footnote. A chip with a
    /// disclosure on it is what every assistant draws here, and it is what this
    /// is now.
    @ViewBuilder
    private var answering: some View {
        if let name = answeringModel {
            Button { model.perform(.showSettings) } label: {
                chip(name, symbol: "chevron.down", tint: AnyShapeStyle(.secondary))
            }
            .buttonStyle(.pressable)
            .help("Answers with \(name). Change it in Settings.")
            .accessibilityLabel("Model: \(name)")
            .accessibilityHint("Opens Settings")
        } else {
            Button { model.perform(.showSettings) } label: {
                chip(
                    "No model set up",
                    symbol: "exclamationmark.circle",
                    tint: AnyShapeStyle(Design.Palette.warning)
                )
            }
            .buttonStyle(.pressable)
            .help("Nothing will answer until a model is set up. Opens Settings.")
            .accessibilityHint("Opens Settings")
        }
    }

    /// The one shape a pressable label wears inside the composer.
    ///
    /// The glyph trails the word rather than leading it, because it is a
    /// disclosure — what pressing does — and not a picture of what the word
    /// means.
    private func chip(_ text: String, symbol: String, tint: AnyShapeStyle) -> some View {
        HStack(spacing: Design.Space.hair) {
            Text(text)
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: symbol)
                .font(Design.Text.micro)
        }
        .font(Design.Text.label)
        .foregroundStyle(tint)
        .padding(.horizontal, Design.Space.tight)
        .padding(.vertical, Design.Space.hair)
        .background(Design.Surface.recessed, in: Capsule())
    }

    /// The model the next question will be sent to, asked of the same function
    /// that builds the request.
    ///
    /// `config` is read and thrown away on purpose. `effectiveProvider()` goes
    /// straight through to the core, so nothing about that call is observable —
    /// without touching the one published property this footer would keep naming
    /// a model somebody removed from the file ten seconds ago.
    private var answeringModel: String? {
        let host = model.configuration
        _ = host.config
        return modelThatWillAnswer(host.effectiveProvider())
    }

    /// One control, and which one it is says what the thread is doing.
    ///
    /// Send and Stop are the same button because they are the same slot: while
    /// an answer is arriving there is nothing to send, and the only thing worth
    /// doing is stopping it. Two buttons with one of them always disabled would
    /// be a control that spends its life saying no.
    @ViewBuilder
    private var action: some View {
        if isBusy {
            Button(action: cancel) {
                actionDisc(symbol: "stop.fill", fill: AnyShapeStyle(Design.Palette.accent))
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("Stop")
            .help("Stop this answer (⎋)")
        } else {
            Button(action: submit) {
                actionDisc(
                    symbol: "arrow.up",
                    // Disabled is drawn rather than dimmed by the button style,
                    // because a borderless disc on a material is nearly nothing
                    // once macOS has taken half its opacity away.
                    fill: hasDraft
                        ? AnyShapeStyle(Design.Palette.accent)
                        : AnyShapeStyle(Design.Palette.inkTertiary.opacity(0.35))
                )
            }
            .buttonStyle(.pressable)
            .disabled(!hasDraft)
            .accessibilityLabel("Send")
            .help("Send (↩)")
        }
    }

    private func actionDisc(symbol: String, fill: AnyShapeStyle) -> some View {
        Image(systemName: symbol)
            .font(.system(size: Metrics.actionGlyph, weight: .semibold))
            .foregroundStyle(Design.Palette.onAccent)
            .frame(width: Metrics.action, height: Metrics.action)
            .background(fill, in: Circle())
    }

    private var hasDraft: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isBusy: Bool {
        guard let conversation else { return false }
        return conversationIsBusy(conversation)
    }

    // MARK: - Doing something

    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        ask(text)
    }

    /// Put a question to this thread: the one that was typed, or one of the
    /// starting points offered on the empty screen.
    ///
    /// A starting point deliberately leaves the draft alone. It is almost
    /// always empty — these are only on screen before the first exchange — and
    /// throwing away something somebody had begun to type in order to send them
    /// a different question would be the interface deciding what they meant.
    private func ask(_ text: String) {
        guard !isBusy else { return }

        if let conversation {
            model.send(.sendChatMessage(conversation: conversation.id, text: text))
        } else {
            // No thread yet. The core mints one scoped to this tab and re-points
            // the tab's address at it, so the page becomes addressable and comes
            // back after a restart (ADR-0054).
            model.send(.openChat(about: .page(tab: tab), ask: text))
        }
        composerFocused = true
    }

    private func cancel() {
        guard let conversation else { return }
        model.send(.cancelChat(conversation: conversation.id))
        composerFocused = true
    }
}

// MARK: - A row that wraps

/// Things laid out along a line, folding onto the next when the line runs out.
///
/// For the starting points, which is a handful of pills whose widths are their
/// words: three of them fit one line in the window this browser is used in and
/// take two or three in the narrowest one it opens at, and neither arrangement
/// is worth writing down as a number. An `HStack` would push them off the edge
/// and a `VStack` would make a list out of three things that are one offer.
///
/// Rows are centred, because what sits above them is.
private struct Wrap: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        folded(subviews, into: proposal.width ?? .infinity).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) {
        let rows = folded(subviews, into: proposal.width ?? bounds.width).rows
        var y = bounds.minY

        for row in rows {
            let width = row.map(\.size.width).reduce(0, +)
                + spacing * CGFloat(max(row.count - 1, 0))
            var x = bounds.midX - width / 2
            let height = row.map(\.size.height).max() ?? 0

            for item in row {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y + (height - item.size.height) / 2),
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + spacing
            }
            y += height + spacing
        }
    }

    private struct Item {
        let index: Int
        let size: CGSize
    }

    private func folded(
        _ subviews: Subviews,
        into width: CGFloat
    ) -> (size: CGSize, rows: [[Item]]) {
        var rows: [[Item]] = []
        var row: [Item] = []
        var used: CGFloat = 0
        var widest: CGFloat = 0
        var height: CGFloat = 0

        func close() {
            guard !row.isEmpty else { return }
            widest = max(widest, used)
            height += (row.map(\.size.height).max() ?? 0) + (rows.isEmpty ? 0 : spacing)
            rows.append(row)
            row = []
            used = 0
        }

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !row.isEmpty, used + spacing + size.width > width { close() }
            used += (row.isEmpty ? 0 : spacing) + size.width
            row.append(Item(index: index, size: size))
        }
        close()

        return (CGSize(width: min(widest, width), height: height), rows)
    }
}

// MARK: - Every conversation about one page

/// The threads a page has, as a screen of its own.
///
/// It fills the tab rather than dropping out of the bar that opened it. This is
/// the moment the feature shows what it is — a page you have talked to before,
/// several times, each about something different — and a menu would file that
/// under housekeeping. It is also, on the day somebody has four threads about
/// one dashboard, the only way to tell them apart, which needs the first
/// question of each at a size a person can read.
///
/// Nothing here decides anything. The order is the core's, "which one am I in"
/// is a comparison of ids, and picking one dispatches.
struct ThreadList: View {
    let current: ConversationId
    /// Most recent first, as the core ordered them. Never re-sorted here.
    let threads: [Conversation]
    let page: PageAnchor?
    let open: (ConversationId) -> Void
    let start: () -> Void
    /// Back to the thread that was on screen, changing nothing. Separate from
    /// `open(current)` because Escape means "I did not pick anything", and
    /// dispatching a choice nobody made is a state change with no cause.
    let dismiss: () -> Void

    /// Which row the keyboard is on. Starts on the thread being read, so ↩
    /// with nothing else touched goes back where you came from.
    @State private var selected: ConversationId?
    @FocusState private var focused: Bool

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: Design.Space.regular) {
                    heading
                    rows
                    newConversation
                }
                .frame(maxWidth: chatColumn, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Design.Space.loose)
                .padding(.vertical, Design.Space.section)
            }
            .onChange(of: selected) { _, row in
                guard let row else { return }
                scroller.scrollTo(row, anchor: .center)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        // A list that opens with the keyboard already in it. Arriving here and
        // having to click before ↓ does anything is the extra step this project
        // does not take.
        .onAppear {
            selected = current
            focused = true
        }
        .onKeyPress(.downArrow) { move(by: 1) }
        .onKeyPress(.upArrow) { move(by: -1) }
        .onKeyPress(.return) {
            if let selected { open(selected) }
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: Design.Space.hair) {
            Text("\(threads.count) conversations")
                .font(Design.Text.emptyTitle)
            // The anchor verbatim, not the shortened form the bar above the
            // transcript wears. This is the one screen that says exactly what
            // was written down about this page, character for character, and a
            // tidied version of it would be the interface deciding what the
            // person is allowed to check.
            if let page {
                Text(page)
                    .font(Design.Text.mono)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
    }

    private var rows: some View {
        VStack(spacing: Design.Space.hair) {
            ForEach(threads, id: \.id) { thread in
                Button { open(thread.id) } label: {
                    ThreadRow(
                        thread: thread,
                        isCurrent: thread.id == current,
                        isSelected: thread.id == selected
                    )
                }
                .buttonStyle(.plain)
                .id(thread.id)
            }
        }
    }

    /// The deliberate act, and it says what it will do rather than only what it
    /// is called: a second thread about one page is a thing people want and a
    /// thing they should not get by accident.
    private var newConversation: some View {
        Button(action: start) {
            HStack(spacing: Design.Space.tight) {
                Image(systemName: "plus.circle")
                    .font(Design.Text.rowTitle)
                    .foregroundStyle(Design.Palette.accent)
                VStack(alignment: .leading, spacing: 0) {
                    Text("New conversation")
                        .font(Design.Text.rowTitle)
                    Text("Starts empty. The ones above are untouched.")
                        .font(Design.Text.label)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(Design.Space.snug)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Design.Surface.recessed,
                in: RoundedRectangle(cornerRadius: Design.Radius.medium)
            )
        }
        .buttonStyle(.plain)
    }

    // `SwiftUI.` spelled out because this module has a `KeyPress` of its own
    // (the keymap's), and the unqualified name resolves to that one.
    private func move(by delta: Int) -> SwiftUI.KeyPress.Result {
        guard !threads.isEmpty else { return .ignored }
        let at = threads.firstIndex { $0.id == selected } ?? 0
        let next = min(max(at + delta, 0), threads.count - 1)
        selected = threads[next].id
        return .handled
    }
}

/// One thread in the list: what was asked first, and how much came of it.
struct ThreadRow: View {
    let thread: Conversation
    let isCurrent: Bool
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Design.Space.snug) {
            VStack(alignment: .leading, spacing: Design.Space.hair) {
                Text(title)
                    .font(Design.Text.rowTitle)
                    .foregroundStyle(question.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Text(detail)
                    .font(Design.Text.label)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            // The one you are reading, marked rather than merely highlighted:
            // the highlight is where the keyboard is, and those are different
            // facts that would otherwise share one appearance.
            if isCurrent {
                Text("Reading")
                    .font(Design.Text.micro)
                    .foregroundStyle(Design.Palette.accent)
            }
        }
        .padding(Design.Space.snug)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Design.Surface.recessed,
            in: RoundedRectangle(cornerRadius: Design.Radius.medium)
        )
        // Where the keyboard is, as a ring rather than a fill. The filled row
        // colour is the sidebar's "this is the page you are on"; borrowing it
        // here would make two different facts wear one appearance, and this
        // screen already says the other one in words.
        .overlay {
            RoundedRectangle(cornerRadius: Design.Radius.medium)
                .strokeBorder(
                    isSelected ? Design.Palette.accent : Color.clear,
                    lineWidth: Design.Stroke.insertion
                )
        }
    }

    /// Asked of the core, not read out of the transcript here: what names a
    /// thread is one rule, and two shells picking their own line would label
    /// the same conversation differently.
    private var question: String {
        conversationOpeningQuestion(conversation: thread)
    }

    private var title: String {
        question.isEmpty ? "Nothing asked yet" : question
    }

    private var detail: String {
        let said = thread.messages.filter { $0.role == .user || $0.role == .assistant }.count
        let turns = said == 1 ? "1 message" : "\(said) messages"
        let when = Date(
            timeIntervalSince1970: Double(conversationLastActivityMs(conversation: thread)) / 1000
        )
        return "\(turns) · \(when.formatted(.relative(presentation: .named)))"
    }
}

// MARK: - What a thread is doing, and what a message says about itself

/// Questions about the page, ready to send, for the screen that has none yet.
///
/// **This is the answer to why this screen exists.** A field and a cursor is
/// what every other assistant already gives you; what this one has that they do
/// not is that it is looking at the page you are, and an empty field is the
/// worst possible way to say so. Somebody who has never used this feature
/// learns what it is for by pressing one of these, which no amount of
/// explanatory copy achieves.
///
/// **They claim nothing about what the page says.** Each is a question a person
/// might ask about anything in front of them, and not one is a summary we are
/// pretending to already have — the page has not been read yet, and it will not
/// be until one of these is pressed (ADR-0018). Nothing here may become a
/// sentence that only a page we had read could produce.
///
/// **Nothing is offered when nothing will be read.** A thread whose page is
/// closed reads nothing for the next question, which the screen says in words
/// two lines above; a chip saying "Summarise this page" under that sentence
/// would be the same screen contradicting itself in the same breath.
///
/// Out of the view for the reason `conversationIsBusy` is: it is the rule
/// behind what a person is shown, and a rule with no test is a rule that can
/// quietly stop being true. In the shell rather than the core because it is
/// *copy* — the words somebody reads, which is the half of the split that
/// follows the platform and the language. What a thread is **called** is the
/// other half and is the core's, because two shells disagreeing about that is
/// two names for one conversation.
func startingPoints(pageWillBeRead: Bool) -> [String] {
    guard pageWillBeRead else { return [] }
    return [
        "Summarise this page",
        "What is this asking me to do?",
        "Explain it in plain language",
    ]
}

/// Whether an answer is on its way, which is the whole of what decides between
/// Send and Stop.
///
/// Out of the view because it is the rule behind a control that changes what a
/// click does, and a rule with no test is a rule that can quietly stop being
/// true — the failure being a Stop button that sends, or a Send button during a
/// reply. Three facts, and every one of them is the core's: the page is being
/// read, text is arriving, or a tool it asked for is still running.
func conversationIsBusy(_ conversation: Conversation) -> Bool {
    if conversation.awaitingPage { return true }
    return conversation.messages.contains { message in
        message.state == .streaming || message.toolCalls.contains { $0.state == .running }
    }
}

/// What a message says about itself when it did not simply finish.
///
/// `complete` and `streaming` say nothing: a finished reply is the ordinary
/// case, and a streaming one is already visibly arriving. The other four are
/// each a fact the reader would otherwise have to infer from an answer that
/// just stops (ADR-0018) — and inferring is exactly what they must not have to
/// do, because "the model stopped here" and "zer0 threw the rest away" read
/// identically on the page.
///
/// Out of the view so a case losing its sentence is something a test can see.
/// Inside one, the four notices were four lines of a `@ViewBuilder` that
/// nothing but a person's eye could check, and the eye only checks the states
/// it can make happen.
func messageNotice(for state: MessageState) -> (text: String, symbol: String)? {
    switch state {
    case .complete, .streaming:
        nil
    case .cancelled:
        ("Stopped.", "stop.circle")
    case .failed:
        ("This answer did not finish.", "exclamationmark.triangle")
    case .interrupted:
        ("zer0 quit while this was still arriving.", "bolt.horizontal.circle")
    case .truncated:
        ("This answer ran past what zer0 will hold, so it is a fragment.", "scissors")
    }
}

// MARK: - One message

/// A message, drawn by what it is rather than as a bubble.
///
/// **Still no two columns of rounded rectangles**, which is what the rail and
/// the gutter of SF Symbols here were defending against, and they were right to
/// — but they paid for it with a debug view: every paragraph indented behind a
/// 26pt column with a `person.fill` at the top of it, on a screen whose whole
/// argument is that it is a reading surface.
///
/// One side wears a shape and the other wears none. The question is a quiet pill
/// against the right edge; the answer is prose, at the measure, with no rail, no
/// mark and no fill behind it. That is what makes a transcript scannable — you
/// find your own questions by their shape, and everything between two of them is
/// the answer — while leaving the thing you actually read unornamented.
///
/// Internal rather than private so `ZZChatPageShots` can render the four states
/// a message can end in. `interrupted` only ever arrives from a session
/// restored after a crash, which is not something a harness can stage through
/// the model — and those four notices are the whole of what stops an answer
/// that stopped and an answer that finished looking identical.
struct MessageRow: View {
    let message: Message
    let conversation: ConversationId

    private enum Metrics {
        /// How much of the column stays blank to the left of a question.
        ///
        /// A question is set as a pill against the right edge, and the blank
        /// beside it is what says somebody else wrote it. A pasted paragraph
        /// that ran the full measure would lose that — the shape would still be
        /// there and the asymmetry, which is the part read at a glance, would
        /// not.
        static let askInset: CGFloat = 96
    }

    var body: some View {
        VStack(alignment: side, spacing: Design.Space.tight) {
            content

            ForEach(message.toolCalls, id: \.invocation.id) { call in
                ToolCallRow(call: call, conversation: conversation)
            }

            if let notice = messageNotice(for: message.state) {
                Note(text: notice.text, symbol: notice.symbol)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }

    /// Which edge this message and everything it says about itself line up on.
    private var side: HorizontalAlignment {
        switch message.role {
        case .user: .trailing
        case .assistant, .pageContext, .toolResult: .leading
        }
    }

    @ViewBuilder
    private var content: some View {
        switch message.role {
        case .user:
            // The pill hugs the question and the blank to its left is what says
            // who wrote it. `Spacer` first rather than a fixed width, so a
            // three-word question is a three-word pill.
            HStack(spacing: 0) {
                Spacer(minLength: Metrics.askInset)
                Text(message.text)
                    .font(Design.Text.detail)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, Design.Space.snug)
                    .padding(.vertical, Design.Space.tight)
                    .background(
                        Design.Surface.recessed,
                        in: RoundedRectangle(cornerRadius: Design.Radius.medium)
                    )
            }

        case .assistant:
            // The reply, and the one view in the shell that grows a character
            // at a time. Nothing is animated on it deliberately: a curve bound
            // to text that changes thirty times a second is a paragraph that
            // never stops moving, and the thing being read is the thing moving.
            ChatProse(message.text)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .pageContext:
            // What the browser sent on somebody's behalf, which is a different
            // claim from "you sent this" and is drawn as one. The text is
            // deliberately not shown: it is a page somebody is already looking
            // at, and reprinting it here would bury the conversation in it.
            PageContextRow(page: message.page)

        case .toolResult:
            ToolResultRow(text: message.text)
        }
    }
}

/// A quiet line under a message, for the things a message says about itself.
private struct Note: View {
    let text: String
    let symbol: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(Design.Text.label)
            .foregroundStyle(.secondary)
    }
}

/// The page the browser attached, named and not reprinted.
///
/// **A line, not a card.** This was a filled panel carrying a sentence, the
/// page's title and its address in monospace, which made the heaviest object on
/// the screen the least important thing on it: a note that the browser did the
/// ordinary thing it says it will do, drawn louder than the answer underneath.
/// At a fourteen-hundred-point window it was the first thing the eye landed on
/// in every exchange.
///
/// What it uniquely says is small and is not said anywhere else: *this address
/// was read, and this is where the answers below it start from*. The core sends
/// one of these per page a thread is told about — a follow-up about the same
/// page does not re-read it, and navigating the anchored tab produces a second
/// row with a different address. So it is not a repeat of the subject bar, which
/// says what the thread is *about*: these two can disagree, and when they do the
/// disagreement is the whole point of the row.
///
/// The address is shortened here and verbatim on `ThreadList`. The title is
/// dropped: it is the page's own claim about itself, where the address is the
/// thing that was fetched, and one line has room for one of them.
private struct PageContextRow: View {
    let page: PageReference?

    var body: some View {
        Label {
            if let page {
                Text("Read \(shortPage(page.url))")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(page.url)
            } else {
                // The host answers a capture even when it read nothing, so this
                // is a real state and not a missing case — and it is the one
                // that changes what the answer below is worth, so it says the
                // whole sentence rather than a shortened one.
                Text("The page could not be read, so only its address was sent.")
            }
        } icon: {
            Image(systemName: page == nil ? "doc.text.magnifyingglass" : "doc.text")
        }
        .font(Design.Text.label)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// What a tool gave back. Monospaced, because it is a value rather than prose.
///
/// It carries a heading now. The wrench in the gutter used to be the only thing
/// saying what this block was, and with the gutter gone a monospaced card in the
/// middle of a conversation could be a tool's answer, a quotation, or something
/// the model wrote — three different claims about who is speaking. The heading
/// is the same shape `ToolCallRow` puts over the arguments, for the same reason.
private struct ToolResultRow: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.hair) {
            Text("What the tool returned")
                .sectionHeading()
                .foregroundStyle(.secondary)

            Text(text.isEmpty ? "The tool returned nothing." : text)
                .font(Design.Text.mono)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Design.Space.snug)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Design.Surface.recessed,
            in: RoundedRectangle(cornerRadius: Design.Radius.small)
        )
    }
}
