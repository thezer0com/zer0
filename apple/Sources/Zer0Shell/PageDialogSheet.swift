import SwiftUI
import Zer0Core

/// A page's question, waiting on an answer.
///
/// `PageDialog` comes from the core and carries no identity, which
/// `.sheet(item:)` needs. The request number is the identity: it is monotonic
/// and never reused, so a sheet cannot be recycled for the next question and
/// carry the last one's words for a frame.
struct PendingPageDialog: Identifiable {
    let dialog: PageDialog
    var id: UInt64 { dialog.request }
}

/// The page's own string, drawn so it cannot be mistaken for the browser's.
///
/// **This is the only path a site's words take to the screen**, and that is the
/// point of it being a view rather than three `Text`s in three places. A
/// panel that let a page's string sit in the browser's own voice is how a
/// phishing page gets to say "your password has expired" in our type, at our
/// weight, under our mark. Four things make it a quotation:
///
/// - `Text(verbatim:)`, never `Text(_:)`. The second parses markdown, so
///   `**Sign in**` would arrive bold and a `[link](…)` would arrive as one.
/// - A recessed surface. Everything else on the sheet sits on the material with
///   no fill of its own, so the filled block is visibly a different thing.
/// - Selectable, because content is selectable and chrome is not.
/// - Never weighted, never tinted, never the accent. Emphasis on this sheet is
///   the browser's to spend, and this is not the browser talking.
///
/// It scrolls rather than growing without limit, and what the core already cut
/// is said out loud rather than left as an ellipsis nobody can tell from the
/// page's own.
struct SiteWords: View {
    let dialog: PageDialog

    /// What the block is holding, in one read.
    ///
    /// One value rather than three, for the reason `ExtensionConsentSheet`'s
    /// `ScrollEdges` is one: the height it settles at and the edges it fades at
    /// are answers to the same question, and two reads of one geometry are two
    /// things that can disagree.
    @State private var shape = Shape()

    /// How tall the page's text is, and which way it carries on.
    struct Shape: Equatable {
        var height: CGFloat = 0
        var above = false
        var below = false

        init() {}

        init(content: CGFloat, offset: CGFloat, visible: CGFloat) {
            height = content
            // Half a point of slack. A resting scroll view reports fractional
            // offsets, and an affordance that blinks on a rounding error is
            // worse than one that never appears.
            above = offset > 0.5
            below = offset + visible < content - 0.5
        }
    }

    /// Sizes that belong to this block rather than to the whole UI.
    private enum Metrics {
        /// A ceiling rather than a height. Most `confirm()` messages are one
        /// line; the ones that are twenty scroll instead of pushing the buttons
        /// off the bottom of the screen.
        static let maxHeight: CGFloat = 200
        /// How far the block dissolves at an edge it carries on past. Deep
        /// enough to swallow a whole line, because a line cut in half against a
        /// hard edge reads as a fault rather than as more text.
        static let fade: CGFloat = 20
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.tight) {
            if dialog.message.isEmpty {
                // A page is allowed to call `alert('')`. An empty recessed
                // rectangle reads as a panel that failed to load; saying what
                // happened is the honest version of the same fact.
                Text("This page opened a message with nothing in it.")
                    .font(Design.Text.label)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    Text(verbatim: dialog.message)
                        .font(Design.Text.detail)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Design.Space.snug)
                }
                .scrollBounceBehavior(.basedOnSize)
                // The list dissolving at an edge it carries on past, for the
                // reason `ExtensionConsentSheet` has one: macOS hides its
                // overlay scrollbars at rest, so a message one line too long
                // looks exactly like a message that ends — rendered, the last
                // visible line was cut through its middle against a hard edge,
                // which reads as a drawing fault rather than as more text.
                .mask(fade)
                .onScrollGeometryChange(for: Shape.self) { geometry in
                    Shape(
                        content: geometry.contentSize.height,
                        offset: geometry.contentOffset.y + geometry.contentInsets.top,
                        visible: geometry.containerSize.height
                    )
                } action: { _, now in
                    shape = now
                }
                // Zero is the first pass, before anything has been laid out.
                // The ceiling is the safe answer there: too tall for a frame is
                // a panel that settles, too short is one that clips its first
                // sentence.
                .frame(height: min(
                    shape.height == 0 ? Metrics.maxHeight : shape.height,
                    Metrics.maxHeight
                ))
                .background(
                    Design.Surface.recessed,
                    in: RoundedRectangle(cornerRadius: Design.Radius.small)
                )
            }

            if dialog.messageTruncated {
                Text("This page wrote more than \(Self.limit) characters. "
                    + "What is above is the beginning of it.")
                    .font(Design.Text.label)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The block's own edges, dissolved where it carries on.
    private var fade: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [.black.opacity(shape.above ? 0 : 1), .black],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: Metrics.fade)
            Rectangle().fill(.black)
            LinearGradient(
                colors: [.black, .black.opacity(shape.below ? 0 : 1)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: Metrics.fade)
        }
    }

    /// Read from the core rather than written here, for the reason the settle
    /// window is read from the core: a sentence naming a number the core does
    /// not use is a sentence that goes wrong silently.
    ///
    /// The locale is pinned rather than the machine's, and that is not an
    /// oversight: every other string in this shell is an English literal
    /// (DESIGN.md §13 — localisation is an open question), so a number grouped
    /// by the machine's locale is the one thing on the panel that changes
    /// language. Rendered on a Brazilian Mac it read "2.000", which an English
    /// reader takes for two.
    static var limit: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: NSNumber(value: dialogMessageLimit()))
            ?? String(dialogMessageLimit())
    }
}

/// Which extension is talking, drawn so it cannot be mistaken for an address.
///
/// **A site's origin and an extension's name are not the same kind of fact, so
/// they are not drawn the same way** (ADR-0098). An origin is something the
/// browser derived from an address it fetched and nobody can choose; a name is
/// a string the package wrote about itself, and a package may call itself
/// `google.com`. Three things keep the difference visible, and the first two are
/// structural rather than a rule somebody has to remember:
///
/// - **The browser's own words come first and always.** "An extension you
///   installed" is a fact only the browser can assert. The name follows it and
///   can never occupy the line on its own, so there is no arrangement of
///   characters a package can choose that reads as the identity line of a site.
/// - **Never `Design.Text.mono`.** Mono is what an origin wears on this sheet
///   and on `SitePermissionSheet`; a name in it would be an address to anybody
///   reading at a glance, which is everybody.
/// - `Text(verbatim:)`, never `Text(_:)`, for `SiteWords`' reason: the second
///   parses markdown at runtime, so a package named `**Trusted**` would arrive
///   bold and one named `[Apple](…)` would arrive as a link.
struct ExtensionName: View {
    let name: String
    let truncated: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.line) {
            Text("An extension you installed")
                .font(Design.Text.label)
                .foregroundStyle(.secondary)

            if name.isEmpty {
                // A package is free to declare no name, and the core does not
                // invent one. Saying so is the honest version of the same fact;
                // an empty quotation reads as a panel that failed to load.
                Text("It does not say what it is called.")
                    .font(Design.Text.label)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(verbatim: truncated ? "\(name)…" : name)
                    .font(Design.Text.detail)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Design.Space.tight)
                    .padding(.vertical, Design.Space.line)
                    .background(
                        Design.Surface.recessed,
                        in: RoundedRectangle(cornerRadius: Design.Radius.small)
                    )
            }
        }
    }
}

/// What a page said, and what you can say back.
///
/// Three of the four panels on `WKUIDelegate` are drawn here — `alert()`,
/// `confirm()` and `prompt()`. The fourth, the file control, is the system's
/// own picker and is put up by `FilePanelPresenter`; it shares this one's
/// seam, its gate and its identity rule, and none of its drawing.
///
/// **Of a piece with `SitePermissionSheet`, deliberately.** Same width, same
/// glyph column, same title-over-origin identity block, same footer rule. These
/// are the most-seen furniture in a browser after the tab strip, and four
/// panels that each invented their own layout would read as four products. Two
/// things differ, and each is argued where it happens:
///
/// - **Return and Escape are bound here** and are not on the camera sheet. That
///   sheet's answers are *written down* and change what the browser does from
///   now on; nothing here is recorded, and every browser in the world binds
///   Return to OK on an `alert()`. What that costs is covered by the point
///   below.
/// - **The buttons are dead for the same half second**, read from the same
///   `promptSettleMs()`. A page picks the moment it interrupts, so the Return
///   that lands first is the one that was already on its way down when it did —
///   and two modal panels a page can summon, one guarded against that and one
///   not, is a gap with nothing but luck in it (ADR-0056).
struct PageDialogSheet: View {
    let dialog: PageDialog
    /// The text and the checkbox travel together: somebody who ticks the box
    /// and presses Cancel means both, and two actions would leave a window in
    /// which the page asks again.
    let onAnswer: (PageDialogAnswer, Bool) -> Void

    /// What has been typed into a `prompt()`. Seeded with the page's
    /// suggestion, which is the page's words and is why it arrives selected.
    @State private var typed: String
    /// Whether the page has been asked to stop. Only ever shown when the core
    /// says this page has interrupted enough times to be worth offering.
    @State private var silence = false
    /// False until the settle window has passed. Not a countdown: a timer drawn
    /// on a panel is a thing to watch instead of read.
    @State private var answerable = false

    /// What wakes the buttons up.
    ///
    /// A run-loop timer for the reason `SitePermissionSheet` uses one: if
    /// whatever wakes them never fires, this panel has dead buttons on it
    /// forever, and a `Timer` on the main run loop is driven by the same thing
    /// that draws the sheet — so the offscreen harness can watch it happen, and
    /// a wake-up nobody has seen is a wake-up nobody should trust.
    @State private var settle = Timer
        .publish(every: Double(promptSettleMs()) / 1000, on: .main, in: .common)
        .autoconnect()

    /// Sizes that belong to this one sheet rather than to the whole UI, so they
    /// are named here instead of pretending to be design tokens.
    private enum Metrics {
        /// The same width as `SitePermissionSheet`. One question, one answer,
        /// no list — and a page's dialog sitting at a different width from the
        /// camera's would read as a different product.
        static let width: CGFloat = 420
        /// The glyph, beside the sentence rather than above it. The same size
        /// and column as the camera sheet's, so the two stack identically.
        static let mark: CGFloat = 30
        static let markColumn: CGFloat = 36
        /// The height of the field a `prompt()` is answered in. Taller than the
        /// find bar's 20, which is sized to a 38pt strip; this one sits in a
        /// panel and is the only thing on it you type into.
        static let fieldHeight: CGFloat = 24
    }

    init(dialog: PageDialog, onAnswer: @escaping (PageDialogAnswer, Bool) -> Void) {
        self.dialog = dialog
        self.onAnswer = onAnswer
        _typed = State(initialValue: Self.defaultText(of: dialog.kind))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            question
            Divider().hairline()
            footer
        }
        .frame(width: Metrics.width)
        .background(.regularMaterial)
        .onReceive(settle) { _ in answerable = true }
    }

    // MARK: - What the page said

    private var question: some View {
        HStack(alignment: .top, spacing: Design.Space.snug) {
            // Grey, not a status colour. On the camera sheet the glyph is red
            // because a live camera is a measured cost; here the browser has no
            // claim to make at all — the page might be saying "saved" or
            // "delete everything", and painting a colour over words we have not
            // read is ranking them on a scale nobody measured (ADR-0018).
            Image(systemName: symbol)
                .font(.system(size: Metrics.mark))
                .foregroundStyle(.secondary)
                .frame(width: Metrics.markColumn)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Design.Space.tight) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)

                identity

                SiteWords(dialog: dialog)

                if case .prompt = dialog.kind {
                    reply
                }
            }
        }
        .padding(Design.Space.loose)
    }

    /// The line a spoof would have to get past, so it is always there.
    ///
    /// Verbatim, in mono, under the sentence rather than inside it — the same
    /// shape the camera sheet uses. The scheme is part of it: `http://` and
    /// `https://` are different sites, and a line that said only the host would
    /// hide which one is talking.
    @ViewBuilder
    private var identity: some View {
        switch dialog.speaker {
        case let .site(origin, _):
            Text(origin)
                .font(Design.Text.mono)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        case let .extension(name, truncated):
            ExtensionName(name: name, truncated: truncated)
        case let .nameless(note):
            // Prose rather than mono, because it is a sentence and not an
            // address. The line is never blank: a panel whose identity line is
            // sometimes simply absent has a blank a spoof can stand in.
            Text(note)
                .font(Design.Text.label)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The field a `prompt()` is answered in.
    ///
    /// `CommandBarField` rather than a SwiftUI `TextField`, for the reason
    /// ADR-0013 gives: a field that opens has the cursor in it and its contents
    /// selected, and this one opens with the page's suggested text in it —
    /// which typing should replace. It draws no chrome of its own, so the
    /// recess around it is this sheet's.
    private var reply: some View {
        CommandBarField(
            text: $typed,
            fontSize: Design.Text.FieldSize.strip,
            placeholder: "",
            onSubmit: { accept() },
            onCancel: { answer(.cancelled) },
            // Nothing to walk. The field is one line and there is no list.
            onMove: { _ in }
        )
        .frame(height: Metrics.fieldHeight)
        .padding(.horizontal, Design.Space.tight)
        .background(
            Design.Surface.recessed,
            in: RoundedRectangle(cornerRadius: Design.Radius.small)
        )
        // **The edge is what makes this a field and not a second quotation.**
        // Rendered without it, the recess under the page's words and the recess
        // under the answer were the same fill at the same radius directly above
        // each other, and the two read as one two-line block — so what somebody
        // types looked like something the site said. Found by looking; no
        // assertion would have caught it.
        .overlay(
            RoundedRectangle(cornerRadius: Design.Radius.small)
                .strokeBorder(Design.Palette.rule, lineWidth: Design.Stroke.hairline)
        )
        .accessibilityLabel("Your answer")
    }

    // MARK: - What you say back

    private var footer: some View {
        VStack(alignment: .leading, spacing: Design.Space.snug) {
            if dialog.offersSilence {
                stopAsking
            }

            HStack(spacing: Design.Space.snug) {
                Spacer(minLength: Design.Space.snug)

                // **Live from the first frame, unlike the camera sheet's, and
                // unlike OK.** The settle window is a defence against a
                // keystroke already in flight *committing* something. Cancel
                // commits nothing: it is the same answer a closing tab, a
                // silenced page and a crashed window all give. Gating it would
                // make Escape and the button beside it disagree for half a
                // second, and one of them would have to win by accident.
                if hasCancel {
                    Button("Cancel") { answer(.cancelled) }
                        .keyboardShortcut(.cancelAction)
                }

                Button("OK") { accept() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!answerable)
            }
            .motion(.subtle, value: answerable)
        }
        .padding(Design.Space.loose)
        // Escape, and any other way the panel goes away without a button being
        // pressed. An `alert()` has no Cancel button to carry `.cancelAction`,
        // so this is the only way out of one — and it is deliberately not gated
        // on the settle window: whatever happens to the timer there is always a
        // way out, and the way out is the neutral answer.
        .onExitCommand { answer(.cancelled) }
    }

    /// The way out of a page that will not stop.
    ///
    /// Offered from the second interruption, which is the core's decision. What
    /// it does is stated under it rather than left to be discovered, because a
    /// control that quietly starts answering for you is the defect this whole
    /// change exists to end — the difference is that this one was asked for.
    private var stopAsking: some View {
        VStack(alignment: .leading, spacing: Design.Space.line) {
            Toggle("Stop this page opening more messages", isOn: $silence)
                .toggleStyle(.checkbox)

            Text("It carries on running. Anything else it asks is answered as if you "
                + "pressed Cancel, until this tab goes somewhere else.")
                .font(Design.Text.label)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - The four shapes

    /// The browser's own sentence, naming who is talking.
    ///
    /// Copy, so it is the shell's (ADR-0053) — but the *name* in it is the
    /// core's canonical spelling, so an internationalised host arrives as
    /// punycode and cannot be drawn as somebody else.
    /// **No extension's own string ever reaches this.** A host is a fact the
    /// browser derived from an address it fetched, so it can stand in the
    /// browser's own sentence; an extension's name is a string the extension
    /// wrote about itself, and a package calling itself `google.com` would
    /// otherwise get "google.com is asking" in our type at our weight
    /// (ADR-0098). What an extension gets here is a word the browser owns, and
    /// its name is on the identity line below, where it is visibly a quotation.
    private var title: String {
        let who: String
        switch dialog.speaker {
        case let .site(_, host): who = host
        case .extension: who = "An extension"
        case .nameless: who = "This page"
        }
        switch dialog.kind {
        case .alert: return "\(who) says"
        case .confirm: return "\(who) is asking"
        case .prompt: return "\(who) wants an answer"
        // Never drawn by this sheet; the file panel is the system's.
        case .chooseFiles: return "\(who) wants a file"
        }
    }

    /// Three bubbles, on purpose. These three panels are one family and the
    /// glyph is where that reads before a word is: a speech bubble that is
    /// saying something, asking something, or waiting for something back.
    ///
    /// Grey and decorative, like `ExtensionConsentSheet`'s puzzle piece and
    /// unlike `SitePermissionSheet`'s red camera — that one is a measured cost
    /// and this one is the browser having no claim to make about words it has
    /// not read (ADR-0018).
    private var symbol: String {
        // The puzzle piece outranks the bubble, and only here. The glyph is the
        // fastest read on the panel — it lands before the title does — and
        // "this is not a web page" is the fact somebody most needs first when
        // the words came from something they installed. It is
        // `ExtensionConsentSheet`'s glyph, so the two panels an extension can
        // put in front of you are recognisably about the same thing.
        if case .extension = dialog.speaker { return "puzzlepiece.extension.fill" }
        switch dialog.kind {
        case .alert: return "bubble.left.fill"
        case .confirm: return "questionmark.bubble.fill"
        case .prompt: return "text.bubble.fill"
        // Never drawn here; the file panel is the system's.
        case .chooseFiles: return "doc.fill"
        }
    }

    /// An `alert()` has one thing to do, and per DESIGN.md a surface with one
    /// action gives it Return and nothing else. A second button reading Cancel
    /// beside it would offer a choice the page never asked and cannot hear.
    private var hasCancel: Bool {
        switch dialog.kind {
        case .alert: false
        case .confirm, .prompt, .chooseFiles: true
        }
    }

    private static func defaultText(of kind: PageDialogKind) -> String {
        switch kind {
        case let .prompt(defaultText): defaultText
        case .alert, .confirm, .chooseFiles: ""
        }
    }

    /// What OK means, which is different for each shape and is decided once.
    ///
    /// Gated on the settle window here as well as on the buttons, because
    /// Return inside the `prompt()` field reaches this without going through
    /// one. The core ignores an early answer either way — that is the actual
    /// guarantee — and a shell that let the keystroke through would leave the
    /// two disagreeing about what the half second is for.
    private func accept() {
        guard answerable else { return }
        switch dialog.kind {
        case .prompt: answer(.typed(text: typed))
        case .alert, .confirm, .chooseFiles: answer(.accepted)
        }
    }

    private func answer(_ value: PageDialogAnswer) {
        onAnswer(value, silence)
    }
}
