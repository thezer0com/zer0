import SwiftUI
import Zer0Core

/// A model's reply, set as prose.
///
/// The reply arrives as Markdown and the core reads it (ADR-0071): this asks
/// for `[ProseBlock]` and draws them. Nothing here decides what a `**` means or
/// where a list item ends — those are the same on every platform, so they are
/// not the shell's to answer. What *is* decided here is everything you can see:
/// the type ladder, the rhythm between blocks, how far a nested item steps in,
/// what a code block sits on, and what a click on a link does.
///
/// **Blocks, not a bubble.** `MessageRow` already says who is speaking with a
/// rail and a mark, so this is a column of text at full width — a page, set to
/// be read for thirty seconds, rather than a form.
///
/// ## Three things this view is measured on
///
/// **It runs on every delta.** A reply arrives as dozens of them and this body
/// is re-evaluated for every one, for every message in the transcript. The
/// parse is behind [`ProseReading`], a one-entry memo on the exact text: a message
/// that is not the one arriving crosses the FFI once and never again, which is
/// what keeps a long conversation from re-reading itself thirty times a second
/// while the last answer streams.
///
/// **It must not strobe.** Half-written Markdown is the normal case, not the
/// error case, and the core answers it: an unterminated fence is a code block
/// from the moment it opens rather than snapping into one when the closing
/// fence lands, and a lone `**` is two characters until its closer arrives.
/// Nothing here animates for the same reason — a curve bound to text that
/// changes thirty times a second is a paragraph that never stops moving.
///
/// **Selection is per block, and that is a limit rather than a choice.** See
/// the note on `body`.
struct ChatProse: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    /// Optional so the view can be rendered on its own — a harness has no
    /// browser. In the app there is always one.
    @Environment(BrowserModel.self) private var browser: BrowserModel?
    @State private var reading = ProseReading()

    /// Sizes that belong to this one view rather than to the whole UI, so they
    /// are named here instead of pretending to be design tokens — the pattern
    /// `CommandBar.Metrics` sets.
    private enum Metrics {
        /// The column a list marker sits in, right-aligned so `9.` and `10.`
        /// put their full stops on the same vertical and the words after them
        /// start in the same place.
        static let markerColumn: CGFloat = 18
        /// Between a marker and the words it introduces.
        static let markerGap: CGFloat = Design.Space.tight
        /// One level of nesting: exactly the marker column and its gap, so a
        /// nested item's marker lands where its parent's words start. Anything
        /// else and a two-level list reads as two lists.
        static let step: CGFloat = markerColumn + markerGap
        /// How far in anything is allowed to be pushed, in levels.
        ///
        /// The core reports the true depth and does not clamp it, because how
        /// much room there is is a question about a column of a particular
        /// width and the core does not know one. This is that answer: past four
        /// steps a reply would be writing in a gutter, and a model that nested
        /// six deep has said everything it is going to say about structure by
        /// the fourth.
        static let deepest: UInt32 = 4

        /// **`#` and `##`.** One step over the body, not three. A reply is a
        /// passage inside a page rather than a page — it must not open louder
        /// than the empty state of the pane it is drawn in, which is what
        /// `Design.Text.emptyTitle` is for and why this is deliberately below
        /// it. `.title3` is 15pt against the body's 12.
        static let majorHeading = Font.system(.title3).weight(.semibold)
        /// **`###` and everything under it.** Models reach for `##` and `###`
        /// interchangeably, so a six-step ladder would be asserting a structure
        /// the source does not have (ADR-0018). Two steps is what can be read
        /// off a reply honestly: this one is body size carrying weight.
        static let minorHeading = Font.system(.headline)
    }

    /// **On selection, plainly: it is per block, not continuous.**
    ///
    /// `.textSelection(.enabled)` makes each `Text` its own selectable region
    /// and SwiftUI publishes no way to join them, so dragging from a paragraph
    /// through a list and into a code block selects inside whichever one the
    /// drag started in and stops at its edge. Within a block — a whole
    /// paragraph, a whole code listing — selection is ordinary and complete,
    /// which is what makes a fence worth copying.
    ///
    /// This is stated rather than worked around because the two workarounds are
    /// both worse than the limit. Collapsing the reply into one `Text` would
    /// take away the code panel, the list indentation and the rails, which is
    /// the entire job. Hosting an `NSTextView` would buy continuous selection
    /// and give up the design system, Dynamic Type and both themes.
    ///
    /// If a reply needs to be copied whole, the thing to build is a copy
    /// action, not a cleverer selection.
    var body: some View {
        let blocks = reading.blocks(of: text)

        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                row(block, after: index == 0 ? nil : blocks[index - 1])
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { url in
            // A browser never hands a web address to another browser. With no
            // model there is nothing that could open it, and pretending
            // otherwise would launch Safari from inside zer0.
            guard let browser else { return .discarded }
            ChatProse.open(url, in: browser)
            return .handled
        })
    }

    /// One block, with its rails and its share of the rhythm.
    ///
    /// The quote rails are outside the top gap on purpose: put the gap outside
    /// and the rail stops at each block's edge, so a three-paragraph quote
    /// draws three short bars with holes between them instead of one line down
    /// the side of the whole thing.
    private func row(_ block: ProseBlock, after previous: ProseBlock?) -> some View {
        HStack(alignment: .top, spacing: Design.Space.snug) {
            ForEach(0 ..< Int(min(block.quoted, Metrics.deepest)), id: \.self) { _ in
                Rectangle()
                    .fill(.tertiary)
                    .frame(width: Design.Stroke.insertion)
                    .frame(maxHeight: .infinity)
            }

            // The column, and it has to be a column rather than the bare block:
            // `Divider` is the one view in SwiftUI that reads its own container
            // to decide which way to run, and a rule that was a direct child of
            // this `HStack` came out as a two-point vertical tick against the
            // left margin. Found by looking; no assertion would have said so.
            VStack(alignment: .leading, spacing: 0) {
                draw(block)
            }
            .padding(.top, previous.map { gap(after: $0, before: block) } ?? 0)
            .padding(.leading, CGFloat(min(block.indent, Metrics.deepest)) * Metrics.step)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Quoted text is somebody else's, and reads as an aside rather than as
        // the answer.
        .foregroundStyle(block.quoted > 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
    }

    @ViewBuilder
    private func draw(_ block: ProseBlock) -> some View {
        switch block.kind {
        case let .paragraph(runs):
            prose(runs, base: Design.Text.detail)

        case let .heading(level, runs):
            prose(runs, base: level <= 2 ? Metrics.majorHeading : Metrics.minorHeading)

        case let .item(number, runs):
            HStack(alignment: .firstTextBaseline, spacing: Metrics.markerGap) {
                Text(marker(number))
                    .font(Design.Text.detail)
                    // Monospaced digits so a list of ten does not shift its
                    // words left when it reaches double figures.
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    // A minimum rather than a width, and `fixedSize` rather
                    // than `lineLimit`. At a fixed 18pt `10.` did not truncate,
                    // it *wrapped*: the full stop went to a second line and sat
                    // under the list as a stray dot. A marker wide enough to
                    // overrun its column now pushes its own row's words across
                    // by a couple of points, which is visible and true, rather
                    // than losing a character, which is neither.
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: Metrics.markerColumn, alignment: .trailing)
                prose(runs, base: Design.Text.detail)
            }

        case let .code(language, source):
            CodeListing(language: language, source: source)

        case .rule:
            Divider().hairline()
        }
    }

    private func prose(_ runs: [ProseRun], base: Font) -> some View {
        Text(attributed(runs, base: base))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The runs of one block as a single `AttributedString`, which is what
    /// makes the block one `Text` and therefore one selectable, one wrappable
    /// paragraph rather than a row of words that break wherever the runs did.
    private func attributed(_ runs: [ProseRun], base: Font) -> AttributedString {
        var out = AttributedString()
        for run in runs {
            var piece = AttributedString(run.text)

            var font = run.code ? base.monospaced() : base
            if run.bold { font = font.bold() }
            if run.italic { font = font.italic() }
            piece.font = font

            if run.code { piece.backgroundColor = Design.Palette.recessed }
            if run.struck { piece.strikethroughStyle = .single }
            if let link = run.link, let url = URL(string: link) {
                piece.link = url
                // Underlined as well as tinted: a link that is only a colour is
                // a link somebody with deuteranopia cannot find in a paragraph.
                piece.foregroundColor = Design.Palette.accent
                piece.underlineStyle = .single
            }

            out.append(piece)
        }
        return out
    }

    private func marker(_ number: UInt32?) -> String {
        guard let number else { return "•" }
        return "\(number)."
    }

    /// The rhythm. Three distances, and each one is a claim about how closely
    /// two blocks belong together.
    private func gap(after previous: ProseBlock, before block: ProseBlock) -> CGFloat {
        if let before = previous.listKind, let after = block.listKind, before == after {
            // Rows of one list are one thing, and a paragraph's worth of air
            // between them turns a list into a stack of paragraphs. Bullets
            // running straight into numbers are two lists, though, and closing
            // them up to 4pt makes seven rows read as one.
            return Design.Space.hair
        }
        if block.opensASection || previous.opensASection {
            return Design.Space.regular
        }
        return Design.Space.snug
    }

    /// What a click on a link in a reply does.
    ///
    /// A free function rather than a closure so it can be asked the question
    /// without a window: a link that leaves for the system browser is a defect
    /// nothing on screen would show.
    static func open(_ url: URL, in browser: BrowserModel) {
        browser.send(.openTab(space: nil, url: url.absoluteString, parent: nil))
    }
}

// MARK: - A fenced block

/// Code, on the recessed surface a value gets, with its language named when the
/// fence named one.
///
/// **It wraps rather than scrolling.** A horizontal scroll view inside a
/// transcript that already scrolls hides the end of a long line behind a
/// gesture nobody is told about, and a line of an answer you cannot see is
/// worse than one that wrapped.
private struct CodeListing: View {
    let language: String?
    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.tight) {
            if let language {
                // Said only when the fence said it. Nothing here guesses a
                // language from the contents (ADR-0018).
                Text(language)
                    .font(Design.Text.mono)
                    .foregroundStyle(.tertiary)
            }
            Text(source)
                .font(ChatProse.codeFont)
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

extension ChatProse {
    /// Code, at the size of the prose around it rather than at
    /// `Design.Text.mono`. That token is for a *value* — a permission key, a
    /// version number — and is `.caption2` because those are read once and
    /// compared. A fenced block is read like prose, so it belongs in the
    /// column's rhythm and takes the column's size.
    ///
    /// Here rather than in `Metrics` because `CodeListing` is its own view — a
    /// fence is the part of a reply most worth looking at on its own.
    static let codeFont = Design.Text.detail.monospaced()
}

// MARK: - Reading the same reply twice

/// The blocks of the reply this view last drew.
///
/// One entry, keyed on the exact text. That is the whole cache and it is enough:
/// a transcript re-evaluates every message's body whenever any one of them
/// changes, so without this a twenty-message conversation would re-read all
/// twenty replies across the FFI on every delta of the twenty-first. With it,
/// exactly one reply is read per delta — the one that changed.
///
/// It deliberately does **not** try to be clever about a growing string. The
/// core reads a 7 KB reply in about 140µs in release and 1.6ms in debug, so the
/// one message that really is arriving costs a fraction of a frame; the cost
/// that mattered was the other nineteen.
@MainActor
final class ProseReading {
    private var source: String?
    private var parsed: [ProseBlock] = []

    /// How many times the reply behind this view has really been read.
    ///
    /// Here for the test, and the test is the point: a memo that has quietly
    /// stopped memoising looks exactly like one that works — same pixels, same
    /// words, and a transcript doing *n* times the work per keystroke of a
    /// reply. There is nothing on screen that would say so.
    private(set) var reads = 0

    func blocks(of text: String) -> [ProseBlock] {
        if source == text { return parsed }
        reads += 1
        parsed = proseBlocks(text: text)
        source = text
        return parsed
    }
}

// MARK: - Reading a block

private extension ProseBlock {
    /// Whether this block is a list row, and if so whether it is a numbered
    /// one. `nil` when it is not a row at all.
    var listKind: Bool? {
        switch kind {
        case let .item(number, _): number != nil
        case .paragraph, .heading, .code, .rule: nil
        }
    }

    /// Whether this block starts something rather than continuing it, which is
    /// what earns the wider gap.
    var opensASection: Bool {
        switch kind {
        case .heading, .rule: true
        case .paragraph, .item, .code: false
        }
    }
}
